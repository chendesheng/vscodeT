// Port of `src/vs/workbench/contrib/scm/common/quickDiffService.ts`.
//
// Terminal adaptations:
// - The upstream promise aggregation is a callback-backed, cancellable query;
//   synchronous native providers resolve their slots immediately.
// - The hidden-provider set is persisted through the in-memory storage service
//   under the upstream key, serialized as a JSON array.
// - Provider matching and selectors use the actual text-model std.Uri.
const std = @import("std");
const Allocator = std.mem.Allocator;

const quick_diff = @import("./quickDiff.zig");
const language_selector = @import("../../../../editor/common/languageSelector.zig");
const storage = @import("../../../../platform/storage/common/storage.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const lifecycle = @import("../../../../base/common/lifecycle.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const QuickDiffProvider = quick_diff.QuickDiffProvider;
pub const QuickDiff = quick_diff.QuickDiff;
pub const QuickDiffProviderKind = quick_diff.QuickDiffProviderKind;
pub const IQuickDiffService = quick_diff.IQuickDiffService;
pub const IDisposable = lifecycle.IDisposable;
pub const InMemoryStorageService = storage.InMemoryStorageService;
pub const StorageScope = storage.StorageScope;
pub const StorageTarget = storage.StorageTarget;

pub const STORAGE_KEY = "workbench.scm.quickDiffProviders.hidden";

pub const QuickDiffService = struct {
    allocator: Allocator,
    providers_list: std.array_list.Managed(*QuickDiffProvider),
    sorted_providers: std.array_list.Managed(*QuickDiffProvider),
    registrations: std.array_list.Managed(*Registration),
    hidden: std.StringHashMap(void),
    storage: ?*InMemoryStorageService = null,
    on_did_change_providers: Emitter(void),

    pub fn init(allocator: Allocator, storage_service: ?*InMemoryStorageService) QuickDiffService {
        var self = QuickDiffService{
            .allocator = allocator,
            .providers_list = .init(allocator),
            .sorted_providers = .init(allocator),
            .registrations = .init(allocator),
            .hidden = std.StringHashMap(void).init(allocator),
            .storage = storage_service,
            .on_did_change_providers = Emitter(void).init(allocator),
        };
        self.loadState();
        return self;
    }

    pub fn deinit(self: *QuickDiffService) void {
        var iterator = self.hidden.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.hidden.deinit();
        for (self.registrations.items) |registration| self.allocator.destroy(registration);
        self.registrations.deinit();
        self.providers_list.deinit();
        self.sorted_providers.deinit();
        self.on_did_change_providers.deinit();
        self.* = undefined;
    }

    /// Providers sorted by kind: primary before secondary before contributed.
    pub fn providers(self: *QuickDiffService, allocator: Allocator) ![]*QuickDiffProvider {
        return allocator.dupe(*QuickDiffProvider, self.sorted_providers.items);
    }

    fn providerLessThan(_: void, a: *QuickDiffProvider, b: *QuickDiffProvider) bool {
        return providerKindRank(a.kind) < providerKindRank(b.kind);
    }

    fn providerKindRank(kind: QuickDiffProviderKind) u8 {
        return switch (kind) {
            .primary => 0,
            .secondary => 1,
            .contributed => 2,
        };
    }

    const Registration = struct {
        owner: *QuickDiffService,
        provider: *QuickDiffProvider,

        fn dispose(self: *Registration) void {
            const owner = self.owner;
            const provider = self.provider;
            for (owner.registrations.items, 0..) |entry, index| {
                if (entry == self) {
                    _ = owner.registrations.orderedRemove(index);
                    break;
                }
            }
            owner.allocator.destroy(self);
            owner.removeProvider(provider);
            owner.on_did_change_providers.fire({}) catch {};
        }
    };

    /// Set registration and removal follow the upstream disposable. The
    /// registration owner must dispose it before releasing the provider.
    pub fn addQuickDiffProvider(self: *QuickDiffService, provider: *QuickDiffProvider) !IDisposable {
        const present = std.mem.indexOfScalar(*QuickDiffProvider, self.providers_list.items, provider) != null;
        try self.registrations.ensureUnusedCapacity(1);
        if (!present) {
            try self.providers_list.ensureUnusedCapacity(1);
            try self.sorted_providers.ensureUnusedCapacity(1);
        }
        const registration = try self.allocator.create(Registration);
        registration.* = .{ .owner = self, .provider = provider };
        self.registrations.appendAssumeCapacity(registration);
        if (!present) {
            self.providers_list.appendAssumeCapacity(provider);
            self.sorted_providers.appendAssumeCapacity(provider);
            std.mem.sort(*QuickDiffProvider, self.sorted_providers.items, {}, providerLessThan);
        }
        self.on_did_change_providers.fire({}) catch {};
        return IDisposable.from(Registration, registration, Registration.dispose);
    }

    fn removeProvider(self: *QuickDiffService, provider: *QuickDiffProvider) void {
        if (std.mem.indexOfScalar(*QuickDiffProvider, self.providers_list.items, provider)) |index| {
            _ = self.providers_list.orderedRemove(index);
        }
        if (std.mem.indexOfScalar(*QuickDiffProvider, self.sorted_providers.items, provider)) |index| {
            _ = self.sorted_providers.orderedRemove(index);
        }
    }

    pub fn requestQuickDiffs(
        self: *QuickDiffService,
        allocator: Allocator,
        resource: std.Uri,
        language: ?[]const u8,
        is_synchronized: bool,
        listener: quick_diff.QuickDiffQueryListener,
    ) !quick_diff.QuickDiffQuery {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var candidates = std.array_list.Managed(*QuickDiffProvider).init(allocator);
        defer candidates.deinit();
        for (self.providers_list.items) |provider| {
            if (provider.root_uri) |root| {
                if (!try std_uri.isEqualOrParent(resource, root, scratch, std.mem.eql(u8, resource.scheme, "file") and (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .macos))) continue;
            }
            try candidates.append(provider);
        }
        // All surviving rooted providers are parents. Upstream sorts those by
        // kind before unrooted providers, whose registration order is retained.
        std.mem.sort(*QuickDiffProvider, candidates.items, {}, struct {
            fn lessThan(_: void, a: *QuickDiffProvider, b: *QuickDiffProvider) bool {
                if (a.root_uri == null) return false;
                if (b.root_uri == null) return true;
                return providerKindRank(a.kind) < providerKindRank(b.kind);
            }
        }.lessThan);

        const candidate = try language_selector.candidateFromUri(scratch, resource, language orelse "", is_synchronized);
        var matching: std.ArrayList(*QuickDiffProvider) = .empty;
        defer matching.deinit(allocator);
        for (candidates.items) |provider| {
            const score_value: i32 = if (provider.selector) |selector|
                language_selector.score(scratch, selector, candidate) catch 0
            else
                10;
            if (score_value > 0) try matching.append(allocator, provider);
        }
        const query = try PendingQuery.create(allocator, matching.items, listener);
        return query.start(matching.items, resource);
    }

    pub fn getQuickDiffs(self: *QuickDiffService, allocator: Allocator, resource: std.Uri, language: ?[]const u8, is_synchronized: bool) ![]QuickDiff {
        return self.interface().getQuickDiffs(allocator, resource, language, is_synchronized);
    }

    /// Equivalent of upstream Promise.allSettled. Each slot owns its
    /// provider metadata independently of the registration, so completion
    /// order and provider disposal cannot change the published ordering.
    const PendingQuery = struct {
        allocator: Allocator,
        listener: quick_diff.QuickDiffQueryListener,
        slots: []Slot,
        remaining: usize = 0,

        const Slot = struct {
            owner: *PendingQuery,
            id: ?[]u8 = null,
            label: ?[]u8 = null,
            kind: QuickDiffProviderKind = .contributed,
            original: ?quick_diff.Original = null,
            request: ?IDisposable = null,

            fn complete(context: *anyopaque, original: ?quick_diff.Original) void {
                const self: *Slot = @ptrCast(@alignCast(context));
                const owner = self.owner;
                self.request = null;
                self.original = original;
                owner.remaining -= 1;
                if (owner.remaining == 0) owner.finish();
            }

            fn deinit(self: *Slot) void {
                if (self.request) |request| request.dispose();
                if (self.original) |*original| original.deinit(self.owner.allocator);
                if (self.id) |id| self.owner.allocator.free(id);
                if (self.label) |label| self.owner.allocator.free(label);
            }
        };

        fn create(allocator: Allocator, candidates: []const *QuickDiffProvider, listener: quick_diff.QuickDiffQueryListener) !*PendingQuery {
            const self = try allocator.create(PendingQuery);
            errdefer allocator.destroy(self);
            const slots = try allocator.alloc(Slot, candidates.len);
            errdefer allocator.free(slots);
            self.* = .{ .allocator = allocator, .listener = listener, .slots = slots };
            for (slots) |*slot| slot.* = .{ .owner = self };
            errdefer for (slots) |*slot| slot.deinit();
            for (slots, candidates) |*slot, provider| {
                slot.id = try allocator.dupe(u8, provider.id);
                slot.label = try allocator.dupe(u8, provider.label);
                slot.kind = provider.kind;
            }
            return self;
        }

        fn start(self: *PendingQuery, candidates: []const *QuickDiffProvider, resource: std.Uri) !quick_diff.QuickDiffQuery {
            for (self.slots, candidates) |*slot, provider| {
                const resolution = provider.requestOriginalResource(self.allocator, resource, .{ .context = slot, .complete = Slot.complete }) catch continue;
                switch (resolution) {
                    .ready => |original| slot.original = original,
                    .pending => |request| {
                        slot.request = request;
                        self.remaining += 1;
                    },
                }
            }
            if (self.remaining != 0) return .{ .pending = IDisposable.from(PendingQuery, self, destroy) };
            defer self.destroy();
            return .{ .ready = try self.collect() };
        }

        fn collect(self: *PendingQuery) ![]QuickDiff {
            var count: usize = 0;
            for (self.slots) |slot| if (slot.original != null) {
                count += 1;
            };
            const results = try self.allocator.alloc(QuickDiff, count);
            var i: usize = 0;
            for (self.slots) |*slot| if (slot.original) |original| {
                results[i] = .{ .id = slot.id.?, .label = slot.label.?, .kind = slot.kind, .original = original };
                slot.id = null;
                slot.label = null;
                slot.original = null;
                i += 1;
            };
            return results;
        }

        fn finish(self: *PendingQuery) void {
            const listener = self.listener;
            const result: quick_diff.QuickDiffQueryResult = if (self.collect()) |values| .{ .resolved = values } else |err| .{ .failure = err };
            self.destroy();
            listener.complete(listener.context, result);
        }

        fn destroy(self: *PendingQuery) void {
            const allocator = self.allocator;
            for (self.slots) |*slot| slot.deinit();
            allocator.free(self.slots);
            allocator.destroy(self);
        }
    };

    pub fn toggleQuickDiffProviderVisibility(self: *QuickDiffService, id: []const u8) void {
        if (self.isQuickDiffProviderVisible(id)) {
            const copy = self.allocator.dupe(u8, id) catch return;
            self.hidden.put(copy, {}) catch {
                self.allocator.free(copy);
                return;
            };
        } else {
            if (self.hidden.fetchRemove(id)) |entry| self.allocator.free(entry.key);
        }
        self.saveState();
        self.on_did_change_providers.fire({}) catch {};
    }

    pub fn isQuickDiffProviderVisible(self: *const QuickDiffService, id: []const u8) bool {
        return !self.hidden.contains(id);
    }

    pub fn interface(self: *QuickDiffService) IQuickDiffService {
        return .{
            .context = self,
            .providers_fn = providersThunk,
            .add_quick_diff_provider_fn = addProviderThunk,
            .request_quick_diffs_fn = requestQuickDiffsThunk,
            .toggle_visibility_fn = toggleVisibilityThunk,
            .is_visible_fn = isVisibleThunk,
            .on_did_change_providers = &self.on_did_change_providers,
        };
    }

    fn providersThunk(context: *anyopaque) []const *QuickDiffProvider {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        return self.sorted_providers.items;
    }

    fn addProviderThunk(context: *anyopaque, provider: *QuickDiffProvider) anyerror!IDisposable {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        return self.addQuickDiffProvider(provider);
    }

    fn requestQuickDiffsThunk(
        context: *anyopaque,
        allocator: Allocator,
        resource: std.Uri,
        language: ?[]const u8,
        is_synchronized: bool,
        listener: quick_diff.QuickDiffQueryListener,
    ) anyerror!quick_diff.QuickDiffQuery {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        return self.requestQuickDiffs(allocator, resource, language, is_synchronized, listener);
    }

    fn toggleVisibilityThunk(context: *anyopaque, id: []const u8) void {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        self.toggleQuickDiffProviderVisibility(id);
    }

    fn isVisibleThunk(context: *anyopaque, id: []const u8) bool {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        return self.isQuickDiffProviderVisible(id);
    }

    fn loadState(self: *QuickDiffService) void {
        const storage_service = self.storage orelse return;
        const raw = storage_service.get(STORAGE_KEY, .profile, null) orelse return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return;
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |value| value,
            else => return,
        };
        for (array.items) |item| {
            const id = switch (item) {
                .string => |value| value,
                else => continue,
            };
            const copy = self.allocator.dupe(u8, id) catch continue;
            self.hidden.put(copy, {}) catch {
                self.allocator.free(copy);
            };
        }
    }

    fn saveState(self: *QuickDiffService) void {
        const storage_service = self.storage orelse return;
        if (self.hidden.count() == 0) {
            storage_service.remove(STORAGE_KEY, .profile);
            return;
        }
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var array = std.json.Array.init(self.allocator);
        defer array.deinit();
        var iterator = self.hidden.keyIterator();
        while (iterator.next()) |key| {
            array.append(.{ .string = key.* }) catch return;
        }
        std.json.Stringify.value(std.json.Value{ .array = array }, .{}, &out.writer) catch return;
        const value = out.toOwnedSlice() catch return;
        defer self.allocator.free(value);
        storage_service.store(STORAGE_KEY, .{ .string = value }, .profile, .user) catch {};
    }
};

test "quickDiffService: provider ordering, selector and visibility storage" {
    const allocator = std.testing.allocator;
    var storage_service = InMemoryStorageService.init(allocator);
    defer storage_service.deinit();
    var service = QuickDiffService.init(allocator, &storage_service);
    defer service.deinit();

    var contributed = TestProvider{};
    contributed.init("contributed", .contributed);
    contributed.base.root_uri = try std.Uri.parse("file:///repo");
    defer contributed.deinit();
    var primary = TestProvider{};
    primary.init("primary", .primary);
    primary.base.root_uri = try std.Uri.parse("file:///repo");
    defer primary.deinit();

    const contributed_disposable = try service.addQuickDiffProvider(&contributed.base);
    defer contributed_disposable.dispose();
    const primary_disposable = try service.addQuickDiffProvider(&primary.base);
    defer primary_disposable.dispose();

    const ordered = try service.providers(allocator);
    defer allocator.free(ordered);
    try std.testing.expectEqualStrings("primary", ordered[0].id);

    const diffs = try service.getQuickDiffs(allocator, try std.Uri.parse("file:///repo/a.zig"), "zig", true);
    defer {
        for (diffs) |*entry| entry.deinit(allocator);
        allocator.free(diffs);
    }
    try std.testing.expectEqual(@as(usize, 2), diffs.len);
    try std.testing.expectEqualStrings("primary", diffs[0].id);
    try std.testing.expectEqualStrings("HEAD", diffs[0].original.ref_label);

    try std.testing.expect(service.isQuickDiffProviderVisible("primary"));
    service.toggleQuickDiffProviderVisibility("primary");
    try std.testing.expect(!service.isQuickDiffProviderVisible("primary"));
    try std.testing.expectEqualStrings("[\"primary\"]", storage_service.get("workbench.scm.quickDiffProviders.hidden", .profile, null).?);

    // A new service over the same storage restores the hidden set.
    var restored = QuickDiffService.init(allocator, &storage_service);
    defer restored.deinit();
    try std.testing.expect(!restored.isQuickDiffProviderVisible("primary"));

    service.toggleQuickDiffProviderVisibility("primary");
    try std.testing.expect(storage_service.get("workbench.scm.quickDiffProviders.hidden", .profile, null) == null);
}

test "quickDiffService: providers are filtered by root and language" {
    const allocator = std.testing.allocator;
    var service = QuickDiffService.init(allocator, null);
    defer service.deinit();

    var provider = TestProvider{};
    provider.init("git", .primary);
    defer provider.deinit();
    provider.base.root_uri = try std.Uri.parse("file:///repo");
    provider.base.selector = .{ .language = "zig" };
    const disposable = try service.addQuickDiffProvider(&provider.base);
    defer disposable.dispose();

    const outside = try service.getQuickDiffs(allocator, try std.Uri.parse("file:///other/a.zig"), "zig", true);
    defer allocator.free(outside);
    try std.testing.expectEqual(@as(usize, 0), outside.len);

    const matching = try service.getQuickDiffs(allocator, try std.Uri.parse("file:///repo/a.zig"), "zig", true);
    defer allocator.free(matching);
    try std.testing.expectEqual(@as(usize, 1), matching.len);
    matching[0].deinit(allocator);

    const wrong_language = try service.getQuickDiffs(allocator, try std.Uri.parse("file:///repo/a.txt"), "plaintext", true);
    defer allocator.free(wrong_language);
    try std.testing.expectEqual(@as(usize, 0), wrong_language.len);
}

test "quickDiffService: missing originals are skipped" {
    const allocator = std.testing.allocator;
    var service = QuickDiffService.init(allocator, null);
    defer service.deinit();

    var provider = TestProvider{};
    provider.init("git", .primary);
    defer provider.deinit();
    provider.return_original = false;
    const disposable = try service.addQuickDiffProvider(&provider.base);
    defer disposable.dispose();

    const diffs = try service.getQuickDiffs(allocator, try std.Uri.parse("file:///repo/a.zig"), "zig", true);
    defer allocator.free(diffs);
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

const TestProvider = struct {
    base: QuickDiffProvider = undefined,
    root: ?[]const u8 = null,
    return_original: bool = true,

    fn init(self: *TestProvider, id: []const u8, kind: QuickDiffProviderKind) void {
        self.base = .{
            .context = self,
            .id = id,
            .label = id,
            .kind = kind,
            .get_original_fn = getOriginal,
        };
    }

    fn deinit(_: *TestProvider) void {}

    fn getOriginal(context: *anyopaque, allocator: Allocator, resource: std.Uri) anyerror!?quick_diff.Original {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        _ = resource;
        if (!self.return_original) return null;
        const original_uri = try allocator.dupe(u8, "test-quickdiff:/original");
        errdefer allocator.free(original_uri);
        return .{ .resource_uri = original_uri, .ref_label = try allocator.dupe(u8, "HEAD") };
    }
};

test "quickDiffService: resource scheme, authority, and rooted ordering follow upstream" {
    const a = std.testing.allocator;
    var service = QuickDiffService.init(a, null);
    defer service.deinit();
    var rootless = TestProvider{};
    rootless.init("first", .contributed);
    var rootless_primary = TestProvider{};
    rootless_primary.init("second", .primary);
    var nested = TestProvider{};
    nested.init("nested", .secondary);
    nested.base.root_uri = try std.Uri.parse("remote://host/repo/nested");
    var primary = TestProvider{};
    primary.init("parent", .primary);
    primary.base.root_uri = try std.Uri.parse("remote://host/repo");
    primary.base.selector = .{ .filter = .{ .scheme = "remote" } };
    var wrong_authority = TestProvider{};
    wrong_authority.init("other", .primary);
    wrong_authority.base.root_uri = try std.Uri.parse("remote://elsewhere/repo");
    const rootless_registration = try service.addQuickDiffProvider(&rootless.base);
    defer rootless_registration.dispose();
    const rootless_primary_registration = try service.addQuickDiffProvider(&rootless_primary.base);
    defer rootless_primary_registration.dispose();
    const nested_registration = try service.addQuickDiffProvider(&nested.base);
    defer nested_registration.dispose();
    const primary_registration = try service.addQuickDiffProvider(&primary.base);
    defer primary_registration.dispose();
    const wrong_authority_registration = try service.addQuickDiffProvider(&wrong_authority.base);
    defer wrong_authority_registration.dispose();

    const matching = try service.getQuickDiffs(a, try std.Uri.parse("remote://host/repo/nested/a%23b.txt"), "plaintext", true);
    defer {
        for (matching) |*entry| entry.deinit(a);
        a.free(matching);
    }
    try std.testing.expectEqual(@as(usize, 4), matching.len);
    try std.testing.expectEqualStrings("parent", matching[0].id);
    try std.testing.expectEqualStrings("nested", matching[1].id);
    try std.testing.expectEqualStrings("first", matching[2].id);
    try std.testing.expectEqualStrings("second", matching[3].id);

    const file = try service.getQuickDiffs(a, try std.Uri.parse("file:///repo/nested/a%23b.txt"), "plaintext", true);
    defer {
        for (file) |*entry| entry.deinit(a);
        a.free(file);
    }
    try std.testing.expectEqual(@as(usize, 2), file.len);
    try std.testing.expectEqualStrings("first", file[0].id);
    try std.testing.expectEqualStrings("second", file[1].id);
}

test "quickDiffService: a disposed registration removes its provider and fires change" {
    const a = std.testing.allocator;
    var service = QuickDiffService.init(a, null);
    defer service.deinit();
    var events: usize = 0;
    const Listener = struct {
        fn changed(_: void, count: *usize) !void {
            count.* += 1;
        }
    };
    _ = try service.on_did_change_providers.listen(&events, Listener.changed);
    var one = TestProvider{};
    one.init("one", .contributed);
    var two = TestProvider{};
    two.init("two", .primary);
    const first = try service.interface().addQuickDiffProvider(&one.base);
    const second = try service.interface().addQuickDiffProvider(&two.base);
    try std.testing.expectEqual(@as(usize, 2), events);
    const providers = service.interface().providers();
    try std.testing.expectEqual(@as(usize, 2), providers.len);
    try std.testing.expectEqual(&two.base, providers[0]);
    try std.testing.expectEqual(&one.base, providers[1]);
    first.dispose();
    try std.testing.expectEqual(@as(usize, 3), events);
    try std.testing.expectEqual(@as(usize, 1), service.interface().providers().len);
    second.dispose();
    try std.testing.expectEqual(@as(usize, 4), events);
    try std.testing.expectEqual(@as(usize, 0), service.interface().providers().len);
}

test "quickDiffService: asynchronous originals settle in provider order and cancellation detaches" {
    const a = std.testing.allocator;
    const Deferred = struct {
        provider: QuickDiffProvider,
        listener: ?quick_diff.OriginalListener = null,
        allocator: ?Allocator = null,
        cancellations: usize = 0,

        fn init(self: *@This(), id: []const u8, kind: QuickDiffProviderKind) void {
            self.* = .{ .provider = .{ .context = self, .id = id, .label = id, .kind = kind, .request_original_fn = request } };
        }

        fn request(context: *anyopaque, allocator: Allocator, _: std.Uri, listener: quick_diff.OriginalListener) !quick_diff.OriginalResolution {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.allocator = allocator;
            self.listener = listener;
            return .{ .pending = IDisposable.from(@This(), self, cancel) };
        }

        fn cancel(self: *@This()) void {
            self.listener = null;
            self.cancellations += 1;
        }

        fn complete(self: *@This(), uri: []const u8) !void {
            const listener = self.listener orelse return error.RequestCanceled;
            const allocator = self.allocator.?;
            const label = try allocator.dupe(u8, "Original");
            errdefer allocator.free(label);
            const original = try allocator.dupe(u8, uri);
            self.listener = null;
            listener.complete(listener.context, .{ .ref_label = label, .resource_uri = original });
        }
    };
    const Result = struct {
        value: ?quick_diff.QuickDiffQueryResult = null,
        fn complete(context: *anyopaque, result: quick_diff.QuickDiffQueryResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.value = result;
        }
        fn listener(self: *@This()) quick_diff.QuickDiffQueryListener {
            return .{ .context = self, .complete = complete };
        }
    };
    var service = QuickDiffService.init(a, null);
    defer service.deinit();
    var primary: Deferred = undefined;
    primary.init("primary", .primary);
    primary.provider.root_uri = try std.Uri.parse("file:///repo");
    var custom: Deferred = undefined;
    custom.init("custom", .contributed);
    custom.provider.root_uri = try std.Uri.parse("file:///repo");
    const custom_registration = try service.addQuickDiffProvider(&custom.provider);
    defer custom_registration.dispose();
    const primary_registration = try service.addQuickDiffProvider(&primary.provider);
    defer primary_registration.dispose();
    const resource = try std.Uri.parse("file:///repo/a.txt");
    var result: Result = .{};
    const query = try service.requestQuickDiffs(a, resource, "plaintext", true, result.listener());
    try std.testing.expect(query == .pending);
    try custom.complete("git:/custom");
    try std.testing.expect(result.value == null);
    // The request owns a copy of the descriptor even if its owner changes.
    primary.provider.label = "Changed after request";
    try primary.complete("git:/primary");
    const diffs = switch (result.value orelse return error.TestExpectedResult) {
        .resolved => |value| value,
        .failure => |err| return err,
    };
    defer {
        for (diffs) |*diff| diff.deinit(a);
        a.free(diffs);
    }
    try std.testing.expectEqual(@as(usize, 2), diffs.len);
    try std.testing.expectEqualStrings("primary", diffs[0].id);
    try std.testing.expectEqualStrings("primary", diffs[0].label);
    try std.testing.expectEqualStrings("custom", diffs[1].id);

    result.value = null;
    const canceled = try service.requestQuickDiffs(a, resource, "plaintext", true, result.listener());
    try std.testing.expect(canceled == .pending);
    canceled.pending.dispose();
    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 1), primary.cancellations);
    try std.testing.expectEqual(@as(usize, 1), custom.cancellations);
    try std.testing.expectError(error.RequestCanceled, custom.complete("git:/late"));
}

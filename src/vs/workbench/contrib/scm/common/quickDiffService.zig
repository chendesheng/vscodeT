// Port of `src/vs/workbench/contrib/scm/common/quickDiffService.ts`.
//
// Terminal adaptations:
// - `Promise<QuickDiff[]>` becomes a synchronous `![]QuickDiff`; the git CLI
//   delegate is local and bounded by its command deadline.
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
    hidden: std.StringHashMap(void),
    storage: ?*InMemoryStorageService = null,
    on_did_change_providers: Emitter(void),

    pub fn init(allocator: Allocator, storage_service: ?*InMemoryStorageService) QuickDiffService {
        var self = QuickDiffService{
            .allocator = allocator,
            .providers_list = std.array_list.Managed(*QuickDiffProvider).init(allocator),
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
        self.providers_list.deinit();
        self.on_did_change_providers.deinit();
        self.* = undefined;
    }

    /// Providers sorted by kind: primary before secondary before contributed.
    pub fn providers(self: *QuickDiffService, allocator: Allocator) ![]*QuickDiffProvider {
        const result = try allocator.dupe(*QuickDiffProvider, self.providers_list.items);
        std.mem.sort(*QuickDiffProvider, result, {}, providerLessThan);
        return result;
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

    /// Registers a provider and returns a disposable. The terminal service
    /// keeps providers until `deinit`/`removeProviderById`; the returned
    /// disposable is a no-op because providers are static for the life of the
    /// workbench and do not need per-registration cleanup.
    pub fn addQuickDiffProvider(self: *QuickDiffService, provider: *QuickDiffProvider) !IDisposable {
        for (self.providers_list.items) |existing| {
            if (existing == provider) return IDisposable.none;
        }
        try self.providers_list.append(provider);
        self.on_did_change_providers.fire({}) catch {};
        return IDisposable.none;
    }

    pub fn removeProvider(self: *QuickDiffService, provider: *QuickDiffProvider) void {
        for (self.providers_list.items, 0..) |candidate, index| {
            if (candidate != provider) continue;
            _ = self.providers_list.orderedRemove(index);
            self.on_did_change_providers.fire({}) catch {};
            return;
        }
    }

    pub fn removeProviderById(self: *QuickDiffService, id: []const u8) void {
        for (self.providers_list.items, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate.id, id)) continue;
            _ = self.providers_list.orderedRemove(index);
            self.on_did_change_providers.fire({}) catch {};
            return;
        }
    }

    pub fn getQuickDiffs(
        self: *QuickDiffService,
        allocator: Allocator,
        resource: std.Uri,
        language: ?[]const u8,
        is_synchronized: bool,
    ) ![]QuickDiff {
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

        var result = std.array_list.Managed(QuickDiff).init(allocator);
        errdefer {
            for (result.items) |*entry| entry.deinit(allocator);
            result.deinit();
        }
        const candidate = try language_selector.candidateFromUri(scratch, resource, language orelse "", is_synchronized);
        for (candidates.items) |provider| {
            const score_value: i32 = if (provider.selector) |selector|
                language_selector.score(scratch, selector, candidate) catch 0
            else
                10;
            if (score_value <= 0) continue;
            var original = (provider.getOriginalResource(allocator, resource) catch continue) orelse continue;
            errdefer original.deinit(allocator);
            const id = try allocator.dupe(u8, provider.id);
            errdefer allocator.free(id);
            const label = try allocator.dupe(u8, provider.label);
            errdefer allocator.free(label);
            try result.append(.{
                .id = id,
                .label = label,
                .original = original,
                .kind = provider.kind,
            });
        }
        return result.toOwnedSlice();
    }

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
            .remove_quick_diff_provider_fn = removeProviderThunk,
            .get_quick_diffs_fn = getQuickDiffsThunk,
            .toggle_visibility_fn = toggleVisibilityThunk,
            .is_visible_fn = isVisibleThunk,
            .on_did_change_providers = &self.on_did_change_providers,
        };
    }

    fn providersThunk(context: *anyopaque) []const *QuickDiffProvider {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        return self.providers_list.items;
    }

    fn addProviderThunk(context: *anyopaque, provider: *QuickDiffProvider) anyerror!IDisposable {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        return self.addQuickDiffProvider(provider);
    }

    fn removeProviderThunk(context: *anyopaque, id: []const u8) void {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        self.removeProviderById(id);
    }

    fn getQuickDiffsThunk(
        context: *anyopaque,
        allocator: Allocator,
        resource: std.Uri,
        language: ?[]const u8,
        is_synchronized: bool,
    ) anyerror![]QuickDiff {
        const self: *QuickDiffService = @ptrCast(@alignCast(context));
        return self.getQuickDiffs(allocator, resource, language, is_synchronized);
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
        return .{
            .content = try allocator.dupe(u8, "original"),
            .ref_label = try allocator.dupe(u8, "HEAD"),
        };
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
    _ = try service.addQuickDiffProvider(&rootless.base);
    _ = try service.addQuickDiffProvider(&rootless_primary.base);
    _ = try service.addQuickDiffProvider(&nested.base);
    _ = try service.addQuickDiffProvider(&primary.base);
    _ = try service.addQuickDiffProvider(&wrong_authority.base);

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

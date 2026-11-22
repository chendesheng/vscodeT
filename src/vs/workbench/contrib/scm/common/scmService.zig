// Port of `src/vs/workbench/contrib/scm/common/scmService.ts`.
//
// Terminal adaptations:
// - The repository map is an ordered list of local-path providers (one Git
//   repository per workspace folder in this milestone); resource lookups use
//   the upstream longest-root match on filesystem paths.
// - Context keys, storage-backed input history and validation are not ported.
//   The terminal `SCMInput` keeps the value, placeholder, enablement and
//   visibility shape the commit input needs.
const std = @import("std");
const Allocator = std.mem.Allocator;

const scm = @import("./scm.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const ISCMProvider = scm.ISCMProvider;
pub const ISCMRepository = scm.ISCMRepository;
pub const ISCMInput = scm.ISCMInput;
pub const ISCMService = scm.ISCMService;

pub const SCMError = error{
    ProviderAlreadyExists,
    RepositoryNotFound,
};

/// Minimal terminal port of `SCMInput`.
pub const SCMInput = struct {
    allocator: Allocator,
    value: []u8,
    placeholder: []u8,
    enabled: bool = true,
    visible: bool = true,
    change: Emitter(void),

    pub fn init(allocator: Allocator) !SCMInput {
        return .{
            .allocator = allocator,
            .value = try allocator.dupe(u8, ""),
            .placeholder = try allocator.dupe(u8, "Message"),
            .change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *SCMInput) void {
        self.change.deinit();
        self.allocator.free(self.value);
        self.allocator.free(self.placeholder);
        self.* = undefined;
    }

    pub fn setValue(self: *SCMInput, value: []const u8) !void {
        if (std.mem.eql(u8, self.value, value)) return;
        const copy = try self.allocator.dupe(u8, value);
        self.allocator.free(self.value);
        self.value = copy;
        self.change.fire({}) catch {};
    }

    pub fn setPlaceholder(self: *SCMInput, placeholder: []const u8) !void {
        if (std.mem.eql(u8, self.placeholder, placeholder)) return;
        const copy = try self.allocator.dupe(u8, placeholder);
        self.allocator.free(self.placeholder);
        self.placeholder = copy;
        self.change.fire({}) catch {};
    }

    pub fn interface(self: *SCMInput) ISCMInput {
        return .{
            .context = self,
            .value_fn = valueThunk,
            .set_value_fn = setValueThunk,
            .placeholder_fn = placeholderThunk,
            .set_placeholder_fn = setPlaceholderThunk,
            .enabled_fn = enabledThunk,
            .set_enabled_fn = setEnabledThunk,
            .visible_fn = visibleThunk,
            .set_visible_fn = setVisibleThunk,
            .on_did_change = &self.change,
        };
    }

    fn valueThunk(context: *anyopaque) []const u8 {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        return self.value;
    }

    fn setValueThunk(context: *anyopaque, value: []const u8, _: bool) void {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        self.setValue(value) catch {};
    }

    fn placeholderThunk(context: *anyopaque) []const u8 {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        return self.placeholder;
    }

    fn setPlaceholderThunk(context: *anyopaque, placeholder: []const u8) void {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        self.setPlaceholder(placeholder) catch {};
    }

    fn enabledThunk(context: *anyopaque) bool {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        return self.enabled;
    }

    fn setEnabledThunk(context: *anyopaque, enabled: bool) void {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        self.enabled = enabled;
    }

    fn visibleThunk(context: *anyopaque) bool {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        return self.visible;
    }

    fn setVisibleThunk(context: *anyopaque, visible: bool) void {
        const self: *SCMInput = @ptrCast(@alignCast(context));
        self.visible = visible;
    }
};

pub const SCMRepository = struct {
    allocator: Allocator,
    service: *SCMService,
    id: []u8,
    provider: ISCMProvider,
    input: SCMInput,
    iface: ISCMRepository,
    disposed: bool = false,

    pub fn interface(self: *SCMRepository) ISCMRepository {
        return self.iface;
    }

    pub fn dispose(self: *SCMRepository) void {
        if (self.disposed) return;
        self.service.removeRepository(self);
    }
};

/// Port of `SCMService` (provider/repository subset).
pub const SCMService = struct {
    allocator: Allocator,
    repositories: std.array_list.Managed(*SCMRepository),
    /// Cached interfaces returned by `ISCMService.repositories`. Rebuilt on
    /// every repository mutation; returned slices are borrowed.
    interfaces: std.array_list.Managed(ISCMRepository),
    on_did_add_repository: Emitter(*ISCMRepository),
    on_did_remove_repository: Emitter(*ISCMRepository),

    pub fn init(allocator: Allocator) SCMService {
        return .{
            .allocator = allocator,
            .repositories = std.array_list.Managed(*SCMRepository).init(allocator),
            .interfaces = std.array_list.Managed(ISCMRepository).init(allocator),
            .on_did_add_repository = Emitter(*ISCMRepository).init(allocator),
            .on_did_remove_repository = Emitter(*ISCMRepository).init(allocator),
        };
    }

    pub fn deinit(self: *SCMService) void {
        for (self.repositories.items) |repository| {
            self.destroyRepository(repository);
        }
        self.repositories.deinit();
        self.interfaces.deinit();
        self.on_did_add_repository.deinit();
        self.on_did_remove_repository.deinit();
        self.* = undefined;
    }

    pub fn repositoryCount(self: *const SCMService) usize {
        return self.repositories.items.len;
    }

    pub fn registerSCMProvider(self: *SCMService, provider: *ISCMProvider) !*SCMRepository {
        if (self.findRepositoryById(provider.id) != null) return SCMError.ProviderAlreadyExists;

        const repository = try self.allocator.create(SCMRepository);
        errdefer self.allocator.destroy(repository);
        const id = try self.allocator.dupe(u8, provider.id);
        errdefer self.allocator.free(id);

        repository.* = .{
            .allocator = self.allocator,
            .service = self,
            .id = id,
            .provider = provider.*,
            .input = try SCMInput.init(self.allocator),
            .iface = undefined,
        };
        repository.iface = .{
            .context = repository,
            .id = repository.id,
            .provider = repository.provider,
            .input = repository.input.interface(),
            .dispose_fn = disposeRepositoryThunk,
        };
        try self.repositories.append(repository);
        try self.rebuildInterfaces();

        self.on_did_add_repository.fire(&repository.iface) catch {};
        return repository;
    }

    pub fn getRepository(self: *const SCMService, id: []const u8) ?*SCMRepository {
        return self.findRepositoryById(id);
    }

    /// Upstream `getRepository(resource)`: the non-hidden repository whose root
    /// is the longest prefix of `path`.
    pub fn getRepositoryByPath(self: *const SCMService, path: []const u8) ?*SCMRepository {
        var best: ?*SCMRepository = null;
        var best_length: usize = std.math.maxInt(usize);
        for (self.repositories.items) |repository| {
            if (repository.provider.is_hidden) continue;
            const root = repository.provider.root_path orelse continue;
            const trimmed = std.mem.trimEnd(u8, root, "/\\");
            if (trimmed.len == 0) continue;
            if (path.len < trimmed.len) continue;
            if (!std.mem.startsWith(u8, path, trimmed)) continue;
            if (path.len > trimmed.len and path[trimmed.len] != '/' and path[trimmed.len] != '\\') continue;
            const relative_length = path.len - trimmed.len;
            if (relative_length < best_length) {
                best = repository;
                best_length = relative_length;
            }
        }
        return best;
    }

    /// Borrowed interfaces for the current repositories, in registration order.
    pub fn repositoryInterfaces(self: *const SCMService) []const ISCMRepository {
        return self.interfaces.items;
    }

    pub fn interface(self: *SCMService) ISCMService {
        return .{
            .context = self,
            .repositories_fn = repositoriesThunk,
            .repository_count_fn = repositoryCountThunk,
            .register_scm_provider_fn = registerThunk,
            .get_repository_by_id_fn = getRepositoryThunk,
            .get_repository_by_path_fn = getRepositoryByPathThunk,
            .on_did_add_repository = &self.on_did_add_repository,
            .on_did_remove_repository = &self.on_did_remove_repository,
        };
    }

    fn findRepositoryById(self: *const SCMService, id: []const u8) ?*SCMRepository {
        for (self.repositories.items) |repository| {
            if (std.mem.eql(u8, repository.id, id)) return repository;
        }
        return null;
    }

    fn rebuildInterfaces(self: *SCMService) !void {
        try self.interfaces.resize(self.repositories.items.len);
        for (self.repositories.items, 0..) |repository, index| {
            self.interfaces.items[index] = repository.iface;
        }
    }

    fn removeRepository(self: *SCMService, repository: *SCMRepository) void {
        if (repository.disposed) return;
        repository.disposed = true;
        for (self.repositories.items, 0..) |candidate, index| {
            if (candidate != repository) continue;
            _ = self.repositories.orderedRemove(index);
            break;
        }
        self.rebuildInterfaces() catch {};
        self.on_did_remove_repository.fire(&repository.iface) catch {};
        self.destroyRepository(repository);
    }

    fn destroyRepository(self: *SCMService, repository: *SCMRepository) void {
        repository.input.deinit();
        self.allocator.free(repository.id);
        self.allocator.destroy(repository);
    }

    fn disposeRepositoryThunk(context: *anyopaque) void {
        const self: *SCMRepository = @ptrCast(@alignCast(context));
        self.dispose();
    }

    fn repositoriesThunk(context: *anyopaque) []const ISCMRepository {
        const self: *SCMService = @ptrCast(@alignCast(context));
        return self.interfaces.items;
    }

    fn repositoryCountThunk(context: *anyopaque) usize {
        const self: *SCMService = @ptrCast(@alignCast(context));
        return self.repositoryCount();
    }

    fn registerThunk(context: *anyopaque, provider: *ISCMProvider) anyerror!*ISCMRepository {
        const self: *SCMService = @ptrCast(@alignCast(context));
        const repository = try self.registerSCMProvider(provider);
        return &repository.iface;
    }

    fn getRepositoryThunk(context: *anyopaque, id: []const u8) ?*ISCMRepository {
        const self: *SCMService = @ptrCast(@alignCast(context));
        const repository = self.findRepositoryById(id) orelse return null;
        return &repository.iface;
    }

    fn getRepositoryByPathThunk(context: *anyopaque, path: []const u8) ?*ISCMRepository {
        const self: *SCMService = @ptrCast(@alignCast(context));
        const repository = self.getRepositoryByPath(path) orelse return null;
        return &repository.iface;
    }
};

test "SCMService: register, duplicate and count" {
    const allocator = std.testing.allocator;
    var service = SCMService.init(allocator);
    defer service.deinit();

    var provider = TestProvider{};
    try provider.init(allocator, "git");
    defer provider.deinit();

    const repository = try service.registerSCMProvider(&provider.base);
    try std.testing.expectEqual(@as(usize, 1), service.repositoryCount());
    try std.testing.expectError(SCMError.ProviderAlreadyExists, service.registerSCMProvider(&provider.base));
    try std.testing.expectEqual(repository, service.getRepository("git").?);
    try std.testing.expect(service.getRepository("other") == null);
}

test "SCMService: disposal removes the repository and fires the event" {
    const allocator = std.testing.allocator;
    var service = SCMService.init(allocator);
    defer service.deinit();

    var provider = TestProvider{};
    try provider.init(allocator, "git");
    defer provider.deinit();
    const repository = try service.registerSCMProvider(&provider.base);

    var removed: usize = 0;
    const listener = try service.on_did_remove_repository.listen(&removed, struct {
        fn onEvent(_: *ISCMRepository, counter: *usize) anyerror!void {
            counter.* += 1;
        }
    }.onEvent);
    defer service.on_did_remove_repository.unlisten(listener);

    var interface = repository.interface();
    interface.dispose();
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(usize, 0), service.repositoryCount());
    try std.testing.expect(service.getRepository("git") == null);
}

test "SCMService: path lookup uses the longest root" {
    const allocator = std.testing.allocator;
    var service = SCMService.init(allocator);
    defer service.deinit();

    var outer = TestProvider{};
    try outer.init(allocator, "outer");
    defer outer.deinit();
    outer.base.root_path = "/repo";
    _ = try service.registerSCMProvider(&outer.base);

    var inner = TestProvider{};
    try inner.init(allocator, "inner");
    defer inner.deinit();
    inner.base.root_path = "/repo/nested";
    _ = try service.registerSCMProvider(&inner.base);

    try std.testing.expectEqualStrings("inner", service.getRepositoryByPath("/repo/nested/file.zig").?.id);
    try std.testing.expectEqualStrings("outer", service.getRepositoryByPath("/repo/file.zig").?.id);
    try std.testing.expect(service.getRepositoryByPath("/other/file.zig") == null);
    // A path that only shares a name prefix does not match.
    try std.testing.expect(service.getRepositoryByPath("/repository/file.zig") == null);
}

test "SCMService: input value and visibility are readable through the interface" {
    const allocator = std.testing.allocator;
    var service = SCMService.init(allocator);
    defer service.deinit();

    var provider = TestProvider{};
    try provider.init(allocator, "git");
    defer provider.deinit();
    const repository = try service.registerSCMProvider(&provider.base);
    const interface = repository.input.interface();
    try std.testing.expectEqualStrings("", interface.value());
    try std.testing.expect(interface.enabled());
    try std.testing.expect(interface.visible());
    interface.setValue("message", true);
    try std.testing.expectEqualStrings("message", interface.value());
}

test "SCMService: repository interface list is rebuilt on registration" {
    const allocator = std.testing.allocator;
    var service = SCMService.init(allocator);
    defer service.deinit();

    try std.testing.expectEqual(@as(usize, 0), service.repositoryInterfaces().len);
    var provider = TestProvider{};
    try provider.init(allocator, "git");
    defer provider.deinit();
    _ = try service.registerSCMProvider(&provider.base);
    try std.testing.expectEqual(@as(usize, 1), service.repositoryInterfaces().len);
    try std.testing.expectEqualStrings("git", service.interface().repositories()[0].id);
}

const TestProvider = struct {
    base: ISCMProvider = undefined,
    root: ?[]const u8 = null,
    groups_data: [0]*scm.ISCMResourceGroup = .{},
    groups_changed: Emitter(void) = undefined,
    resources_changed: Emitter(void) = undefined,

    fn init(self: *TestProvider, allocator: Allocator, id: []const u8) !void {
        self.groups_changed = Emitter(void).init(allocator);
        self.resources_changed = Emitter(void).init(allocator);
        self.base = .{
            .context = self,
            .id = id,
            .provider_id = id,
            .label = id,
            .name = id,
            .root_path = null,
            .groups_fn = groups,
            .on_did_change_resource_groups = &self.groups_changed,
            .on_did_change_resources = &self.resources_changed,
        };
    }

    fn deinit(self: *TestProvider) void {
        self.groups_changed.deinit();
        self.resources_changed.deinit();
    }

    fn groups(context: *anyopaque) []const *scm.ISCMResourceGroup {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return &self.groups_data;
    }
};

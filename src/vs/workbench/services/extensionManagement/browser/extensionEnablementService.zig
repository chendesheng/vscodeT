// Port of user and workspace enablement in
// `src/vs/workbench/services/extensionManagement/browser/extensionEnablementService.ts`.
// The profile store retains the upstream disabled-identifier representation.
// Workspace overrides are stored atomically per workspace under workspaceStorage.
// Trust, environment, kind and other computed restrictions are separate layers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const util = @import("../../../../platform/extensionManagement/common/extensionManagementUtil.zig");
const management = @import("../common/extensionManagement.zig");
const EnablementState = management.EnablementState;
const Workspace = @import("../../../../platform/workspace/common/workspace.zig").Workspace;
const storage = @import("../../../../platform/storage/common/storage.zig");
const Ids = std.array_list.Managed([]u8);

/// Native persistence boundary. `load` returns the raw stored JSON value or
/// null when no value has been stored; `save` stores the raw JSON value.
pub const Store = struct {
    context: *anyopaque,
    load: *const fn (context: *anyopaque, allocator: Allocator) anyerror!?[]const u8,
    save: *const fn (context: *anyopaque, value: []const u8) anyerror!void,
};

const StoredIdentifier = struct { id: []const u8 };

pub const ExtensionEnablementService = struct {
    allocator: Allocator,
    store: ?Store = null,
    /// Owned identifiers of globally disabled extensions; comparisons are case-insensitive.
    disabled: std.array_list.Managed([]u8),
    on_did_change: Emitter([]const u8),
    workspace_io: ?std.Io = null,
    workspace_storage_root: ?[]u8 = null,
    workspace_path: ?[]u8 = null,
    workspace_key: ?[]u8 = null,
    has_workspace: bool = false,
    workspace_enabled: Ids,
    workspace_disabled: Ids,

    pub fn init(allocator: Allocator, store: ?Store) !*ExtensionEnablementService {
        const self = try allocator.create(ExtensionEnablementService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .store = store,
            .disabled = std.array_list.Managed([]u8).init(allocator),
            .on_did_change = Emitter([]const u8).init(allocator),
            .workspace_enabled = .init(allocator),
            .workspace_disabled = .init(allocator),
        };
        errdefer self.deinitContents();
        try self.load();
        return self;
    }

    pub fn deinit(self: *ExtensionEnablementService) void {
        self.deinitContents();
        self.allocator.destroy(self);
    }

    fn deinitContents(self: *ExtensionEnablementService) void {
        freeIds(self.allocator, &self.disabled);
        freeIds(self.allocator, &self.workspace_enabled);
        freeIds(self.allocator, &self.workspace_disabled);
        if (self.workspace_path) |path| self.allocator.free(path);
        if (self.workspace_key) |key| self.allocator.free(key);
        if (self.workspace_storage_root) |path| self.allocator.free(path);
        self.on_did_change.deinit();
    }

    fn load(self: *ExtensionEnablementService) !void {
        const store = self.store orelse return;
        const raw = (try store.load(store.context, self.allocator)) orelse return;
        defer self.allocator.free(raw);
        var parsed = std.json.parseFromSlice([]StoredIdentifier, self.allocator, raw, .{
            .ignore_unknown_fields = true,
        }) catch return; // A corrupt value loads as "nothing disabled".
        defer parsed.deinit();
        for (parsed.value) |entry| {
            if (entry.id.len == 0) continue;
            if (self.find(entry.id) != null) continue;
            const owned = try self.allocator.dupe(u8, entry.id);
            errdefer self.allocator.free(owned);
            try self.disabled.append(owned);
        }
    }

    pub fn getDisabledExtensions(self: *const ExtensionEnablementService, allocator: Allocator) ![][]const u8 {
        const result = try allocator.alloc([]const u8, self.disabled.items.len);
        for (self.disabled.items, 0..) |identifier, index| result[index] = identifier;
        return result;
    }

    pub fn isEnabled(self: *const ExtensionEnablementService, identifier: []const u8) bool {
        return self.getEnablementState(identifier).isEnabled();
    }

    pub fn getEnablementState(self: *const ExtensionEnablementService, identifier: []const u8) EnablementState {
        if (self.has_workspace) {
            if (contains(self.workspace_enabled.items, identifier)) return .EnabledWorkspace;
            if (contains(self.workspace_disabled.items, identifier)) return .DisabledWorkspace;
        }
        return if (self.find(identifier) != null) .DisabledGlobally else .EnabledGlobally;
    }

    const WorkspaceState = struct {
        @"extensionsIdentifiers/enabled": []const StoredIdentifier = &.{},
        @"extensionsIdentifiers/disabled": []const StoredIdentifier = &.{},
    };

    pub fn configureWorkspaceStorage(self: *ExtensionEnablementService, io: std.Io, profile: ?[]const u8) !void {
        const root = if (profile) |dir| try std.fs.path.join(self.allocator, &.{ dir, "User", "workspaceStorage" }) else null;
        if (self.workspace_storage_root) |old| self.allocator.free(old);
        self.workspace_storage_root = root;
        self.workspace_io = io;
    }

    /// Switch to the new workspace before computing effective enablement.
    /// Empty windows never expose workspace actions or stale overrides.
    pub fn setWorkspace(self: *ExtensionEnablementService, workspace: *const Workspace) !bool {
        const has_workspace = workspace.folders.items.len != 0 or workspace.configuration != null;
        const key = if (has_workspace) blk: {
            if (workspace.configuration) |config| break :blk try std.fmt.allocPrint(self.allocator, "{x:0>16}", .{std.hash.Wyhash.hash(0, config)});
            break :blk try storage.workspaceFolderStatePath(self.allocator, "", workspace.folders.items, "extensions.state.json");
        } else null;
        var own_key = true;
        defer if (own_key) if (key) |value| self.allocator.free(value);
        const path = if (has_workspace and self.workspace_storage_root != null) blk: {
            if (workspace.configuration != null) break :blk try std.fs.path.join(self.allocator, &.{ self.workspace_storage_root.?, key.?, "extensions.state.json" });
            break :blk try storage.workspaceFolderStatePath(self.allocator, self.workspace_storage_root.?, workspace.folders.items, "extensions.state.json");
        } else null;
        var own_path = true;
        defer if (own_path) if (path) |value| self.allocator.free(value);
        if (has_workspace == self.has_workspace and samePath(self.workspace_key, key) and samePath(self.workspace_path, path)) return false;
        var enabled: Ids = .init(self.allocator);
        errdefer freeIds(self.allocator, &enabled);
        var disabled: Ids = .init(self.allocator);
        errdefer freeIds(self.allocator, &disabled);
        if (path) |value| {
            if (try storage.readStateFile(WorkspaceState, self.allocator, self.workspace_io.?, value)) |parsed| {
                defer parsed.deinit();
                for (parsed.value.@"extensionsIdentifiers/enabled") |id| try appendUnique(&enabled, id.id);
                for (parsed.value.@"extensionsIdentifiers/disabled") |id| try appendUnique(&disabled, id.id);
            }
        }
        freeIds(self.allocator, &self.workspace_enabled);
        freeIds(self.allocator, &self.workspace_disabled);
        if (self.workspace_path) |old| self.allocator.free(old);
        self.workspace_enabled = enabled;
        self.workspace_disabled = disabled;
        self.workspace_path = path;
        if (self.workspace_key) |old| self.allocator.free(old);
        self.workspace_key = key;
        self.has_workspace = has_workspace;
        own_path = false;
        own_key = false;
        return true;
    }

    fn samePath(left: ?[]const u8, right: ?[]const u8) bool {
        if (left) |a| return if (right) |b| std.mem.eql(u8, a, b) else false;
        return right == null;
    }

    fn contains(ids: []const []u8, identifier: []const u8) bool {
        for (ids) |id| if (util.areSameExtensions(id, identifier)) return true;
        return false;
    }

    fn appendUnique(ids: *Ids, identifier: []const u8) !void {
        if (identifier.len == 0 or contains(ids.items, identifier)) return;
        const value = try ids.allocator.dupe(u8, identifier);
        errdefer ids.allocator.free(value);
        try ids.append(value);
    }

    fn freeIds(allocator: Allocator, ids: *Ids) void {
        for (ids.items) |id| allocator.free(id);
        ids.deinit();
    }

    fn withId(self: *ExtensionEnablementService, ids: []const []u8, identifier: []const u8, included: bool) !Ids {
        var next: Ids = .init(self.allocator);
        errdefer freeIds(self.allocator, &next);
        for (ids) |id| if (!util.areSameExtensions(id, identifier)) try appendUnique(&next, id);
        if (included) try appendUnique(&next, identifier);
        return next;
    }

    fn persistWorkspace(self: *ExtensionEnablementService, enabled: []const []u8, disabled: []const []u8) !void {
        const path = self.workspace_path orelse return;
        const enabled_items = try self.allocator.alloc(StoredIdentifier, enabled.len);
        defer self.allocator.free(enabled_items);
        for (enabled, enabled_items) |id, *entry| entry.* = .{ .id = id };
        const disabled_items = try self.allocator.alloc(StoredIdentifier, disabled.len);
        defer self.allocator.free(disabled_items);
        for (disabled, disabled_items) |id, *entry| entry.* = .{ .id = id };
        try storage.writeStateFile(self.allocator, self.workspace_io.?, path, WorkspaceState{ .@"extensionsIdentifiers/enabled" = enabled_items, .@"extensionsIdentifiers/disabled" = disabled_items });
    }

    /// Global actions clear workspace overrides. Workspace actions only
    /// change the selected workspace's explicit enable/disable lists.
    pub fn setEnablement(self: *ExtensionEnablementService, identifier: []const u8, state: EnablementState) !bool {
        const workspace = switch (state) {
            .EnabledWorkspace, .DisabledWorkspace => true,
            .EnabledGlobally, .DisabledGlobally => false,
            else => return error.UnsupportedEnablementState,
        };
        if (workspace and !self.has_workspace) return error.UnsupportedEnablementState;
        if (self.getEnablementState(identifier) == state) return false;
        var next_global = try self.withId(self.disabled.items, identifier, if (workspace) contains(self.disabled.items, identifier) else state == .DisabledGlobally);
        errdefer freeIds(self.allocator, &next_global);
        var next_enabled = try self.withId(self.workspace_enabled.items, identifier, state == .EnabledWorkspace);
        errdefer freeIds(self.allocator, &next_enabled);
        var next_disabled = try self.withId(self.workspace_disabled.items, identifier, state == .DisabledWorkspace);
        errdefer freeIds(self.allocator, &next_disabled);
        try self.persistWorkspace(next_enabled.items, next_disabled.items);
        if (!workspace) self.persist(next_global.items) catch |err| {
            self.persistWorkspace(self.workspace_enabled.items, self.workspace_disabled.items) catch {};
            return err;
        };
        freeIds(self.allocator, &self.disabled);
        freeIds(self.allocator, &self.workspace_enabled);
        freeIds(self.allocator, &self.workspace_disabled);
        self.disabled = next_global;
        self.workspace_enabled = next_enabled;
        self.workspace_disabled = next_disabled;
        // Storage has committed. Listener failures do not free the new lists.
        self.on_did_change.fire(identifier) catch {};
        return true;
    }

    /// Serializes the upstream profile value shape: `[{"id":"…"}]`.
    fn persist(self: *ExtensionEnablementService, identifiers: []const []u8) !void {
        const store = self.store orelse return;
        var items: std.array_list.Managed(StoredIdentifier) = .init(self.allocator);
        defer items.deinit();
        try items.ensureTotalCapacity(identifiers.len);
        for (identifiers) |identifier| items.appendAssumeCapacity(.{ .id = identifier });
        const wrapped = try std.json.Stringify.valueAlloc(self.allocator, items.items, .{});
        defer self.allocator.free(wrapped);
        try store.save(store.context, wrapped);
    }

    fn find(self: *const ExtensionEnablementService, identifier: []const u8) ?[]const u8 {
        for (self.disabled.items) |entry| {
            if (util.areSameExtensions(entry, identifier)) return entry;
        }
        return null;
    }
};

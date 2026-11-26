// Port of
// `src/vs/workbench/contrib/multiDiffEditor/browser/scmMultiDiffSourceResolver.ts`.
// The source's query is the upstream JSON object; URI serialization uses the
// shared std.Uri encoder rather than concatenating raw query bytes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scm = @import("../../scm/common/scm.zig");
const source = @import("multiDiffSourceResolverService.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const Subscription = @import("../../../../base/common/event.zig").SignalSubscription;
const activity = @import("../../../services/activity/browser/activityService.zig");
const URI = @import("../../../../base/common/uri.zig").URI;
const std_uri = @import("../../../../base/common/stdUri.zig");
const comparePaths = @import("../../../../base/common/comparers.zig").comparePaths;

pub const ScmMultiDiffSourceResolver = struct {
    allocator: Allocator,
    scm_service: scm.ISCMService,
    activity_service: *activity.ActivityService,
    pub fn interface(self: *ScmMultiDiffSourceResolver) source.IMultiDiffSourceResolver {
        return .{ .context = self, .can_handle_uri = canHandleUri, .resolve_diff_source = resolveDiffSource };
    }
    fn canHandleUri(context: *anyopaque, uri: std.Uri) bool {
        const self: *ScmMultiDiffSourceResolver = @ptrCast(@alignCast(context));
        var parsed = (parseUri(self.allocator, uri) catch null) orelse return false;
        parsed.deinit();
        return true;
    }
    fn resolveDiffSource(context: *anyopaque, uri: std.Uri) !source.IResolvedMultiDiffSource {
        const self: *ScmMultiDiffSourceResolver = @ptrCast(@alignCast(context));
        var parsed = (try parseUri(self.allocator, uri)) orelse return error.InvalidMultiDiffSource;
        defer parsed.deinit();
        return (try ScmResolvedMultiDiffSource.create(self.allocator, self.scm_service, self.activity_service, parsed.value)).interface();
    }
    pub const scheme = "scm-multi-diff-source";
    pub const UriFields = struct { repositoryUri: []const u8, groupId: []const u8 };
    pub fn getMultiDiffSourceUri(allocator: Allocator, repository_uri: []const u8, group_id: []const u8) ![]u8 {
        const query = try std.json.Stringify.valueAlloc(allocator, UriFields{ .repositoryUri = repository_uri, .groupId = group_id }, .{});
        defer allocator.free(query);
        const uri: std.Uri = .{ .scheme = scheme, .path = .{ .raw = "" }, .query = .{ .raw = query } };
        return std.fmt.allocPrint(allocator, "{f}", .{uri});
    }
    pub fn parseUri(allocator: Allocator, uri: std.Uri) !?std.json.Parsed(UriFields) {
        if (!std.mem.eql(u8, uri.scheme, scheme) or uri.query == null) return null;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const query = try uri.query.?.toRawMaybeAlloc(arena.allocator());
        return std.json.parseFromSlice(UriFields, allocator, query, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
    }
};

pub const ScmHistoryItemResolver = struct {
    allocator: Allocator,
    scm_service: scm.ISCMService,
    pub fn interface(self: *ScmHistoryItemResolver) source.IMultiDiffSourceResolver {
        return .{ .context = self, .can_handle_uri = canHandleUri, .resolve_diff_source = resolveDiffSource };
    }
    fn canHandleUri(context: *anyopaque, uri: std.Uri) bool {
        const self: *ScmHistoryItemResolver = @ptrCast(@alignCast(context));
        var parsed = (parseUri(self.allocator, uri) catch null) orelse return false;
        parsed.deinit();
        return true;
    }
    fn resolveDiffSource(context: *anyopaque, uri: std.Uri) !source.IResolvedMultiDiffSource {
        const self: *ScmHistoryItemResolver = @ptrCast(@alignCast(context));
        var parsed = (try parseUri(self.allocator, uri)) orelse return error.InvalidMultiDiffSource;
        defer parsed.deinit();
        return (try ScmResolvedHistorySource.create(self.allocator, self.scm_service, parsed.value)).interface();
    }
    pub const scheme = "scm-history-item";
    pub const UriFields = struct {
        repositoryId: []const u8,
        historyItemId: []const u8,
        historyItemParentId: ?[]const u8 = null,
        historyItemDisplayId: ?[]const u8 = null,
    };
    pub fn getMultiDiffSourceUri(allocator: Allocator, root_path: []const u8, fields: UriFields) ![]u8 {
        const query = try std.json.Stringify.valueAlloc(allocator, fields, .{});
        defer allocator.free(query);
        const uri: std.Uri = .{ .scheme = scheme, .path = .{ .raw = root_path }, .query = .{ .raw = query } };
        return std.fmt.allocPrint(allocator, "{f}", .{uri});
    }
    pub fn parseUri(allocator: Allocator, uri: std.Uri) !?std.json.Parsed(UriFields) {
        if (!std.mem.eql(u8, uri.scheme, scheme) or uri.query == null) return null;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const query = try uri.query.?.toRawMaybeAlloc(arena.allocator());
        return std.json.parseFromSlice(UriFields, allocator, query, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch null;
    }
};

fn parseOwned(arena: Allocator, encoded: []const u8) !std.Uri {
    return std.Uri.parse(try arena.dupe(u8, encoded));
}

fn parseOptional(arena: Allocator, encoded: ?[]const u8) !?std.Uri {
    return if (encoded) |value| try parseOwned(arena, value) else null;
}

fn fileUri(arena: Allocator, path: []const u8) !std.Uri {
    var uri = try URI.file(arena, path);
    defer uri.deinit();
    return std.Uri.parse(try uri.toStringEncoded(arena));
}

/// Upstream waits for the repository, resource group, and SCM progress
/// barrier before resolving. In the native event loop the source reports its
/// readiness and resource result through the same subscription instead of a
/// JavaScript promise. A live source owns a copy of its resource metadata.
const ScmResolvedMultiDiffSource = struct {
    allocator: Allocator,
    scm_service: scm.ISCMService,
    activity_service: *activity.ActivityService,
    repository_path: []const u8,
    group_id: []const u8,
    provider: ?*scm.ISCMProvider = null,
    group: ?*scm.ISCMResourceGroup = null,
    added: ?Subscription = null,
    removed: ?Subscription = null,
    groups_changed: ?Subscription = null,
    resources_changed: ?Subscription = null,
    activity_changed: ?Subscription = null,
    arena: std.heap.ArenaAllocator,
    items: []const source.MultiDiffEditorItem = &.{},
    changed: Emitter(void),
    ready: bool = false,

    fn create(allocator: Allocator, service: scm.ISCMService, activities: *activity.ActivityService, fields: ScmMultiDiffSourceResolver.UriFields) !*ScmResolvedMultiDiffSource {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const path = try allocator.dupe(u8, try std_uri.fsPath(try std.Uri.parse(fields.repositoryUri), scratch.allocator()));
        errdefer allocator.free(path);
        const group_id = try allocator.dupe(u8, fields.groupId);
        errdefer allocator.free(group_id);
        const self = try allocator.create(ScmResolvedMultiDiffSource);
        self.* = .{
            .allocator = allocator,
            .scm_service = service,
            .activity_service = activities,
            .repository_path = path,
            .group_id = group_id,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .changed = Emitter(void).init(allocator),
        };
        errdefer {
            self.detach();
            if (self.added) |sub| sub.dispose();
            if (self.removed) |sub| sub.dispose();
            if (self.activity_changed) |sub| sub.dispose();
            self.arena.deinit();
            self.changed.deinit();
            allocator.destroy(self);
        }
        self.added = try service.on_did_add_repository.listenDisposable(self, onRepositoryAdded);
        self.removed = try service.on_did_remove_repository.listenDisposable(self, onRepositoryRemoved);
        self.activity_changed = try activities.on_did_change_activity.listenDisposable(self, onActivityChanged);
        for (service.repositories()) |repository| {
            if (self.matches(repository.provider)) {
                try self.attach(repository.provider);
                break;
            }
        }
        return self;
    }
    fn matches(self: *ScmResolvedMultiDiffSource, provider: *scm.ISCMProvider) bool {
        return if (provider.root_path) |root| std.mem.eql(u8, root, self.repository_path) else false;
    }
    fn attach(self: *ScmResolvedMultiDiffSource, provider: *scm.ISCMProvider) !void {
        self.detach();
        self.provider = provider;
        self.groups_changed = try provider.on_did_change_resource_groups.listenDisposable(self, onGroupsChanged);
        try self.bindGroup();
    }
    fn detach(self: *ScmResolvedMultiDiffSource) void {
        if (self.resources_changed) |sub| sub.dispose();
        self.resources_changed = null;
        if (self.groups_changed) |sub| sub.dispose();
        self.groups_changed = null;
        self.group = null;
        self.provider = null;
    }
    fn onRepositoryAdded(repository: *scm.ISCMRepository, self: *ScmResolvedMultiDiffSource) !void {
        if (self.provider == null and self.matches(repository.provider)) try self.attach(repository.provider);
    }
    fn onRepositoryRemoved(repository: *scm.ISCMRepository, self: *ScmResolvedMultiDiffSource) !void {
        if (self.provider != repository.provider) return;
        self.detach();
        try self.refresh();
    }
    fn onGroupsChanged(_: void, self: *ScmResolvedMultiDiffSource) !void {
        try self.bindGroup();
    }
    fn bindGroup(self: *ScmResolvedMultiDiffSource) !void {
        var group: ?*scm.ISCMResourceGroup = null;
        if (self.provider) |provider| for (provider.groups()) |candidate| {
            if (std.mem.eql(u8, candidate.id, self.group_id)) {
                group = candidate;
                break;
            }
        };
        if (group != self.group) {
            if (self.resources_changed) |sub| sub.dispose();
            self.resources_changed = null;
            self.group = group;
            if (group) |actual| self.resources_changed = try actual.on_did_change_resources.listenDisposable(self, onResourcesChanged);
        }
        try self.refresh();
    }
    fn onResourcesChanged(_: void, self: *ScmResolvedMultiDiffSource) !void {
        try self.refresh();
    }
    fn onActivityChanged(change: activity.Change, self: *ScmResolvedMultiDiffSource) !void {
        if (!self.ready and change == .container and std.mem.eql(u8, change.container, scm.VIEWLET_ID)) try self.refresh();
    }
    fn refresh(self: *ScmResolvedMultiDiffSource) !void {
        if (!self.ready) {
            if (self.group == null) return;
            const activities = try self.activity_service.getViewContainerActivities(self.allocator, scm.VIEWLET_ID);
            defer self.allocator.free(activities);
            for (activities) |item| if (item.badge.is_progress) return;
        }
        var next = std.heap.ArenaAllocator.init(self.allocator);
        errdefer next.deinit();
        const a = next.allocator();
        const entries = if (self.group) |group| group.resources() else &.{};
        const sorted = try a.dupe(scm.ISCMResource, entries);
        std.mem.sort(scm.ISCMResource, sorted, {}, struct {
            fn less(_: void, left: scm.ISCMResource, right: scm.ISCMResource) bool {
                return comparePaths(left.source_path, right.source_path) < 0;
            }
        }.less);
        var items: std.ArrayList(source.MultiDiffEditorItem) = .empty;
        for (sorted) |entry| {
            const item: source.MultiDiffEditorItem = .{
                .originalUri = try parseOptional(a, entry.multi_diff_original_uri),
                .modifiedUri = try parseOptional(a, entry.multi_diff_modified_uri),
                .goToFileUri = try fileUri(a, entry.source_path),
            };
            // Resource groups that cannot expose text changes (e.g. merge)
            // do not contribute an item with two nonexistent resources.
            if (item.originalUri == null and item.modifiedUri == null) continue;
            try items.append(a, item);
        }
        var previous = self.arena;
        self.arena = next;
        self.items = items.items;
        self.ready = true;
        defer previous.deinit();
        self.changed.fire({}) catch {};
    }
    fn getItems(context: *anyopaque) []const source.MultiDiffEditorItem {
        const self: *ScmResolvedMultiDiffSource = @ptrCast(@alignCast(context));
        return self.items;
    }
    fn getReady(context: *anyopaque) bool {
        const self: *ScmResolvedMultiDiffSource = @ptrCast(@alignCast(context));
        return self.ready;
    }
    fn getContextKeys(context: *anyopaque) source.IResolvedMultiDiffSource.ContextKeys {
        const self: *ScmResolvedMultiDiffSource = @ptrCast(@alignCast(context));
        return .{ .scmResourceGroup = self.group_id, .scmProvider = if (self.provider) |provider| provider.provider_id else null };
    }
    fn dispose(context: *anyopaque) void {
        const self: *ScmResolvedMultiDiffSource = @ptrCast(@alignCast(context));
        self.detach();
        if (self.added) |sub| sub.dispose();
        if (self.removed) |sub| sub.dispose();
        if (self.activity_changed) |sub| sub.dispose();
        self.changed.deinit();
        self.arena.deinit();
        self.allocator.free(self.repository_path);
        self.allocator.free(self.group_id);
        self.allocator.destroy(self);
    }
    fn interface(self: *ScmResolvedMultiDiffSource) source.IResolvedMultiDiffSource {
        return .{ .context = self, .resources = getItems, .on_did_change_resources = &self.changed, .is_ready = getReady, .get_context_keys = getContextKeys, .dispose = dispose };
    }
};

/// History resources are immutable once the provider supplies the commit.
const ScmResolvedHistorySource = struct {
    allocator: Allocator,
    fields: ScmHistoryItemResolver.UriFields,
    arena: std.heap.ArenaAllocator,
    provider: ?*scm.ISCMProvider = null,
    added: ?Subscription = null,
    removed: ?Subscription = null,
    provider_changed: ?Subscription = null,
    items: []const source.MultiDiffEditorItem = &.{},
    changed: Emitter(void),
    ready: bool = false,
    failure: ?anyerror = null,

    fn create(allocator: Allocator, service: scm.ISCMService, fields: ScmHistoryItemResolver.UriFields) !*ScmResolvedHistorySource {
        const self = try allocator.create(ScmResolvedHistorySource);
        self.* = .{ .allocator = allocator, .fields = undefined, .arena = std.heap.ArenaAllocator.init(allocator), .changed = Emitter(void).init(allocator) };
        errdefer dispose(self);
        const a = self.arena.allocator();
        self.fields = .{
            .repositoryId = try a.dupe(u8, fields.repositoryId),
            .historyItemId = try a.dupe(u8, fields.historyItemId),
            .historyItemParentId = if (fields.historyItemParentId) |value| try a.dupe(u8, value) else null,
            .historyItemDisplayId = if (fields.historyItemDisplayId) |value| try a.dupe(u8, value) else null,
        };
        self.added = try service.on_did_add_repository.listenDisposable(self, onRepositoryAdded);
        self.removed = try service.on_did_remove_repository.listenDisposable(self, onRepositoryRemoved);
        if (service.getRepository(self.fields.repositoryId)) |repository| try self.attach(repository.provider);
        return self;
    }
    fn attach(self: *ScmResolvedHistorySource, provider: *scm.ISCMProvider) !void {
        self.provider = provider;
        if (provider.on_did_change) |changed| self.provider_changed = try changed.listenDisposable(self, onProviderChanged);
        self.resolve();
    }
    fn onRepositoryAdded(repository: *scm.ISCMRepository, self: *ScmResolvedHistorySource) !void {
        if (!self.ready and self.provider == null and std.mem.eql(u8, repository.id, self.fields.repositoryId)) try self.attach(repository.provider);
    }
    fn onRepositoryRemoved(repository: *scm.ISCMRepository, self: *ScmResolvedHistorySource) !void {
        if (self.provider != repository.provider) return;
        if (self.provider_changed) |sub| sub.dispose();
        self.provider_changed = null;
        self.provider = null;
    }
    fn onProviderChanged(_: void, self: *ScmResolvedHistorySource) !void {
        self.resolve();
    }
    fn resolve(self: *ScmResolvedHistorySource) void {
        if (self.ready) return;
        const provider = self.provider orelse return;
        const history = provider.history_provider orelse return;
        self.items = self.load(history.*) catch |err| blk: {
            self.failure = err;
            break :blk &.{};
        };
        self.ready = true;
        self.changed.fire({}) catch {};
    }
    fn load(self: *ScmResolvedHistorySource, history: @import("../../scm/common/history.zig").ISCMHistoryProvider) ![]const source.MultiDiffEditorItem {
        const a = self.arena.allocator();
        const changes = try history.provideHistoryItemChanges(a, self.fields.historyItemId, self.fields.historyItemParentId);
        // Provider results and all URI strings are in the source arena.
        var items: std.ArrayList(source.MultiDiffEditorItem) = .empty;
        for (changes) |change| {
            const original = try parseOptional(a, change.original_uri);
            const modified = try parseOptional(a, change.modified_uri);
            if (original == null and modified == null) continue;
            try items.append(a, .{
                .originalUri = original,
                .modifiedUri = modified,
                .goToFileUri = modified,
                .goToFileEditorTitle = if (modified) |uri| try std.fmt.allocPrint(a, "{s} ({s})", .{
                    std.fs.path.basename(try std_uri.path(uri, a)), self.fields.historyItemDisplayId orelse self.fields.historyItemId,
                }) else null,
            });
        }
        return items.items;
    }
    fn getItems(context: *anyopaque) []const source.MultiDiffEditorItem {
        const self: *ScmResolvedHistorySource = @ptrCast(@alignCast(context));
        return self.items;
    }
    fn getReady(context: *anyopaque) bool {
        const self: *ScmResolvedHistorySource = @ptrCast(@alignCast(context));
        return self.ready;
    }
    fn getFailure(context: *anyopaque) ?anyerror {
        const self: *ScmResolvedHistorySource = @ptrCast(@alignCast(context));
        return self.failure;
    }
    fn dispose(context: *anyopaque) void {
        const self: *ScmResolvedHistorySource = @ptrCast(@alignCast(context));
        if (self.provider_changed) |sub| sub.dispose();
        if (self.added) |sub| sub.dispose();
        if (self.removed) |sub| sub.dispose();
        self.changed.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn interface(self: *ScmResolvedHistorySource) source.IResolvedMultiDiffSource {
        return .{ .context = self, .resources = getItems, .on_did_change_resources = &self.changed, .is_ready = getReady, .get_failure = getFailure, .dispose = dispose };
    }
};

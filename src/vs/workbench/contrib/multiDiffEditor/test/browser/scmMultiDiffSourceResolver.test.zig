// Port of `src/vs/workbench/contrib/multiDiffEditor/test/browser/scmMultiDiffSourceResolver.test.ts`.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const URI = @import("../../../../../base/common/uri.zig").URI;
const std_uri = @import("../../../../../base/common/stdUri.zig");
const scm = @import("../../../scm/common/scm.zig");
const history = @import("../../../scm/common/history.zig");
const SCMService = @import("../../../scm/common/scmService.zig").SCMService;
const activity = @import("../../../../services/activity/browser/activityService.zig");
const resolvers = @import("../../browser/scmMultiDiffSourceResolver.zig");
const SourceService = @import("../../browser/multiDiffSourceResolverService.zig").MultiDiffSourceResolverService;
const root = if (@import("builtin").os.tag == .windows) "C:\\repository" else "/repository";

const TestProvider = struct {
    provider: scm.ISCMProvider = undefined,
    group: scm.ISCMResourceGroup = undefined,
    groups: [1]*scm.ISCMResourceGroup = undefined,
    entries: [3]scm.ISCMResource = undefined,
    entry_count: usize = 0,
    group_available: bool = true,
    changed: Emitter(void),
    groups_changed: Emitter(void),
    resources_changed: Emitter(void),
    refs_changed: Emitter(history.ISCMHistoryItemRefsChangeEvent),
    history_provider: history.ISCMHistoryProvider = undefined,
    calls: usize = 0,

    fn init(self: *TestProvider) void {
        self.* = .{
            .changed = Emitter(void).init(testing.allocator),
            .groups_changed = Emitter(void).init(testing.allocator),
            .resources_changed = Emitter(void).init(testing.allocator),
            .refs_changed = Emitter(history.ISCMHistoryItemRefsChangeEvent).init(testing.allocator),
        };
        self.provider = .{
            .context = self,
            .id = "scm0",
            .provider_id = "scm0",
            .label = "Git",
            .name = "Git",
            .root_path = root,
            .groups_fn = getGroups,
            .on_did_change = &self.changed,
            .on_did_change_resource_groups = &self.groups_changed,
            .on_did_change_resources = &self.resources_changed,
        };
        self.group = .{
            .context = self,
            .id = "changes",
            .provider = &self.provider,
            .label = "Changes",
            .resources_fn = getResources,
            .on_did_change = &self.changed,
            .on_did_change_resources = &self.resources_changed,
        };
        self.groups = .{&self.group};
        self.history_provider = .{
            .context = self,
            .on_did_change_history_item_refs = &self.refs_changed,
            .provide_history_item_refs_fn = provideRefs,
            .provide_history_items_fn = provideItems,
            .provide_history_item_changes_fn = provideChanges,
            .resolve_history_item_refs_common_ancestor_fn = provideAncestor,
        };
    }
    fn deinit(self: *TestProvider) void {
        self.changed.deinit();
        self.groups_changed.deinit();
        self.resources_changed.deinit();
        self.refs_changed.deinit();
    }
    fn getGroups(context: *anyopaque) []const *scm.ISCMResourceGroup {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return if (self.group_available) &self.groups else &.{};
    }
    fn getResources(context: *anyopaque) []const scm.ISCMResource {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        return self.entries[0..self.entry_count];
    }
    fn provideRefs(_: *anyopaque, _: Allocator, _: ?[]const []const u8) ![]history.ISCMHistoryItemRef {
        return error.UnexpectedCall;
    }
    fn provideItems(_: *anyopaque, _: Allocator, _: history.ISCMHistoryOptions) ![]history.ISCMHistoryItem {
        return error.UnexpectedCall;
    }
    fn provideAncestor(_: *anyopaque, _: Allocator, _: []const []const u8) !?[]u8 {
        return error.UnexpectedCall;
    }
    fn provideChanges(context: *anyopaque, a: Allocator, id: []const u8, parent: ?[]const u8) ![]history.ISCMHistoryItemChange {
        const self: *TestProvider = @ptrCast(@alignCast(context));
        self.calls += 1;
        try testing.expectEqualStrings("commit", id);
        try testing.expectEqualStrings("parent", parent.?);
        const result = try a.alloc(history.ISCMHistoryItemChange, 1);
        result[0] = .{ .path = try a.dupe(u8, "modified.ts"), .original_uri = try a.dupe(u8, "file:///original.ts"), .modified_uri = try a.dupe(u8, "file:///modified.ts") };
        return result;
    }
};

fn countEvent(_: void, count: *usize) !void {
    count.* += 1;
}

test "ScmMultiDiffSourceResolver: sorts resources by path and follows live group changes after progress" {
    const a = testing.allocator;
    var svc = SCMService.init(a);
    defer svc.deinit();
    var activities = activity.ActivityService.init(a);
    defer activities.deinit();
    var provider: TestProvider = undefined;
    provider.init();
    defer provider.deinit();
    provider.group_available = false;
    var resolver = resolvers.ScmMultiDiffSourceResolver{ .allocator = a, .scm_service = svc.interface(), .activity_service = &activities };
    var sources = SourceService.init(a);
    defer sources.deinit();
    const registration = try sources.registerResolver(resolver.interface());
    defer registration.dispose();
    var root_uri = try URI.file(a, root);
    defer root_uri.deinit();
    const root_string = try root_uri.toStringEncoded(a);
    defer a.free(root_string);
    const uri = try resolvers.ScmMultiDiffSourceResolver.getMultiDiffSourceUri(a, root_string, "changes");
    defer a.free(uri);
    const source = (try sources.resolve(try std.Uri.parse(uri))).?;
    defer source.dispose(source.context);
    try testing.expect(!source.isReady());
    var count: usize = 0;
    const listener = try source.on_did_change_resources.listenDisposable(&count, countEvent);
    defer listener.dispose();
    try activities.showViewContainerActivity(scm.VIEWLET_ID, .{ .id = "scan", .badge = .{ .description = "Scanning", .is_progress = true } });
    const repository = try svc.interface().registerSCMProvider(&provider.provider);
    try testing.expect(!source.isReady());
    provider.group_available = true;
    try provider.groups_changed.fire({});
    const names = [_][]const u8{ "githubServer.ts", "env.ts", "githubUri.ts" };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (names, 0..) |name, i| {
        const path = try std.fs.path.join(arena.allocator(), &.{ root, name });
        var file = try URI.file(arena.allocator(), path);
        defer file.deinit();
        provider.entries[i] = .{ .context = &provider, .resource_group = &provider.group, .source_path = path, .multi_diff_modified_uri = try file.toStringEncoded(arena.allocator()) };
    }
    provider.entry_count = 3;
    try provider.resources_changed.fire({});
    try testing.expect(!source.isReady());
    activities.removeActivity(scm.VIEWLET_ID, "scan");
    try testing.expect(source.isReady());
    try testing.expectEqual(@as(usize, 1), count);
    const items = source.resources(source.context);
    try testing.expectEqual(@as(usize, 3), items.len);
    const expected = [_][]const u8{ "env.ts", "githubServer.ts", "githubUri.ts" };
    for (items, expected) |item, name| {
        try testing.expectEqualStrings(name, std.fs.path.basename(try std_uri.fsPath(item.goToFileUri.?, arena.allocator())));
    }
    try testing.expectEqualStrings("changes", source.get_context_keys.?(source.context).scmResourceGroup.?);
    try testing.expectEqualStrings("scm0", source.get_context_keys.?(source.context).scmProvider.?);
    provider.entry_count = 1;
    try provider.resources_changed.fire({});
    try testing.expectEqual(@as(usize, 1), source.resources(source.context).len);
    repository.dispose();
    try testing.expectEqual(@as(usize, 0), source.resources(source.context).len);
    try testing.expectEqual(@as(usize, 0), provider.resources_changed.listenerCount());
    try testing.expectEqual(@as(usize, 3), count);
}

test "ScmHistoryItemResolver: waits for the repository to be added and the history provider" {
    const a = testing.allocator;
    var svc = SCMService.init(a);
    defer svc.deinit();
    var provider: TestProvider = undefined;
    provider.init();
    defer provider.deinit();
    var resolver = resolvers.ScmHistoryItemResolver{ .allocator = a, .scm_service = svc.interface() };
    var sources = SourceService.init(a);
    defer sources.deinit();
    const registration = try sources.registerResolver(resolver.interface());
    defer registration.dispose();
    const uri = try resolvers.ScmHistoryItemResolver.getMultiDiffSourceUri(a, root, .{ .repositoryId = "scm0", .historyItemId = "commit", .historyItemParentId = "parent", .historyItemDisplayId = "display" });
    defer a.free(uri);
    const source = (try sources.resolve(try std.Uri.parse(uri))).?;
    defer source.dispose(source.context);
    try testing.expect(!source.isReady());
    var count: usize = 0;
    const listener = try source.on_did_change_resources.listenDisposable(&count, countEvent);
    defer listener.dispose();
    const repository = try svc.interface().registerSCMProvider(&provider.provider);
    try testing.expect(!source.isReady());
    provider.provider.history_provider = &provider.history_provider;
    try provider.changed.fire({});
    try testing.expect(source.isReady());
    try testing.expect(source.failure() == null);
    try testing.expectEqual(@as(usize, 1), provider.calls);
    try testing.expectEqual(@as(usize, 1), count);
    const items = source.resources(source.context);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("/original.ts", items[0].originalUri.?.path.percent_encoded);
    try testing.expectEqualStrings("/modified.ts", items[0].modifiedUri.?.path.percent_encoded);
    try testing.expectEqualStrings("/modified.ts", items[0].goToFileUri.?.path.percent_encoded);
    try testing.expectEqualStrings("modified.ts (display)", items[0].goToFileEditorTitle.?);
    try provider.changed.fire({});
    repository.dispose();
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(usize, 1), source.resources(source.context).len);
}

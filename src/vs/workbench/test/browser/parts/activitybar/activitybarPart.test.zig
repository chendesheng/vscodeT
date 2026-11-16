// Port of the portable activity-bar state tested by
// `src/vs/workbench/test/browser/parts/activitybar/activitybarPart.test.ts`.
//
// The browser suite mostly asserts CSS/theme/DOM dimensions and the custom
// menu bar. The terminal port tests the model those assertions are built on:
// activity order/visibility, compact width constraints and change events.

const std = @import("std");
const activitybar = @import("../../../../browser/parts/activitybar/activitybarPart.zig");
const ActivityBarPart = activitybar.ActivityBarPart;
const Activity = activitybar.Activity;
const activity_service_mod = @import("../../../../services/activity/browser/activityService.zig");
const ActivityService = activity_service_mod.ActivityService;

test "ActivityBarPart: default and compact width constraints" {
    var part = ActivityBarPart.init(std.testing.allocator);
    defer part.deinit();

    try std.testing.expectEqual(@as(usize, 3), part.width());
    try std.testing.expectEqual(@as(usize, 3), part.minimumWidth());
    try std.testing.expectEqual(@as(usize, 3), part.maximumWidth());
    try std.testing.expectEqual(@as(usize, 0), part.minimumHeight());
    try std.testing.expectEqual(std.math.maxInt(usize), part.maximumHeight());

    try part.setCompact(true);
    try std.testing.expectEqual(@as(usize, 2), part.width());
    try std.testing.expectEqual(@as(usize, 2), part.minimumWidth());
    try std.testing.expectEqual(@as(usize, 2), part.maximumWidth());
}

test "ActivityBarPart: compact and visibility changes fire onDidChange" {
    var part = ActivityBarPart.init(std.testing.allocator);
    defer part.deinit();

    var changes: usize = 0;
    try part.on_did_change.event(&changes, struct {
        fn callback(_: void, context: *usize) !void {
            context.* += 1;
        }
    }.callback);

    try part.setCompact(false);
    try std.testing.expectEqual(@as(usize, 0), changes);

    try part.setCompact(true);
    try std.testing.expectEqual(@as(usize, 1), changes);

    try part.setVisible(true);
    try std.testing.expectEqual(@as(usize, 2), changes);
    try part.setVisible(true);
    try std.testing.expectEqual(@as(usize, 2), changes);
    try part.setVisible(false);
    try std.testing.expectEqual(@as(usize, 3), changes);
}

test "ActivityBarPart: activities order, visibility and activation" {
    var part = ActivityBarPart.init(std.testing.allocator);
    defer part.deinit();

    try part.addActivity(.{ .id = "search", .name = "Search", .glyph = 'F', .order = 2 });
    try part.addActivity(.{ .id = "explorer", .name = "Explorer", .glyph = 'E', .order = 1 });
    try part.addActivity(.{ .id = "settings", .name = "Settings", .glyph = 'S', .order = 3, .visible = false });

    const visible = try part.visibleActivities(std.testing.allocator);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expectEqualStrings("explorer", visible[0].id);
    try std.testing.expectEqualStrings("search", visible[1].id);

    _ = try part.setActive("explorer");
    try std.testing.expectEqualStrings("explorer", part.active_id.?);
    try std.testing.expect(try part.setActive("search"));
    try std.testing.expectEqual(@as(?usize, 1), part.activeIndex());
    try std.testing.expect(!try part.setActive("settings"));
    try std.testing.expectEqual(@as(usize, 0), part.next(1, 1));
    try std.testing.expectEqual(@as(usize, 1), part.next(0, -1));

    try part.removeActivity("search");
    try std.testing.expectEqualStrings("explorer", part.active_id.?);
    try std.testing.expectEqual(@as(usize, 2), part.count());
}

test "ActivityBarPart: replacing an activity keeps its position" {
    var part = ActivityBarPart.init(std.testing.allocator);
    defer part.deinit();

    try part.addActivity(.{ .id = "explorer", .name = "Explorer", .order = 1 });
    try part.addActivity(.{ .id = "search", .name = "Search", .order = 2 });
    try part.addActivity(.{ .id = "explorer", .name = "Files", .order = 1 });

    try std.testing.expectEqual(@as(usize, 2), part.count());
    try std.testing.expectEqualStrings("Files", part.activities.items[0].name);
}

test "ActivityService: view container and global activities" {
    var service = ActivityService.init(std.testing.allocator);
    defer service.deinit();

    try service.showViewContainerActivity("explorer", .{ .id = "explorer.badge", .badge = .{ .description = "3" } });
    try service.showViewActivity("explorer.view", .{ .id = "view.badge", .badge = .{ .description = "1" } });
    try service.showGlobalActivity(.{ .id = "global.badge", .badge = .{ .description = "2" } });

    const explorer = try service.getViewContainerActivities(std.testing.allocator, "explorer");
    defer std.testing.allocator.free(explorer);
    try std.testing.expectEqual(@as(usize, 1), explorer.len);
    try std.testing.expectEqualStrings("3", explorer[0].badge.description);

    const view = try service.getViewContainerActivities(std.testing.allocator, "explorer.view");
    defer std.testing.allocator.free(view);
    try std.testing.expectEqual(@as(usize, 1), view.len);
    try std.testing.expectEqualStrings("1", view[0].badge.description);

    const global = try service.getActivity(std.testing.allocator, "global");
    defer std.testing.allocator.free(global);
    try std.testing.expectEqual(@as(usize, 1), global.len);
    try std.testing.expectEqualStrings("2", global[0].badge.description);

    const accounts = try service.getViewContainerActivities(std.testing.allocator, "accounts");
    defer std.testing.allocator.free(accounts);
    try std.testing.expectEqual(@as(usize, 0), accounts.len);

    service.removeActivity("explorer", "explorer.badge");
    const after_remove = try service.getViewContainerActivities(std.testing.allocator, "explorer");
    defer std.testing.allocator.free(after_remove);
    try std.testing.expectEqual(@as(usize, 0), after_remove.len);
}

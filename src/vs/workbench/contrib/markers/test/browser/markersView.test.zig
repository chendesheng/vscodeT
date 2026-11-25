// Tests for the portable Problems list state. The upstream
// `markersView.test.ts` exercises the Workbench widget; this port covers the
// row/selection behavior the terminal view consumes.

const ui = @import("ui");
const std = @import("std");
const markers = @import("../../../../../platform/markers/common/markers.zig");
const MarkerService = @import("../../../../../platform/markers/common/markerService.zig").MarkerService;
const view_mod = @import("../../browser/markersView.zig");

test "markersView: live refresh preserves selection by marker identity" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = markers.Resource{ .scheme = "file", .path = "/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .message = "one", .severity = markers.MarkerSeverity.Error, .start_line_number = 1 },
        .{ .message = "two", .severity = markers.MarkerSeverity.Warning, .start_line_number = 2 },
    }, null);

    var view = view_mod.MarkersView.init(allocator);
    defer view.deinit();
    view.setService(&service);
    try std.testing.expect(view.moveSelection(1));
    try std.testing.expectEqualStrings("two", view.selectedMarker().?.message);

    try service.changeOne("owner", resource, &.{
        .{ .message = "one", .severity = markers.MarkerSeverity.Error, .start_line_number = 1 },
        .{ .message = "two", .severity = markers.MarkerSeverity.Warning, .start_line_number = 2 },
        .{ .message = "three", .severity = markers.MarkerSeverity.Info, .start_line_number = 3 },
    }, null);
    try std.testing.expectEqualStrings("two", view.selectedMarker().?.message);
}

test "markersView: clearing the selected resource during a marker event is safe" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = markers.Resource{ .scheme = "file", .path = "/cleared.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .message = "first", .severity = markers.MarkerSeverity.Error, .start_line_number = 1 },
        .{ .message = "second", .severity = markers.MarkerSeverity.Warning, .start_line_number = 2 },
    }, null);

    var view = view_mod.MarkersView.init(allocator);
    defer view.deinit();
    view.setService(&service);
    try std.testing.expect(view.moveSelection(1));
    try std.testing.expectEqualStrings("second", view.selectedMarker().?.message);

    // This is the stack from the reported segfault: the change retires and then
    // frees the resource's bucket while the view still holds the selected
    // marker pointer. `refresh` must capture the selection before the service
    // releases the retired records, and must not retain the freed pointers.
    try service.changeOne("owner", resource, &.{}, null);

    try std.testing.expectEqual(@as(usize, 0), view.markerCount());
    try std.testing.expect(view.selectedMarker() == null);
    // A later refresh must operate only on the newly-built, empty model.
    try view.refresh();
    try std.testing.expectEqual(@as(usize, 0), view.markerCount());
}

test "markersView: rows, counts and selection" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();

    const resource = markers.Resource{ .scheme = "file", .path = "/b.zig" };
    const resource2 = markers.Resource{ .scheme = "file", .path = "/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .severity = markers.MarkerSeverity.Warning, .message = "warn", .start_line_number = 3 },
    }, null);
    try service.changeOne("owner", resource2, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "error", .start_line_number = 8 },
    }, null);

    var view = view_mod.MarkersView.init(allocator);
    defer view.deinit();
    view.setService(&service);

    try std.testing.expectEqual(@as(usize, 2), view.markerCount());
    try std.testing.expectEqual(@as(usize, 2), view.resourceCount());
    try std.testing.expectEqual(@as(usize, 4), view.rowCount());
    try std.testing.expectEqual(@as(usize, 1), view.counts.errors);
    try std.testing.expectEqual(@as(usize, 1), view.counts.warnings);
    // Error resource sorts before the warning resource.
    try std.testing.expectEqualStrings("/a.zig", view.rows.items[0].resource.path);

    try std.testing.expect(view.moveSelection(1));
    try std.testing.expectEqualStrings("warn", view.selectedMarker().?.message);
    try std.testing.expect(!view.moveSelection(1));
}

const testing = std.testing;

const TestHost = struct {
    previews: usize = 0,
    opens: usize = 0,
    changes: usize = 0,
    focused: usize = 0,

    fn openEditor(context: *anyopaque, _: *const markers.Marker, preserve_focus: bool, pinned: bool) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(!preserve_focus, pinned);
        if (preserve_focus) self.previews += 1 else self.opens += 1;
    }
    fn changed(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.changes += 1;
    }
    fn root(_: *anyopaque) ?[]const u8 {
        return "/repo";
    }
    fn focus(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.focused += 1;
    }
};

test "problemsView: empty state and list rendering" {
    const allocator = testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    var host = TestHost{};
    var view = view_mod.MarkersView.init(allocator);
    defer view.deinit();
    try view.attach(&service, .{
        .context = &host,
        .open_editor = TestHost.openEditor,
        .selection_changed = TestHost.changed,
        .workspace_root = TestHost.root,
        .focus_editor = TestHost.focus,
    });

    var grid = try ui.CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    try view.render(&grid, .{ .x = 0, .y = 0, .w = 40, .h = 10 }, true, .{});
    const empty = try grid.rowText(allocator, 2);
    defer allocator.free(empty);
    try testing.expect(std.mem.indexOf(u8, empty, "No problems") != null);

    const resource = markers.Resource{ .scheme = "file", .path = "/repo/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "broken", .start_line_number = 3, .start_column = 1 },
    }, null);
    try view.render(&grid, .{ .x = 0, .y = 0, .w = 40, .h = 10 }, true, .{});
    const header = try grid.rowText(allocator, 0);
    defer allocator.free(header);
    try testing.expect(std.mem.indexOf(u8, header, "PROBLEMS") != null);
    const file_row = try grid.rowText(allocator, 2);
    defer allocator.free(file_row);
    try testing.expect(std.mem.indexOf(u8, file_row, "a.zig") != null);
    const marker_row = try grid.rowText(allocator, 3);
    defer allocator.free(marker_row);
    try testing.expect(std.mem.indexOf(u8, marker_row, "3:1") != null);
    try testing.expect(std.mem.indexOf(u8, marker_row, "broken") != null);
}

test "problemsView: selection previews, enter opens and escape focuses editor" {
    const allocator = testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    const resource = markers.Resource{ .scheme = "file", .path = "/repo/a.zig" };
    try service.changeOne("owner", resource, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "one", .start_line_number = 1 },
        .{ .severity = markers.MarkerSeverity.Warning, .message = "two", .start_line_number = 2 },
    }, null);

    var host = TestHost{};
    var view = view_mod.MarkersView.init(allocator);
    defer view.deinit();
    try view.attach(&service, .{
        .context = &host,
        .open_editor = TestHost.openEditor,
        .selection_changed = TestHost.changed,
        .workspace_root = TestHost.root,
        .focus_editor = TestHost.focus,
    });

    const down = ui.KeyEvent{ .key = .down };
    try testing.expect(try view.handleKey(&down));
    try testing.expectEqual(@as(usize, 1), host.previews);
    try testing.expectEqualStrings("two", view.selectedMarker().?.message);

    const enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(try view.handleKey(&enter));
    try testing.expectEqual(@as(usize, 1), host.opens);

    const escape = ui.KeyEvent{ .key = .escape };
    try testing.expect(try view.handleKey(&escape));
    try testing.expectEqual(@as(usize, 1), host.focused);

    const rect = ui.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 };
    const click = ui.MouseEvent{ .kind = .down, .x = 4, .y = 3, .button = .left };
    try testing.expect(try view.handleMouse(&click, rect, .{}));
    try testing.expectEqual(@as(usize, 2), host.previews);
}

test "embedded Problems list clicks the displayed marker without a standalone header" {
    const allocator = std.testing.allocator;
    var service = MarkerService.init(allocator);
    defer service.deinit();
    var host = TestHost{};
    var view = view_mod.MarkersView.init(allocator);
    defer view.deinit();
    try view.attach(&service, .{
        .context = &host,
        .open_editor = TestHost.openEditor,
        .selection_changed = TestHost.changed,
        .workspace_root = TestHost.root,
        .focus_editor = TestHost.focus,
    });
    try service.changeOne("owner", .{ .scheme = "file", .path = "/repo/a.zig" }, &.{
        .{ .severity = markers.MarkerSeverity.Error, .message = "first", .start_line_number = 1 },
        .{ .severity = markers.MarkerSeverity.Error, .message = "second", .start_line_number = 2 },
    }, null);
    var grid = try ui.CellGrid.init(allocator, 40, 10);
    defer grid.deinit();
    const rect = ui.Rect{ .x = 3, .y = 4, .w = 32, .h = 4 };
    try view.render(&grid, rect, true, .{ .show_header = false });
    const row = try grid.rowText(allocator, 6);
    defer allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "second") != null);
    try std.testing.expect(try view.handleMouse(&.{ .kind = .down, .button = .left, .x = 10, .y = 6 }, rect, .{ .show_header = false }));
    try std.testing.expectEqualStrings("second", view.selectedMarker().?.message);
    try std.testing.expectEqual(1, host.previews);
}

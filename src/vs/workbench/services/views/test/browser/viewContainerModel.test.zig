// Port of `src/vs/workbench/services/views/test/browser/viewContainerModel.test.ts`.
//
// The terminal model keeps visibility/collapsed/active-view state; storage,
// context keys and move/order persistence are not ported yet.

const std = @import("std");
const views = @import("../../common/viewContainerModel.zig");
const ViewContainerModel = views.ViewContainerModel;

test "ViewContainerModel: visibility and active view" {
    const allocator = std.testing.allocator;
    var model = ViewContainerModel.init(allocator, .{
        .id = "explorer",
        .title = "Explorer",
        .icon = "files",
    });
    defer model.deinit();

    try model.addView(.{ .id = "files", .name = "Files" });
    try model.addView(.{ .id = "outline", .name = "Outline" });
    try std.testing.expectEqualStrings("files", model.activeView().?);

    model.setVisible("files", false);
    try std.testing.expect(!model.isVisible("files"));
    model.setActiveView("outline");
    try std.testing.expectEqualStrings("outline", model.activeView().?);

    const visible = try model.visibleViews(allocator);
    defer allocator.free(visible);
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqualStrings("outline", visible[0].id);
}

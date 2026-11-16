// Port of the portable sidebar state exercised by
// `src/vs/workbench/test/browser/parts/sidebar/sidebarPart.test.ts`.
//
// The browser test checks which DOM boundary sash gets the primary-sidebar
// class when the side bar position changes. The terminal model exposes the
// position that the terminal divider and tab strip use instead.

const std = @import("std");
const sidebar_mod = @import("../../../../browser/parts/sidebar/sidebarPart.zig");
const SidebarPart = sidebar_mod.SidebarPart;
const Position = sidebar_mod.Position;

test "SidebarPart: width clamps to the terminal minimum" {
    var part = SidebarPart.init(std.testing.allocator);
    defer part.deinit();

    try part.setWidth(4);
    try std.testing.expectEqual(@as(usize, 10), part.width);
    try part.setWidth(28);
    try std.testing.expectEqual(@as(usize, 28), part.width);
}

test "SidebarPart: visibility, position and active pane composite" {
    var part = SidebarPart.init(std.testing.allocator);
    defer part.deinit();

    try part.pane.addComposite(.{ .id = "explorer", .name = "Explorer", .order = 1 });
    try part.pane.addComposite(.{ .id = "search", .name = "Search", .order = 2 });

    try std.testing.expect(!part.visible);
    try std.testing.expect(try part.openPaneComposite("search"));
    try std.testing.expect(part.visible);
    try std.testing.expectEqualStrings("search", part.activePaneComposite().?.id);

    try part.setPosition(.right);
    try std.testing.expectEqual(Position.right, part.position);
    try std.testing.expect(!try part.openPaneComposite("missing"));

    try part.hideActivePaneComposite();
    try std.testing.expect(!part.visible);
    try std.testing.expect(part.activePaneComposite() == null);
    try std.testing.expectEqualStrings("search", part.pane.last_active_id.?);
}

test "PaneCompositePart: visible ids follow descriptor order" {
    var part = sidebar_mod.SidebarPart.init(std.testing.allocator);
    defer part.deinit();

    try part.pane.addComposite(.{ .id = "search", .name = "Search", .order = 2 });
    try part.pane.addComposite(.{ .id = "explorer", .name = "Explorer", .order = 1 });
    try part.pane.addComposite(.{ .id = "settings", .name = "Settings", .order = 3, .visible = false });

    const ids = try part.pane.visibleIds(std.testing.allocator);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("explorer", ids[0]);
    try std.testing.expectEqualStrings("search", ids[1]);
}

// Port of the portable layout state exercised by
// `src/vs/workbench/test/browser/layout.test.ts`.
//
// The browser tests drive the real Grid and DOM sash endpoints. The terminal
// port tests the part-visibility/size state that the terminal workbench uses
// instead; grid composition stays in `src/vs/workbench/browser/workbench.zig`.

const std = @import("std");
const layout_mod = @import("../../browser/layout.zig");
const LayoutModel = layout_mod.LayoutModel;
const Parts = layout_mod.Parts;
const Position = layout_mod.Position;

test "LayoutModel: defaults and part visibility" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    try std.testing.expect(layout.isVisible(.titlebar));
    try std.testing.expect(layout.isVisible(.activitybar));
    try std.testing.expect(layout.isVisible(.sidebar));
    try std.testing.expect(layout.isVisible(.editor));
    try std.testing.expect(layout.isVisible(.statusbar));
    try std.testing.expectEqual(Position.left, layout.sidebarPosition());

    try layout.setVisible(.sidebar, false);
    try std.testing.expect(!layout.isVisible(.sidebar));
    try layout.setVisible(.sidebar, false);
    try std.testing.expect(!layout.isVisible(.sidebar));
    try layout.setVisible(.sidebar, true);
    try std.testing.expect(layout.isVisible(.sidebar));
}

test "LayoutModel: sizes and sidebar position fire changes" {
    var layout = LayoutModel.init(std.testing.allocator);
    defer layout.deinit();

    var changes: usize = 0;
    try layout.on_did_change.event(&changes, struct {
        fn callback(_: void, context: *usize) !void {
            context.* += 1;
        }
    }.callback);

    try layout.setSize(.sidebar, 28);
    try std.testing.expectEqual(@as(usize, 28), layout.size(.sidebar));
    try std.testing.expectEqual(@as(usize, 1), changes);

    try layout.setSize(.sidebar, 28);
    try std.testing.expectEqual(@as(usize, 1), changes);

    try layout.setSidebarPosition(.right);
    try std.testing.expectEqual(Position.right, layout.sidebarPosition());
    try std.testing.expectEqual(@as(usize, 2), changes);
}

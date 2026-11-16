// Port of the core IndexTree view cases of
// `src/vs/base/test/browser/ui/tree/indexTree.test.ts` (upstream keeps the
// model tests in indexTreeModel.test.ts; this covers the terminal view adapter).

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const index_tree = @import("../../../../browser/ui/tree/indexTree.zig");

const Tree = index_tree.IndexTree(i32);
const Element = @import("../../../../browser/ui/tree/tree.zig").TreeElement(i32);

fn renderRow(_: *anyopaque, row: *const list.Row, node: *const Tree.Node) void {
    const glyph: u21 = @intCast('0' + @as(u8, @intCast(node.element)));
    row.grid.putCodepoint(row.x, row.y, glyph, 1, .{});
}

test "IndexTree: splice renders the node projection" {
    const allocator = testing.allocator;
    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, "test", -1, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
    defer tree.deinit();

    const nested = [_]Element{.{ .element = 2 }};
    try tree.splice(&.{0}, 0, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &nested },
    });
    try testing.expectEqual(@as(usize, 3), tree.count());

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, '0'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, '1'), grid.cluster[grid.index(0, 1)]);
    try testing.expectEqual(@as(u32, '2'), grid.cluster[grid.index(0, 2)]);
}

test "IndexTree: right expands and left collapses" {
    const allocator = testing.allocator;
    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, "test", -1, .{
        .context = @ptrCast(&context),
        .render = renderRow,
    });
    defer tree.deinit();

    const nested = [_]Element{.{ .element = 2 }};
    try tree.splice(&.{0}, 0, &.{.{ .element = 1, .children = &nested }});
    tree.setFocus(true);
    tree.widget.view.setSelection(0);

    var left = ui.KeyEvent{ .key = .left };
    try testing.expect(tree.handleKey(&left));
    try testing.expectEqual(@as(usize, 1), tree.count());

    var right = ui.KeyEvent{ .key = .right };
    try testing.expect(tree.handleKey(&right));
    try testing.expectEqual(@as(usize, 2), tree.count());
}

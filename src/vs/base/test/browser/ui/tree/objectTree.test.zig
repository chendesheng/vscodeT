// Port of the core ObjectTree view cases of
// `src/vs/base/test/browser/ui/tree/objectTree.test.ts`.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const object_tree = @import("../../../../browser/ui/tree/objectTree.zig");

const Tree = object_tree.ObjectTree(i32);
const Element = object_tree.ObjectTreeElement(i32);

fn renderRow(_: *anyopaque, row: *const list.Row, node: *const Tree.Model.Node) void {
    const element = node.element orelse return;
    const glyph: u21 = @intCast('0' + @as(u8, @intCast(element)));
    row.grid.putCodepoint(row.x, row.y, glyph, 1, .{});
}

test "ObjectTree: setChildren renders through AbstractTree" {
    const allocator = testing.allocator;
    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, "test", .{
        .context = @ptrCast(&context),
        .render = renderRow,
    }, false);
    defer tree.deinit();

    const nested = [_]Element{.{ .element = 2 }};
    try tree.setChildren(null, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &nested },
    });
    try testing.expectEqual(@as(usize, 3), tree.count());
    try testing.expect(tree.hasElement(1));

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, '0'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, '1'), grid.cluster[grid.index(0, 1)]);
    try testing.expectEqual(@as(u32, '2'), grid.cluster[grid.index(0, 2)]);

    try testing.expect(try tree.setCollapsed(1, true, false));
    try testing.expectEqual(@as(usize, 2), tree.count());
}

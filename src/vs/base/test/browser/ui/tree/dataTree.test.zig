// Port of the synchronous input/children cases of
// `src/vs/base/test/browser/ui/tree/dataTree.test.ts`.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const data_tree = @import("../../../../browser/ui/tree/dataTree.zig");

const TestNode = struct {
    label: u8,
    children: []const *const TestNode = &.{},
};

const Data = data_tree.DataTree(*const TestNode);

fn getChildren(_: *anyopaque, element: *const TestNode) []const *const TestNode {
    return element.children;
}

fn hasChildren(_: *anyopaque, element: *const TestNode) bool {
    return element.children.len > 0;
}

fn renderRow(_: *anyopaque, row: *const list.Row, node: *const Data.Node) void {
    const element = node.element orelse return;
    row.grid.putCodepoint(row.x, row.y, element.label, 1, .{});
}

test "DataTree: setInput resolves children" {
    const allocator = testing.allocator;
    var c = TestNode{ .label = 'c' };
    var a_children = [_]*const TestNode{&c};
    var a = TestNode{ .label = 'a', .children = &a_children };
    var root_children = [_]*const TestNode{ &a, undefined };
    var b = TestNode{ .label = 'b' };
    root_children[1] = &b;
    var root = TestNode{ .label = 'r', .children = &root_children };

    var context: u8 = 0;
    _ = &context;
    const tree = try Data.init(allocator, "test", .{
        .context = @ptrCast(&context),
        .render = renderRow,
    }, .{
        .context = &context,
        .get_children = getChildren,
        .has_children = hasChildren,
    }, false, .{});
    defer tree.deinit();

    try tree.setInput(&root);
    try testing.expectEqual(@as(usize, 3), tree.count());

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, 'a'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, 'c'), grid.cluster[grid.index(0, 1)]);
    try testing.expectEqual(@as(u32, 'b'), grid.cluster[grid.index(0, 2)]);

    try tree.setInput(null);
    try testing.expectEqual(@as(usize, 0), tree.count());
}

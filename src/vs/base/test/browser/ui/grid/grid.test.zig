// Port of the split-tree cases in
// `src/vs/base/test/browser/ui/grid/grid.test.ts`, adapted to the terminal
// grid's pointer-view and rect model.

const std = @import("std");
const grid = @import("../../../../browser/ui/grid/grid.zig");
const ui = @import("ui");

fn gap(_: void, _: grid.Orientation, _: ui.Rect) f64 {
    return 0;
}

test "grid: split and assign rects" {
    const allocator = std.testing.allocator;
    var a: u32 = 1;
    var b: u32 = 2;
    var c: u32 = 3;

    var root = try grid.initNode(*u32, allocator, &a);
    defer grid.deinitRoot(*u32, allocator, root);

    try grid.splitRoot(*u32, allocator, &root, &a, .horizontal, &b, false);
    try grid.splitRoot(*u32, allocator, &root, &b, .vertical, &c, false);
    grid.layoutRoot(*u32, root, .{ .x = 0, .y = 0, .w = 100, .h = 20 }, {}, gap);

    const a_node = grid.findLeaf(*u32, root, &a).?;
    const b_node = grid.findLeaf(*u32, root, &b).?;
    const c_node = grid.findLeaf(*u32, root, &c).?;
    try std.testing.expectEqual(@as(f64, 50), a_node.rect.w);
    try std.testing.expectEqual(@as(f64, 10), b_node.rect.h);
    try std.testing.expectEqual(@as(f64, 50), b_node.rect.w);
    try std.testing.expectEqual(@as(f64, 10), c_node.rect.y);
    try std.testing.expectEqual(@as(f64, 10), c_node.rect.h);
}

test "grid: new view can be inserted first" {
    const allocator = std.testing.allocator;
    var a: u32 = 1;
    var b: u32 = 2;
    var root = try grid.initNode(*u32, allocator, &a);
    defer grid.deinitRoot(*u32, allocator, root);

    try grid.splitRoot(*u32, allocator, &root, &a, .horizontal, &b, true);
    const split = switch (root.kind) {
        .split => |*value| value,
        .leaf => return error.TestUnexpectedResult,
    };
    try std.testing.expect(split.first.kind.leaf == &b);
    try std.testing.expect(split.second.kind.leaf == &a);
}

test "grid: branch demotion keeps the sibling" {
    const allocator = std.testing.allocator;
    var a: u32 = 1;
    var b: u32 = 2;
    var root = try grid.initNode(*u32, allocator, &a);
    defer grid.deinitRoot(*u32, allocator, root);

    try grid.splitRoot(*u32, allocator, &root, &a, .horizontal, &b, false);
    try std.testing.expect(grid.removeRoot(*u32, allocator, &root, &a));
    try std.testing.expect(root.kind.leaf == &b);
}

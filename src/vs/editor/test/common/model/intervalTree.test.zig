// Regression in the upstream interval-tree test owner
// `src/vs/editor/test/common/model/intervalTree.test.ts`.
// Relative coordinates may be negative even though every resolved model
// offset is nonnegative. In particular a node can retain a positive right
// delta after its former right child has been deleted.
const std = @import("std");
const model = @import("../../../common/model/intervalTree.zig");

test "IntervalTree: negative relative offsets survive insertion, editing and deletion" {
    const a = std.testing.allocator;
    var tree = model.IntervalTree.init(a);
    defer tree.deinit();
    const root = try model.IntervalNode.init(a, 1, 1, 2);
    tree.insert(root);
    // Valid tree state: with no right child, this delta affects no absolute
    // offsets. The upstream insert subtracts it from any new right child.
    root.delta = 10;
    const right = try model.IntervalNode.init(a, 2, 3, 4);
    tree.insert(right);
    try std.testing.expectEqual(@as(isize, -7), right.start);
    try std.testing.expectEqual(@as(isize, -6), right.end);
    try std.testing.expectEqual(@as(isize, -6), right.maxEnd);
    try std.testing.expectEqual(@as(isize, 4), root.maxEnd);
    tree.resolveNode(right, 1);
    try std.testing.expectEqual(@as(usize, 3), right.cachedAbsoluteStart);
    try std.testing.expectEqual(@as(usize, 4), right.cachedAbsoluteEnd);

    try tree.acceptReplace(0, 0, 2, false);
    tree.resolveNode(right, 2);
    try std.testing.expectEqual(@as(usize, 5), right.cachedAbsoluteStart);
    try std.testing.expectEqual(@as(usize, 6), right.cachedAbsoluteEnd);
    tree.delete(root);
    root.deinit(a);
    try std.testing.expectEqual(right, tree.root);
    try std.testing.expectEqual(@as(isize, 5), right.start);
    try std.testing.expectEqual(@as(isize, 6), right.maxEnd);
}

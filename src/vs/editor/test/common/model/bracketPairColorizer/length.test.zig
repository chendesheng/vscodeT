// Port of
// `src/vs/editor/test/common/model/bracketPairColorizer/length.test.ts`.

const std = @import("std");
const tree = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig");

test "length: basic arithmetic" {
    const l1 = tree.toLength(100, 10);
    try std.testing.expectEqual(@as(usize, 100), tree.lengthLineCount(l1));
    try std.testing.expectEqual(@as(usize, 10), tree.lengthColumnCount(l1));

    try std.testing.expectEqual(tree.toLength(200, 10), tree.lengthAdd(l1, tree.toLength(100, 10)));
    try std.testing.expectEqual(tree.toLength(100, 20), tree.lengthAdd(l1, tree.toLength(0, 10)));
}

test "length: lengthDiffNonNegative" {
    try std.testing.expectEqual(tree.toLength(0, 10), tree.lengthDiffNonNegative(tree.toLength(100, 10), tree.toLength(100, 20)));
    try std.testing.expectEqual(tree.toLength(1, 20), tree.lengthDiffNonNegative(tree.toLength(100, 10), tree.toLength(101, 20)));
    try std.testing.expectEqual(tree.toLength(0, 0), tree.lengthDiffNonNegative(tree.toLength(101, 30), tree.toLength(101, 20)));
    try std.testing.expectEqual(tree.toLength(0, 0), tree.lengthDiffNonNegative(tree.toLength(102, 10), tree.toLength(101, 20)));
}

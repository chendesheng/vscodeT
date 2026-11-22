// Port of
// `src/vs/editor/test/common/model/bracketPairColorizer/smallImmutableSet.test.ts`.

const std = @import("std");
const tree = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig");
const SmallImmutableSet = tree.SmallImmutableSet;

test "smallImmutableSet: basic add, has, intersects, equals" {
    const empty = SmallImmutableSet.empty();
    const items1 = try empty.add(0);
    const items12 = try items1.add(1);
    const items2 = try empty.add(1);
    const items21 = try items2.add(0);
    const items3 = try empty.add(2);

    try std.testing.expect(items12.intersects(items1));
    try std.testing.expect(items12.has(0));
    try std.testing.expect(!items12.intersects(items3));
    try std.testing.expect(!items12.has(2));
    try std.testing.expect(items21.eql(items12));
    try std.testing.expect(!items21.eql(items2));
}

test "smallImmutableSet: many elements keep membership" {
    var set = SmallImmutableSet.empty();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (i % 2 == 0) set = try set.add(i);
    }
    i = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(i % 2 == 0, set.has(i));
    }
}

test "smallImmutableSet: overflow is an error, not a silent drop" {
    try std.testing.expectError(error.BracketSetOverflow, SmallImmutableSet.empty().add(256));
}

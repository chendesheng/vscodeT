// Port of `src/vs/editor/contrib/folding/test/browser/foldingRanges.test.ts`.
const std = @import("std");
const folding = @import("../../browser/foldingRanges.zig");
const FoldRange = folding.FoldRange;
const FoldingRegions = folding.FoldingRegions;
const FoldSource = folding.FoldSource;

fn range(from: usize, to: usize, collapsed: bool, source: FoldSource, type_name: ?[]const u8) FoldRange {
    return .{ .startLineNumber = from, .endLineNumber = to, .isCollapsed = collapsed, .source = source, .type = type_name };
}

fn expectRange(actual: FoldRange, expected: FoldRange) !void {
    try std.testing.expectEqual(expected.startLineNumber, actual.startLineNumber);
    try std.testing.expectEqual(expected.endLineNumber, actual.endLineNumber);
    try std.testing.expectEqual(expected.isCollapsed, actual.isCollapsed);
    try std.testing.expectEqual(expected.source, actual.source);
    if (expected.type) |expected_type| {
        try std.testing.expectEqualStrings(expected_type, actual.type.?);
    } else {
        try std.testing.expect(actual.type == null);
    }
}

test "FoldingRanges: findRange" {
    const allocator = std.testing.allocator;
    const ranges = [_]FoldRange{
        range(1, 2, false, .provider, null),
        range(3, 12, false, .provider, null),
        range(4, 11, false, .provider, null),
        range(5, 6, false, .provider, null),
        range(9, 10, false, .provider, null),
    };
    var regions = try FoldingRegions.fromFoldRanges(allocator, &ranges);
    defer regions.deinit();

    const expected = [_]isize{ 0, 0, 1, 2, 3, 3, 2, 2, 4, 4, 2, 1, -1 };
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, try regions.findRange(index + 1));
    }
}

test "FoldingRanges: setCollapsed" {
    const allocator = std.testing.allocator;
    const ranges = [_]FoldRange{
        range(1, 10, false, .provider, null),
        range(2, 9, false, .provider, null),
        range(3, 8, false, .provider, null),
    };
    var regions = try FoldingRegions.fromFoldRanges(allocator, &ranges);
    defer regions.deinit();
    for (0..3) |i| regions.setCollapsed(i, i % 3 == 0);
    for (0..3) |i| try std.testing.expectEqual(i % 3 == 0, regions.isCollapsed(i));
}

test "FoldingRanges: sanitizeAndMerge1" {
    const allocator = std.testing.allocator;
    const set1 = [_]FoldRange{
        range(0, 100, false, .provider, null),
        range(1, 100, false, .provider, "A"),
        range(1, 100, false, .provider, "Z"),
        range(10, 10, false, .provider, null),
        range(20, 80, false, .provider, "C1"),
        range(22, 80, true, .provider, "D1"),
        range(90, 101, false, .provider, null),
    };
    const set2 = [_]FoldRange{
        range(20, 80, true, .provider, null),
        range(18, 80, true, .provider, null),
        range(21, 81, true, .provider, "Z"),
        range(22, 80, true, .provider, "D2"),
    };
    const result = try folding.sanitizeAndMerge(allocator, .{ .ranges = &set1 }, .{ .ranges = &set2 }, 100, null);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try expectRange(result[0], range(1, 100, false, .provider, "A"));
    try expectRange(result[1], range(20, 80, true, .provider, "C1"));
    try expectRange(result[2], range(22, 80, true, .provider, "D1"));
}

test "FoldingRanges: sanitizeAndMerge2" {
    const allocator = std.testing.allocator;
    const set1 = [_]FoldRange{
        range(1, 100, false, .provider, "a1"),
        range(2, 100, false, .provider, "a2"),
        range(3, 19, false, .provider, "a3"),
        range(20, 71, false, .provider, "a4"),
        range(21, 29, false, .provider, "a5"),
        range(81, 91, false, .provider, "a6"),
    };
    const set2 = [_]FoldRange{
        range(30, 39, true, .provider, "b1"),
        range(40, 49, true, .user_defined, "b2"),
        range(50, 100, true, .user_defined, "b3"),
        range(80, 90, true, .user_defined, "b4"),
        range(92, 100, true, .user_defined, "b5"),
    };
    const result = try folding.sanitizeAndMerge(allocator, .{ .ranges = &set1 }, .{ .ranges = &set2 }, 100, null);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 9), result.len);
    try expectRange(result[4], range(30, 39, true, .recovered, "b1"));
    try expectRange(result[5], range(40, 49, true, .user_defined, "b2"));
    try expectRange(result[6], range(50, 100, true, .user_defined, "b3"));
    try expectRange(result[8], range(92, 100, true, .user_defined, "b5"));
}

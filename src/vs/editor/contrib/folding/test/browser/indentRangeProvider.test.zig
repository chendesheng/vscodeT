// Port of the indentation-provider cases from
// `src/vs/editor/contrib/folding/test/browser/indentRangeProvider.test.ts`.
const std = @import("std");
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const indent = @import("../../browser/indentRangeProvider.zig");

test "indentRangeProvider: folds one level" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "A\n  A\n  A\n    A\nA", "nullLanguage");
    defer ctx.deinit();
    var reporter = indent.FoldingLimitReporter{ .limit = 1000 };
    var ranges = try indent.computeRanges(allocator, ctx.model, true, null, &reporter);
    defer ranges.deinit();
    try std.testing.expect(ranges.length() >= 1);
    try std.testing.expectEqual(@as(usize, 1), ranges.getStartLineNumber(0));
    try std.testing.expectEqual(@as(usize, 4), ranges.getEndLineNumber(0));
}

test "indentRangeProvider: folds two levels" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "A\n  A\n    A\n  A\nA", "nullLanguage");
    defer ctx.deinit();
    var reporter = indent.FoldingLimitReporter{ .limit = 1000 };
    var ranges = try indent.computeRanges(allocator, ctx.model, true, null, &reporter);
    defer ranges.deinit();
    try std.testing.expectEqual(@as(usize, 2), ranges.length());
    try std.testing.expectEqual(@as(usize, 1), ranges.getStartLineNumber(0));
    try std.testing.expectEqual(@as(usize, 4), ranges.getEndLineNumber(0));
    try std.testing.expectEqual(@as(usize, 2), ranges.getStartLineNumber(1));
    try std.testing.expectEqual(@as(usize, 3), ranges.getEndLineNumber(1));
}

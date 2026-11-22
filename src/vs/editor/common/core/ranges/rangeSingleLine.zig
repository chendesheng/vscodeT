// Port of `src/vs/editor/common/core/ranges/rangeSingleLine.ts`.
const std = @import("std");
const ColumnRange = @import("columnRange.zig").ColumnRange;
const Range = @import("../range.zig").Range;

pub const RangeSingleLine = struct {
    lineNumber: usize,
    columnRange: ColumnRange,

    pub fn fromRange(range: Range) ?RangeSingleLine {
        if (range.endLineNumber != range.startLineNumber) return null;
        return .{
            .lineNumber = range.startLineNumber,
            .columnRange = ColumnRange.init(range.startColumn, range.endColumn) catch return null,
        };
    }

    pub fn toRange(self: RangeSingleLine) Range {
        return Range.init(self.lineNumber, self.columnRange.startColumn, self.lineNumber, self.columnRange.endColumnExclusive);
    }
};

test "rangeSingleLine: round trip" {
    const single = RangeSingleLine.fromRange(Range.init(2, 3, 2, 5)).?;
    const range = single.toRange();
    try std.testing.expectEqual(@as(usize, 2), range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), range.startColumn);
    try std.testing.expectEqual(@as(usize, 5), range.endColumn);
    try std.testing.expect(RangeSingleLine.fromRange(Range.init(1, 1, 2, 1)) == null);
}

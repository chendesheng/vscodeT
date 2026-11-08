const std = @import("std");
const OffsetRange = @import("offsetRange.zig").OffsetRange;
const Range = @import("../range.zig").Range;

/// A 1-based range of columns.
pub const ColumnRange = struct {
    startColumn: usize,
    endColumnExclusive: usize,

    pub fn init(startColumn: usize, endColumnExclusive: usize) !ColumnRange {
        if (startColumn > endColumnExclusive) return error.InvalidColumnRange;
        return .{ .startColumn = startColumn, .endColumnExclusive = endColumnExclusive };
    }

    pub fn fromOffsetRange(offsetRange: OffsetRange) !ColumnRange {
        return init(offsetRange.start + 1, offsetRange.endExclusive + 1);
    }

    pub fn toRange(self: ColumnRange, lineNumber: usize) Range {
        return Range.init(lineNumber, self.startColumn, lineNumber, self.endColumnExclusive);
    }

    pub fn equals(self: ColumnRange, other: ColumnRange) bool {
        return self.startColumn == other.startColumn and self.endColumnExclusive == other.endColumnExclusive;
    }

    pub fn toZeroBasedOffsetRange(self: ColumnRange) OffsetRange {
        return OffsetRange.init(self.startColumn - 1, self.endColumnExclusive - 1);
    }
};

test "columnRange: conversion and validation" {
    const offset = OffsetRange.init(2, 5);
    const columns = try ColumnRange.fromOffsetRange(offset);
    try std.testing.expectEqual(@as(usize, 3), columns.startColumn);
    try std.testing.expectEqual(@as(usize, 6), columns.endColumnExclusive);
    try std.testing.expectError(error.InvalidColumnRange, ColumnRange.init(3, 2));
    const zero = columns.toZeroBasedOffsetRange();
    try std.testing.expectEqual(@as(usize, 2), zero.start);
    try std.testing.expectEqual(@as(usize, 5), zero.endExclusive);
}

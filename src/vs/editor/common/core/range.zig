const std = @import("std");
const usizeSub = @import("../../../base/common/utils.zig").usizeSub;
const Position = @import("./position.zig").Position;
const fmt = std.fmt;

pub const Range = struct {
    //  Line number on which the range starts (starts at 1).
    startLineNumber: usize,
    // Column on which the range starts in line `startLineNumber` (starts at 1).
    startColumn: usize,
    // Line number on which the range ends.
    endLineNumber: usize,
    // Column on which the range ends in line `endLineNumber`.
    endColumn: usize,

    pub fn startPosition(self: *const Range) Position {
        return Position.init(self.startLineNumber, self.startColumn);
    }

    pub fn endPosition(self: *const Range) Position {
        return Position.init(self.endLineNumber, self.endColumn);
    }

    pub fn fromPositions(start: Position, end: Position) Range {
        return init(start.lineNumber, start.column, end.lineNumber, end.column);
    }

    pub fn init(startLineNumber: usize, startColumn: usize, endLineNumber: usize, endColumn: usize) Range {
        if ((startLineNumber > endLineNumber) or (startLineNumber == endLineNumber and startColumn > endColumn)) {
            return .{
                .startLineNumber = endLineNumber,
                .startColumn = endColumn,
                .endLineNumber = startLineNumber,
                .endColumn = startColumn,
            };
        } else {
            return .{
                .startLineNumber = startLineNumber,
                .startColumn = startColumn,
                .endLineNumber = endLineNumber,
                .endColumn = endColumn,
            };
        }
    }

    pub fn isEmpty(self: *const Range) bool {
        return self.startLineNumber == self.endLineNumber and self.startColumn == self.endColumn;
    }

    // Test if `otherRange` is strictly in `range` (must start after, and end before). If the ranges are equal, will return false.
    pub fn strictContainsRange(self: *const Range, otherRange: *const Range) bool {
        if (otherRange.startLineNumber < self.startLineNumber or otherRange.endLineNumber < self.startLineNumber) {
            return false;
        }
        if (otherRange.startLineNumber > self.endLineNumber or otherRange.endLineNumber > self.endLineNumber) {
            return false;
        }
        if (otherRange.startLineNumber == self.startLineNumber and otherRange.startColumn <= self.startColumn) {
            return false;
        }
        if (otherRange.endLineNumber == self.endLineNumber and otherRange.endColumn >= self.endColumn) {
            return false;
        }
        return true;
    }

    // A reunion of the two ranges.
    // The smallest position will be used as the start point, and the largest one as the end point.
    pub fn plusRange(a: *const Range, b: *const Range) Range {
        var startLineNumber: usize = undefined;
        var startColumn: usize = undefined;
        var endLineNumber: usize = undefined;
        var endColumn: usize = undefined;

        if (b.startLineNumber < a.startLineNumber) {
            startLineNumber = b.startLineNumber;
            startColumn = b.startColumn;
        } else if (b.startLineNumber == a.startLineNumber) {
            startLineNumber = b.startLineNumber;
            startColumn = @min(b.startColumn, a.startColumn);
        } else {
            startLineNumber = a.startLineNumber;
            startColumn = a.startColumn;
        }

        if (b.endLineNumber > a.endLineNumber) {
            endLineNumber = b.endLineNumber;
            endColumn = b.endColumn;
        } else if (b.endLineNumber == a.endLineNumber) {
            endLineNumber = b.endLineNumber;
            endColumn = @max(b.endColumn, a.endColumn);
        } else {
            endLineNumber = a.endLineNumber;
            endColumn = a.endColumn;
        }

        return Range{
            .startLineNumber = startLineNumber,
            .startColumn = startColumn,
            .endLineNumber = endLineNumber,
            .endColumn = endColumn,
        };
    }

    // A intersection of the two ranges.
    pub fn intersectRanges(a: *const Range, b: *const Range) ?Range {
        var resultStartLineNumber = a.startLineNumber;
        var resultStartColumn = a.startColumn;
        var resultEndLineNumber = a.endLineNumber;
        var resultEndColumn = a.endColumn;
        const otherStartLineNumber = b.startLineNumber;
        const otherStartColumn = b.startColumn;
        const otherEndLineNumber = b.endLineNumber;
        const otherEndColumn = b.endColumn;

        if (resultStartLineNumber < otherStartLineNumber) {
            resultStartLineNumber = otherStartLineNumber;
            resultStartColumn = otherStartColumn;
        } else if (resultStartLineNumber == otherStartLineNumber) {
            resultStartColumn = @max(resultStartColumn, otherStartColumn);
        }

        if (resultEndLineNumber > otherEndLineNumber) {
            resultEndLineNumber = otherEndLineNumber;
            resultEndColumn = otherEndColumn;
        } else if (resultEndLineNumber == otherEndLineNumber) {
            resultEndColumn = @min(resultEndColumn, otherEndColumn);
        }

        // Check if selection is now empty
        if (resultStartLineNumber > resultEndLineNumber) {
            return null;
        }
        if (resultStartLineNumber == resultEndLineNumber and resultStartColumn > resultEndColumn) {
            return null;
        }
        return Range{
            .startLineNumber = resultStartLineNumber,
            .startColumn = resultStartColumn,
            .endLineNumber = resultEndLineNumber,
            .endColumn = resultEndColumn,
        };
    }

    // Test if range `a` equals `b`. Upstream models this as a free function so
    // that either side may be missing.
    pub fn equalsRange(a: ?Range, b: ?Range) bool {
        if (a == null or b == null) return false;
        const left = a.?;
        const right = b.?;
        return left.startLineNumber == right.startLineNumber and
            left.startColumn == right.startColumn and
            left.endLineNumber == right.endLineNumber and
            left.endColumn == right.endColumn;
    }

    // Return the end position (which will be after or equal to the start position)
    pub fn getEndPosition(self: *const Range) Position {
        return Position{
            .lineNumber = self.endLineNumber,
            .column = self.endColumn,
        };
    }

    // Return the start position (which will be before or equal to the end position)
    pub fn getStartPosition(self: *const Range) Position {
        return Position{
            .lineNumber = self.startLineNumber,
            .column = self.startColumn,
        };
    }

    // Transform to a user presentable string representation.
    pub fn toString(self: *const Range) ![]const u8 {
        var buf: [1024]u8 = undefined;
        return try fmt.bufPrint(&buf, "[{d},{d} -> {d},{d}]", .{ self.startLineNumber, self.startColumn, self.endLineNumber, self.endColumn });
    }

    // Create a new range using this range's start position, and using endLineNumber and endColumn as the end position.
    pub fn setEndPosition(self: *Range, endLineNumber: usize, endColumn: usize) Range {
        return Range{
            .startLineNumber = self.startLineNumber,
            .startColumn = self.startColumn,
            .endLineNumber = endLineNumber,
            .endColumn = endColumn,
        };
    }

    // Create a new range using this range's end position, and using startLineNumber and startColumn as the start position.
    pub fn setStartPosition(self: *Range, startLineNumber: usize, startColumn: usize) Range {
        return Range{
            .startLineNumber = startLineNumber,
            .startColumn = startColumn,
            .endLineNumber = self.endLineNumber,
            .endColumn = self.endColumn,
        };
    }

    // Create a new empty range using this range's end position.
    pub fn collapseToEnd(self: *const Range) Range {
        return Range{
            .startLineNumber = self.endLineNumber,
            .startColumn = self.endColumn,
            .endLineNumber = self.endLineNumber,
            .endColumn = self.endColumn,
        };
    }

    // Moves the range by the given amount of lines.
    pub fn delta(self: *const Range, lineCount: usize) Range {
        return Range{
            .startLineNumber = self.startLineNumber + lineCount,
            .startColumn = self.startColumn,
            .endLineNumber = self.endLineNumber + lineCount,
            .endColumn = self.endColumn,
        };
    }

    pub fn isSingleLine(self: *const Range) bool {
        return self.startLineNumber == self.endLineNumber;
    }

    // Test if `position` is in `range`. If the position is at the edges, will return true.
    pub fn containsPosition(self: *const Range, position: *const Position) bool {
        if (position.lineNumber < self.startLineNumber or position.lineNumber > self.endLineNumber) {
            return false;
        }
        if (position.lineNumber == self.startLineNumber and position.column < self.startColumn) {
            return false;
        }
        if (position.lineNumber == self.endLineNumber and position.column > self.endColumn) {
            return false;
        }
        return true;
    }

    // Test if `otherRange` is in `range`. If the ranges are equal, will return true.
    pub fn containsRange(self: *const Range, otherRange: *const Range) bool {
        if (otherRange.startLineNumber < self.startLineNumber or otherRange.endLineNumber < self.startLineNumber) {
            return false;
        }
        if (otherRange.startLineNumber > self.endLineNumber or otherRange.endLineNumber > self.endLineNumber) {
            return false;
        }
        if (otherRange.startLineNumber == self.startLineNumber and otherRange.startColumn < self.startColumn) {
            return false;
        }
        if (otherRange.endLineNumber == self.endLineNumber and otherRange.endColumn > self.endColumn) {
            return false;
        }
        return true;
    }

    pub fn lessThan(self: *const Range, other: *const Range) bool {
        return self.startLineNumber < other.startLineNumber or self.startColumn < other.startColumn;
    }
};

// Create a new range from two positions.
pub fn fromPositions(start: Position, end: ?Position) Range {
    if (end) |end_position| {
        return Range{
            .startLineNumber = start.lineNumber,
            .startColumn = start.column,
            .endLineNumber = end_position.lineNumber,
            .endColumn = end_position.column,
        };
    }
    return Range{
        .startLineNumber = start.lineNumber,
        .startColumn = start.column,
        .endLineNumber = start.lineNumber,
        .endColumn = start.column,
    };
}

// Test if the two ranges are touching in any way.
pub fn areIntersectingOrTouching(a: *const Range, b: *const Range) bool {
    // Check if `a` is before `b`
    if (a.endLineNumber < b.startLineNumber or (a.endLineNumber == b.startLineNumber and a.endColumn < b.startColumn)) {
        return false;
    }

    // Check if `b` is before `a`
    if (b.endLineNumber < a.startLineNumber or (b.endLineNumber == a.startLineNumber and b.endColumn < a.startColumn)) {
        return false;
    }

    // These ranges must intersect
    return true;
}

// Test if the two ranges are intersecting. If the ranges are touching it returns true.
pub fn areIntersecting(a: *const Range, b: *const Range) bool {
    // Check if `a` is before `b`
    if (a.endLineNumber < b.startLineNumber or (a.endLineNumber == b.startLineNumber and a.endColumn <= b.startColumn)) {
        return false;
    }

    // Check if `b` is before `a`
    if (b.endLineNumber < a.startLineNumber or (b.endLineNumber == a.startLineNumber and b.endColumn <= a.startColumn)) {
        return false;
    }

    // These ranges must intersect
    return true;
}

// Test if the two ranges are intersecting, but not touching at all.
pub fn areOnlyIntersecting(a: *const Range, b: *const Range) bool {
    // Check if `a` is before `b`
    if (a.endLineNumber < (b.startLineNumber - 1) or (a.endLineNumber == b.startLineNumber and a.endColumn < (b.startColumn - 1))) {
        return false;
    }

    // Check if `b` is before `a`
    if (b.endLineNumber < (a.startLineNumber - 1) or (b.endLineNumber == a.startLineNumber and b.endColumn < (a.startColumn - 1))) {
        return false;
    }

    // These ranges must intersect
    return true;
}

// A function that compares ranges, useful for sorting ranges
// It will first compare ranges on the startPosition and then on the endPosition
pub fn compareRangesUsingStarts(a: *const Range, b: *const Range) isize {
    if (a.startLineNumber != b.startLineNumber) return if (a.startLineNumber < b.startLineNumber) -1 else 1;
    if (a.startColumn != b.startColumn) return if (a.startColumn < b.startColumn) -1 else 1;
    if (a.endLineNumber != b.endLineNumber) return if (a.endLineNumber < b.endLineNumber) -1 else 1;
    if (a.endColumn != b.endColumn) return if (a.endColumn < b.endColumn) -1 else 1;
    return 0;
}

// A function that compares ranges, useful for sorting ranges
// It will first compare ranges on the endPosition and then on the startPosition
pub fn compareRangesUsingEnds(a: *const Range, b: *const Range) isize {
    if (a.endLineNumber == b.endLineNumber) {
        if (a.endColumn == b.endColumn) {
            if (a.startLineNumber == b.startLineNumber) {
                return usizeSub(a.startColumn, b.startColumn);
            }
            return usizeSub(a.startLineNumber, b.startLineNumber);
        }
        return usizeSub(a.endColumn, b.endColumn);
    }
    return usizeSub(a.endLineNumber, b.endLineNumber);
}

// Test if the range spans multiple lines.
pub fn spansMultipleLines(range: *const Range) bool {
    return range.endLineNumber > range.startLineNumber;
}

test "empty range" {
    const s = Range.init(1, 1, 1, 1);
    try std.testing.expectEqual(1, s.startLineNumber);
    try std.testing.expectEqual(1, s.startColumn);
    try std.testing.expectEqual(1, s.endLineNumber);
    try std.testing.expectEqual(1, s.endColumn);
    try std.testing.expectEqual(true, s.isEmpty());
}

test "swap start and stop same line" {
    const s = Range.init(1, 2, 1, 1);
    try std.testing.expectEqual(1, s.startLineNumber);
    try std.testing.expectEqual(1, s.startColumn);
    try std.testing.expectEqual(1, s.endLineNumber);
    try std.testing.expectEqual(2, s.endColumn);
    try std.testing.expectEqual(false, s.isEmpty());
}

test "swap start and stop" {
    const s = Range.init(2, 1, 1, 2);
    try std.testing.expectEqual(1, s.startLineNumber);
    try std.testing.expectEqual(2, s.startColumn);
    try std.testing.expectEqual(2, s.endLineNumber);
    try std.testing.expectEqual(1, s.endColumn);
    try std.testing.expectEqual(false, s.isEmpty());
}

test "no swap same line" {
    const s = Range.init(1, 1, 1, 2);
    try std.testing.expectEqual(1, s.startLineNumber);
    try std.testing.expectEqual(1, s.startColumn);
    try std.testing.expectEqual(1, s.endLineNumber);
    try std.testing.expectEqual(2, s.endColumn);
    try std.testing.expectEqual(false, s.isEmpty());
}

test "no swap" {
    const s = Range.init(1, 1, 2, 1);
    try std.testing.expectEqual(1, s.startLineNumber);
    try std.testing.expectEqual(1, s.startColumn);
    try std.testing.expectEqual(2, s.endLineNumber);
    try std.testing.expectEqual(1, s.endColumn);
    try std.testing.expectEqual(false, s.isEmpty());
}

test "compareRangesUsingEnds" {
    var a: Range = undefined;
    var b: Range = undefined;

    a = Range.init(1, 1, 1, 3);
    b = Range.init(1, 2, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) < 0);

    a = Range.init(1, 1, 1, 3);
    b = Range.init(1, 1, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) < 0);

    a = Range.init(1, 2, 1, 3);
    b = Range.init(1, 1, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) < 0);

    a = Range.init(1, 1, 1, 4);
    b = Range.init(1, 1, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) == 0);

    a = Range.init(1, 2, 1, 4);
    b = Range.init(1, 1, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) > 0);

    a = Range.init(1, 1, 1, 5);
    b = Range.init(1, 2, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) > 0);

    a = Range.init(1, 1, 2, 4);
    b = Range.init(1, 1, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) > 0);

    a = Range.init(1, 2, 5, 1);
    b = Range.init(1, 1, 1, 4);
    try std.testing.expect(compareRangesUsingEnds(&a, &b) > 0);
}

test "containsPosition" {
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsPosition(&Position.init(1, 3)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsPosition(&Position.init(2, 1)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsPosition(&Position.init(2, 2)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsPosition(&Position.init(2, 3)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsPosition(&Position.init(3, 1)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsPosition(&Position.init(5, 9)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsPosition(&Position.init(5, 10)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsPosition(&Position.init(5, 11)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsPosition(&Position.init(6, 1)));
}

test "containsRange" {
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsRange(&Range.init(1, 3, 2, 2)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsRange(&Range.init(2, 1, 2, 2)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsRange(&Range.init(2, 2, 5, 11)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsRange(&Range.init(2, 2, 6, 1)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsRange(&Range.init(5, 9, 6, 1)));
    try std.testing.expect(!Range.init(2, 2, 5, 10).containsRange(&Range.init(5, 10, 6, 1)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsRange(&Range.init(2, 2, 5, 10)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsRange(&Range.init(2, 3, 5, 9)));
    try std.testing.expect(Range.init(2, 2, 5, 10).containsRange(&Range.init(3, 100, 4, 100)));
}

test "areIntersecting" {
    try std.testing.expect(!areIntersecting(&Range.init(2, 2, 3, 2), &Range.init(4, 2, 5, 2)));
    try std.testing.expect(!areIntersecting(&Range.init(4, 2, 5, 2), &Range.init(2, 2, 3, 2)));
    try std.testing.expect(!areIntersecting(&Range.init(4, 2, 5, 2), &Range.init(5, 2, 6, 2)));
    try std.testing.expect(!areIntersecting(&Range.init(5, 2, 6, 2), &Range.init(4, 2, 5, 2)));
    try std.testing.expect(areIntersecting(&Range.init(2, 2, 2, 7), &Range.init(2, 4, 2, 6)));
    try std.testing.expect(areIntersecting(&Range.init(2, 2, 2, 7), &Range.init(2, 4, 2, 9)));
    try std.testing.expect(areIntersecting(&Range.init(2, 4, 2, 9), &Range.init(2, 2, 2, 7)));
}

test "fromPositions" {
    const with_end = fromPositions(.{ .lineNumber = 1, .column = 2 }, .{ .lineNumber = 3, .column = 4 });
    try std.testing.expectEqual(@as(usize, 1), with_end.startLineNumber);
    try std.testing.expectEqual(@as(usize, 3), with_end.endLineNumber);
    try std.testing.expectEqual(@as(usize, 4), with_end.endColumn);

    const single = fromPositions(.{ .lineNumber = 5, .column = 6 }, null);
    try std.testing.expectEqual(@as(usize, 5), single.startLineNumber);
    try std.testing.expectEqual(@as(usize, 5), single.endLineNumber);
    try std.testing.expectEqual(@as(usize, 6), single.endColumn);
}

test "intersectRanges keeps the narrower columns" {
    const a = Range.init(1, 5, 3, 2);
    const b = Range.init(1, 2, 3, 9);
    const result = Range.intersectRanges(&a, &b) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), result.startLineNumber);
    try std.testing.expectEqual(@as(usize, 5), result.startColumn);
    try std.testing.expectEqual(@as(usize, 3), result.endLineNumber);
    try std.testing.expectEqual(@as(usize, 2), result.endColumn);

    const same_line = Range.intersectRanges(&Range.init(1, 2, 1, 10), &Range.init(1, 5, 1, 8)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 5), same_line.startColumn);
    try std.testing.expectEqual(@as(usize, 8), same_line.endColumn);
}

const std = @import("std");
const LineRange = @import("../ranges/lineRange.zig").LineRange;
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;

/// A non-negative length of text in terms of line and column count.
pub const TextLength = struct {
    lineCount: usize,
    columnCount: usize,

    pub const zero: TextLength = .{ .lineCount = 0, .columnCount = 0 };

    pub fn lengthDiffNonNegative(start: TextLength, end: TextLength) TextLength {
        if (end.isLessThan(start)) return zero;
        if (start.lineCount == end.lineCount) {
            return .{ .lineCount = 0, .columnCount = end.columnCount - start.columnCount };
        }
        return .{ .lineCount = end.lineCount - start.lineCount, .columnCount = end.columnCount };
    }

    pub fn betweenPositions(position1: Position, position2: Position) TextLength {
        if (position1.lineNumber == position2.lineNumber) {
            return .{ .lineCount = 0, .columnCount = position2.column - position1.column };
        }
        return .{ .lineCount = position2.lineNumber - position1.lineNumber, .columnCount = position2.column - 1 };
    }

    pub fn fromPosition(pos: Position) TextLength {
        return .{ .lineCount = pos.lineNumber - 1, .columnCount = pos.column - 1 };
    }

    pub fn ofRange(range: Range) TextLength {
        return betweenPositions(range.getStartPosition(), range.getEndPosition());
    }

    pub fn ofText(text: []const u8) TextLength {
        var line: usize = 0;
        var column: usize = 0;
        for (text) |ch| {
            if (ch == '\n') {
                line += 1;
                column = 0;
            } else {
                column += 1;
            }
        }
        return .{ .lineCount = line, .columnCount = column };
    }

    pub fn ofSubstr(text: []const u8, range: OffsetRange) TextLength {
        return ofText(range.substring(text));
    }

    pub fn isZero(self: TextLength) bool {
        return self.lineCount == 0 and self.columnCount == 0;
    }

    pub fn isLessThan(self: TextLength, other: TextLength) bool {
        if (self.lineCount != other.lineCount) return self.lineCount < other.lineCount;
        return self.columnCount < other.columnCount;
    }

    pub fn isGreaterThan(self: TextLength, other: TextLength) bool {
        if (self.lineCount != other.lineCount) return self.lineCount > other.lineCount;
        return self.columnCount > other.columnCount;
    }

    pub fn isGreaterThanOrEqualTo(self: TextLength, other: TextLength) bool {
        if (self.lineCount != other.lineCount) return self.lineCount > other.lineCount;
        return self.columnCount >= other.columnCount;
    }

    pub fn equals(self: TextLength, other: TextLength) bool {
        return self.lineCount == other.lineCount and self.columnCount == other.columnCount;
    }

    pub fn compare(self: TextLength, other: TextLength) isize {
        if (self.lineCount != other.lineCount) {
            return @as(isize, @intCast(self.lineCount)) - @as(isize, @intCast(other.lineCount));
        }
        return @as(isize, @intCast(self.columnCount)) - @as(isize, @intCast(other.columnCount));
    }

    pub fn add(self: TextLength, other: TextLength) TextLength {
        if (other.lineCount == 0) {
            return .{ .lineCount = self.lineCount, .columnCount = self.columnCount + other.columnCount };
        }
        return .{ .lineCount = self.lineCount + other.lineCount, .columnCount = other.columnCount };
    }

    pub fn createRange(self: TextLength, startPosition: Position) Range {
        if (self.lineCount == 0) {
            return Range.init(startPosition.lineNumber, startPosition.column, startPosition.lineNumber, startPosition.column + self.columnCount);
        }
        return Range.init(startPosition.lineNumber, startPosition.column, startPosition.lineNumber + self.lineCount, self.columnCount + 1);
    }

    pub fn toRange(self: TextLength) Range {
        return Range.init(1, 1, self.lineCount + 1, self.columnCount + 1);
    }

    pub fn toLineRange(self: TextLength) LineRange {
        return LineRange.ofLength(1, self.lineCount + 1);
    }

    pub fn addToPosition(self: TextLength, position: Position) Position {
        if (self.lineCount == 0) {
            return Position.init(position.lineNumber, position.column + self.columnCount);
        }
        return Position.init(position.lineNumber + self.lineCount, self.columnCount + 1);
    }

    pub fn addToRange(self: TextLength, range: Range) Range {
        const start = self.addToPosition(range.getStartPosition());
        const end = self.addToPosition(range.getEndPosition());
        return Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
    }
};

test "textLength: positions, text, and arithmetic" {
    try std.testing.expect(TextLength.fromPosition(Position.init(3, 4)).equals(.{ .lineCount = 2, .columnCount = 3 }));
    try std.testing.expect(TextLength.ofText("ab\ncde").equals(.{ .lineCount = 1, .columnCount = 3 }));
    try std.testing.expect(TextLength.betweenPositions(Position.init(1, 2), Position.init(1, 5)).equals(.{ .lineCount = 0, .columnCount = 3 }));
    const length = TextLength{ .lineCount = 1, .columnCount = 2 };
    const pos = length.addToPosition(Position.init(1, 1));
    try std.testing.expectEqual(@as(usize, 2), pos.lineNumber);
    try std.testing.expectEqual(@as(usize, 3), pos.column);
    try std.testing.expect(TextLength.zero.isZero());
}

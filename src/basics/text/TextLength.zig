const std = @import("std");
const LineRange = @import("../lineRange.zig").LineRange;
const usizeSub = @import("../utils.zig").usizeSub;
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const OffsetRange = @import("../offsetRange.zig").OffsetRange;

const TextLength = @This();

// Represents a non-negative length of text in terms of line and column count.
pub const zero = TextLength.init(0, 0);

pub fn lengthDiffNonNegative(start: TextLength, end: TextLength) TextLength {
    if (end.isLessThan(start)) {
        return TextLength.zero;
    }
    if (start.lineCount == end.lineCount) {
        return TextLength.init(0, end.columnCount - start.columnCount);
    } else {
        return TextLength.init(end.lineCount - start.lineCount, end.columnCount);
    }
}

pub fn betweenPositions(position1: Position, position2: Position) TextLength {
    if (position1.lineNumber == position2.lineNumber) {
        return TextLength.init(0, position2.column - position1.column);
    } else {
        return TextLength.init(position2.lineNumber - position1.lineNumber, position2.column - 1);
    }
}

pub fn fromPosition(pos: Position) TextLength {
    return TextLength.init(pos.lineNumber - 1, pos.column - 1);
}

pub fn ofRange(range: Range) TextLength {
    return TextLength.betweenPositions(range.getStartPosition(), range.getEndPosition());
}

pub fn ofText(text: []const u8) TextLength {
    var line: usize = 0;
    var column: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    return TextLength.init(line, column);
}

pub fn ofSubstr(str: []const u8, range: OffsetRange) TextLength {
    return TextLength.ofText(str[range.start..range.endExclusive]);
}

pub fn sum(comptime T: type, fragments: []const T, getLength: fn (f: T) TextLength) TextLength {
    var acc = TextLength.zero;
    for (fragments) |f| {
        acc = acc.add(getLength(f));
    }
    return acc;
}

lineCount: usize,
columnCount: usize,

pub fn init(lineCount: usize, columnCount: usize) TextLength {
    return .{
        .lineCount = lineCount,
        .columnCount = columnCount,
    };
}

pub fn isZero(self: *const TextLength) bool {
    return self.lineCount == 0 and self.columnCount == 0;
}

pub fn isLessThan(self: *const TextLength, other: TextLength) bool {
    if (self.lineCount != other.lineCount) {
        return self.lineCount < other.lineCount;
    }
    return self.columnCount < other.columnCount;
}

pub fn isGreaterThan(self: *const TextLength, other: TextLength) bool {
    if (self.lineCount != other.lineCount) {
        return self.lineCount > other.lineCount;
    }
    return self.columnCount > other.columnCount;
}

pub fn isGreaterThanOrEqualTo(self: *const TextLength, other: TextLength) bool {
    if (self.lineCount != other.lineCount) {
        return self.lineCount > other.lineCount;
    }
    return self.columnCount >= other.columnCount;
}

pub fn equals(self: *const TextLength, other: TextLength) bool {
    return self.lineCount == other.lineCount and self.columnCount == other.columnCount;
}

pub fn compare(self: *const TextLength, other: TextLength) isize {
    if (self.lineCount != other.lineCount) {
        return usizeSub(self.lineCount, other.lineCount);
    }
    return usizeSub(self.columnCount, other.columnCount);
}

pub fn add(self: *const TextLength, other: TextLength) TextLength {
    if (other.lineCount == 0) {
        return TextLength.init(self.lineCount, self.columnCount + other.columnCount);
    } else {
        return TextLength.init(self.lineCount + other.lineCount, other.columnCount);
    }
}

pub fn createRange(self: *const TextLength, startPosition: Position) Range {
    if (self.lineCount == 0) {
        return Range.init(startPosition.lineNumber, startPosition.column, startPosition.lineNumber, startPosition.column + self.columnCount);
    } else {
        return Range.init(startPosition.lineNumber, startPosition.column, startPosition.lineNumber + self.lineCount, self.columnCount + 1);
    }
}

pub fn toRange(self: *const TextLength) Range {
    return Range.init(1, 1, self.lineCount + 1, self.columnCount + 1);
}

pub fn toLineRange(self: *const TextLength) LineRange {
    return LineRange.ofLength(1, self.lineCount + 1);
}

pub fn addToPosition(self: *const TextLength, position: Position) Position {
    if (self.lineCount == 0) {
        return Position.init(position.lineNumber, position.column + self.columnCount);
    } else {
        return Position.init(position.lineNumber + self.lineCount, self.columnCount + 1);
    }
}

pub fn addToRange(self: *const TextLength, range: Range) Range {
    return Range.fromPositions(self.addToPosition(range.getStartPosition()), self.addToPosition(range.getEndPosition()));
}

pub fn toString(self: *const TextLength) []const u8 {
    var buf: [32]u8 = undefined;
    return std.fmt.bufPrint(&buf, "{d},{d}", .{ self.lineCount, self.columnCount }) catch unreachable;
}

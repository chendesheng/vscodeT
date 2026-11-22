// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/length.ts`.
//
// Lengths are UTF-8 byte columns, not UTF-16 code units.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Position = @import("../../../core/position.zig").Position;
const Range = @import("../../../core/range.zig").Range;

pub const factor: u64 = 1 << 32;

/// A compact line/column length. Upper 32 bits are lines, lower 32 columns.
pub const Length = u64;

pub fn toLength(lineCount: usize, columnCount: usize) Length {
    return (@as(u64, @intCast(lineCount)) << 32) | @as(u64, @intCast(columnCount));
}

pub fn lengthZero() Length {
    return 0;
}

pub fn lengthLineCount(length: Length) usize {
    return @intCast(length >> 32);
}

/// Returns the amount of columns of the given length, assuming that it does not
/// span any line.
pub fn lengthGetColumnCountIfZeroLineCount(length: Length) usize {
    return @intCast(length);
}

pub fn lengthColumnCount(length: Length) usize {
    return @intCast(length & 0xFFFF_FFFF);
}

pub fn lengthAdd(a: Length, b: Length) Length {
    if (b >> 32 != 0) return toLength(lengthLineCount(a) + lengthLineCount(b), lengthColumnCount(b));
    return toLength(lengthLineCount(a), lengthColumnCount(a) + lengthColumnCount(b));
}

pub fn lengthOfString(text: []const u8) Length {
    // Upstream uses `splitLines` (`/\r\n|\r|\n/`): CRLF is a single line
    // break, not two.
    var lines: usize = 0;
    var last_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            lines += 1;
            i += 1;
            if (i < text.len and text[i] == '\n') i += 1;
            last_start = i;
        } else if (text[i] == '\n') {
            lines += 1;
            i += 1;
            last_start = i;
        } else {
            i += 1;
        }
    }
    return toLength(lines, text.len - last_start);
}

pub fn positionToLength(position: Position) Length {
    return toLength(position.lineNumber - 1, position.column - 1);
}

pub const LengthObj = struct {
    lineCount: usize,
    columnCount: usize,

    pub fn toString(self: LengthObj, allocator: Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{d},{d}", .{ self.lineCount, self.columnCount });
    }
};

/// Upstream `lengthToObj`.
pub fn lengthToObj(length: Length) LengthObj {
    return .{ .lineCount = lengthLineCount(length), .columnCount = lengthColumnCount(length) };
}

pub fn lengthToPosition(length: Length) Position {
    return Position.init(lengthLineCount(length) + 1, lengthColumnCount(length) + 1);
}

/// Upstream `lengthsToRange`: turn an AST span into a document range. Cached
/// nodes are reused after edits, so a bracket position can only be derived
/// from the node's current offset, never from its tokenization position.
pub fn lengthsToRange(start: Length, end: Length) Range {
    return Range.init(
        lengthLineCount(start) + 1,
        lengthColumnCount(start) + 1,
        lengthLineCount(end) + 1,
        lengthColumnCount(end) + 1,
    );
}

pub fn lengthDiff(start: Length, end: Length) Length {
    if (lengthLineCount(start) != lengthLineCount(end)) {
        return toLength(lengthLineCount(end) - lengthLineCount(start), lengthColumnCount(end));
    }
    return toLength(0, lengthColumnCount(end) - lengthColumnCount(start));
}

pub fn lengthDiffNonNegative(start: Length, end: Length) Length {
    if (!lengthLessThan(start, end)) return 0;
    return lengthDiff(start, end);
}

pub fn lengthEquals(a: Length, b: Length) bool {
    return a == b;
}

pub fn lengthBetween(start: Position, end: Position) Length {
    if (start.lineNumber == end.lineNumber) {
        return toLength(0, end.column - start.column);
    }
    return toLength(end.lineNumber - start.lineNumber, end.column - 1);
}

pub fn lengthIsZero(length: Length) bool {
    return length == 0;
}

pub fn lengthLessThanEqual(a: Length, b: Length) bool {
    return a == b or lengthLessThan(a, b);
}

pub fn lengthLessThan(a: Length, b: Length) bool {
    if (lengthLineCount(a) != lengthLineCount(b)) return lengthLineCount(a) < lengthLineCount(b);
    return lengthColumnCount(a) < lengthColumnCount(b);
}

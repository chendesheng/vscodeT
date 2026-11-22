// Port of `src/vs/editor/common/core/position.ts`.
const std = @import("std");
const Io = std.Io;

pub const Position = struct {
    lineNumber: usize,
    column: usize,

    pub fn init(line: usize, col: usize) Position {
        return .{
            .lineNumber = line,
            .column = col,
        };
    }

    pub fn create(line: usize, col: usize) Position {
        return .{
            .lineNumber = line,
            .column = col,
        };
    }

    /// Create a new position from this position. `null` keeps the current value.
    pub fn with(self: Position, newLineNumber: ?usize, newColumn: ?usize) Position {
        const line = newLineNumber orelse self.lineNumber;
        const col = newColumn orelse self.column;
        if (line == self.lineNumber and col == self.column) {
            return self;
        }
        return init(line, col);
    }

    pub fn clone(self: Position) Position {
        return self;
    }

    /// Create a `Position` from an `IPosition`-shaped value.
    pub fn lift(pos: Position) Position {
        return pos;
    }

    pub fn toString(self: Position, writer: *Io.Writer) !void {
        try writer.print("({d},{d})", .{ self.lineNumber, self.column });
    }

    pub fn isBefore(self: *const Position, other: Position) bool {
        if (self.lineNumber < other.lineNumber) {
            return true;
        }
        if (self.lineNumber > other.lineNumber) {
            return false;
        }
        return self.column < other.column;
    }

    pub fn compare(a: Position, b: Position) isize {
        if (a.lineNumber < b.lineNumber) return -1;
        if (a.lineNumber > b.lineNumber) return 1;
        if (a.column < b.column) return -1;
        if (a.column > b.column) return 1;
        return 0;
    }

    pub fn equals(self: *const Position, other: Position) bool {
        return self.lineNumber == other.lineNumber and self.column == other.column;
    }

    pub fn delta(self: Position, lineDelta: ?isize, columnDelta: isize) Position {
        const new_line = if (lineDelta) |d| @as(isize, @intCast(self.lineNumber)) + d else @as(isize, @intCast(self.lineNumber));
        const new_column = @as(isize, @intCast(self.column)) + columnDelta;
        return .{
            .lineNumber = @intCast(@max(new_line, 1)),
            .column = @intCast(@max(new_column, 1)),
        };
    }

    pub fn isBeforeOrEqual(self: *const Position, other: Position) bool {
        if (self.lineNumber < other.lineNumber) {
            return true;
        }
        if (self.lineNumber > other.lineNumber) {
            return false;
        }
        return self.column <= other.column;
    }
};

test "Position: with, clone, lift and toString" {
    const pos = Position.init(2, 3);
    try std.testing.expectEqual(pos, pos.clone());
    try std.testing.expectEqual(pos, Position.lift(pos));
    try std.testing.expectEqual(Position.init(2, 5), pos.with(null, 5));
    try std.testing.expectEqual(Position.init(7, 3), pos.with(7, null));
    try std.testing.expectEqual(pos, pos.with(null, null));

    var buffer: [32]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try pos.toString(&writer);
    try std.testing.expectEqualStrings("(2,3)", writer.buffered());
}

const std = @import("std");

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

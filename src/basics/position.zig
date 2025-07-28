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

const std = @import("std");

pub const Position = struct {
    lineNumber: usize,
    column: usize,

    pub fn create(line: usize, col: usize) Position {
        return .{
            .lineNumber = line,
            .column = col,
        };
    }
};

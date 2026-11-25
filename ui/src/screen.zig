//! ANSI screen-control sequences shared by the terminal host and its examples.
//!
//! These are the portable escape strings only; raw mode, reading, polling and
//! signal handling stay in the host. `std.Io.Writer` is the boundary so the
//! same helpers work for a terminal, a pipe or a test buffer.

const std = @import("std");

/// Moves the hardware cursor to a one-based terminal position.
pub fn moveCursor(out: *std.Io.Writer, row: usize, col: usize) !void {
    try out.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn hideCursor(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[?25l");
}

pub fn showCursor(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[?25h");
}

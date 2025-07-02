// https://viewsourcecode.org/snaptoken/kilo/index.html
const std = @import("std");
const ArrayList = std.ArrayList;
const posix = std.posix;
const termios = posix.system.termios;

pub fn enableRawMode() !termios {
    const orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = orig_termios;

    // Disable canonical mode, echo, extended input processing, and signals
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    // Disable IXON and ICRNL in input flags
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;

    // Disable post‑processing of output
    raw.oflag.OPOST = false;

    raw.cc[@intFromEnum(posix.system.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.system.V.TIME)] = 1;

    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, raw);

    return orig_termios;
}

pub fn disableRawMode(orig_termios: termios) !void {
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, orig_termios);
}

pub fn writeAll(writer: anytype, text: []const u8) !void {
    try writer.writeAll(text);
}

pub fn getTerminalSize() !struct { width: u16, height: u16 } {
    var size: posix.winsize = undefined;
    _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&size));
    return .{
        .width = size.col,
        .height = size.row,
    };
}

pub fn clearScreen(out: anytype) !void {
    try writeAll(out, "\x1b[2J"); // clear screen
}

pub fn getCursorPosition() !struct { row: usize, col: usize } {
    const stdout = std.io.getStdOut();
    const stdin = std.io.getStdIn();

    // Step 1: Ask for cursor position
    try stdout.writer().writeAll("\x1b[6n");

    // Step 2: Read the response
    var buf: [32]u8 = undefined;
    const n = try stdin.reader().readUntilDelimiterOrEof(&buf, 'R');

    if (n == null) return error.CursorResponseTimeout;

    // Example response: ESC [ 12 ; 40 R
    const response = n.?;

    // Strip prefix: "\x1b["
    if (response.len < 2 or response[0] != 0x1B or response[1] != '[') {
        return error.InvalidCursorResponse;
    }

    // Step 3: Parse "{ROW};{COL}"
    var parts = std.mem.splitSequence(u8, response[2..], ";");
    const row_str = parts.next() orelse return error.MissingRow;
    const col_str = parts.next() orelse return error.MissingCol;

    const row = try std.fmt.parseUnsigned(usize, row_str, 10);
    const col = try std.fmt.parseUnsigned(usize, col_str, 10);

    return .{ .row = row, .col = col };
}

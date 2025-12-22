// https://viewsourcecode.org/snaptoken/kilo/index.html
const std = @import("std");
const ArrayList = std.array_list.Managed;
const posix = std.posix;
const termios = posix.system.termios;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

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
    raw.cc[@intFromEnum(posix.system.V.TIME)] = 0;

    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, raw);

    return orig_termios;
}

pub fn enableLineWrap(out: File) !void {
    try writeAll(out, "\x1b[?7h");
}

pub fn disableLineWrap(out: File) !void {
    try writeAll(out, "\x1b[?7l");
}

pub fn enableBracketedPaste(out: File) !void {
    try writeAll(out, "\x1b[?2004h");
}

pub fn disableBracketedPaste(out: File) !void {
    try writeAll(out, "\x1b[?2004l");
}

pub fn disableRawMode(orig_termios: termios) !void {
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, orig_termios);
}

pub fn writeAll(writer: std.fs.File, text: []const u8) !void {
    try writer.writeAll(text);
}

pub fn enterAltScreen(out: File) !void {
    try writeAll(out, "\x1b[?1049h");
}

pub fn exitAltScreen(out: File) !void {
    try writeAll(out, "\x1b[?1049l");
}

pub const Point = struct {
    col: usize,
    row: usize,

    pub fn equals(self: *const Point, other: Point) bool {
        return self.row == other.row and self.col == other.col;
    }
};

pub const Size = struct {
    width: usize,
    height: usize,

    pub fn equals(self: *const Size, other: Size) bool {
        return self.width == other.width and self.height == other.height;
    }
};

pub fn getTerminalSize() !Size {
    var size: posix.winsize = undefined;
    _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&size));
    return .{
        .width = size.col,
        .height = size.row,
    };
}

pub fn clearScreen(out: File) !void {
    try writeAll(out, "\x1b[2J"); // clear screen
}

pub fn clearToEndOfScreen(out: File) !void {
    try writeAll(out, "\x1b[J");
}

pub fn getCursorPosition() !Point {
    const stdout = File.stdout();
    const stdin = File.stdin();

    // Step 1: Ask for cursor position
    try stdout.writeAll("\x1b[6n");

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

pub fn moveCursor(out: File, point: Point) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(buf[0..], "\x1b[{d};{d}H", .{ point.row, point.col });
    try writeAll(out, text);
}

pub fn moveCursorBy(out: File, row: isize, col: isize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(buf[0..], "\x1b[{d};{d}H", .{ row, col });
    try writeAll(out, text);
}

pub fn hideCursor(out: File) !void {
    try writeAll(out, "\x1b[?25l");
}

pub fn showCursor(out: File) !void {
    try writeAll(out, "\x1b[?25h");
}

var g_orig_termios: ?std.posix.termios = null;
pub fn rememberOrigTermios(t: std.posix.termios) void {
    g_orig_termios = t;
}

pub const panic = std.debug.FullPanic(myPanic);

pub fn myPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (g_orig_termios) |t| {
        _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, t) catch {};
    }

    const stdout = File.stdout();

    exitAltScreen(stdout) catch {};
    enableLineWrap(stdout) catch {};

    std.debug.defaultPanic(msg, first_trace_addr);

    std.process.exit(1);
}

var resized = std.atomic.Value(bool).init(false);

fn handleSigWinch(_: i32) callconv(.c) void {
    resized.store(true, .seq_cst);
}

pub fn resizedSize() !?Size {
    if (resized.swap(false, .seq_cst)) {
        return try getTerminalSize();
    } else {
        return null;
    }
}

pub fn installSigWinch() !void {
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = handleSigWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
}

pub fn readFd(fd: posix.fd_t, buffer: *ArrayList(u8)) ![]const u8 {
    var tmp: [32]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &tmp);
        if (n > 0) {
            try buffer.appendSlice(tmp[0..n]);
        } else {
            break;
        }
    }
    return buffer.items;
}

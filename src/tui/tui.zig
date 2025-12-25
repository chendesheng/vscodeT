// https://viewsourcecode.org/snaptoken/kilo/index.html
const std = @import("std");
const ansi = @import("ansi.zig");
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

pub fn writeAll(writer: File, text: []const u8) !void {
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

pub const SGRAttribute = enum(u8) {
    Reset = 0,
    Bold = 1,
    Dim = 2,
    Italic = 3,
    Underline = 4,
    Blink = 5,
    Reverse = 7,
    Hidden = 8,
    Strikethrough = 9,

    DoubleUnderline = 21,
    NormalIntensity = 22,
    NeitherItalicNorBlackletter = 23,
    NotUnderlined = 24,
    NotBlink = 25,
    ProportionalSpacing = 26,
    NotReversed = 27,
    NotHidden = 28,
    NotStrikethrough = 29,
    DefaultForeground = 39,
    DefaultBackground = 49,

    ForegroundBlack = 30,
    ForegroundRed = 31,
    ForegroundGreen = 32,
    ForegroundYellow = 33,
    ForegroundBlue = 34,
    ForegroundMagenta = 35,
    ForegroundCyan = 36,
    ForegroundWhite = 37,
    ForegroundGray = 90,
    ForegroundBrightRed = 91,
    ForegroundBrightGreen = 92,
    ForegroundBrightYellow = 93,
    ForegroundBrightBlue = 94,
    ForegroundBrightMagenta = 95,
    ForegroundBrightCyan = 96,
    ForegroundBrightWhite = 97,

    BackgroundBlack = 40,
    BackgroundRed = 41,
    BackgroundGreen = 42,
    BackgroundYellow = 43,
    BackgroundBlue = 44,
    BackgroundMagenta = 45,
    BackgroundCyan = 46,
    BackgroundWhite = 47,
    BackgroundGray = 100,
    BackgroundBrightRed = 101,
    BackgroundBrightGreen = 102,
    BackgroundBrightYellow = 103,
    BackgroundBrightBlue = 104,
    BackgroundBrightMagenta = 105,
    BackgroundBrightCyan = 106,
    BackgroundBrightWhite = 107,
};

pub const CursorShape = enum(u8) {
    BlinkingBlock = 1,
    Block = 2,
    BlinkingUnderline = 3,
    Underline = 4,
    BlinkingBar = 5,
    Bar = 6,
};

pub const Screen = struct {
    stdin: File,
    stdout: File,
    inputBufferList: ArrayList(u8),

    pub fn init(stdin: File, stdout: File, allocator: Allocator) !Screen {
        return Screen{ .stdin = stdin, .stdout = stdout, .inputBufferList = try ArrayList(u8).initCapacity(allocator, 20) };
    }

    pub fn deinit(self: *const Screen) void {
        self.inputBufferList.deinit();
    }

    pub fn eraseToEnd(self: *const Screen) !void {
        try self.stdout.writeAll("\x1b[J");
    }

    pub fn eraseToLineEnd(self: *const Screen) !void {
        try self.stdout.writeAll("\x1b[K");
    }

    pub fn moveCursor(self: *const Screen, point: Point) !void {
        try self.writeFmt("\x1b[{d};{d}H", .{ point.row, point.col });
    }

    pub fn moveCursorNextLine(self: *const Screen) !void {
        try self.writeAll("\x1b[E");
    }

    pub fn writeFmt(self: *const Screen, comptime fmt: []const u8, args: anytype) !void {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try self.stdout.writeAll(text);
    }

    pub fn hideCursor(self: *const Screen) !void {
        try self.stdout.writeAll("\x1b[?25l");
    }

    pub fn showCursor(self: *const Screen) !void {
        try self.stdout.writeAll("\x1b[?25h");
    }

    pub fn getSize(_: *const Screen) !Size {
        return try getTerminalSize();
    }

    pub fn writeAll(self: *const Screen, text: []const u8) !void {
        try self.stdout.writeAll(text);
    }

    pub fn writeSGRAttribute(self: *const Screen, attributes: []const SGRAttribute) !void {
        try self.writeFmt("\x1b[", .{});
        for (attributes) |attribute| {
            try self.writeFmt("{d}", .{@intFromEnum(attribute)});
            if (attribute != attributes[attributes.len - 1]) {
                try self.writeAll(";");
            }
        }
        try self.writeFmt("m", .{});
    }

    pub fn resetSGRAttributes(self: *const Screen) !void {
        try self.writeAll("\x1b[0m");
    }

    pub fn setCursorShape(self: *const Screen, shape: CursorShape) !void {
        try self.writeFmt("\x1b[{d} q", .{@intFromEnum(shape)});
    }

    pub fn poll(self: *Screen) !ArrayList(ansi.AnsiToken) {
        self.inputBufferList.clearRetainingCapacity();
        const input = try readFd(&self.inputBufferList);
        return try ansi.tokenize(self.inputBufferList.allocator, input);
    }
};

pub const KeyModifier = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
};

pub const Keycode = union(enum) {
    up: void,
    down: void,
    left: void,
    right: void,
    home: void,
    end: void,
    backspace: void,
    enter: void,
    tab: void,
    escape: void,
    pageUp: void,
    pageDown: void,
    character: u8,
};

pub const KeyPress = struct {
    keycode: Keycode,
    modifier: KeyModifier = .{},

    pub fn init(keycode: Keycode, modifier: KeyModifier) KeyPress {
        return KeyPress{ .keycode = keycode, .modifier = modifier };
    }
};

pub const Event = union(enum) {
    key: KeyPress,
    paste: []const u8,
    resize: Size,
};

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

fn readFd(buffer: *ArrayList(u8)) ![]const u8 {
    var tmp: [32]u8 = undefined;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &tmp);
        if (n > 0) {
            try buffer.appendSlice(tmp[0..n]);
        } else {
            break;
        }
    }
    return buffer.items;
}

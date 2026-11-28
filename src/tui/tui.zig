// https://viewsourcecode.org/snaptoken/kilo/index.html
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const ArrayList = std.array_list.Managed;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;

const STD_INPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -11));

const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: windows.DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: windows.DWORD = 0x0010;
const ENABLE_EXTENDED_FLAGS: windows.DWORD = 0x0080;
const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
const DISABLE_NEWLINE_AUTO_RETURN: windows.DWORD = 0x0008;
const CP_UTF8: windows.UINT = 65001;

const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;
const WAIT_FAILED: windows.DWORD = 0xFFFFFFFF;
const INFINITE: windows.DWORD = 0xFFFFFFFF;

const COORD = extern struct {
    x: i16,
    y: i16,
};

const SMALL_RECT = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

const ConsoleScreenBufferInfo = extern struct {
    size: COORD,
    cursor_position: COORD,
    attributes: u16,
    window: SMALL_RECT,
    maximum_window_size: COORD,
};

extern "kernel32" fn GetStdHandle(std_handle: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetConsoleMode(handle: windows.HANDLE, mode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(handle: windows.HANDLE, mode: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn SetConsoleCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleOutputCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteConsoleW(handle: windows.HANDLE, buffer: [*]const u16, chars_to_write: windows.DWORD, chars_written: *windows.DWORD, reserved: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(handle: windows.HANDLE, info: *ConsoleScreenBufferInfo) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn WaitForMultipleObjects(
    count: windows.DWORD,
    handles: [*]const windows.HANDLE,
    wait_all: windows.BOOL,
    milliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;
extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: windows.DWORD,
    bytes_written: ?*windows.DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

/// Platform-specific state saved by `enableRawMode`.
pub const RawModeState = if (is_windows) WindowsRawMode else posix.termios;

const WindowsRawMode = struct {
    input: ?windows.HANDLE = null,
    input_mode: windows.DWORD = 0,
    output: ?windows.HANDLE = null,
    output_mode: windows.DWORD = 0,
    input_code_page: windows.UINT = 0,
    output_code_page: windows.UINT = 0,
};

pub fn enableRawMode() !RawModeState {
    if (is_windows) return enableRawModeWindows();
    return enableRawModePosix();
}

fn enableRawModePosix() !posix.termios {
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

    // Disable post-processing of output
    raw.oflag.OPOST = false;

    raw.cc[@backingInt(posix.system.V.MIN)] = 0;
    raw.cc[@backingInt(posix.system.V.TIME)] = 0;

    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, raw);

    return orig_termios;
}

fn enableRawModeWindows() !WindowsRawMode {
    var state = WindowsRawMode{};
    errdefer disableRawModeWindows(state);

    const input = GetStdHandle(STD_INPUT_HANDLE);
    if (input != windows.INVALID_HANDLE_VALUE) {
        if (GetConsoleMode(input, &state.input_mode) != .FALSE) {
            state.input = input;
            var mode = state.input_mode;
            mode &= ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
            mode |= ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS;
            mode |= ENABLE_WINDOW_INPUT | ENABLE_MOUSE_INPUT;
            if (SetConsoleMode(input, mode) == .FALSE) return error.ConsoleModeFailed;
            state.input_code_page = GetConsoleCP();
            if (state.input_code_page != 0 and SetConsoleCP(CP_UTF8) == .FALSE) return error.ConsoleCodePageFailed;
        }
    }

    const output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output != windows.INVALID_HANDLE_VALUE) {
        if (GetConsoleMode(output, &state.output_mode) != .FALSE) {
            state.output = output;
            var mode = state.output_mode;
            mode |= ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            mode &= ~DISABLE_NEWLINE_AUTO_RETURN;
            if (SetConsoleMode(output, mode) == .FALSE) return error.ConsoleModeFailed;
            state.output_code_page = GetConsoleOutputCP();
            if (state.output_code_page != 0 and SetConsoleOutputCP(CP_UTF8) == .FALSE) return error.ConsoleCodePageFailed;
        }
    }

    return state;
}

pub fn enableLineWrap(out: anytype) !void {
    try writeAll(out, "\x1b[?7h");
}

pub fn disableLineWrap(out: anytype) !void {
    try writeAll(out, "\x1b[?7l");
}

pub fn enableBracketedPaste(out: anytype) !void {
    try writeAll(out, "\x1b[?2004h");
}

pub fn disableBracketedPaste(out: anytype) !void {
    try writeAll(out, "\x1b[?2004l");
}

/// All-motion mouse tracking with SGR coordinates. Mode 1003 reports motion
/// without a button too, which drives hover; button-held motion still drives
/// drag selection. Mode 1004 reports focus loss so a drag can be cancelled
/// when the terminal loses the mouse release.
pub fn enableMouseCapture(out: anytype) !void {
    try writeAll(out, "\x1b[?1003h\x1b[?1006h\x1b[?1004h");
}

pub fn disableMouseCapture(out: anytype) !void {
    try writeAll(out, "\x1b[?1004l\x1b[?1006l\x1b[?1003l");
}

pub fn disableRawMode(state: RawModeState) !void {
    if (is_windows) {
        disableRawModeWindows(state);
        return;
    }
    try posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, state);
}

fn disableRawModeWindows(state: WindowsRawMode) void {
    if (state.input) |handle| _ = SetConsoleMode(handle, state.input_mode);
    if (state.output) |handle| _ = SetConsoleMode(handle, state.output_mode);
    if (state.input_code_page != 0) _ = SetConsoleCP(state.input_code_page);
    if (state.output_code_page != 0) _ = SetConsoleOutputCP(state.output_code_page);
}

/// Windows console handles interpret byte writes using an OEM code page.
/// Convert the UTF-8 ANSI stream to UTF-16 at the console boundary instead;
/// redirected pipes/files must continue receiving the original UTF-8 bytes.
pub const TerminalWriter = struct {
    file: Io.File.Writer,
    console: if (is_windows) ?WindowsConsoleWriter else void = if (is_windows) null else {},

    pub fn init(allocator: Allocator, io: Io, buffer: []u8, state: RawModeState) TerminalWriter {
        var result: TerminalWriter = .{ .file = Io.File.stdout().writer(io, buffer) };
        if (is_windows) if (state.output) |handle| {
            result.console = WindowsConsoleWriter.init(allocator, handle, buffer);
        };
        return result;
    }

    pub fn writer(self: *TerminalWriter) *Io.Writer {
        if (is_windows) if (self.console) |*console| return &console.interface;
        return &self.file.interface;
    }

    pub fn deinit(self: *TerminalWriter) void {
        if (is_windows) if (self.console) |*console| console.deinit();
    }
};

const WindowsConsoleWriter = struct {
    interface: Io.Writer,
    allocator: Allocator,
    handle: windows.HANDLE,
    write_wide: *const fn (windows.HANDLE, []const u16) Io.Writer.Error!void = writeWide,
    bytes: std.ArrayList(u8) = .empty,
    wide: std.ArrayList(u16) = .empty,

    fn init(allocator: Allocator, handle: windows.HANDLE, buffer: []u8) WindowsConsoleWriter {
        return .{
            .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain, .flush = flush } },
            .allocator = allocator,
            .handle = handle,
        };
    }

    fn deinit(self: *WindowsConsoleWriter) void {
        self.bytes.deinit(self.allocator);
        self.wide.deinit(self.allocator);
    }

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *WindowsConsoleWriter = @fieldParentPtr("interface", writer);
        self.bytes.appendSlice(self.allocator, writer.buffer[0..writer.end]) catch return error.WriteFailed;
        writer.end = 0;
        for (data[0 .. data.len - 1]) |slice| self.bytes.appendSlice(self.allocator, slice) catch return error.WriteFailed;
        for (0..splat) |_| self.bytes.appendSlice(self.allocator, data[data.len - 1]) catch return error.WriteFailed;

        const complete = utf8CompletePrefix(self.bytes.items);
        self.wide.resize(self.allocator, complete) catch return error.WriteFailed;
        const len = std.unicode.utf8ToUtf16Le(self.wide.items, self.bytes.items[0..complete]) catch return error.WriteFailed;
        try self.write_wide(self.handle, self.wide.items[0..len]);
        // Retain a partial UTF-8 scalar if a buffered write split it.
        self.bytes.replaceRangeAssumeCapacity(0, complete, &.{});
        return Io.Writer.countSplat(data, splat);
    }

    fn writeWide(handle: windows.HANDLE, text: []const u16) Io.Writer.Error!void {
        var remaining = text;
        while (remaining.len > 0) {
            var chunk_len = @min(remaining.len, 32768);
            // A UTF-16 surrogate pair must stay in the same console write.
            if (chunk_len < remaining.len and remaining[chunk_len - 1] >= 0xd800 and remaining[chunk_len - 1] <= 0xdbff) chunk_len -= 1;
            var written: windows.DWORD = 0;
            if (WriteConsoleW(handle, remaining.ptr, @intCast(chunk_len), &written, null) == .FALSE or written == 0 or written > chunk_len) return error.WriteFailed;
            remaining = remaining[written..];
        }
    }

    fn flush(writer: *Io.Writer) Io.Writer.Error!void {
        try Io.Writer.defaultFlush(writer);
        const self: *WindowsConsoleWriter = @fieldParentPtr("interface", writer);
        if (self.bytes.items.len != 0) return error.WriteFailed;
    }
};

fn utf8CompletePrefix(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var start = bytes.len - 1;
    while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
    const expected = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes.len;
    return if (bytes.len - start < expected) start else bytes.len;
}

test "Windows terminal output preserves UTF-8 scalars and ANSI escape sequences" {
    const text = "\x1b[38;2;191;191;191m╭─你好😀\x1b[0m";
    const expected = std.unicode.utf8ToUtf16LeStringLiteral(text);
    for (0..text.len + 1) |split| {
        const complete = utf8CompletePrefix(text[0..split]);
        var wide: [text.len]u16 = undefined;
        const first = try std.unicode.utf8ToUtf16Le(&wide, text[0..complete]);
        const second = try std.unicode.utf8ToUtf16Le(wide[first..], text[complete..]);
        try std.testing.expectEqualSlices(u16, expected, wide[0 .. first + second]);
        try std.testing.expect(split - complete <= 3);
    }
}

test "Windows console writer preserves split scalars and buffered ANSI output" {
    if (!is_windows) return error.SkipZigTest;
    const text = "\x1b[31m╭─你好😀\x1b[0m";
    var captured: std.ArrayList(u16) = .empty;
    defer captured.deinit(std.testing.allocator);
    var buffer: [3]u8 = undefined;
    var console = WindowsConsoleWriter.init(std.testing.allocator, @ptrCast(&captured), &buffer);
    defer console.deinit();
    console.write_wide = struct {
        fn write(handle: windows.HANDLE, wide: []const u16) Io.Writer.Error!void {
            const list: *std.ArrayList(u16) = @ptrCast(@alignCast(handle));
            list.appendSlice(std.testing.allocator, wide) catch return error.WriteFailed;
        }
    }.write;
    for (text) |byte| try console.interface.writeByte(byte);
    try console.interface.flush();
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(text), captured.items);
}

pub fn writeAll(writer: anytype, text: []const u8) !void {
    try writer.writeAll(text);
}

pub fn enterAltScreen(out: anytype) !void {
    try writeAll(out, "\x1b[?1049h");
}

pub fn exitAltScreen(out: anytype) !void {
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
    /// Cell pixel size when the terminal reports it through `TIOCGWINSZ`
    /// (`ws_xpixel`/`ws_ypixel`); the terminal UI uses it to size images.
    cell_width_px: usize = 8,
    cell_height_px: usize = 16,

    pub fn equals(self: *const Size, other: Size) bool {
        return self.width == other.width and self.height == other.height;
    }
};

pub fn getTerminalSize() !Size {
    if (is_windows) return getTerminalSizeWindows();
    var size: posix.winsize = std.mem.zeroes(posix.winsize);
    _ = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&size));
    const width = if (size.col == 0) 80 else size.col;
    const height = if (size.row == 0) 24 else size.row;
    return .{
        .width = width,
        .height = height,
        .cell_width_px = if (size.xpixel > 0 and size.col > 0) @max(size.xpixel / size.col, 1) else 8,
        .cell_height_px = if (size.ypixel > 0 and size.row > 0) @max(size.ypixel / size.row, 1) else 16,
    };
}

fn getTerminalSizeWindows() !Size {
    const handle = GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == windows.INVALID_HANDLE_VALUE) return .{ .width = 80, .height = 24 };
    var info: ConsoleScreenBufferInfo = undefined;
    if (GetConsoleScreenBufferInfo(handle, &info) == .FALSE) return .{ .width = 80, .height = 24 };
    const width: usize = @intCast(@max(info.window.right - info.window.left + 1, 1));
    const height: usize = @intCast(@max(info.window.bottom - info.window.top + 1, 1));
    return .{ .width = width, .height = height };
}

pub fn clearScreen(out: anytype) !void {
    try writeAll(out, "\x1b[2J"); // clear screen
}

pub fn clearToEndOfScreen(out: anytype) !void {
    try writeAll(out, "\x1b[J");
}

pub fn getCursorPosition(io: Io) !Point {
    // Step 1: Ask for cursor position
    var out_buffer: [64]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &out_buffer);
    try stdout_writer.interface.writeAll("\x1b[6n");
    try stdout_writer.interface.flush();

    // Step 2: Read the response
    var in_buffer: [64]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &in_buffer);
    const response = stdin_reader.interface.takeDelimiterInclusive('R') catch |err| switch (err) {
        error.EndOfStream => return error.CursorResponseTimeout,
        else => return err,
    };

    // Example response: ESC [ 12 ; 40 R
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

pub fn moveCursor(out: anytype, point: Point) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(buf[0..], "\x1b[{d};{d}H", .{ point.row, point.col });
    try writeAll(out, text);
}

pub fn moveCursorBy(out: anytype, row: isize, col: isize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(buf[0..], "\x1b[{d};{d}H", .{ row, col });
    try writeAll(out, text);
}

pub fn hideCursor(out: anytype) !void {
    try writeAll(out, "\x1b[?25l");
}

pub fn showCursor(out: anytype) !void {
    try writeAll(out, "\x1b[?25h");
}

var g_orig_state: ?RawModeState = null;
pub fn rememberOrigTermios(state: RawModeState) void {
    g_orig_state = state;
}

/// Reverses every terminal mode the TUI enables. The crash paths print the
/// stack trace after this sequence, so it must leave the alternate screen and
/// restore raw mode before the trace: otherwise the trace is written to the
/// alternate screen, which the terminal discards when the process dies.
pub const crash_restore_sequence = "\x1b[0m\x1b[?2004l\x1b[?1004l\x1b[?1006l\x1b[?1003l\x1b[?1049l\x1b[?7h\x1b[?25h\r\n";

/// Restores the terminal before a panic or segfault report. This also runs in a
/// signal handler, so it must not allocate or touch the IO locks; the escape
/// sequence is written with a direct file-descriptor write. The sequence is
/// emitted before termios/console modes are restored: Windows only interprets
/// it while virtual-terminal processing is enabled, and on POSIX the explicit
/// `\r\n` keeps its exact bytes while output post-processing is still off.
pub fn restoreTerminalForCrash() void {
    if (is_windows) {
        const handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if (handle != windows.INVALID_HANDLE_VALUE) {
            var written: windows.DWORD = 0;
            _ = WriteFile(handle, crash_restore_sequence.ptr, @intCast(crash_restore_sequence.len), &written, null);
        }
    } else {
        var remaining: []const u8 = crash_restore_sequence;
        while (remaining.len > 0) {
            const written = std.c.write(@intCast(posix.STDOUT_FILENO), remaining.ptr, remaining.len);
            if (written <= 0) break;
            remaining = remaining[@intCast(written)..];
        }
    }

    if (g_orig_state) |state| {
        disableRawMode(state) catch {};
    }
}

pub const panic = std.debug.FullPanic(myPanic);

pub fn myPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    restoreTerminalForCrash();
    std.debug.defaultPanic(msg, first_trace_addr);
}

test "crash restore sequence leaves the alternate screen and re-enables terminal modes" {
    const sequence = crash_restore_sequence;
    try std.testing.expect(std.mem.indexOf(u8, sequence, "\x1b[?1049l") != null);
    try std.testing.expect(std.mem.indexOf(u8, sequence, "\x1b[?2004l") != null);
    try std.testing.expect(std.mem.indexOf(u8, sequence, "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, sequence, "\x1b[?1003l") != null);
    try std.testing.expect(std.mem.indexOf(u8, sequence, "\x1b[?7h") != null);
    try std.testing.expect(std.mem.indexOf(u8, sequence, "\x1b[?25h") != null);
    // The trace starts on a fresh line after the restored screen.
    try std.testing.expect(std.mem.endsWith(u8, sequence, "\r\n"));
}

var resized = std.atomic.Value(bool).init(false);
var windows_last_size: Size = .{ .width = 0, .height = 0 };
var windows_size_initialized = false;

fn handleSigWinch(_: posix.SIG) callconv(.c) void {
    resized.store(true, .seq_cst);
}

pub fn resizedSize() !?Size {
    if (is_windows) {
        const current = try getTerminalSize();
        if (!windows_size_initialized) {
            windows_size_initialized = true;
            windows_last_size = current;
            return null;
        }
        if (current.width != windows_last_size.width or
            current.height != windows_last_size.height or
            current.cell_width_px != windows_last_size.cell_width_px or
            current.cell_height_px != windows_last_size.cell_height_px)
        {
            windows_last_size = current;
            return current;
        }
        return null;
    }
    if (resized.swap(false, .seq_cst)) {
        return try getTerminalSize();
    } else {
        return null;
    }
}

pub fn installSigWinch() !void {
    if (is_windows) return;
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = handleSigWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
}

pub fn readFd(io: Io, fd: anytype, buffer: *ArrayList(u8)) ![]const u8 {
    if (is_windows) {
        var tmp: [4096]u8 = undefined;
        const n = Io.File.stdin().readStreaming(io, &.{tmp[0..]}) catch 0;
        if (n > 0) try buffer.appendSlice(tmp[0..n]);
        return buffer.items;
    }
    var tmp: [4096]u8 = undefined;
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

pub fn pollInput(timeout_ms: i32) !bool {
    if (is_windows) {
        const handle = GetStdHandle(STD_INPUT_HANDLE);
        if (handle == windows.INVALID_HANDLE_VALUE) return false;
        const milliseconds: windows.DWORD = if (timeout_ms < 0) INFINITE else @intCast(timeout_ms);
        const result = WaitForSingleObject(handle, milliseconds);
        return result == WAIT_OBJECT_0;
    }
    var fds = [_]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const result = try posix.poll(&fds, timeout_ms);
    return result > 0;
}

pub const PollResult = struct {
    input: bool,
    extra: bool,
    worker: bool = false,
};

/// Polls stdin plus an optional extra POSIX fd (the file watcher's
/// inotify/kqueue handle). The caller drains the extra fd when `extra` is true.
pub fn pollInputWithFd(extra_fd: ?i32, timeout_ms: i32) !PollResult {
    var fds = [_]posix.pollfd{
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = extra_fd orelse -1, .events = posix.POLL.IN, .revents = 0 },
    };
    _ = try posix.poll(&fds, timeout_ms);
    return .{ .input = fds[0].revents != 0, .extra = fds[1].revents != 0 };
}

/// Windows variant of `pollInputWithFd`, using the watcher's native handle.
pub fn pollInputWithHandles(extra_handle: ?windows.HANDLE, worker_handle: windows.HANDLE, timeout_ms: i32) !PollResult {
    if (!is_windows) return pollInputWithFd(null, timeout_ms);

    var handles: [3]windows.HANDLE = undefined;
    const stdin = GetStdHandle(STD_INPUT_HANDLE);
    if (stdin == windows.INVALID_HANDLE_VALUE) {
        return .{ .input = false, .extra = false };
    }
    handles[0] = stdin;
    var count: windows.DWORD = 1;
    if (extra_handle) |handle| {
        handles[1] = handle;
        count = 2;
    }

    const worker_index = count;
    handles[count] = worker_handle;
    count += 1;
    const milliseconds: windows.DWORD = if (timeout_ms < 0) INFINITE else @intCast(timeout_ms);
    const result = WaitForMultipleObjects(count, &handles, .FALSE, milliseconds);
    if (result == WAIT_TIMEOUT or result == WAIT_FAILED) {
        return .{ .input = false, .extra = false };
    }
    return .{
        .input = result == WAIT_OBJECT_0,
        .extra = extra_handle != null and result == WAIT_OBJECT_0 + 1,
        .worker = result == WAIT_OBJECT_0 + worker_index,
    };
}

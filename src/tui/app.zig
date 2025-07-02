const std = @import("std");
const posix = std.posix;
const tui = @import("tui.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut();
    const out = stdout.writer();

    const orig_termios = try tui.enableRawMode();
    defer tui.disableRawMode(orig_termios) catch unreachable;

    try tui.writeAll(out, "\x1b[?1049h"); // alternate screen
    defer tui.writeAll(out, "\x1b[?1049l") catch {};
    try tui.clearScreen(out);
    // try writeAll(out, "\x1b[?25l"); // hide cursor
    // defer writeAll(out, "\x1b[?25h") catch {}; // show cursor on exit

    const size = try tui.getTerminalSize();
    const allocator = std.heap.page_allocator;
    const text = try std.fmt.allocPrint(allocator, "Terminal size: {} cols × {} rows\n", .{ size.width, size.height });
    defer allocator.free(text);
    const cursor_pos = try tui.getCursorPosition();
    const text1 = try std.fmt.allocPrint(allocator, "Cursor position: {} cols × {} rows\n", .{ cursor_pos.col, cursor_pos.row });
    defer allocator.free(text1);
    try tui.writeAll(out, text);
    try tui.writeAll(out, text1);
    try tui.writeAll(out, "\x1b[2;1H");
    try tui.writeAll(out, "\x1b[31mPress 'q' to exit.\x1b[0m\n");

    var buf: [1]u8 = undefined;
    var i: usize = 0;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 1 and buf[0] == 'q') break;

        const s = try std.fmt.allocPrint(allocator, "{}", .{i});
        defer allocator.free(s);
        try tui.writeAll(out, s);
        i += 1;
    }

    try tui.writeAll(out, "\nExiting...\n");
}

const std = @import("std");
const posix = std.posix;
const tui = @import("tui.zig");
const UTF8ChunkReader = @import("utf8ChunkReader.zig").UTF8ChunkReader;
const ArrayList = std.ArrayList;
const StringBuffer = @import("../pieceTreeBase.zig").StringBuffer;
const PieceTreeBase = @import("../pieceTreeBase.zig").PieceTreeBase;

fn readFile(allocator: std.mem.Allocator, path: []const u8) !PieceTreeBase {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const reader = file.reader();

    var chunkReader = UTF8ChunkReader.init(allocator, reader.any());
    var buffers = ArrayList(StringBuffer).init(allocator);
    defer buffers.deinit();

    while (try chunkReader.readAlloc(65535)) |chunk| {
        try buffers.append(try StringBuffer.initFromArrayList(allocator, chunk));
    }

    return try PieceTreeBase.init(allocator, buffers.items, .LF);
}

fn drawVisibleLines(out: anytype, tree: *PieceTreeBase, scrollTop: usize, width: usize, height: usize) !void {
    try tui.moveCursor(out, 0, 0);
    try tui.hideCursor(out);
    defer tui.showCursor(out) catch {};

    const from = scrollTop;
    const to = from + height;
    for (from..to) |i| {
        const line = try tree.getLineContent(i);
        try tui.writeAll(out, line);
        if (line.len < width) {
            for (0..width - line.len) |_| {
                try tui.writeAll(out, " ");
            }
        }

        if (i < to - 1) {
            try tui.writeAll(out, "\r\n");
        }
    }
}

fn clamp(value: usize, min: usize, max: usize) usize {
    return @max(min, @min(value, max));
}

fn getFirstArg() !ArrayList(u8) {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var firstArg = ArrayList(u8).init(allocator);
    try firstArg.appendSlice(args[1]);
    return firstArg;
}

pub fn main() !void {
    const stdout = std.io.getStdOut();
    const out = stdout.writer();

    const orig_termios = try tui.enableRawMode();
    defer tui.disableRawMode(orig_termios) catch unreachable;

    try tui.enterAltScreen(out);
    defer tui.exitAltScreen(out) catch {};

    const pathArg = try getFirstArg();
    defer pathArg.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var tree = try readFile(allocator, pathArg.items);
    defer tree.deinit();

    const size = try tui.getTerminalSize();

    // try writeAll(out, "\x1b[?25l"); // hide cursor
    // defer writeAll(out, "\x1b[?25h") catch {}; // show cursor on exit

    // const size = try tui.getTerminalSize();
    // const allocator = std.heap.page_allocator;
    // const text = try std.fmt.allocPrint(allocator, "Terminal size: {} cols × {} rows\n", .{ size.width, size.height });
    // defer allocator.free(text);
    // const cursor_pos = try tui.getCursorPosition();
    // const text1 = try std.fmt.allocPrint(allocator, "Cursor position: {} cols × {} rows\n", .{ cursor_pos.col, cursor_pos.row });
    // defer allocator.free(text1);
    // try tui.writeAll(out, text);
    // try tui.writeAll(out, text1);
    // try tui.writeAll(out, "\x1b[2;1H");
    // try tui.writeAll(out, "\x1b[31mPress 'q' to exit.\x1b[0m\n");

    var buf: [3]u8 = undefined;
    var scrollTop: usize = 0;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 1 and buf[0] == 'q') break;

        var newScrollTop = scrollTop;
        if (n > 0) {
            if (buf[0] == '\x1b' and buf[1] == '[') {
                if (buf[2] == 'A') {
                    newScrollTop = scrollTop - 1;
                } else if (buf[2] == 'B') {
                    newScrollTop = scrollTop + 1;
                }
            }
        }

        newScrollTop = clamp(newScrollTop, 1, tree.getLineCount() - size.height);

        if (newScrollTop != scrollTop) {
            scrollTop = newScrollTop;
            try drawVisibleLines(out, &tree, scrollTop, size.width, size.height);
        }
    }
}

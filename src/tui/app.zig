const std = @import("std");
const io = std.io;
const posix = std.posix;
const tui = @import("tui.zig");
const Size = tui.Size;
const Point = tui.Point;
const UTF8ChunkReader = @import("utf8ChunkReader.zig").UTF8ChunkReader;
const ArrayList = std.ArrayList;
const StringBuffer = @import("../pieceTreeBase.zig").StringBuffer;
const PieceTreeBase = @import("../pieceTreeBase.zig").PieceTreeBase;

const MoveAction = enum {
    Up,
    Down,
    Left,
    Right,
};

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

const View = struct {
    writer: io.AnyWriter,
    size: Size,
    scrollPosition: Point,
    cursorPosition: Point,

    fn drawVisibleLines(self: *const View, tree: *PieceTreeBase) !void {
        const out = self.writer;
        try tui.moveCursor(out, .{ .col = 1, .row = 1 });
        defer tui.moveCursor(out, self.cursorPosition) catch {};
        try tui.hideCursor(out);
        defer tui.showCursor(out) catch {};

        const from = self.scrollPosition.row;
        const to: usize = @min(self.scrollPosition.row + self.size.height, tree.getLineCount());
        for (from..to) |i| {
            const line = try tree.getLineContent(i);

            try tui.writeAll(out, line[0..]);
            if (line.len <= self.size.width) {
                for (line.len..self.size.width) |_| {
                    try tui.writeAll(out, " ");
                }
            }

            if (i < to - 1) {
                try tui.writeAll(out, "\r\n");
            }
        }

        try tui.clearToEndOfScreen(out);
    }

    fn drawCursor(self: *const View) !void {
        const out = self.writer;
        try tui.moveCursor(out, self.cursorPosition);
    }

    fn moveCursor(self: *View, action: MoveAction, tree: *const PieceTreeBase) !void {
        var newCol = self.cursorPosition.col;
        var newRow = self.cursorPosition.row;
        switch (action) {
            .Up => {
                if (newRow > 1) {
                    newRow -= 1;
                } else if (self.scrollPosition.row > 1) {
                    self.scrollPosition.row -= 1;
                }
            },
            .Down => {
                if (newRow < self.size.height) {
                    if (self.scrollPosition.row + newRow < tree.getLineCount()) {
                        newRow += 1;
                    }
                } else if (self.scrollPosition.row + self.size.height <= tree.getLineCount()) {
                    self.scrollPosition.row += 1;
                }
            },
            .Left => {
                if (newCol > 1) {
                    newCol -= 1;
                }
            },
            .Right => {
                newCol += 1;
            },
        }
        self.cursorPosition.row = newRow;

        const lineLength = tree.getLineLength(self.cursorPosition.row + self.scrollPosition.row - 1);
        if (newCol > lineLength) {
            newCol = lineLength;
        }
        self.cursorPosition.col = newCol;
    }

    fn updateCursorPosition(self: *View, tree: *const PieceTreeBase, offset: usize) !void {
        const pos = tree.getPositionAt(offset);
        self.cursorPosition.row = pos.lineNumber - self.scrollPosition.row + 1;
        self.cursorPosition.col = pos.column;
    }

    fn insertAtCursor(self: *View, tree: *PieceTreeBase, text: []const u8) !void {
        const offset = tree.getOffsetAt(self.cursorPosition.row, self.cursorPosition.col);
        try tree.insert(offset, text, false);
        try self.updateCursorPosition(tree, offset + text.len);
    }

    fn deleteLeftOfCursor(self: *View, tree: *PieceTreeBase) !void {
        const offset = tree.getOffsetAt(self.cursorPosition.row, self.cursorPosition.col);
        if (offset > 0) {
            try tree.delete(offset - 1, 1);
            try self.updateCursorPosition(tree, offset - 1);
        }
    }
};

fn equalPosition(a: Point, b: Point) bool {
    return a.col == b.col and a.row == b.row;
}

fn equalSize(a: Size, b: Size) bool {
    return a.width == b.width and a.height == b.height;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.cwd().openFile("debug.log", .{
        .mode = .write_only,
    }) catch blk: {
        // If file doesn't exist, create it
        break :blk std.fs.cwd().createFile("debug.log", .{}) catch unreachable;
    };

    defer file.close();
    file.seekFromEnd(0) catch unreachable;
    std.fmt.format(file.writer(), fmt ++ "\n", args) catch unreachable;
}

pub fn main() !void {
    const stdout = std.io.getStdOut();
    const out = stdout.writer();

    const orig_termios = try tui.enableRawMode();
    tui.rememberOrigTermios(orig_termios);
    defer tui.disableRawMode(orig_termios) catch unreachable;

    try tui.enterAltScreen(out);
    defer tui.exitAltScreen(out) catch {};

    try tui.disableLineWrap(out);
    defer tui.enableLineWrap(out) catch {};

    const pathArg = try getFirstArg();
    defer pathArg.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var tree = try readFile(allocator, pathArg.items);
    defer tree.deinit();

    const size = try tui.getTerminalSize();

    var view = View{
        .writer = out.any(),
        .size = size,
        .scrollPosition = .{ .col = 1, .row = 1 },
        .cursorPosition = .{ .col = 1, .row = 1 },
    };
    try view.drawVisibleLines(&tree);

    var contentChanged = false;

    var buf: [3]u8 = undefined;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 1) {
            if (buf[0] == 'q') {
                break;
            } else if (buf[0] == 0x7f) {
                try view.deleteLeftOfCursor(&tree);
                contentChanged = true;
            } else {
                try view.insertAtCursor(&tree, buf[0..n]);
                contentChanged = true;
            }
        }

        var newView = view;

        if (n > 0) {
            if (buf[0] == '\x1b' and buf[1] == '[') {
                if (buf[2] == 'A') {
                    try newView.moveCursor(.Up, &tree);
                } else if (buf[2] == 'B') {
                    try newView.moveCursor(.Down, &tree);
                } else if (buf[2] == 'C') {
                    try newView.moveCursor(.Right, &tree);
                } else if (buf[2] == 'D') {
                    try newView.moveCursor(.Left, &tree);
                }
            }
        }

        const cursorChanged = !equalPosition(newView.cursorPosition, view.cursorPosition);
        const scrollChanged = !equalPosition(newView.scrollPosition, view.scrollPosition);

        if (scrollChanged) {
            view = newView;
            try view.drawVisibleLines(&tree);
        } else if (cursorChanged) {
            view = newView;
            try view.drawCursor();
        } else if (contentChanged) {
            view = newView;
            try view.drawVisibleLines(&tree);
            contentChanged = false;
        }
    }
}

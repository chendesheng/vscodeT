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
        const to: usize = self.scrollPosition.row + self.size.height;
        log("getLineContent {d}..{d}", .{ from, to });
        for (from..to) |i| {
            const line = try tree.getLineContent(i);

            if (line.len < self.scrollPosition.col) {
                for (0..self.size.width) |_| {
                    try tui.writeAll(out, " ");
                }
            } else if (line.len <= self.scrollPosition.col + self.size.width) {
                try tui.writeAll(out, line[self.scrollPosition.col - 1 .. line.len]);

                for (line.len..self.scrollPosition.col - 1 + self.size.width) |_| {
                    try tui.writeAll(out, " ");
                }
            } else {
                try tui.writeAll(out, line[self.scrollPosition.col - 1 ..]);
            }

            if (i < to - 1) {
                try tui.writeAll(out, "\r\n");
            }
        }
    }

    fn drawCursor(self: *const View) !void {
        const out = self.writer;
        try tui.moveCursor(out, self.cursorPosition);
    }

    fn moveCursor(self: *View, action: MoveAction, lineCount: usize) !void {
        var newX = self.cursorPosition.col;
        var newY = self.cursorPosition.row;
        switch (action) {
            .Up => {
                if (newY > 1) {
                    newY -= 1;
                } else if (self.scrollPosition.row > 1) {
                    self.scrollPosition.row -= 1;
                }
            },
            .Down => {
                if (newY < self.size.height) {
                    newY += 1;
                } else if (self.scrollPosition.row + self.size.height <= lineCount) {
                    self.scrollPosition.row += 1;
                }
            },
            .Left => {
                if (newX > 1) {
                    newX -= 1;
                } else if (self.scrollPosition.col > 1) {
                    self.scrollPosition.col -= 1;
                }
            },
            .Right => {
                if (newX < self.size.width) {
                    newX += 1;
                } else if (self.scrollPosition.col <= self.size.width) {
                    self.scrollPosition.col += 1;
                }
            },
        }
        self.cursorPosition.col = newX;
        self.cursorPosition.row = newY;
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
    log("start", .{});
    const stdout = std.io.getStdOut();
    const out = stdout.writer();

    const orig_termios = try tui.enableRawMode();
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

    log("line count: {d}", .{tree.getLineCount()});

    const size = try tui.getTerminalSize();
    log("size: {d}x{d}", .{ size.width, size.height });

    var view = View{
        .writer = out.any(),
        .size = size,
        .scrollPosition = .{ .col = 1, .row = 1 },
        .cursorPosition = .{ .col = 1, .row = 1 },
    };
    try view.drawVisibleLines(&tree);

    var buf: [3]u8 = undefined;
    while (true) {
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 1 and buf[0] == 'q') break;

        var newView = view;

        if (n > 0) {
            if (buf[0] == '\x1b' and buf[1] == '[') {
                if (buf[2] == 'A') {
                    try newView.moveCursor(.Up, tree.getLineCount());
                } else if (buf[2] == 'B') {
                    try newView.moveCursor(.Down, tree.getLineCount());
                } else if (buf[2] == 'C') {
                    try newView.moveCursor(.Right, tree.getLineCount());
                } else if (buf[2] == 'D') {
                    try newView.moveCursor(.Left, tree.getLineCount());
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
        }
    }
}

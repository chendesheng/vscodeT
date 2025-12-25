const std = @import("std");
const io = std.io;
const fs = std.fs;
const File = fs.File;
const posix = std.posix;
const tui = @import("tui.zig");
const Size = tui.Size;
const Point = tui.Point;
const ArrayList = std.array_list.Managed;
const logger = @import("logger.zig");
const PieceTreeBufferBuilder = @import("../pieceTreeTextBuffer/pieceTreeBufferBuilder.zig").PieceTreeBufferBuilder;
const PieceTreeTextBuffer = @import("../pieceTreeTextBuffer/pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const ValidAnnotatedEditOperation = @import("../model.zig").ValidAnnotatedEditOperation;
const Range = @import("../basics/range.zig").Range;
const Utf8StreamIterator = @import("../basics/utf8Helper.zig").Utf8StreamIterator;
const utils = @import("../basics/utils.zig");
const Screen = tui.Screen;
const SGRAttribute = tui.SGRAttribute;

const MoveAction = enum {
    Up,
    Down,
    Left,
    Right,
    LineFirst,
    LineLast,
};

var readerBuffer: [65535]u8 = undefined;

fn readFile(allocator: std.mem.Allocator, path: []const u8) !PieceTreeTextBuffer {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var builder = PieceTreeBufferBuilder.init(allocator);
    while (true) {
        const len = try file.readAll(&readerBuffer);
        if (len == 0) {
            break;
        }
        try builder.acceptChunk(readerBuffer[0..len]);
    }

    const factory = try builder.finish(false);
    defer factory.deinit();
    return try factory.create(.LF);
}

fn getFirstArg() !ArrayList(u8) {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        return error.NoPathProvided;
    }
    var firstArg = ArrayList(u8).init(allocator);
    try firstArg.appendSlice(args[1]);
    return firstArg;
}

fn getLineNumberGutterWidth(tree: *const PieceTreeTextBuffer) usize {
    const lineCount = tree.getLineCount();
    const maxLineNumberWidth = std.fmt.count("{d}", .{lineCount});
    return maxLineNumberWidth + 2;
}

const View = struct {
    log: *std.Io.Writer,
    size: Size,
    scrollPosition: Point,
    cursorPosition: Point,
    mode: Mode,

    const Mode = enum(u8) {
        Normal,
        Insert,
    };

    fn drawLineNumberGutter(screen: *Screen, lineNumberGutterWidth: usize, lineNumber: usize) !void {
        const lineNumberWidth = std.fmt.count("{d}", .{lineNumber});
        for (lineNumberWidth..lineNumberGutterWidth - 1) |_| {
            try screen.writeAll(" ");
        }

        try screen.writeFmt("{d} ", .{lineNumber});
    }

    fn drawVisibleLines(self: *const View, screen: *Screen, tree: *PieceTreeTextBuffer) !void {
        try screen.moveCursor(.{ .col = 1, .row = 1 });
        defer self.drawCursor(screen, tree) catch {};
        try screen.hideCursor();
        defer screen.showCursor() catch {};

        const lineCount = tree.getLineCount();
        const lineNumberGutterWidth = getLineNumberGutterWidth(tree);
        const from = self.scrollPosition.row;
        const to: usize = @min(self.scrollPosition.row + self.size.height - 1, lineCount);

        const width = self.size.width - lineNumberGutterWidth;

        for (from..to + 1) |i| {
            const lineContent = try tree.getLineContent(i);
            defer lineContent.deinit();
            const line = lineContent.items;

            try drawLineNumberGutter(screen, lineNumberGutterWidth, i);

            try screen.writeAll(line);

            if (i < to) {
                try screen.writeAll("⏎");
            }

            if (line.len <= width) {
                try screen.eraseToLineEnd();
            }

            if (i < to) {
                try screen.moveCursorNextLine();
            }
        }

        try screen.eraseToEnd();
    }

    fn drawCursor(self: *const View, screen: *Screen, tree: *const PieceTreeTextBuffer) !void {
        const lineNumberGutterWidth = getLineNumberGutterWidth(tree);
        const row = self.cursorPosition.row - self.scrollPosition.row + 1;
        const col = lineNumberGutterWidth + utils.clamp(self.cursorPosition.col, 1, tree.getLineLength(self.cursorPosition.row) + 1);
        try screen.moveCursor(.{ .row = row, .col = col });
        if (self.mode == .Normal) {
            try screen.setCursorShape(.Block);
        } else if (self.mode == .Insert) {
            try screen.setCursorShape(.Bar);
        }
    }

    fn moveCursor(self: *View, action: MoveAction, tree: *const PieceTreeTextBuffer) !void {
        var newCol = self.cursorPosition.col;
        var newRow = self.cursorPosition.row;
        switch (action) {
            .Up => {
                newRow -= 1;
                newRow = utils.clamp(newRow, 1, tree.getLineCount());
                newCol = utils.clamp(newCol, 1, tree.getLineLength(newRow));
            },
            .Down => {
                newRow += 1;
                newRow = utils.clamp(newRow, 1, tree.getLineCount());
                newCol = utils.clamp(newCol, 1, tree.getLineLength(newRow));
            },
            .Left => {
                newCol -= 1;
                newCol = utils.clamp(newCol, 1, tree.getLineLength(newRow));
            },
            .Right => {
                newCol += 1;
                newCol = utils.clamp(newCol, 1, tree.getLineLength(newRow));
            },
            .LineFirst => {
                newCol = 1;
            },
            .LineLast => {
                newCol = tree.getLineLength(newRow);
            },
        }

        self.cursorPosition.row = newRow;
        self.cursorPosition.col = newCol;

        if (newRow < self.scrollPosition.row) {
            self.scrollPosition.row = newRow;
        } else if (newRow >= self.scrollPosition.row + self.size.height) {
            self.scrollPosition.row = newRow - self.size.height + 1;
        }
    }

    fn updateCursorPosition(self: *View, tree: *const PieceTreeTextBuffer, offset: usize) !void {
        const pos = tree.getPositionAt(offset);

        if (pos.lineNumber < self.scrollPosition.row) {
            self.scrollPosition.row = pos.lineNumber;
        } else if (pos.lineNumber >= self.scrollPosition.row + self.size.height) {
            self.scrollPosition.row = pos.lineNumber - self.size.height + 1;
        }
        self.cursorPosition.row = pos.lineNumber;
        self.cursorPosition.col = pos.column;
    }

    fn insertAtCursor(self: *View, tree: *PieceTreeTextBuffer, text: []const u8) !void {
        const offset = tree.getOffsetAt(self.cursorPosition.row, self.cursorPosition.col);
        var edits = [_]ValidAnnotatedEditOperation{ValidAnnotatedEditOperation.fromRangeAndText(Range{
            .startLineNumber = self.cursorPosition.row,
            .startColumn = self.cursorPosition.col,
            .endLineNumber = self.cursorPosition.row,
            .endColumn = self.cursorPosition.col,
        }, .initBorrowed(text))};
        _ = try tree.applyEdits(&edits, false, false);
        try self.updateCursorPosition(tree, offset + text.len);
    }

    fn deleteLeftOfCursor(self: *View, tree: *PieceTreeTextBuffer) !void {
        const startPos = self.cursorPosition;
        const offset = tree.getOffsetAt(startPos.row, startPos.col);
        if (offset == 0) {
            return;
        }
        try self.updateCursorPosition(tree, offset - 1);
        var edits = [_]ValidAnnotatedEditOperation{ValidAnnotatedEditOperation.fromRange(Range{
            .startLineNumber = self.cursorPosition.row,
            .startColumn = self.cursorPosition.col,
            .endLineNumber = startPos.row,
            .endColumn = startPos.col,
        })};
        _ = try tree.applyEdits(&edits, false, false);
    }

    fn resize(self: *View, newSize: Size, tree: *const PieceTreeTextBuffer) !void {
        self.size = newSize;

        const lineCount = tree.getLineCount();

        if (self.scrollPosition.row + self.size.height > lineCount and lineCount + 1 > self.size.height) {
            self.scrollPosition.row = lineCount + 1 - self.size.height;
        }
    }

    fn setMode(self: *View, mode: Mode) !void {
        self.mode = mode;
    }

    fn handleKeyPress(self: *View, key: *const tui.KeyPress, tree: *PieceTreeTextBuffer) !void {
        if (self.mode == .Normal) {
            switch (key.keycode) {
                .up => try self.moveCursor(.Up, tree),
                .down => try self.moveCursor(.Down, tree),
                .left => try self.moveCursor(.Left, tree),
                .right => try self.moveCursor(.Right, tree),
                .backspace => try self.moveCursor(.Left, tree),
                .enter => try self.moveCursor(.Down, tree),
                .character => |c| {
                    switch (c) {
                        'i' => try self.setMode(.Insert),
                        'h' => try self.moveCursor(.Left, tree),
                        'j' => try self.moveCursor(.Down, tree),
                        'k' => try self.moveCursor(.Up, tree),
                        'l' => try self.moveCursor(.Right, tree),
                        '0' => try self.moveCursor(.LineFirst, tree),
                        '$' => try self.moveCursor(.LineLast, tree),
                        'q' => return error.Quit,
                        else => return,
                    }
                },
                else => return,
            }
        } else if (self.mode == .Insert) {
            switch (key.keycode) {
                .backspace => try self.deleteLeftOfCursor(tree),
                .enter => try self.insertAtCursor(tree, "\n"),
                .tab => try self.insertAtCursor(tree, "\t"),
                .escape => try self.setMode(.Normal),
                .character => |c| try self.insertAtCursor(tree, &[1]u8{c}),
                else => return,
            }
        }
    }
};

pub fn main() !void {
    var loggerFile = try logger.openLoggerFile("debug.log");
    var buf: [1024]u8 = undefined;
    var loggerWriter = loggerFile.writer(&buf);
    var logWriter = &loggerWriter.interface;
    defer loggerFile.close();

    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    const orig_termios = try tui.enableRawMode();
    tui.rememberOrigTermios(orig_termios);
    defer tui.disableRawMode(orig_termios) catch unreachable;

    try tui.enableBracketedPaste(stdout);
    defer tui.disableBracketedPaste(stdout) catch {};

    try tui.enterAltScreen(stdout);
    defer tui.exitAltScreen(stdout) catch {};

    try tui.disableLineWrap(stdout);
    defer tui.enableLineWrap(stdout) catch {};

    const pathArg = try getFirstArg();
    defer pathArg.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var tree = try readFile(allocator, pathArg.items);
    defer tree.deinit();

    var screen = try Screen.init(stdin, stdout, allocator);
    defer screen.deinit();
    var view = View{
        .log = logWriter,
        .size = try tui.getTerminalSize(),
        .scrollPosition = .{ .col = 1, .row = 1 },
        .cursorPosition = .{ .col = 1, .row = 1 },
        .mode = .Normal,
    };
    try view.drawVisibleLines(&screen, &tree);

    while (true) {
        const events = try screen.pollEvents();
        defer events.deinit();

        for (events.items) |event| {
            logWriter.print("{any}\n", .{event}) catch {};
            logWriter.flush() catch {};

            switch (event) {
                .key => |*key| {
                    try view.handleKeyPress(key, &tree);
                },
                .resize => |newSize| {
                    try view.resize(newSize, &tree);
                },
            }
        }

        if (events.items.len > 0) {
            try view.drawVisibleLines(&screen, &tree);
        }
    }
}

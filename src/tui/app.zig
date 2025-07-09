const std = @import("std");
const io = std.io;
const fs = std.fs;
const posix = std.posix;
const tui = @import("tui.zig");
const Size = tui.Size;
const Point = tui.Point;
const ArrayList = std.ArrayList;
const logger = @import("logger.zig");
const PieceTreeBufferBuilder = @import("../pieceTreeBufferBuilder.zig").PieceTreeBufferBuilder;
const PieceTreeTextBuffer = @import("../pieceTreeTextBuffer.zig").PieceTreeTextBuffer;
const ValidAnnotatedEditOperation = @import("../model.zig").ValidAnnotatedEditOperation;
const Range = @import("../range.zig").Range;
const Utf8StreamIterator = @import("utf8Helper.zig").Utf8StreamIterator;
const ansi = @import("ansi.zig");

const MoveAction = enum {
    Up,
    Down,
    Left,
    Right,
};

var readerBuffer: [65535]u8 = undefined;

fn readFile(allocator: std.mem.Allocator, path: []const u8) !PieceTreeTextBuffer {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var builder = PieceTreeBufferBuilder.init(allocator);
    const reader = file.reader();
    while (true) {
        const len = try reader.readAll(&readerBuffer);
        if (len == 0) {
            break;
        }
        try builder.acceptChunk(readerBuffer[0..len]);
    }

    const factory = try builder.finish(false);
    defer factory.deinit();
    return try factory.create(.LF);
}

fn clamp(value: usize, min: usize, max: usize) usize {
    return @max(min, @min(value, max));
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
    writer: io.AnyWriter,
    size: Size,
    scrollPosition: Point,
    cursorPosition: Point,

    fn drawLineNumberGutter(self: *const View, lineNumberGutterWidth: usize, lineNumber: usize) !void {
        const out = self.writer;

        const lineNumberWidth = std.fmt.count("{d}", .{lineNumber});
        for (lineNumberWidth..lineNumberGutterWidth - 1) |_| {
            try tui.writeAll(out, " ");
        }

        var buf: [64]u8 = undefined;
        try tui.writeAll(out, try std.fmt.bufPrint(&buf, "{d} ", .{lineNumber}));
    }

    fn drawVisibleLines(self: *const View, tree: *PieceTreeTextBuffer) !void {
        const out = self.writer;
        try tui.moveCursor(out, .{ .col = 1, .row = 1 });
        defer self.drawCursor(tree) catch {};
        try tui.hideCursor(out);
        defer tui.showCursor(out) catch {};

        const lineCount = tree.getLineCount();
        const lineNumberGutterWidth = getLineNumberGutterWidth(tree);
        const from = self.scrollPosition.row;
        const to: usize = @min(self.scrollPosition.row + self.size.height - 1, lineCount);

        const width = self.size.width - lineNumberGutterWidth;

        for (from..to + 1) |i| {
            const line = try tree.getLineContent(i);

            try self.drawLineNumberGutter(lineNumberGutterWidth, i);

            try tui.writeAll(out, line);

            if (i < to) {
                try tui.writeAll(out, "⏎");
            }

            if (line.len <= width) {
                for (line.len..width) |_| {
                    try tui.writeAll(out, " ");
                }
            }

            if (i < to) {
                try tui.writeAll(out, "\r\n");
            }
        }

        try tui.clearToEndOfScreen(out);
    }

    fn drawCursor(self: *const View, tree: *const PieceTreeTextBuffer) !void {
        const out = self.writer;
        const lineNumberGutterWidth = getLineNumberGutterWidth(tree);
        const row = self.cursorPosition.row - self.scrollPosition.row + 1;
        const col = lineNumberGutterWidth + clamp(self.cursorPosition.col, 1, tree.getLineLength(self.cursorPosition.row) + 1);
        try tui.moveCursor(out, .{ .row = row, .col = col });
    }

    fn moveCursor(self: *View, action: MoveAction, tree: *const PieceTreeTextBuffer) !void {
        var newCol = self.cursorPosition.col;
        var newRow = self.cursorPosition.row;
        switch (action) {
            .Up => {
                newRow -= 1;
                newRow = clamp(newRow, 1, tree.getLineCount());
            },
            .Down => {
                newRow += 1;
                newRow = clamp(newRow, 1, tree.getLineCount());
            },
            .Left => {
                newCol -= 1;
                newCol = clamp(newCol, 1, tree.getLineLength(newRow) + 1);
            },
            .Right => {
                newCol += 1;
                newCol = clamp(newCol, 1, tree.getLineLength(newRow) + 1);
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
        _ = try tree.applyEdits(&[_]ValidAnnotatedEditOperation{ValidAnnotatedEditOperation.fromRangeAndText(Range{
            .startLineNumber = self.cursorPosition.row,
            .startColumn = self.cursorPosition.col,
            .endLineNumber = self.cursorPosition.row,
            .endColumn = self.cursorPosition.col,
        }, text)}, false, false);
        try self.updateCursorPosition(tree, offset + text.len);
    }

    fn deleteLeftOfCursor(self: *View, tree: *PieceTreeTextBuffer) !void {
        const startPos = self.cursorPosition;
        const offset = tree.getOffsetAt(startPos.row, startPos.col);
        if (offset == 0) {
            return;
        }
        try self.updateCursorPosition(tree, offset - 1);
        _ = try tree.applyEdits(&[_]ValidAnnotatedEditOperation{ValidAnnotatedEditOperation.fromRange(Range{
            .startLineNumber = self.cursorPosition.row,
            .startColumn = self.cursorPosition.col,
            .endLineNumber = startPos.row,
            .endColumn = startPos.col,
        })}, false, false);
    }

    fn resize(self: *View, newSize: Size, tree: *const PieceTreeTextBuffer) !void {
        self.size = newSize;

        const lineCount = tree.getLineCount();

        if (self.scrollPosition.row + self.size.height > lineCount) {
            self.scrollPosition.row = lineCount - self.size.height + 1;
        }
    }
};

fn initUtf8StreamIterator(fd: posix.fd_t) Utf8StreamIterator(16) {
    const file = std.fs.File{ .handle = fd };
    return Utf8StreamIterator(16).init(file.reader().any());
}

pub fn main() !void {
    try logger.init("debug.log");
    defer logger.deinit();

    const stdout = std.io.getStdOut();
    const out = stdout.writer();

    const orig_termios = try tui.enableRawMode();
    tui.rememberOrigTermios(orig_termios);
    defer tui.disableRawMode(orig_termios) catch unreachable;

    try tui.enableBracketedPaste(out);
    defer tui.disableBracketedPaste(out) catch {};

    try tui.enterAltScreen(out);
    defer tui.exitAltScreen(out) catch {};

    try tui.disableLineWrap(out);
    defer tui.enableLineWrap(out) catch {};

    try tui.installSigWinch();

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
    var scrollChanged = false;

    var inputBuffer = try ArrayList(u8).initCapacity(allocator, 1024);
    defer inputBuffer.deinit();

    while (true) {
        inputBuffer.clearRetainingCapacity();
        const input = try tui.readFd(posix.STDIN_FILENO, &inputBuffer);
        const tokens = try ansi.tokenize(allocator, input);
        defer tokens.deinit();

        var oldView = view;
        var isPasting = false;

        for (tokens.items) |token| {
            switch (token) {
                .string => {
                    if (token.string[0] == 'q') {
                        return;
                    } else if (token.string[0] == 0x7f) {
                        try view.deleteLeftOfCursor(&tree);
                        contentChanged = true;
                    } else if (token.string[0] == '\r') {
                        try view.insertAtCursor(&tree, "\n");
                        contentChanged = true;
                    } else if (isPasting) {
                        try view.insertAtCursor(&tree, token.string);
                        contentChanged = true;
                    } else {
                        try view.insertAtCursor(&tree, token.string);
                        contentChanged = true;
                    }
                },
                .csi => {
                    switch (token.csi.final) {
                        'A' => try view.moveCursor(.Up, &tree),
                        'B' => try view.moveCursor(.Down, &tree),
                        'C' => try view.moveCursor(.Right, &tree),
                        'D' => try view.moveCursor(.Left, &tree),
                        '~' => {
                            if (token.isBracketedPasteStart()) {
                                isPasting = true;
                            } else if (token.isBracketedPasteEnd()) {
                                isPasting = false;
                            }
                        },
                        else => unreachable,
                    }
                },
            }
        }

        if (try tui.resizedSize()) |newSize| {
            scrollChanged = true;
            try view.resize(newSize, &tree);
        } else {
            scrollChanged = !oldView.scrollPosition.equals(view.scrollPosition);
        }

        if (scrollChanged) {
            try view.drawVisibleLines(&tree);
        }

        if (!oldView.cursorPosition.equals(view.cursorPosition)) {
            try view.drawCursor(&tree);
        }

        if (contentChanged) {
            try view.drawVisibleLines(&tree);
            contentChanged = false;
        }
    }
}

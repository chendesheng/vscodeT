const std = @import("std");
const Io = std.Io;
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
const Utf8StreamIterator = @import("utf8Helper.zig").Utf8StreamIterator;
const ansi = @import("ansi.zig");
const String = @import("../basics/strings.zig").String;

const MoveAction = enum {
    Up,
    Down,
    Left,
    Right,
};

var readerBuffer: [65535]u8 = undefined;
var fileReaderBuffer: [65535]u8 = undefined;

fn readFile(io: Io, allocator: std.mem.Allocator, path: []const u8) !PieceTreeTextBuffer {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var builder = PieceTreeBufferBuilder.init(allocator);
    var reader = file.readerStreaming(io, &fileReaderBuffer);
    while (true) {
        const len = try reader.interface.readSliceShort(&readerBuffer);
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

fn getFirstArg(args: std.process.Args) ![]const u8 {
    var it = args.iterate();
    _ = it.next(); // executable name
    return it.next() orelse error.NoPathProvided;
}

fn getLineNumberGutterWidth(tree: *const PieceTreeTextBuffer) usize {
    const lineCount = tree.getLineCount();
    const maxLineNumberWidth = std.fmt.count("{d}", .{lineCount});
    return maxLineNumberWidth + 2;
}

const View = struct {
    writer: *Io.Writer,
    size: Size,
    scrollPosition: Point,
    cursorPosition: Point,

    fn drawLineNumberGutter(self: *const View, lineNumberGutterWidth: usize, lineNumber: usize) !void {
        const out = self.writer;

        const lineNumberWidth = std.fmt.count("{d}", .{lineNumber});
        if (lineNumberGutterWidth > lineNumberWidth + 1) {
            for (lineNumberWidth..lineNumberGutterWidth - 1) |_| {
                try tui.writeAll(out, " ");
            }
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
        const from = @min(self.scrollPosition.row, lineCount);
        const visibleHeight = @max(self.size.height, 1);
        const to: usize = @min(from + visibleHeight - 1, lineCount);

        const width = self.size.width -| lineNumberGutterWidth;

        for (from..to + 1) |i| {
            const line = try tree.getLineContent(i);
            defer line.deinit();

            try self.drawLineNumberGutter(lineNumberGutterWidth, i);

            try tui.writeAll(out, line.items);

            if (i < to) {
                try tui.writeAll(out, "⏎");
            }

            if (line.items.len <= width) {
                for (line.items.len..width) |_| {
                    try tui.writeAll(out, " ");
                }
            }

            if (i < to) {
                try tui.writeAll(out, "\r\n");
            }
        }

        try tui.clearToEndOfScreen(out);
        try out.flush();
    }

    fn drawCursor(self: *const View, tree: *const PieceTreeTextBuffer) !void {
        const out = self.writer;
        const lineNumberGutterWidth = getLineNumberGutterWidth(tree);
        const row = self.cursorPosition.row -| self.scrollPosition.row + 1;
        const col = lineNumberGutterWidth + clamp(self.cursorPosition.col, 1, tree.getLineLength(self.cursorPosition.row) + 1);
        try tui.moveCursor(out, .{ .row = row, .col = col });
        try out.flush();
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
            },
            .Right => {
                newCol += 1;
            },
        }

        self.cursorPosition.row = newRow;
        self.cursorPosition.col = clamp(newCol, 1, tree.getLineLength(newRow) + 1);

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
        var ops = [_]ValidAnnotatedEditOperation{ValidAnnotatedEditOperation.fromRangeAndText(Range{
            .startLineNumber = self.cursorPosition.row,
            .startColumn = self.cursorPosition.col,
            .endLineNumber = self.cursorPosition.row,
            .endColumn = self.cursorPosition.col,
        }, String.initBorrowed(text))};
        var result = try tree.applyEdits(&ops, false, false);
        defer {
            for (result.changes.items) |*change| change.modelContentChange.deinit();
            result.deinit();
        }
        try self.updateCursorPosition(tree, offset + text.len);
    }

    fn deleteLeftOfCursor(self: *View, tree: *PieceTreeTextBuffer) !void {
        const startPos = self.cursorPosition;
        const offset = tree.getOffsetAt(startPos.row, startPos.col);
        if (offset == 0) {
            return;
        }
        try self.updateCursorPosition(tree, offset - 1);
        var ops = [_]ValidAnnotatedEditOperation{ValidAnnotatedEditOperation.fromRange(Range{
            .startLineNumber = self.cursorPosition.row,
            .startColumn = self.cursorPosition.col,
            .endLineNumber = startPos.row,
            .endColumn = startPos.col,
        })};
        var result = try tree.applyEdits(&ops, false, false);
        defer {
            for (result.changes.items) |*change| change.modelContentChange.deinit();
            result.deinit();
        }
    }

    fn resize(self: *View, newSize: Size, tree: *const PieceTreeTextBuffer) !void {
        self.size = newSize;

        const lineCount = tree.getLineCount();

        if (self.scrollPosition.row + self.size.height > lineCount and lineCount + 1 > self.size.height) {
            self.scrollPosition.row = lineCount + 1 - self.size.height;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    try logger.init(io, "debug.log");
    defer logger.deinit();

    var out_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

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

    const pathArg = try getFirstArg(init.minimal.args);

    var tree = try readFile(io, allocator, pathArg);
    defer tree.deinit();

    const size = try tui.getTerminalSize();

    var view = View{
        .writer = out,
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

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
    screen: Screen,
    size: Size,
    scrollPosition: Point,
    cursorPosition: Point,
    mode: Mode,

    const Mode = enum(u8) {
        Normal,
        Insert,
    };

    fn drawLineNumberGutter(self: *const View, lineNumberGutterWidth: usize, lineNumber: usize) !void {
        const lineNumberWidth = std.fmt.count("{d}", .{lineNumber});
        for (lineNumberWidth..lineNumberGutterWidth - 1) |_| {
            try self.screen.writeAll(" ");
        }

        try self.screen.writeFmt("{d} ", .{lineNumber});
    }

    fn drawVisibleLines(self: *const View, tree: *PieceTreeTextBuffer) !void {
        try self.screen.moveCursor(.{ .col = 1, .row = 1 });
        defer self.drawCursor(tree) catch {};
        try self.screen.hideCursor();
        defer self.screen.showCursor() catch {};

        const lineCount = tree.getLineCount();
        const lineNumberGutterWidth = getLineNumberGutterWidth(tree);
        const from = self.scrollPosition.row;
        const to: usize = @min(self.scrollPosition.row + self.size.height - 1, lineCount);

        const width = self.size.width - lineNumberGutterWidth;

        for (from..to + 1) |i| {
            const lineContent = try tree.getLineContent(i);
            defer lineContent.deinit();
            const line = lineContent.items;

            try self.drawLineNumberGutter(lineNumberGutterWidth, i);

            try self.screen.writeAll(line);

            if (i < to) {
                try self.screen.writeAll("⏎");
            }

            if (line.len <= width) {
                try self.screen.eraseToLineEnd();
            }

            if (i < to) {
                try self.screen.moveCursorNextLine();
            }
        }

        try self.screen.eraseToEnd();
    }

    fn drawCursor(self: *const View, tree: *const PieceTreeTextBuffer) !void {
        const lineNumberGutterWidth = getLineNumberGutterWidth(tree);
        const row = self.cursorPosition.row - self.scrollPosition.row + 1;
        const col = lineNumberGutterWidth + utils.clamp(self.cursorPosition.col, 1, tree.getLineLength(self.cursorPosition.row) + 1);
        try self.screen.moveCursor(.{ .row = row, .col = col });
    }

    fn moveCursor(self: *View, action: MoveAction, tree: *const PieceTreeTextBuffer) !void {
        var newCol = self.cursorPosition.col;
        var newRow = self.cursorPosition.row;
        switch (action) {
            .Up => {
                newRow -= 1;
                newRow = utils.clamp(newRow, 1, tree.getLineCount());
            },
            .Down => {
                newRow += 1;
                newRow = utils.clamp(newRow, 1, tree.getLineCount());
            },
            .Left => {
                newCol -= 1;
            },
            .Right => {
                newCol += 1;
            },
        }

        self.cursorPosition.row = newRow;
        self.cursorPosition.col = utils.clamp(newCol, 1, tree.getLineLength(newRow) + 1);

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
        if (mode == .Normal) {
            try self.screen.setCursorShape(.Block);
        } else if (mode == .Insert) {
            try self.screen.setCursorShape(.Bar);
        }
    }

    fn handleKeyPress(self: *View, key: tui.KeyPress, tree: *PieceTreeTextBuffer) !void {
        if (self.mode == .Normal) {
            switch (key.keycode) {
                .up => try self.moveCursor(.Up, tree),
                .down => try self.moveCursor(.Down, tree),
                .left => try self.moveCursor(.Left, tree),
                .right => try self.moveCursor(.Right, tree),
                .character => |c| {
                    switch (c) {
                        'i' => try self.setMode(.Insert),
                        'q' => std.process.exit(0),
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

    try tui.installSigWinch();

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
        .screen = screen,
        .size = try tui.getTerminalSize(),
        .scrollPosition = .{ .col = 1, .row = 1 },
        .cursorPosition = .{ .col = 1, .row = 1 },
        .mode = .Normal,
    };
    try view.drawVisibleLines(&tree);

    var contentChanged = false;
    var scrollChanged = false;

    while (true) {
        const tokens = try view.screen.poll();
        defer tokens.deinit();

        var oldView = view;
        var isPasting = false;

        for (tokens.items) |token| {
            logWriter.print("{any}\n", .{token}) catch {};
            logWriter.flush() catch {};

            switch (token) {
                .string => {
                    if (token.string[0] == 0x7f) {
                        try view.handleKeyPress(.init(.backspace, .{}), &tree);
                        contentChanged = true;
                    } else if (token.string[0] == 27) {
                        try view.handleKeyPress(.init(.escape, .{}), &tree);
                        contentChanged = true;
                    } else if (token.string[0] == '\r') {
                        try view.handleKeyPress(.init(.enter, .{}), &tree);
                        contentChanged = true;
                    } else if (isPasting) {
                        try view.insertAtCursor(&tree, token.string);
                        contentChanged = true;
                    } else {
                        try view.handleKeyPress(.init(.{ .character = token.string[0] }, .{}), &tree);
                        contentChanged = true;
                    }
                },
                .csi => {
                    if (token.csi.final == '~') {
                        if (token.isBracketedPasteStart()) {
                            isPasting = true;
                        } else if (token.isBracketedPasteEnd()) {
                            isPasting = false;
                        }
                    } else {
                        const key: tui.KeyPress = switch (token.csi.final) {
                            'A' => .init(.up, .{}),
                            'B' => .init(.down, .{}),
                            'C' => .init(.right, .{}),
                            'D' => .init(.left, .{}),
                            else => unreachable,
                        };
                        try view.handleKeyPress(key, &tree);
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const UndoRedoGroup = @import("../undoRedo.zig").UndoRedoGroup;
const IdentifiedSingleEditOperation = @import("../model.zig").IdentifiedSingleEditOperation;
const UndoRedoService = @import("../undoRedoService.zig").UndoRedoService;
const TextModel = @import("../textModel.zig").TextModel;
const TextModelCreationOptions = @import("../model.zig").TextModelCreationOptions;
const io = std.io;
const fs = std.fs;
const File = fs.File;
const posix = std.posix;
const tui = @import("tui.zig");
const Size = tui.Size;
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
const Position = @import("../basics/position.zig").Position;

const MoveAction = enum {
    Up,
    Down,
    Left,
    Right,
    LineFirstNonSpace,
    LineStart,
    LineEnd,
    BufferStart,
    BufferEnd,
    PageTop,
    PageMiddle,
    PageBottom,
    // scroll
    HalfPageUp,
    HalfPageDown,
};

const Self = @This();

log: *std.Io.Writer,
size: Size,
scrollPosition: Position = .init(1, 1),
cursorPosition: Position = .init(1, 1),
cursorColumn: usize = 1,
textModel: *TextModel,
mode: Mode = .Normal,
undoRedoGroup: UndoRedoGroup,

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

pub fn drawVisibleLines(self: *const Self, screen: *Screen) !void {
    try screen.moveCursor(1, 1);
    defer self.drawCursor(screen) catch {};
    try screen.hideCursor();
    defer screen.showCursor() catch {};

    const lineCount = self.textModel.getLineCount();
    const lineNumberGutterWidth = getLineNumberGutterWidth(lineCount);
    const from = self.scrollPosition.lineNumber;
    const to: usize = @min(self.scrollPosition.lineNumber + self.size.height - 1, lineCount);

    const width = self.size.width - lineNumberGutterWidth;

    for (from..to + 1) |i| {
        const lineContent = try self.textModel.getLineContent(i);
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

fn drawCursor(self: *const Self, screen: *Screen) !void {
    const lineNumberGutterWidth = getLineNumberGutterWidth(self.textModel.getLineCount());
    const lineNumber = self.cursorPosition.lineNumber - self.scrollPosition.lineNumber + 1;
    const col = lineNumberGutterWidth + utils.clamp(self.cursorPosition.column, 1, self.textModel.getLineLength(self.cursorPosition.lineNumber) + 1);
    try screen.moveCursor(lineNumber, col);
    if (self.mode == .Normal) {
        try screen.setCursorShape(.Block);
    } else if (self.mode == .Insert) {
        try screen.setCursorShape(.Bar);
    }
}

fn moveCursor(self: *Self, action: MoveAction) !void {
    var newCol = self.cursorPosition.column;
    var newLineNumber = self.cursorPosition.lineNumber;
    var newCursorColumn = self.cursorColumn;
    switch (action) {
        .Up => {
            newLineNumber = utils.clamp(newLineNumber - 1, 1, self.textModel.getLineCount());
            newCol = utils.clamp(newCursorColumn, 1, self.textModel.getLineLength(newLineNumber));
        },
        .Down => {
            newLineNumber = utils.clamp(newLineNumber + 1, 1, self.textModel.getLineCount());
            newCol = utils.clamp(newCursorColumn, 1, self.textModel.getLineLength(newLineNumber));
        },
        .Left => {
            newCol = utils.clamp(newCol - 1, 1, self.textModel.getLineLength(newLineNumber));
            newCursorColumn = newCol;
        },
        .Right => {
            newCol = utils.clamp(newCol + 1, 1, self.textModel.getLineLength(newLineNumber));
            newCursorColumn = newCol;
        },
        .LineStart => {
            newCol = 1;
            newCursorColumn = newCol;
        },
        .LineEnd => {
            newCol = self.textModel.getLineLength(newLineNumber);
            newCursorColumn = newCol;
        },
        .LineFirstNonSpace => {
            newCol = try self.textModel.getLineFirstNonWhitespaceColumn(newLineNumber);
            newCursorColumn = newCol;
        },
        .BufferStart => {
            newLineNumber = 1;
            newCol = 1;
            newCursorColumn = newCol;
        },
        .BufferEnd => {
            newLineNumber = self.textModel.getLineCount();
            newCol = self.textModel.getLineLength(newLineNumber);
            newCursorColumn = newCol;
        },
        .HalfPageUp => {
            // FIXME: this is not correct, should scroll
            const h = self.size.height / 2;
            newLineNumber = if (newLineNumber > h) newLineNumber - h else 1;
            newCol = try self.textModel.getLineFirstNonWhitespaceColumn(newLineNumber);
            newCursorColumn = newCol;
        },
        .HalfPageDown => {
            // FIXME: this is not correct, should scroll
            newLineNumber = utils.clamp(newLineNumber + self.size.height / 2, 1, self.textModel.getLineCount());
            newCol = try self.textModel.getLineFirstNonWhitespaceColumn(newLineNumber);
            newCursorColumn = newCol;
        },
        .PageTop => {
            newLineNumber = self.scrollPosition.lineNumber;
            newLineNumber = utils.clamp(newLineNumber, 1, self.textModel.getLineCount());
            newCol = try self.textModel.getLineFirstNonWhitespaceColumn(newLineNumber);
            newCursorColumn = newCol;
        },
        .PageBottom => {
            newLineNumber = self.scrollPosition.lineNumber + self.size.height - 1;
            newLineNumber = utils.clamp(newLineNumber, 1, self.textModel.getLineCount());
            newCol = try self.textModel.getLineFirstNonWhitespaceColumn(newLineNumber);
            newCursorColumn = newCol;
        },
        .PageMiddle => {
            newLineNumber = self.scrollPosition.lineNumber + self.size.height / 2;
            newLineNumber = utils.clamp(newLineNumber, 1, self.textModel.getLineCount());
            newCol = try self.textModel.getLineFirstNonWhitespaceColumn(newLineNumber);
            newCursorColumn = newCol;
        },
    }

    self.cursorPosition.lineNumber = newLineNumber;
    self.cursorPosition.column = newCol;
    self.cursorColumn = newCursorColumn;

    if (newLineNumber < self.scrollPosition.lineNumber) {
        self.scrollPosition.lineNumber = newLineNumber;
    } else if (newLineNumber >= self.scrollPosition.lineNumber + self.size.height) {
        self.scrollPosition.lineNumber = newLineNumber - self.size.height + 1;
    }
}

fn updateCursorPosition(self: *Self, offset: usize) !void {
    const pos = self.textModel.getPositionAt(offset);

    if (pos.lineNumber < self.scrollPosition.lineNumber) {
        self.scrollPosition.lineNumber = pos.lineNumber;
    } else if (pos.lineNumber >= self.scrollPosition.lineNumber + self.size.height) {
        self.scrollPosition.lineNumber = pos.lineNumber - self.size.height + 1;
    }
    self.cursorPosition.lineNumber = pos.lineNumber;
    self.cursorPosition.column = pos.column;
}

fn insertAt(self: *Self, text: []const u8, position: Position) !void {
    var edits = [_]IdentifiedSingleEditOperation{.init(Range.init(position.lineNumber, position.column, position.lineNumber, position.column), .initBorrowed(text))};
    _ = try self.textModel.pushEditOperations(null, &edits, null, self.undoRedoGroup);
}

fn insertAtCursor(self: *Self, text: []const u8) !void {
    const offset = self.textModel.getOffsetAt(self.cursorPosition);
    try self.insertAt(text, self.cursorPosition);
    try self.updateCursorPosition(offset + text.len);
}

fn deleteLeftOfCursor(self: *Self) !void {
    const startPos = self.cursorPosition;
    const offset = self.textModel.getOffsetAt(startPos);
    if (offset == 0) {
        return;
    }
    try self.updateCursorPosition(offset - 1);
    var edits = [_]IdentifiedSingleEditOperation{.init(Range.init(
        self.cursorPosition.lineNumber,
        self.cursorPosition.column,
        startPos.lineNumber,
        startPos.column,
    ), null)};
    _ = try self.textModel.pushEditOperations(null, &edits, null, self.undoRedoGroup);
}

pub fn resize(self: *Self, newSize: Size) !void {
    self.size = newSize;

    const lineCount = self.textModel.getLineCount();

    if (self.scrollPosition.lineNumber + self.size.height > lineCount and lineCount + 1 > self.size.height) {
        self.scrollPosition.lineNumber = lineCount + 1 - self.size.height;
    }
}

fn beginInsert(self: *Self) !void {
    self.mode = .Insert;
}

fn beginInsertAppend(self: *Self) !void {
    self.cursorPosition.column += 1;
    self.mode = .Insert;
}

fn beginInsertNewLine(self: *Self) !void {
    try self.insertAt("\n", .{ .lineNumber = self.cursorPosition.lineNumber + 1, .column = 1 });
    self.cursorPosition.lineNumber += 1;
    self.cursorPosition.column = 1;
    self.mode = .Insert;
}

fn endInsert(self: *Self) !void {
    std.debug.assert(self.mode == .Insert);

    self.mode = .Normal;
    self.cursorColumn = self.cursorPosition.column;
    self.undoRedoGroup = UndoRedoGroup.init();
    self.moveCursor(.Left) catch unreachable;
}

pub fn handleKeyPress(self: *Self, key: *const tui.KeyPress) !void {
    if (self.mode == .Normal) {
        if (key.noModifiers()) {
            switch (key.keycode) {
                .up => try self.moveCursor(.Up),
                .down => try self.moveCursor(.Down),
                .left => try self.moveCursor(.Left),
                .right => try self.moveCursor(.Right),
                .backspace => try self.moveCursor(.Left),
                .enter => try self.moveCursor(.Down),
                .character => |c| {
                    switch (c) {
                        'i' => try self.beginInsert(),
                        'a' => try self.beginInsertAppend(),
                        'o' => try self.beginInsertNewLine(),
                        'h' => try self.moveCursor(.Left),
                        'j' => try self.moveCursor(.Down),
                        'k' => try self.moveCursor(.Up),
                        'l' => try self.moveCursor(.Right),
                        '0' => try self.moveCursor(.LineStart),
                        '$' => try self.moveCursor(.LineEnd),
                        'G' => try self.moveCursor(.BufferEnd),
                        'H' => try self.moveCursor(.PageTop),
                        'M' => try self.moveCursor(.PageMiddle),
                        'L' => try self.moveCursor(.PageBottom),
                        'u' => try self.textModel.undo(),
                        'q' => return error.Quit,
                        else => return,
                    }
                },
                else => return,
            }
        } else if (key.modifier.ctrl) {
            switch (key.keycode) {
                .character => |c| {
                    switch (c) {
                        'u' => try self.moveCursor(.HalfPageUp),
                        'd' => try self.moveCursor(.HalfPageDown),
                        'r' => try self.textModel.redo(),
                        else => return,
                    }
                },
                else => return,
            }
        }
    } else if (self.mode == .Insert) {
        switch (key.keycode) {
            .backspace => try self.deleteLeftOfCursor(),
            .enter => try self.insertAtCursor("\n"),
            .tab => try self.insertAtCursor("\t"),
            .escape => try self.endInsert(),
            .character => |c| try self.insertAtCursor(&[1]u8{c}),
            else => return,
        }
    }
}

fn getLineNumberGutterWidth(lineCount: usize) usize {
    const maxLineNumberWidth = std.fmt.count("{d}", .{lineCount});
    return maxLineNumberWidth + 2;
}

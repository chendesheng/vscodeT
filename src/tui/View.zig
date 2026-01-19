const std = @import("std");
const Allocator = std.mem.Allocator;
const UndoRedoGroup = @import("../textModel/undoRedo.zig").UndoRedoGroup;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const UndoRedoService = @import("../textModel/undoRedoService.zig").UndoRedoService;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const TextModelCreationOptions = @import("../textModel/model.zig").TextModelCreationOptions;
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
const ValidAnnotatedEditOperation = @import("../textModel/model.zig").ValidAnnotatedEditOperation;
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

size: Size = .{ .width = 0, .height = 0 },
scrollPosition: Position = .init(1, 1),
cursorPosition: Position = .init(1, 1),
cursorColumn: usize = 1,
textModel: *TextModel,
mode: Mode = .Normal,
undoRedoGroup: UndoRedoGroup,

pub fn init(textModel: *TextModel) Self {
    return Self{
        .textModel = textModel,
        .undoRedoGroup = UndoRedoGroup.init(),
    };
}

const Mode = enum(u8) {
    Normal,
    Insert,
};

fn drawLineNumberGutter(self: *const Self, screen: *Screen, lineNumberGutterWidth: usize, lineNumber: usize) !void {
    if (lineNumber == self.cursorPosition.lineNumber) {
        try screen.writeSGRAttributes(&[_]SGRAttribute{ .ForegroundWhite, .BackgroundGray });
    } else {
        try screen.writeSGRAttribute(.ForegroundGray);
    }

    const lineNumberWidth = std.fmt.count("{d}", .{lineNumber});
    for (lineNumberWidth..lineNumberGutterWidth - 1) |_| {
        try screen.writeAll(" ");
    }

    try screen.writeFmt("{d} ", .{lineNumber});
    try screen.resetSGRAttributes();
}

fn drawVisibleLines(self: *const Self, screen: *Screen) !void {
    const lineCount = self.textModel.getLineCount();
    const lineNumberGutterWidth = getLineNumberGutterWidth(lineCount);
    const from = self.scrollPosition.lineNumber;
    const to: usize = @min(self.scrollPosition.lineNumber + self.size.height - 1, lineCount);

    for (from..to + 1) |i| {
        const lineContent = try self.textModel.getLineContent(i);
        defer lineContent.deinit();
        const line = lineContent.items;

        try self.drawLineNumberGutter(screen, lineNumberGutterWidth, i);

        if (i == self.cursorPosition.lineNumber) {
            try screen.writeSGRAttribute(.BackgroundGray);
        }

        try screen.writeAll(line);

        if (i < to) {
            try screen.writeAll("⏎");
        }

        try screen.eraseToLineEnd();

        if (i == self.cursorPosition.lineNumber) {
            try screen.resetSGRAttributes();
        }

        try screen.moveCursorNextLine();
    }

    try screen.eraseToEnd();
}

fn drawCursor(self: *const Self, screen: *Screen) !void {
    const lineNumberGutterWidth = getLineNumberGutterWidth(self.textModel.getLineCount());
    const row = utils.clamp(self.cursorPosition.lineNumber - self.scrollPosition.lineNumber + 1, 1, self.size.height);
    const column = lineNumberGutterWidth + utils.clamp(self.cursorPosition.column, 1, self.textModel.getLineLength(self.cursorPosition.lineNumber) + 1);
    try screen.moveCursor(row, column);
    if (self.mode == .Normal) {
        try screen.setCursorShape(.Block);
    } else if (self.mode == .Insert) {
        try screen.setCursorShape(.Bar);
    }
}

fn drawStatusLine(self: *const Self, screen: *Screen) !void {
    try screen.moveCursor(self.size.height + 1, 1);
    if (self.mode == .Normal) {
        try screen.writeSGRAttributes(&[_]SGRAttribute{ .BackgroundBlue, .ForegroundBlack, .Bold });
        try screen.writeAll(" NORMAL ");
        try screen.resetSGRAttributes();
    } else if (self.mode == .Insert) {
        try screen.writeSGRAttributes(&[_]SGRAttribute{ .BackgroundGreen, .ForegroundBlack, .Bold });
        try screen.writeAll(" INSERT ");
        try screen.resetSGRAttributes();
    }
    try screen.writeSGRAttributes(&[_]SGRAttribute{ .BackgroundBlack, .ForegroundWhite });
    try screen.writeFmt("{d}:{d} ", .{ self.cursorPosition.lineNumber, self.cursorPosition.column });
    try screen.eraseToLineEnd();
    try screen.resetSGRAttributes();
}

pub fn draw(self: *const Self, screen: *Screen) !void {
    try screen.moveCursor(1, 1);
    defer self.drawCursor(screen) catch {};
    try screen.hideCursor();
    defer screen.showCursor() catch {};

    try self.drawVisibleLines(screen);
    try self.drawStatusLine(screen);
}

fn moveCursor(self: *Self, action: MoveAction) !void {
    const column = self.cursorPosition.column;
    const lineNumber = self.cursorPosition.lineNumber;
    const cursorColumn = self.cursorColumn;
    switch (action) {
        .Up => {
            self.cursorPosition.lineNumber = @max(1, lineNumber - 1);
            self.cursorPosition.column = utils.clamp(cursorColumn, 1, self.textModel.getLineLength(self.cursorPosition.lineNumber));
        },
        .Down => {
            self.cursorPosition.lineNumber = utils.clamp(lineNumber + 1, 1, self.textModel.getLineCount());
            self.cursorPosition.column = utils.clamp(cursorColumn, 1, self.textModel.getLineLength(self.cursorPosition.lineNumber));
        },
        .Left => {
            self.cursorPosition.column = @max(1, column - 1);
            self.cursorColumn = self.cursorPosition.column;
        },
        .Right => {
            self.cursorPosition.column = utils.clamp(column + 1, 1, self.textModel.getLineLength(self.cursorPosition.lineNumber));
            self.cursorColumn = self.cursorPosition.column;
        },
        .LineStart => {
            self.cursorPosition.column = 1;
            self.cursorColumn = 1;
        },
        .LineEnd => {
            self.cursorPosition.column = self.textModel.getLineLength(lineNumber);
            self.cursorColumn = self.cursorPosition.column;
        },
        .LineFirstNonSpace => {
            self.cursorPosition.column = try self.textModel.getLineFirstNonWhitespaceColumn(lineNumber);
            self.cursorColumn = self.cursorPosition.column;
        },
        .BufferStart => {
            self.cursorPosition.lineNumber = 1;
            self.cursorPosition.column = @max(1, try self.textModel.getLineFirstNonWhitespaceColumn(1));
            self.cursorColumn = self.cursorPosition.column;
        },
        .BufferEnd => {
            self.cursorPosition.lineNumber = self.textModel.getLineCount();
            self.cursorPosition.column = @max(1, try self.textModel.getLineFirstNonWhitespaceColumn(self.cursorPosition.lineNumber));
            self.cursorColumn = self.cursorPosition.column;
        },
        .HalfPageUp => {
            // FIXME: this is not correct, should scroll
            const h = self.size.height / 2;
            self.cursorPosition.lineNumber = if (self.cursorPosition.lineNumber > h) self.cursorPosition.lineNumber - h else 1;
            self.cursorPosition.column = @max(1, try self.textModel.getLineFirstNonWhitespaceColumn(self.cursorPosition.lineNumber));
            self.cursorColumn = self.cursorPosition.column;
        },
        .HalfPageDown => {
            // FIXME: this is not correct, should scroll
            self.cursorPosition.lineNumber = self.cursorPosition.lineNumber + self.size.height / 2;
            self.cursorPosition.column = @max(1, try self.textModel.getLineFirstNonWhitespaceColumn(self.cursorPosition.lineNumber));
            self.cursorColumn = self.cursorPosition.column;
        },
        .PageTop => {
            self.cursorPosition.lineNumber = self.scrollPosition.lineNumber;
            self.cursorPosition.column = @max(1, try self.textModel.getLineFirstNonWhitespaceColumn(self.cursorPosition.lineNumber));
            self.cursorColumn = self.cursorPosition.column;
        },
        .PageBottom => {
            self.cursorPosition.lineNumber = self.scrollPosition.lineNumber + self.size.height - 1;
            self.cursorPosition.column = @max(1, try self.textModel.getLineFirstNonWhitespaceColumn(self.cursorPosition.lineNumber));
            self.cursorColumn = self.cursorPosition.column;
        },
        .PageMiddle => {
            self.cursorPosition.lineNumber = self.scrollPosition.lineNumber + self.size.height / 2;
            self.cursorPosition.column = @max(1, try self.textModel.getLineFirstNonWhitespaceColumn(self.cursorPosition.lineNumber));
            self.cursorColumn = self.cursorPosition.column;
        },
    }

    self.scrollToCursor();
}

fn scrollToCursor(self: *Self) void {
    if (self.cursorPosition.lineNumber < self.scrollPosition.lineNumber) {
        self.scrollPosition.lineNumber = self.cursorPosition.lineNumber;
    } else if (self.cursorPosition.lineNumber >= self.scrollPosition.lineNumber + self.size.height) {
        self.scrollPosition.lineNumber = self.cursorPosition.lineNumber - self.size.height + 1;
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
    self.cursorColumn = self.cursorPosition.column;
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
    const width = newSize.width;
    const height = newSize.height;
    // last line is the status line
    self.size = .{ .width = width, .height = height - 1 };

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

fn clampCursorPosition(self: *Self) void {
    self.cursorPosition.lineNumber = utils.clamp(self.cursorPosition.lineNumber, 1, self.textModel.getLineCount());
}

fn undo(self: *Self) !void {
    try self.textModel.undo();
    self.clampCursorPosition();
}

fn redo(self: *Self) !void {
    try self.textModel.redo();
    self.clampCursorPosition();
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
                        'u' => try self.undo(),
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
                        'r' => try self.redo(),
                        else => {
                            return;
                        },
                    }
                },
                else => return,
            }
        }
    } else if (self.mode == .Insert) {
        if (key.noModifiers()) {
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
}

fn getLineNumberGutterWidth(lineCount: usize) usize {
    const maxLineNumberWidth = std.fmt.count("{d}", .{lineCount});
    return maxLineNumberWidth + 2;
}

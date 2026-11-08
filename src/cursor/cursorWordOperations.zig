const std = @import("std");
const WordCharacterClassifier = @import("../basics/wordCharacterClassifier.zig").WordCharacterClassifier;
const WordCharacterClass = @import("../basics/wordCharacterClassifier.zig").WordCharacterClass;
const Position = @import("../basics/position.zig").Position;
const cursorCommon = @import("cursorCommon.zig");
const ICursorSimpleModel = cursorCommon.ICursorSimpleModel;

const WordType = enum { None, Regular, Separator };

pub const WordNavigationType = enum(u2) {
    WordStart = 0,
    WordStartFast = 1,
    WordEnd = 2,
    WordAccessibility = 3,
};

pub const IFindWordResult = struct {
    start: usize,
    end: usize,
    wordType: WordType,
    nextCharClass: WordCharacterClass,
};

pub const WordOperations = struct {
    fn createWord(word_type: WordType, next_char_class: WordCharacterClass, start: usize, end: usize) IFindWordResult {
        return .{ .start = start, .end = end, .wordType = word_type, .nextCharClass = next_char_class };
    }

    fn findPreviousWordOnLine(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, position: Position) ?IFindWordResult {
        return doFindPreviousWordOnLine(model.getLineContent(model.context, position.lineNumber), wordSeparators, position);
    }

    fn doFindPreviousWordOnLine(lineContent: []const u8, wordSeparators: *const WordCharacterClassifier, position: Position) ?IFindWordResult {
        var word_type: WordType = .None;
        var ch_index: isize = @as(isize, @intCast(position.column)) - 2;

        while (ch_index >= 0) : (ch_index -= 1) {
            const index: usize = @intCast(ch_index);
            if (index >= lineContent.len) continue;
            const ch_class = wordSeparators.get(lineContent[index]);

            if (ch_class == .Regular) {
                if (word_type == .Separator) {
                    return createWord(word_type, ch_class, index + 1, findEndOfWord(lineContent, wordSeparators, word_type, index + 1));
                }
                word_type = .Regular;
            } else if (ch_class == .WordSeparator) {
                if (word_type == .Regular) {
                    return createWord(word_type, ch_class, index + 1, findEndOfWord(lineContent, wordSeparators, word_type, index + 1));
                }
                word_type = .Separator;
            } else if (ch_class == .Whitespace) {
                if (word_type != .None) {
                    return createWord(word_type, ch_class, index + 1, findEndOfWord(lineContent, wordSeparators, word_type, index + 1));
                }
            }
        }

        if (word_type != .None) {
            return createWord(word_type, .Whitespace, 0, findEndOfWord(lineContent, wordSeparators, word_type, 0));
        }
        return null;
    }

    fn findEndOfWord(lineContent: []const u8, wordSeparators: *const WordCharacterClassifier, word_type: WordType, startIndex: usize) usize {
        var ch_index = startIndex;
        while (ch_index < lineContent.len) : (ch_index += 1) {
            const ch_class = wordSeparators.get(lineContent[ch_index]);
            if (ch_class == .Whitespace) return ch_index;
            if (word_type == .Regular and ch_class == .WordSeparator) return ch_index;
            if (word_type == .Separator and ch_class == .Regular) return ch_index;
        }
        return lineContent.len;
    }

    fn findNextWordOnLine(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, position: Position) ?IFindWordResult {
        return doFindNextWordOnLine(model.getLineContent(model.context, position.lineNumber), wordSeparators, position);
    }

    fn doFindNextWordOnLine(lineContent: []const u8, wordSeparators: *const WordCharacterClassifier, position: Position) ?IFindWordResult {
        var word_type: WordType = .None;
        var ch_index = position.column - 1;
        while (ch_index < lineContent.len) : (ch_index += 1) {
            const ch_class = wordSeparators.get(lineContent[ch_index]);
            if (ch_class == .Regular) {
                if (word_type == .Separator) {
                    return createWord(word_type, ch_class, findStartOfWord(lineContent, wordSeparators, word_type, ch_index - 1), ch_index);
                }
                word_type = .Regular;
            } else if (ch_class == .WordSeparator) {
                if (word_type == .Regular) {
                    return createWord(word_type, ch_class, findStartOfWord(lineContent, wordSeparators, word_type, ch_index - 1), ch_index);
                }
                word_type = .Separator;
            } else if (ch_class == .Whitespace) {
                if (word_type != .None) {
                    return createWord(word_type, ch_class, findStartOfWord(lineContent, wordSeparators, word_type, ch_index - 1), ch_index);
                }
            }
        }

        if (word_type != .None) {
            return createWord(word_type, .Whitespace, findStartOfWord(lineContent, wordSeparators, word_type, lineContent.len - 1), lineContent.len);
        }
        return null;
    }

    fn findStartOfWord(lineContent: []const u8, wordSeparators: *const WordCharacterClassifier, word_type: WordType, startIndex: usize) usize {
        var ch_index = startIndex;
        while (true) {
            const ch_class = wordSeparators.get(lineContent[ch_index]);
            if (ch_class == .Whitespace) return ch_index + 1;
            if (word_type == .Regular and ch_class == .WordSeparator) return ch_index + 1;
            if (word_type == .Separator and ch_class == .Regular) return ch_index + 1;
            if (ch_index == 0) break;
            ch_index -= 1;
        }
        return 0;
    }

    pub fn moveWordLeft(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, position: Position, wordNavigationType: WordNavigationType, hasMulticursor: bool) Position {
        var lineNumber = position.lineNumber;
        var column = position.column;

        if (column == 1 and lineNumber > 1) {
            lineNumber -= 1;
            column = model.getLineMaxColumn(model.context, lineNumber);
        }

        var prevWordOnLine = findPreviousWordOnLine(wordSeparators, model, Position.init(lineNumber, column));

        if (wordNavigationType == .WordStart) {
            return Position.init(lineNumber, if (prevWordOnLine) |word| word.start + 1 else 1);
        }

        if (wordNavigationType == .WordStartFast) {
            if (!hasMulticursor and prevWordOnLine != null and prevWordOnLine.?.wordType == .Separator and
                prevWordOnLine.?.end - prevWordOnLine.?.start == 1 and prevWordOnLine.?.nextCharClass == .Regular)
            {
                prevWordOnLine = findPreviousWordOnLine(wordSeparators, model, Position.init(lineNumber, prevWordOnLine.?.start + 1));
            }
            return Position.init(lineNumber, if (prevWordOnLine) |word| word.start + 1 else 1);
        }

        if (wordNavigationType == .WordAccessibility) {
            while (prevWordOnLine != null and prevWordOnLine.?.wordType == .Separator) {
                prevWordOnLine = findPreviousWordOnLine(wordSeparators, model, Position.init(lineNumber, prevWordOnLine.?.start + 1));
            }
            return Position.init(lineNumber, if (prevWordOnLine) |word| word.start + 1 else 1);
        }

        if (prevWordOnLine != null and column <= prevWordOnLine.?.end + 1) {
            prevWordOnLine = findPreviousWordOnLine(wordSeparators, model, Position.init(lineNumber, prevWordOnLine.?.start + 1));
        }
        return Position.init(lineNumber, if (prevWordOnLine) |word| word.end + 1 else 1);
    }

    pub fn moveWordRight(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, position: Position, wordNavigationType: WordNavigationType) Position {
        var lineNumber = position.lineNumber;
        var column = position.column;
        var movedDown = false;

        if (column == model.getLineMaxColumn(model.context, lineNumber) and lineNumber < model.getLineCount(model.context)) {
            movedDown = true;
            lineNumber += 1;
            column = 1;
        }

        var nextWordOnLine = findNextWordOnLine(wordSeparators, model, Position.init(lineNumber, column));

        if (wordNavigationType == .WordEnd) {
            if (nextWordOnLine != null and nextWordOnLine.?.wordType == .Separator and
                nextWordOnLine.?.end - nextWordOnLine.?.start == 1 and nextWordOnLine.?.nextCharClass == .Regular)
            {
                nextWordOnLine = findNextWordOnLine(wordSeparators, model, Position.init(lineNumber, nextWordOnLine.?.end + 1));
            }
            return Position.init(lineNumber, if (nextWordOnLine) |word| word.end + 1 else model.getLineMaxColumn(model.context, lineNumber));
        }

        if (wordNavigationType == .WordAccessibility) {
            if (movedDown) column = 0;
            while (nextWordOnLine != null and (nextWordOnLine.?.wordType == .Separator or nextWordOnLine.?.start + 1 <= column)) {
                nextWordOnLine = findNextWordOnLine(wordSeparators, model, Position.init(lineNumber, nextWordOnLine.?.end + 1));
            }
            return Position.init(lineNumber, if (nextWordOnLine) |word| word.start + 1 else model.getLineMaxColumn(model.context, lineNumber));
        }

        if (nextWordOnLine != null and !movedDown and column >= nextWordOnLine.?.start + 1) {
            nextWordOnLine = findNextWordOnLine(wordSeparators, model, Position.init(lineNumber, nextWordOnLine.?.end + 1));
        }
        return Position.init(lineNumber, if (nextWordOnLine) |word| word.start + 1 else model.getLineMaxColumn(model.context, lineNumber));
    }

    pub fn moveWordPartLeft(model: ICursorSimpleModel, position: Position) Position {
        const lineNumber = position.lineNumber;
        const maxColumn = model.getLineMaxColumn(model.context, lineNumber);
        if (position.column == 1) {
            return if (lineNumber > 1) Position.init(lineNumber - 1, model.getLineMaxColumn(model.context, lineNumber - 1)) else position;
        }

        const lineContent = model.getLineContent(model.context, lineNumber);
        var column = position.column - 1;
        while (column > 1) : (column -= 1) {
            const left = lineContent[column - 2];
            const right = lineContent[column - 1];
            if (left == '_' and right != '_') return Position.init(lineNumber, column);
            if (left == '-' and right != '-') return Position.init(lineNumber, column);
            if ((isLowerAsciiLetter(left) or isAsciiDigit(left)) and isUpperAsciiLetter(right)) return Position.init(lineNumber, column);
            if (isUpperAsciiLetter(left) and isUpperAsciiLetter(right) and column + 1 < maxColumn) {
                const rightRight = lineContent[column];
                if (isLowerAsciiLetter(rightRight) or isAsciiDigit(rightRight)) return Position.init(lineNumber, column);
            }
        }
        return Position.init(lineNumber, 1);
    }

    pub fn moveWordPartRight(model: ICursorSimpleModel, position: Position) Position {
        const lineNumber = position.lineNumber;
        const maxColumn = model.getLineMaxColumn(model.context, lineNumber);
        if (position.column == maxColumn) {
            return if (lineNumber < model.getLineCount(model.context)) Position.init(lineNumber + 1, 1) else position;
        }

        const lineContent = model.getLineContent(model.context, lineNumber);
        var column = position.column + 1;
        while (column < maxColumn) : (column += 1) {
            const left = lineContent[column - 2];
            const right = lineContent[column - 1];
            if (left != '_' and right == '_') return Position.init(lineNumber, column);
            if (left != '-' and right == '-') return Position.init(lineNumber, column);
            if ((isLowerAsciiLetter(left) or isAsciiDigit(left)) and isUpperAsciiLetter(right)) return Position.init(lineNumber, column);
            if (isUpperAsciiLetter(left) and isUpperAsciiLetter(right) and column + 1 < maxColumn) {
                const rightRight = lineContent[column];
                if (isLowerAsciiLetter(rightRight) or isAsciiDigit(rightRight)) return Position.init(lineNumber, column);
            }
        }
        return Position.init(lineNumber, maxColumn);
    }
};

fn isLowerAsciiLetter(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}
fn isUpperAsciiLetter(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}
fn isAsciiDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

const WordTestModel = struct {
    lines: []const []const u8,

    fn getLineCount(context: *anyopaque) usize {
        const self: *WordTestModel = @ptrCast(@alignCast(context));
        return self.lines.len;
    }
    fn getLineContent(context: *anyopaque, lineNumber: usize) []const u8 {
        const self: *WordTestModel = @ptrCast(@alignCast(context));
        return self.lines[lineNumber - 1];
    }
    fn getLineMinColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn getLineMaxColumn(context: *anyopaque, lineNumber: usize) usize {
        return getLineContent(context, lineNumber).len + 1;
    }
    fn getLineFirstNonWhitespaceColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn getLineLastNonWhitespaceColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn normalizePosition(_: *anyopaque, position: Position, _: @import("../model.zig").PositionAffinity) Position {
        return position;
    }
    fn getLineIndentColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn interface(self: *WordTestModel) ICursorSimpleModel {
        return .{
            .context = self,
            .getLineCount = getLineCount,
            .getLineContent = getLineContent,
            .getLineMinColumn = getLineMinColumn,
            .getLineMaxColumn = getLineMaxColumn,
            .getLineFirstNonWhitespaceColumn = getLineFirstNonWhitespaceColumn,
            .getLineLastNonWhitespaceColumn = getLineLastNonWhitespaceColumn,
            .normalizePosition = normalizePosition,
            .getLineIndentColumn = getLineIndentColumn,
        };
    }
};

test "cursor word operations: left and right navigation" {
    const allocator = std.testing.allocator;
    var separators = try WordCharacterClassifier.init(allocator, ",.;");
    defer separators.deinit();
    const lines = [_][]const u8{"foo bar"};
    var test_model = WordTestModel{ .lines = &lines };
    const model = test_model.interface();

    const left_start = WordOperations.moveWordLeft(&separators, model, Position.init(1, 8), .WordStart, false);
    try std.testing.expectEqual(@as(usize, 5), left_start.column);

    const left_end = WordOperations.moveWordLeft(&separators, model, Position.init(1, 8), .WordEnd, false);
    try std.testing.expectEqual(@as(usize, 4), left_end.column);

    const right_start = WordOperations.moveWordRight(&separators, model, Position.init(1, 1), .WordStart);
    try std.testing.expectEqual(@as(usize, 5), right_start.column);

    const right_end = WordOperations.moveWordRight(&separators, model, Position.init(1, 1), .WordEnd);
    try std.testing.expectEqual(@as(usize, 4), right_end.column);
}

test "cursor word operations: word parts" {
    const lines = [_][]const u8{"fooBar"};
    var test_model = WordTestModel{ .lines = &lines };
    const model = test_model.interface();

    const right = WordOperations.moveWordPartRight(model, Position.init(1, 1));
    try std.testing.expectEqual(@as(usize, 4), right.column);

    const left = WordOperations.moveWordPartLeft(model, Position.init(1, 7));
    try std.testing.expectEqual(@as(usize, 4), left.column);
}

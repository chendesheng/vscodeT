const std = @import("std");
const WordCharacterClassifier = @import("../core/wordCharacterClassifier.zig").WordCharacterClassifier;
const WordCharacterClass = @import("../core/wordCharacterClassifier.zig").WordCharacterClass;
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const Selection = @import("../core/selection.zig").Selection;
const cursorCommon = @import("../cursorCommon.zig");
const ICursorSimpleModel = cursorCommon.ICursorSimpleModel;
const EditorAutoClosingEditStrategy = @import("../config/editorOptions.zig").EditorAutoClosingEditStrategy;
const StandardAutoClosingPairConditional = @import("../languages/languageConfiguration.zig").StandardAutoClosingPairConditional;

pub const DeleteWordContext = struct {
    wordSeparators: *const WordCharacterClassifier,
    model: ICursorSimpleModel,
    selection: Selection,
    whitespaceHeuristics: bool = false,
    autoClosingDelete: EditorAutoClosingEditStrategy = .never,
    autoClosingPairs: []const StandardAutoClosingPairConditional = &.{},
};

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

    fn charAtIsWhitespace(str: []const u8, index: usize) bool {
        const ch = str[index];
        return ch == ' ' or ch == '\t';
    }

    fn findFirstNonWhitespaceChar(str: []const u8, start_index: usize) usize {
        var index = start_index;
        while (index < str.len) : (index += 1) {
            const ch = str[index];
            if (ch != ' ' and ch != '\t') return index;
        }
        return str.len;
    }

    fn isAutoClosingPairDelete(ctx: DeleteWordContext) bool {
        if (ctx.autoClosingDelete == .never or !ctx.selection.isEmpty()) return false;
        const position = ctx.selection.getPosition();
        if (position.column <= 1) return false;
        const line = ctx.model.getLineContent(ctx.model.context, position.lineNumber);
        if (position.column > line.len) return false;
        const before = line[position.column - 2];
        const after = line[position.column - 1];
        for (ctx.autoClosingPairs) |pair| {
            if (pair.open.len == 1 and pair.close.len == 1 and pair.open[0] == before and pair.close[0] == after) return true;
        }
        return false;
    }

    fn deleteWordLeftWhitespace(model: ICursorSimpleModel, position: Position) ?Range {
        const lineContent = model.getLineContent(model.context, position.lineNumber);
        const startIndex = position.column -| 2;
        const lastNonWhitespace = @import("../../../base/common/strings.zig").lastNonWhitespaceIndex(lineContent) orelse 0;
        if (lastNonWhitespace < startIndex) {
            return Range.init(position.lineNumber, lastNonWhitespace + 2, position.lineNumber, position.column);
        }
        return null;
    }

    fn deleteWordRightWhitespace(model: ICursorSimpleModel, position: Position) ?Range {
        const lineContent = model.getLineContent(model.context, position.lineNumber);
        const startIndex = position.column -| 1;
        const firstNonWhitespace = findFirstNonWhitespaceChar(lineContent, startIndex);
        if (startIndex < firstNonWhitespace) {
            return Range.init(position.lineNumber, position.column, position.lineNumber, firstNonWhitespace + 1);
        }
        return null;
    }

    fn selectionRange(selection: Selection) Range {
        return Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
    }

    pub fn deleteWordLeft(ctx: DeleteWordContext, wordNavigationType: WordNavigationType) ?Range {
        const selection = ctx.selection;
        if (!selection.isEmpty()) return selectionRange(selection);

        if (isAutoClosingPairDelete(ctx)) {
            const position = selection.getPosition();
            return Range.init(position.lineNumber, position.column - 1, position.lineNumber, position.column + 1);
        }

        const position = selection.getPosition();
        var lineNumber = position.lineNumber;
        var column = position.column;

        if (lineNumber == 1 and column == 1) return null;

        if (ctx.whitespaceHeuristics) {
            if (deleteWordLeftWhitespace(ctx.model, position)) |range| return range;
        }

        const separators = ctx.wordSeparators;
        const model = ctx.model;
        var prevWord = findPreviousWordOnLine(separators, model, position);
        if (wordNavigationType == .WordStart) {
            if (prevWord) |word| {
                column = word.start + 1;
            } else if (column > 1) {
                column = 1;
            } else {
                lineNumber -= 1;
                column = model.getLineMaxColumn(model.context, lineNumber);
            }
        } else {
            if (prevWord != null and column <= prevWord.?.end + 1) {
                prevWord = findPreviousWordOnLine(separators, model, Position.init(lineNumber, prevWord.?.start + 1));
            }
            if (prevWord) |word| {
                column = word.end + 1;
            } else if (column > 1) {
                column = 1;
            } else {
                lineNumber -= 1;
                column = model.getLineMaxColumn(model.context, lineNumber);
            }
        }
        return Range.init(lineNumber, column, position.lineNumber, position.column);
    }

    pub fn deleteWordRight(ctx: DeleteWordContext, wordNavigationType: WordNavigationType) ?Range {
        const selection = ctx.selection;
        if (!selection.isEmpty()) return selectionRange(selection);

        const position = selection.getPosition();
        var lineNumber = position.lineNumber;
        var column = position.column;
        const lineCount = ctx.model.getLineCount(ctx.model.context);
        const maxColumn = ctx.model.getLineMaxColumn(ctx.model.context, lineNumber);
        if (lineNumber == lineCount and column == maxColumn) return null;

        if (ctx.whitespaceHeuristics) {
            if (deleteWordRightWhitespace(ctx.model, position)) |range| return range;
        }

        var nextWord = findNextWordOnLine(ctx.wordSeparators, ctx.model, position);
        if (wordNavigationType == .WordEnd) {
            if (nextWord) |word| {
                column = word.end + 1;
            } else if (column < maxColumn or lineNumber == lineCount) {
                column = maxColumn;
            } else {
                lineNumber += 1;
                nextWord = findNextWordOnLine(ctx.wordSeparators, ctx.model, Position.init(lineNumber, 1));
                column = if (nextWord) |word| word.start + 1 else ctx.model.getLineMaxColumn(ctx.model.context, lineNumber);
            }
        } else {
            if (nextWord != null and column >= nextWord.?.start + 1) {
                nextWord = findNextWordOnLine(ctx.wordSeparators, ctx.model, Position.init(lineNumber, nextWord.?.end + 1));
            }
            if (nextWord) |word| {
                column = word.start + 1;
            } else if (column < maxColumn or lineNumber == lineCount) {
                column = maxColumn;
            } else {
                lineNumber += 1;
                nextWord = findNextWordOnLine(ctx.wordSeparators, ctx.model, Position.init(lineNumber, 1));
                column = if (nextWord) |word| word.start + 1 else ctx.model.getLineMaxColumn(ctx.model.context, lineNumber);
            }
        }
        return Range.init(lineNumber, column, position.lineNumber, position.column);
    }

    fn deleteInsideWordWhitespace(model: ICursorSimpleModel, position: Position) ?Range {
        const lineContent = model.getLineContent(model.context, position.lineNumber);
        if (lineContent.len == 0) return null;
        var leftIndex = position.column -| 2;
        if (!charAtIsWhitespace(lineContent, leftIndex)) return null;
        var rightIndex = @min(position.column - 1, lineContent.len - 1);
        if (!charAtIsWhitespace(lineContent, rightIndex)) return null;
        while (leftIndex > 0 and charAtIsWhitespace(lineContent, leftIndex - 1)) leftIndex -= 1;
        while (rightIndex + 1 < lineContent.len and charAtIsWhitespace(lineContent, rightIndex + 1)) rightIndex += 1;
        return Range.init(position.lineNumber, leftIndex + 1, position.lineNumber, rightIndex + 2);
    }

    fn deleteInsideWordDetermineRange(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, position: Position, onlyWord: bool) Range {
        const lineContent = model.getLineContent(model.context, position.lineNumber);
        const lineLength = lineContent.len;
        if (lineLength == 0) {
            if (position.lineNumber > 1) return Range.init(position.lineNumber - 1, model.getLineMaxColumn(model.context, position.lineNumber - 1), position.lineNumber, 1);
            if (position.lineNumber < model.getLineCount(model.context)) return Range.init(position.lineNumber, 1, position.lineNumber + 1, 1);
            return Range.init(position.lineNumber, 1, position.lineNumber, 1);
        }

        const touchesWord = struct {
            fn check(word: IFindWordResult, column: usize) bool {
                return word.start + 1 <= column and column <= word.end + 1;
            }
        }.check;
        const createRange = struct {
            fn call(column: usize, start_column: usize, end_column: usize) Range {
                return Range.init(0, @min(start_column, column), 0, @max(end_column, column));
            }
        }.call;

        const deleteWordAndAdjacentWhitespace = struct {
            fn call(word: IFindWordResult, col: usize, line: []const u8, only_word: bool) Range {
                var startColumn = word.start + 1;
                var endColumn = word.end + 1;
                if (only_word) {
                    return Range.init(0, @min(startColumn, col), 0, @max(endColumn, col));
                }
                var expandedToTheRight = false;
                while (endColumn - 1 < line.len and charAtIsWhitespace(line, endColumn - 1)) {
                    expandedToTheRight = true;
                    endColumn += 1;
                }
                if (!expandedToTheRight) {
                    while (startColumn > 1 and charAtIsWhitespace(line, startColumn - 2)) startColumn -= 1;
                }
                return Range.init(0, @min(startColumn, col), 0, @max(endColumn, col));
            }
        }.call;

        const prevWord = findPreviousWordOnLine(wordSeparators, model, position);
        if (prevWord != null and touchesWord(prevWord.?, position.column)) {
            return deleteWordAndAdjacentWhitespace(prevWord.?, position.column, lineContent, onlyWord);
        }
        const nextWord = findNextWordOnLine(wordSeparators, model, position);
        if (nextWord != null and touchesWord(nextWord.?, position.column)) {
            return deleteWordAndAdjacentWhitespace(nextWord.?, position.column, lineContent, onlyWord);
        }
        if (prevWord != null and nextWord != null) {
            return createRange(position.column, prevWord.?.end + 1, nextWord.?.start + 1);
        }
        if (prevWord) |word| return createRange(position.column, word.start + 1, word.end + 1);
        if (nextWord) |word| return createRange(position.column, word.start + 1, word.end + 1);
        return createRange(position.column, 1, lineLength + 1);
    }

    pub fn deleteInsideWord(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, selection: Selection, onlyWord: bool) Range {
        if (!selection.isEmpty()) return selectionRange(selection);
        const position = selection.getPosition();
        if (deleteInsideWordWhitespace(model, position)) |range| return range;
        var range = deleteInsideWordDetermineRange(wordSeparators, model, position, onlyWord);
        range.startLineNumber = position.lineNumber;
        range.endLineNumber = position.lineNumber;
        return range;
    }

    pub fn _deleteWordPartLeft(model: ICursorSimpleModel, selection: Selection) Range {
        if (!selection.isEmpty()) return selectionRange(selection);
        const pos = selection.getPosition();
        const to = WordOperations.moveWordPartLeft(model, pos);
        return Range.init(pos.lineNumber, pos.column, to.lineNumber, to.column);
    }

    pub fn _deleteWordPartRight(model: ICursorSimpleModel, selection: Selection) Range {
        if (!selection.isEmpty()) return selectionRange(selection);
        const pos = selection.getPosition();
        const to = WordOperations.moveWordPartRight(model, pos);
        return Range.init(pos.lineNumber, pos.column, to.lineNumber, to.column);
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

pub const WordPartOperations = struct {
    fn sortRangesByEnds(items: *[3]?Range) void {
        std.mem.sort(?Range, items, {}, struct {
            fn lessThan(_: void, a: ?Range, b: ?Range) bool {
                if (a == null) return false;
                if (b == null) return true;
                return Range.compareRangesUsingEnds(&a.?, &b.?) < 0;
            }
        }.lessThan);
    }

    fn sortRangesByStarts(items: *[3]?Range) void {
        std.mem.sort(?Range, items, {}, struct {
            fn lessThan(_: void, a: ?Range, b: ?Range) bool {
                if (a == null) return false;
                if (b == null) return true;
                return Range.compareRangesUsingStarts(&a.?, &b.?) < 0;
            }
        }.lessThan);
    }

    pub fn deleteWordPartLeft(ctx: DeleteWordContext) Range {
        var candidates = [3]?Range{
            WordOperations.deleteWordLeft(ctx, .WordStart),
            WordOperations.deleteWordLeft(ctx, .WordEnd),
            WordOperations._deleteWordPartLeft(ctx.model, ctx.selection),
        };
        sortRangesByEnds(&candidates);
        return candidates[2].?;
    }

    pub fn deleteWordPartRight(ctx: DeleteWordContext) Range {
        var candidates = [3]?Range{
            WordOperations.deleteWordRight(ctx, .WordStart),
            WordOperations.deleteWordRight(ctx, .WordEnd),
            WordOperations._deleteWordPartRight(ctx.model, ctx.selection),
        };
        sortRangesByStarts(&candidates);
        return candidates[0].?;
    }

    pub fn moveWordPartLeft(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, position: Position, has_multicursor: bool) Position {
        var candidates = [3]Position{
            WordOperations.moveWordLeft(wordSeparators, model, position, .WordStart, has_multicursor),
            WordOperations.moveWordLeft(wordSeparators, model, position, .WordEnd, has_multicursor),
            WordOperations.moveWordPartLeft(model, position),
        };
        std.mem.sort(Position, &candidates, {}, struct {
            fn lessThan(_: void, a: Position, b: Position) bool {
                return Position.compare(a, b) < 0;
            }
        }.lessThan);
        return candidates[2];
    }

    pub fn moveWordPartRight(wordSeparators: *const WordCharacterClassifier, model: ICursorSimpleModel, position: Position) Position {
        var candidates = [3]Position{
            WordOperations.moveWordRight(wordSeparators, model, position, .WordStart),
            WordOperations.moveWordRight(wordSeparators, model, position, .WordEnd),
            WordOperations.moveWordPartRight(model, position),
        };
        std.mem.sort(Position, &candidates, {}, struct {
            fn lessThan(_: void, a: Position, b: Position) bool {
                return Position.compare(a, b) < 0;
            }
        }.lessThan);
        return candidates[0];
    }
};

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

const std = @import("std");
const Position = @import("../basics/position.zig").Position;
const Range = @import("../basics/range.zig").Range;
const PositionAffinity = @import("../model.zig").PositionAffinity;
const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;
const AtomicTabMoveOperations = @import("cursorAtomicMoveOperations.zig").AtomicTabMoveOperations;
const Direction = @import("cursorAtomicMoveOperations.zig").Direction;
const cursorCommon = @import("cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const ICursorSimpleModel = cursorCommon.ICursorSimpleModel;
const SingleCursorState = cursorCommon.SingleCursorState;
const SelectionStartKind = cursorCommon.SelectionStartKind;

const MAX_SAFE_SMALL_INTEGER: isize = 1 << 30;

pub const CursorPosition = struct {
    lineNumber: usize,
    column: usize,
    leftoverVisibleColumns: isize,
};

pub const MoveOperations = struct {
    pub fn leftPosition(model: ICursorSimpleModel, position: Position) Position {
        if (position.column > model.getLineMinColumn(model.context, position.lineNumber)) {
            const line = model.getLineContent(model.context, position.lineNumber);
            return Position.init(position.lineNumber, position.column - prevCharLength(line, position.column - 1));
        } else if (position.lineNumber > 1) {
            const newLineNumber = position.lineNumber - 1;
            return Position.init(newLineNumber, model.getLineMaxColumn(model.context, newLineNumber));
        }
        return position;
    }

    fn leftPositionAtomicSoftTabs(model: ICursorSimpleModel, position: Position, tabSize: usize) Position {
        if (position.column <= model.getLineIndentColumn(model.context, position.lineNumber)) {
            const minColumn = model.getLineMinColumn(model.context, position.lineNumber);
            const lineContent = model.getLineContent(model.context, position.lineNumber);
            const newPosition = AtomicTabMoveOperations.atomicPosition(lineContent, position.column - 1, tabSize, .Left);
            if (newPosition != -1 and @as(usize, @intCast(newPosition)) + 1 >= minColumn) {
                return Position.init(position.lineNumber, @intCast(newPosition + 1));
            }
        }
        return leftPosition(model, position);
    }

    fn left(config: *const CursorConfiguration, model: ICursorSimpleModel, position: Position) CursorPosition {
        const pos = if (config.stickyTabStops)
            leftPositionAtomicSoftTabs(model, position, config.tabSize)
        else
            leftPosition(model, position);
        return .{ .lineNumber = pos.lineNumber, .column = pos.column, .leftoverVisibleColumns = 0 };
    }

    pub fn moveLeft(
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        cursor: SingleCursorState,
        inSelectionMode: bool,
        noOfColumns: usize,
    ) SingleCursorState {
        var lineNumber: usize = undefined;
        var column: usize = undefined;

        if (cursor.hasSelection() and !inSelectionMode) {
            lineNumber = cursor.selection.startLineNumber;
            column = cursor.selection.startColumn;
        } else {
            const delta = -@as(isize, @intCast(noOfColumns - 1));
            const pos = cursor.position.delta(null, delta);
            const normalizedPos = model.normalizePosition(model.context, clipPositionColumn(model, pos), .Left);
            const p = left(config, model, normalizedPos);
            lineNumber = p.lineNumber;
            column = p.column;
        }

        return cursor.move(inSelectionMode, lineNumber, column, 0);
    }

    fn clipPositionColumn(model: ICursorSimpleModel, position: Position) Position {
        return Position.init(
            position.lineNumber,
            clipRange(position.column, model.getLineMinColumn(model.context, position.lineNumber), model.getLineMaxColumn(model.context, position.lineNumber)),
        );
    }

    fn clipRange(value: usize, min: usize, max: usize) usize {
        if (value < min) return min;
        if (value > max) return max;
        return value;
    }

    pub fn rightPosition(model: ICursorSimpleModel, lineNumber: usize, column: usize) Position {
        var newLineNumber = lineNumber;
        var newColumn = column;
        if (newColumn < model.getLineMaxColumn(model.context, newLineNumber)) {
            const line = model.getLineContent(model.context, newLineNumber);
            newColumn += nextCharLength(line, newColumn - 1);
        } else if (newLineNumber < model.getLineCount(model.context)) {
            newLineNumber += 1;
            newColumn = model.getLineMinColumn(model.context, newLineNumber);
        }
        return model.normalizePosition(model.context, Position.init(newLineNumber, newColumn), .Right);
    }

    pub fn rightPositionAtomicSoftTabs(model: ICursorSimpleModel, lineNumber: usize, column: usize, tabSize: usize) Position {
        if (column < model.getLineIndentColumn(model.context, lineNumber)) {
            const lineContent = model.getLineContent(model.context, lineNumber);
            const newPosition = AtomicTabMoveOperations.atomicPosition(lineContent, column - 1, tabSize, .Right);
            if (newPosition != -1) return Position.init(lineNumber, @intCast(newPosition + 1));
        }
        return rightPosition(model, lineNumber, column);
    }

    fn right(config: *const CursorConfiguration, model: ICursorSimpleModel, position: Position) CursorPosition {
        const pos = if (config.stickyTabStops)
            rightPositionAtomicSoftTabs(model, position.lineNumber, position.column, config.tabSize)
        else
            rightPosition(model, position.lineNumber, position.column);
        return .{ .lineNumber = pos.lineNumber, .column = pos.column, .leftoverVisibleColumns = 0 };
    }

    pub fn moveRight(
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        cursor: SingleCursorState,
        inSelectionMode: bool,
        noOfColumns: usize,
    ) SingleCursorState {
        var lineNumber: usize = undefined;
        var column: usize = undefined;
        if (cursor.hasSelection() and !inSelectionMode) {
            lineNumber = cursor.selection.endLineNumber;
            column = cursor.selection.endColumn;
        } else {
            const pos = cursor.position.delta(null, @intCast(noOfColumns - 1));
            const normalizedPos = model.normalizePosition(model.context, clipPositionColumn(model, pos), .Right);
            const r = right(config, model, normalizedPos);
            lineNumber = r.lineNumber;
            column = r.column;
        }
        return cursor.move(inSelectionMode, lineNumber, column, 0);
    }

    pub fn vertical(
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        lineNumber: usize,
        column: usize,
        leftoverVisibleColumns: isize,
        newLineNumber: isize,
        allowMoveOnEdgeLine: bool,
        normalizationAffinity: ?PositionAffinity,
    ) CursorPosition {
        const currentVisibleColumn = CursorColumns.visibleColumnFromColumn(
            model.getLineContent(model.context, lineNumber),
            column,
            config.tabSize,
        ) + if (leftoverVisibleColumns > 0) @as(usize, @intCast(leftoverVisibleColumns)) else 0;
        const lineCount = model.getLineCount(model.context);
        const wasOnFirstPosition = lineNumber == 1 and column == 1;
        const wasOnLastPosition = lineNumber == lineCount and column == model.getLineMaxColumn(model.context, lineNumber);
        const wasAtEdgePosition = if (newLineNumber < @as(isize, @intCast(lineNumber))) wasOnFirstPosition else wasOnLastPosition;

        var new_line = newLineNumber;
        var new_column = column;
        if (new_line < 1) {
            new_line = 1;
            new_column = if (allowMoveOnEdgeLine)
                model.getLineMinColumn(model.context, 1)
            else
                @min(model.getLineMaxColumn(model.context, 1), column);
        } else if (new_line > @as(isize, @intCast(lineCount))) {
            new_line = @intCast(lineCount);
            new_column = if (allowMoveOnEdgeLine)
                model.getLineMaxColumn(model.context, lineCount)
            else
                @min(model.getLineMaxColumn(model.context, lineCount), column);
        } else {
            new_column = config.columnFromVisibleColumn(model, @intCast(new_line), currentVisibleColumn);
        }

        var new_leftover: isize = 0;
        if (!wasAtEdgePosition) {
            const newVisible = CursorColumns.visibleColumnFromColumn(
                model.getLineContent(model.context, @intCast(new_line)),
                new_column,
                config.tabSize,
            );
            new_leftover = @as(isize, @intCast(currentVisibleColumn)) - @as(isize, @intCast(newVisible));
        }

        if (normalizationAffinity) |affinity| {
            const normalized = model.normalizePosition(model.context, Position.init(@intCast(new_line), new_column), affinity);
            new_leftover += @as(isize, @intCast(new_column)) - @as(isize, @intCast(normalized.column));
            new_line = @intCast(normalized.lineNumber);
            new_column = normalized.column;
        }

        return .{ .lineNumber = @intCast(new_line), .column = new_column, .leftoverVisibleColumns = new_leftover };
    }

    pub fn down(config: *const CursorConfiguration, model: ICursorSimpleModel, lineNumber: usize, column: usize, leftoverVisibleColumns: isize, count: usize, allowMoveOnLastLine: bool) CursorPosition {
        return vertical(config, model, lineNumber, column, leftoverVisibleColumns, @as(isize, @intCast(lineNumber + count)), allowMoveOnLastLine, .RightOfInjectedText);
    }

    pub fn moveDown(config: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool, linesCount: usize) SingleCursorState {
        var lineNumber = cursor.position.lineNumber;
        var column = cursor.position.column;
        if (cursor.hasSelection() and !inSelectionMode) {
            lineNumber = cursor.selection.endLineNumber;
            column = cursor.selection.endColumn;
        }

        var result: CursorPosition = undefined;
        var i: usize = 0;
        while (true) {
            result = down(config, model, lineNumber + i, column, cursor.leftoverVisibleColumns, linesCount, true);
            const np = model.normalizePosition(model.context, Position.init(result.lineNumber, result.column), .None);
            if (np.lineNumber > lineNumber) break;
            i += 1;
            if (!(i < 10 and lineNumber + i < model.getLineCount(model.context))) break;
        }
        return cursor.move(inSelectionMode, result.lineNumber, result.column, result.leftoverVisibleColumns);
    }

    pub fn translateDown(config: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState) SingleCursorState {
        const selection = cursor.selection;
        const selectionStart = down(config, model, selection.selectionStartLineNumber, selection.selectionStartColumn, cursor.selectionStartLeftoverVisibleColumns, 1, false);
        const position = down(config, model, selection.positionLineNumber, selection.positionColumn, cursor.leftoverVisibleColumns, 1, false);
        return SingleCursorState.init(
            Range.init(selectionStart.lineNumber, selectionStart.column, selectionStart.lineNumber, selectionStart.column),
            .Simple,
            selectionStart.leftoverVisibleColumns,
            Position.init(position.lineNumber, position.column),
            position.leftoverVisibleColumns,
        );
    }

    pub fn up(config: *const CursorConfiguration, model: ICursorSimpleModel, lineNumber: usize, column: usize, leftoverVisibleColumns: isize, count: usize, allowMoveOnFirstLine: bool) CursorPosition {
        return vertical(config, model, lineNumber, column, leftoverVisibleColumns, @as(isize, @intCast(lineNumber)) - @as(isize, @intCast(count)), allowMoveOnFirstLine, .LeftOfInjectedText);
    }

    pub fn moveUp(config: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool, linesCount: usize) SingleCursorState {
        var lineNumber = cursor.position.lineNumber;
        var column = cursor.position.column;
        if (cursor.hasSelection() and !inSelectionMode) {
            lineNumber = cursor.selection.startLineNumber;
            column = cursor.selection.startColumn;
        }
        const result = up(config, model, lineNumber, column, cursor.leftoverVisibleColumns, linesCount, true);
        return cursor.move(inSelectionMode, result.lineNumber, result.column, result.leftoverVisibleColumns);
    }

    pub fn translateUp(config: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState) SingleCursorState {
        const selection = cursor.selection;
        const selectionStart = up(config, model, selection.selectionStartLineNumber, selection.selectionStartColumn, cursor.selectionStartLeftoverVisibleColumns, 1, false);
        const position = up(config, model, selection.positionLineNumber, selection.positionColumn, cursor.leftoverVisibleColumns, 1, false);
        return SingleCursorState.init(
            Range.init(selectionStart.lineNumber, selectionStart.column, selectionStart.lineNumber, selectionStart.column),
            .Simple,
            selectionStart.leftoverVisibleColumns,
            Position.init(position.lineNumber, position.column),
            position.leftoverVisibleColumns,
        );
    }

    fn isBlankLine(model: ICursorSimpleModel, lineNumber: usize) bool {
        return model.getLineFirstNonWhitespaceColumn(model.context, lineNumber) == 0;
    }

    pub fn moveToPrevBlankLine(_: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool) SingleCursorState {
        var lineNumber = cursor.position.lineNumber;
        while (lineNumber > 1 and isBlankLine(model, lineNumber)) lineNumber -= 1;
        while (lineNumber > 1 and !isBlankLine(model, lineNumber)) lineNumber -= 1;
        return cursor.move(inSelectionMode, lineNumber, model.getLineMinColumn(model.context, lineNumber), 0);
    }

    pub fn moveToNextBlankLine(_: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool) SingleCursorState {
        const lineCount = model.getLineCount(model.context);
        var lineNumber = cursor.position.lineNumber;
        while (lineNumber < lineCount and isBlankLine(model, lineNumber)) lineNumber += 1;
        while (lineNumber < lineCount and !isBlankLine(model, lineNumber)) lineNumber += 1;
        return cursor.move(inSelectionMode, lineNumber, model.getLineMinColumn(model.context, lineNumber), 0);
    }

    pub fn moveToBeginningOfLine(_: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool) SingleCursorState {
        const lineNumber = cursor.position.lineNumber;
        const minColumn = model.getLineMinColumn(model.context, lineNumber);
        const firstNonBlankColumn = model.getLineFirstNonWhitespaceColumn(model.context, lineNumber);
        const effectiveFirst = if (firstNonBlankColumn == 0) minColumn else firstNonBlankColumn;
        const column = if (cursor.position.column == effectiveFirst) minColumn else effectiveFirst;
        return cursor.move(inSelectionMode, lineNumber, column, 0);
    }

    pub fn moveToEndOfLine(_: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool, sticky: bool) SingleCursorState {
        const maxColumn = model.getLineMaxColumn(model.context, cursor.position.lineNumber);
        return cursor.move(inSelectionMode, cursor.position.lineNumber, maxColumn, if (sticky) MAX_SAFE_SMALL_INTEGER - @as(isize, @intCast(maxColumn)) else 0);
    }

    pub fn moveToBeginningOfBuffer(_: *const CursorConfiguration, _: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool) SingleCursorState {
        return cursor.move(inSelectionMode, 1, 1, 0);
    }

    pub fn moveToEndOfBuffer(_: *const CursorConfiguration, model: ICursorSimpleModel, cursor: SingleCursorState, inSelectionMode: bool) SingleCursorState {
        const lastLineNumber = model.getLineCount(model.context);
        return cursor.move(inSelectionMode, lastLineNumber, model.getLineMaxColumn(model.context, lastLineNumber), 0);
    }
};

fn prevCharLength(text: []const u8, index: usize) usize {
    if (index == 0) return 1;
    var start = index - 1;
    while (start > 0 and (text[start] & 0xC0) == 0x80) start -= 1;
    return index - start;
}

fn nextCharLength(text: []const u8, index: usize) usize {
    if (index >= text.len) return 1;
    const len = std.unicode.utf8ByteSequenceLength(text[index]) catch return 1;
    return if (index + len <= text.len) len else 1;
}

const MoveTestModel = struct {
    lines: []const []const u8,

    fn getLineCount(context: *anyopaque) usize {
        const self: *MoveTestModel = @ptrCast(@alignCast(context));
        return self.lines.len;
    }
    fn getLineContent(context: *anyopaque, lineNumber: usize) []const u8 {
        const self: *MoveTestModel = @ptrCast(@alignCast(context));
        return self.lines[lineNumber - 1];
    }
    fn getLineMinColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn getLineMaxColumn(context: *anyopaque, lineNumber: usize) usize {
        return getLineContent(context, lineNumber).len + 1;
    }
    fn getLineFirstNonWhitespaceColumn(context: *anyopaque, lineNumber: usize) usize {
        const line = getLineContent(context, lineNumber);
        for (line, 0..) |ch, i| {
            if (ch != ' ' and ch != '\t' and ch != '\r') return i + 1;
        }
        return 0;
    }
    fn getLineLastNonWhitespaceColumn(context: *anyopaque, lineNumber: usize) usize {
        const line = getLineContent(context, lineNumber);
        var i = line.len;
        while (i > 0) : (i -= 1) {
            const ch = line[i - 1];
            if (ch != ' ' and ch != '\t' and ch != '\r') return i;
        }
        return 0;
    }
    fn normalizePosition(context: *anyopaque, position: Position, _: PositionAffinity) Position {
        const lineCount = getLineCount(context);
        const line = @min(@max(position.lineNumber, 1), lineCount);
        const maxColumn = getLineMaxColumn(context, line);
        return Position.init(line, @min(@max(position.column, 1), maxColumn));
    }
    fn getLineIndentColumn(context: *anyopaque, lineNumber: usize) usize {
        const first = getLineFirstNonWhitespaceColumn(context, lineNumber);
        return if (first == 0) getLineMaxColumn(context, lineNumber) else first;
    }

    fn interface(self: *MoveTestModel) ICursorSimpleModel {
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

test "cursor move: left and right positions" {
    const lines = [_][]const u8{ "abc", "defg", "" };
    var test_model = MoveTestModel{ .lines = &lines };
    const model = test_model.interface();

    const left_from_start = MoveOperations.leftPosition(model, Position.init(2, 1));
    try std.testing.expectEqual(@as(usize, 1), left_from_start.lineNumber);
    try std.testing.expectEqual(@as(usize, 4), left_from_start.column);

    const left = MoveOperations.leftPosition(model, Position.init(2, 3));
    try std.testing.expectEqual(@as(usize, 2), left.column);

    const right_wrap = MoveOperations.rightPosition(model, 2, 5);
    try std.testing.expectEqual(@as(usize, 3), right_wrap.lineNumber);
    try std.testing.expectEqual(@as(usize, 1), right_wrap.column);

    const right = MoveOperations.rightPosition(model, 2, 1);
    try std.testing.expectEqual(@as(usize, 2), right.column);
}

test "cursor move: moveLeft, moveRight, vertical, and line boundaries" {
    const lines = [_][]const u8{ "abc", "defg", "" };
    var test_model = MoveTestModel{ .lines = &lines };
    const model = test_model.interface();
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };

    const cursor = SingleCursorState.init(Range.init(2, 3, 2, 3), .Simple, 0, Position.init(2, 3), 0);

    const left = MoveOperations.moveLeft(&config, model, cursor, false, 1);
    try std.testing.expectEqual(@as(usize, 2), left.position.column);

    const right = MoveOperations.moveRight(&config, model, cursor, false, 1);
    try std.testing.expectEqual(@as(usize, 4), right.position.column);

    const vertical = MoveOperations.vertical(&config, model, 1, 2, 0, 2, false, null);
    try std.testing.expectEqual(@as(usize, 2), vertical.lineNumber);
    try std.testing.expectEqual(@as(usize, 2), vertical.column);
    try std.testing.expectEqual(@as(isize, 0), vertical.leftoverVisibleColumns);

    const down = MoveOperations.moveDown(&config, model, cursor, false, 1);
    try std.testing.expectEqual(@as(usize, 3), down.position.lineNumber);

    const up = MoveOperations.moveUp(&config, model, cursor, false, 1);
    try std.testing.expectEqual(@as(usize, 1), up.position.lineNumber);

    const end = MoveOperations.moveToEndOfLine(&config, model, cursor, false, true);
    try std.testing.expectEqual(@as(usize, 5), end.position.column);
    try std.testing.expect(end.leftoverVisibleColumns > 0);
}

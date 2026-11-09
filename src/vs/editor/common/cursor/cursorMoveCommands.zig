const std = @import("std");
const Allocator = std.mem.Allocator;
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const cursorCommon = @import("../cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const CursorState = cursorCommon.CursorState;
const ICursorSimpleModel = cursorCommon.ICursorSimpleModel;
const PartialCursorState = cursorCommon.PartialCursorState;
const SingleCursorState = cursorCommon.SingleCursorState;
const MoveOperations = @import("./cursorMoveOperations.zig").MoveOperations;
const WordOperations = @import("./cursorWordOperations.zig").WordOperations;
const WordNavigationType = @import("./cursorWordOperations.zig").WordNavigationType;
const WordCharacterClassifier = @import("../core/wordCharacterClassifier.zig").WordCharacterClassifier;

pub const Direction = enum {
    left,
    right,
    up,
    down,
    prev_blank_line,
    next_blank_line,
    wrapped_line_start,
    wrapped_line_first_non_whitespace_character,
    wrapped_line_column_center,
    wrapped_line_end,
    wrapped_line_last_non_whitespace_character,
};

pub const Unit = enum {
    none,
    line,
    wrapped_line,
    character,
    half_line,
    folded_line,
};

pub const WordDirection = enum {
    left,
    right,
};

pub const CursorMoveCommands = struct {
    pub fn expandLineSelection(allocator: Allocator, model: ICursorSimpleModel, cursors: []const CursorState) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len);
        for (cursors, 0..) |cursor, i| {
            const startLineNumber = cursor.modelState.selection.startLineNumber;
            const lineCount = model.getLineCount(model.context);
            var endLineNumber = cursor.modelState.selection.endLineNumber;
            const endColumn = if (endLineNumber == lineCount)
                model.getLineMaxColumn(model.context, lineCount)
            else blk: {
                endLineNumber += 1;
                break :blk 1;
            };

            result[i] = CursorState.fromModelState(SingleCursorState.init(
                Range.init(startLineNumber, 1, startLineNumber, 1),
                .Simple,
                0,
                Position.init(endLineNumber, endColumn),
                0,
            ));
        }
        return result;
    }

    pub fn moveToBeginningOfBuffer(allocator: Allocator, config: *const CursorConfiguration, model: ICursorSimpleModel, cursors: []const CursorState, inSelectionMode: bool) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len);
        for (cursors, 0..) |cursor, i| {
            result[i] = CursorState.fromModelState(MoveOperations.moveToBeginningOfBuffer(config, model, cursor.modelState, inSelectionMode));
        }
        return result;
    }

    pub fn moveToEndOfBuffer(allocator: Allocator, config: *const CursorConfiguration, model: ICursorSimpleModel, cursors: []const CursorState, inSelectionMode: bool) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len);
        for (cursors, 0..) |cursor, i| {
            result[i] = CursorState.fromModelState(MoveOperations.moveToEndOfBuffer(config, model, cursor.modelState, inSelectionMode));
        }
        return result;
    }

    pub fn addCursorDown(allocator: Allocator, config: *const CursorConfiguration, model: ICursorSimpleModel, cursors: []const CursorState) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len * 2);
        for (cursors, 0..) |cursor, i| {
            result[i * 2] = .{ .modelState = cursor.modelState, .viewState = cursor.viewState };
            result[i * 2 + 1] = CursorState.fromModelState(MoveOperations.translateDown(config, model, cursor.modelState));
        }
        return result;
    }

    pub fn addCursorUp(allocator: Allocator, config: *const CursorConfiguration, model: ICursorSimpleModel, cursors: []const CursorState) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len * 2);
        for (cursors, 0..) |cursor, i| {
            result[i * 2] = .{ .modelState = cursor.modelState, .viewState = cursor.viewState };
            result[i * 2 + 1] = CursorState.fromModelState(MoveOperations.translateUp(config, model, cursor.modelState));
        }
        return result;
    }
    pub fn simpleMove(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        view_model: ICursorSimpleModel,
        cursors: []const CursorState,
        direction: Direction,
        in_selection_mode: bool,
        value: usize,
        unit: Unit,
    ) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len);
        errdefer allocator.free(result);

        for (cursors, 0..) |cursor, i| {
            switch (direction) {
                .left => {
                    if (unit == .half_line) {
                        const line_length = view_model.getLineContent(view_model.context, cursor.viewState.position.lineNumber).len;
                        const columns = @max(1, (line_length + 1) / 2);
                        result[i] = CursorState.fromViewState(MoveOperations.moveLeft(config, view_model, cursor.viewState, in_selection_mode, columns));
                    } else {
                        result[i] = CursorState.fromViewState(MoveOperations.moveLeft(config, view_model, cursor.viewState, in_selection_mode, value));
                    }
                },
                .right => {
                    if (unit == .half_line) {
                        const line_length = view_model.getLineContent(view_model.context, cursor.viewState.position.lineNumber).len;
                        const columns = @max(1, (line_length + 1) / 2);
                        result[i] = CursorState.fromViewState(MoveOperations.moveRight(config, view_model, cursor.viewState, in_selection_mode, columns));
                    } else {
                        result[i] = CursorState.fromViewState(MoveOperations.moveRight(config, view_model, cursor.viewState, in_selection_mode, value));
                    }
                },
                .up => {
                    if (unit == .wrapped_line) {
                        result[i] = CursorState.fromViewState(MoveOperations.moveUp(config, view_model, cursor.viewState, in_selection_mode, value));
                    } else {
                        result[i] = CursorState.fromModelState(MoveOperations.moveUp(config, model, cursor.modelState, in_selection_mode, value));
                    }
                },
                .down => {
                    if (unit == .wrapped_line) {
                        result[i] = CursorState.fromViewState(MoveOperations.moveDown(config, view_model, cursor.viewState, in_selection_mode, value));
                    } else {
                        result[i] = CursorState.fromModelState(MoveOperations.moveDown(config, model, cursor.modelState, in_selection_mode, value));
                    }
                },
                .prev_blank_line => {
                    if (unit == .wrapped_line) {
                        result[i] = CursorState.fromViewState(MoveOperations.moveToPrevBlankLine(config, view_model, cursor.viewState, in_selection_mode));
                    } else {
                        result[i] = CursorState.fromModelState(MoveOperations.moveToPrevBlankLine(config, model, cursor.modelState, in_selection_mode));
                    }
                },
                .next_blank_line => {
                    if (unit == .wrapped_line) {
                        result[i] = CursorState.fromViewState(MoveOperations.moveToNextBlankLine(config, view_model, cursor.viewState, in_selection_mode));
                    } else {
                        result[i] = CursorState.fromModelState(MoveOperations.moveToNextBlankLine(config, model, cursor.modelState, in_selection_mode));
                    }
                },
                .wrapped_line_start => {
                    const line = cursor.viewState.position.lineNumber;
                    result[i] = CursorState.fromViewState(cursor.viewState.move(in_selection_mode, line, view_model.getLineMinColumn(view_model.context, line), 0));
                },
                .wrapped_line_first_non_whitespace_character => {
                    const line = cursor.viewState.position.lineNumber;
                    const column = view_model.getLineFirstNonWhitespaceColumn(view_model.context, line);
                    const normalized = if (column == 0) view_model.getLineMinColumn(view_model.context, line) else column;
                    result[i] = CursorState.fromViewState(cursor.viewState.move(in_selection_mode, line, normalized, 0));
                },
                .wrapped_line_column_center => {
                    const line = cursor.viewState.position.lineNumber;
                    const min_column = view_model.getLineMinColumn(view_model.context, line);
                    const max_column = view_model.getLineMaxColumn(view_model.context, line);
                    const column = (min_column + max_column + 1) / 2;
                    result[i] = CursorState.fromViewState(cursor.viewState.move(in_selection_mode, line, column, 0));
                },
                .wrapped_line_end => {
                    const line = cursor.viewState.position.lineNumber;
                    result[i] = CursorState.fromViewState(cursor.viewState.move(in_selection_mode, line, view_model.getLineMaxColumn(view_model.context, line), 0));
                },
                .wrapped_line_last_non_whitespace_character => {
                    const line = cursor.viewState.position.lineNumber;
                    const column = view_model.getLineLastNonWhitespaceColumn(view_model.context, line);
                    const normalized = if (column == 0) view_model.getLineMaxColumn(view_model.context, line) else column;
                    result[i] = CursorState.fromViewState(cursor.viewState.move(in_selection_mode, line, normalized, 0));
                },
            }
        }
        return result;
    }

    pub fn moveToBeginningOfLine(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        view_model: ICursorSimpleModel,
        cursors: []const CursorState,
        in_selection_mode: bool,
    ) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len);
        errdefer allocator.free(result);
        for (cursors, 0..) |cursor, i| {
            const view_column = cursor.viewState.position.column;
            const model_column = cursor.modelState.position.column;
            const is_first_line_of_wrapped = view_column == model_column;
            const view_line = cursor.viewState.position.lineNumber;
            const first_non_blank = view_model.getLineFirstNonWhitespaceColumn(view_model.context, view_line);
            const is_beginning_of_view_line = view_column == first_non_blank;

            if (!is_first_line_of_wrapped and !is_beginning_of_view_line) {
                result[i] = CursorState.fromViewState(MoveOperations.moveToBeginningOfLine(config, view_model, cursor.viewState, in_selection_mode));
            } else {
                result[i] = CursorState.fromModelState(MoveOperations.moveToBeginningOfLine(config, model, cursor.modelState, in_selection_mode));
            }
        }
        return result;
    }

    pub fn moveToEndOfLine(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        view_model: ICursorSimpleModel,
        cursors: []const CursorState,
        in_selection_mode: bool,
        sticky: bool,
    ) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len);
        errdefer allocator.free(result);
        for (cursors, 0..) |cursor, i| {
            const view_position = cursor.viewState.position;
            const view_max = view_model.getLineMaxColumn(view_model.context, view_position.lineNumber);
            const is_end_of_view_line = view_position.column == view_max;
            const model_position = cursor.modelState.position;
            const model_max = model.getLineMaxColumn(model.context, model_position.lineNumber);
            const is_end_of_wrapped_line = (view_max - view_position.column) == (model_max - model_position.column);

            if (is_end_of_view_line or is_end_of_wrapped_line) {
                result[i] = CursorState.fromModelState(MoveOperations.moveToEndOfLine(config, model, cursor.modelState, in_selection_mode, sticky));
            } else {
                result[i] = CursorState.fromViewState(MoveOperations.moveToEndOfLine(config, view_model, cursor.viewState, in_selection_mode, sticky));
            }
        }
        return result;
    }

    pub fn moveWord(
        allocator: Allocator,
        model: ICursorSimpleModel,
        cursors: []const CursorState,
        direction: WordDirection,
        word_separators: *const WordCharacterClassifier,
        in_selection_mode: bool,
        has_multicursor: bool,
    ) ![]PartialCursorState {
        const result = try allocator.alloc(PartialCursorState, cursors.len);
        errdefer allocator.free(result);
        for (cursors, 0..) |cursor, i| {
            const position = switch (direction) {
                .left => WordOperations.moveWordLeft(word_separators, model, cursor.modelState.position, .WordStart, has_multicursor),
                .right => WordOperations.moveWordRight(word_separators, model, cursor.modelState.position, .WordStart),
            };
            result[i] = CursorState.fromModelState(cursor.modelState.move(in_selection_mode, position.lineNumber, position.column, 0));
        }
        return result;
    }

    pub fn selectAll(model: ICursorSimpleModel) PartialCursorState {
        const lineCount = model.getLineCount(model.context);
        const maxColumn = model.getLineMaxColumn(model.context, lineCount);
        return CursorState.fromModelState(SingleCursorState.init(
            Range.init(1, 1, 1, 1),
            .Simple,
            0,
            Position.init(lineCount, maxColumn),
            0,
        ));
    }

    pub fn cancelSelection(cursor: CursorState) PartialCursorState {
        if (!cursor.modelState.hasSelection()) {
            return .{ .modelState = cursor.modelState, .viewState = cursor.viewState };
        }
        const lineNumber = cursor.viewState.position.lineNumber;
        const column = cursor.viewState.position.column;
        return CursorState.fromViewState(SingleCursorState.init(
            Range.init(lineNumber, column, lineNumber, column),
            .Simple,
            0,
            Position.init(lineNumber, column),
            0,
        ));
    }
};

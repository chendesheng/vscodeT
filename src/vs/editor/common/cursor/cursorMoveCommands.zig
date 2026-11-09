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

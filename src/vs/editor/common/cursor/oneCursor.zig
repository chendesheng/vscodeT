const std = @import("std");
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const selection_mod = @import("../core/selection.zig");
const Selection = selection_mod.Selection;
const PositionAffinity = @import("../model.zig").PositionAffinity;
const TrackedRangeStickiness = @import("../model.zig").TrackedRangeStickiness;
const CursorContext = @import("./cursorContext.zig").CursorContext;
const cursorCommon = @import("../cursorCommon.zig");
const CursorState = cursorCommon.CursorState;
const SingleCursorState = cursorCommon.SingleCursorState;

const CursorStateResult = struct {
    modelState: SingleCursorState,
    viewState: SingleCursorState,
};

/// Represents a single cursor.
pub const Cursor = struct {
    modelState: SingleCursorState,
    viewState: SingleCursorState,
    _selTrackedRange: ?u64,
    _trackSelection: bool,

    pub fn init(context: *const CursorContext) !Cursor {
        var cursor = Cursor{
            .modelState = undefined,
            .viewState = undefined,
            ._selTrackedRange = null,
            ._trackSelection = true,
        };
        try cursor._setState(
            context,
            SingleCursorState.init(Range.init(1, 1, 1, 1), .Simple, 0, Position.init(1, 1), 0),
            SingleCursorState.init(Range.init(1, 1, 1, 1), .Simple, 0, Position.init(1, 1), 0),
        );
        return cursor;
    }

    pub fn dispose(self: *Cursor, context: *const CursorContext) void {
        self._removeTrackedRange(context);
    }

    pub fn startTrackingSelection(self: *Cursor, context: *const CursorContext) !void {
        self._trackSelection = true;
        try self._updateTrackedRange(context);
    }

    pub fn stopTrackingSelection(self: *Cursor, context: *const CursorContext) void {
        self._trackSelection = false;
        self._removeTrackedRange(context);
    }

    fn _updateTrackedRange(self: *Cursor, context: *const CursorContext) !void {
        _ = self;
        _ = context;
        // TODO: enable once TextModel's tracked-range decoration IDs are
        // consistently numeric. The underlying decoration implementation is
        // still mid-migration between string and u64 IDs.
    }

    fn _removeTrackedRange(self: *Cursor, context: *const CursorContext) void {
        _ = self;
        _ = context;
    }

    pub fn asCursorState(self: *const Cursor) CursorState {
        return .{ .modelState = self.modelState, .viewState = self.viewState };
    }

    pub fn readSelectionFromMarkers(self: *const Cursor, context: *const CursorContext) !Selection {
        _ = context;
        return self.modelState.selection;
    }

    pub fn ensureValidState(self: *Cursor, context: *const CursorContext) !void {
        try self._setState(context, self.modelState, self.viewState);
    }

    pub fn setState(self: *Cursor, context: *const CursorContext, modelState: ?SingleCursorState, viewState: ?SingleCursorState) !void {
        try self._setState(context, modelState, viewState);
    }

    fn _validatePositionWithCache(viewModel: cursorCommon.ICursorSimpleModel, position: Position, cacheInput: Position, cacheOutput: Position) Position {
        if (position.equals(cacheInput)) return cacheOutput;
        return viewModel.normalizePosition(viewModel.context, position, .None);
    }

    fn _validateViewState(viewModel: cursorCommon.ICursorSimpleModel, viewState: SingleCursorState) SingleCursorState {
        const position = viewState.position;
        const sStartPosition = viewState.selectionStart.getStartPosition();
        const sEndPosition = viewState.selectionStart.getEndPosition();

        const validPosition = viewModel.normalizePosition(viewModel.context, position, .None);
        const validSStartPosition = _validatePositionWithCache(viewModel, sStartPosition, position, validPosition);
        const validSEndPosition = _validatePositionWithCache(viewModel, sEndPosition, sStartPosition, validSStartPosition);

        if (position.equals(validPosition) and sStartPosition.equals(validSStartPosition) and sEndPosition.equals(validSEndPosition)) {
            return viewState;
        }

        return SingleCursorState.init(
            Range.init(validSStartPosition.lineNumber, validSStartPosition.column, validSEndPosition.lineNumber, validSEndPosition.column),
            viewState.selectionStartKind,
            viewState.selectionStartLeftoverVisibleColumns + @as(isize, @intCast(sStartPosition.column)) - @as(isize, @intCast(validSStartPosition.column)),
            validPosition,
            viewState.leftoverVisibleColumns + @as(isize, @intCast(position.column)) - @as(isize, @intCast(validPosition.column)),
        );
    }

    fn _setState(self: *Cursor, context: *const CursorContext, modelState_: ?SingleCursorState, viewState_: ?SingleCursorState) !void {
        var modelState = modelState_;
        var viewState = viewState_;

        if (viewState) |vs| {
            viewState = _validateViewState(context.viewModel, vs);
        }

        if (modelState == null) {
            const vs = viewState orelse return;
            const selectionStart = context.model.validateRange(
                context.coordinatesConverter.convertViewRangeToModelRange(context.coordinatesConverter.context, vs.selectionStart),
            );
            const position = context.model.validatePosition(
                context.coordinatesConverter.convertViewPositionToModelPosition(context.coordinatesConverter.context, vs.position),
            );
            modelState = SingleCursorState.init(selectionStart, vs.selectionStartKind, vs.selectionStartLeftoverVisibleColumns, position, vs.leftoverVisibleColumns);
        } else {
            const ms = modelState.?;
            const selectionStart = context.model.validateRange(ms.selectionStart);
            const startLeftover: isize = if (rangesEqual(ms.selectionStart, selectionStart)) ms.selectionStartLeftoverVisibleColumns else 0;
            const position = context.model.validatePosition(ms.position);
            const leftover: isize = if (ms.position.equals(position)) ms.leftoverVisibleColumns else 0;
            modelState = SingleCursorState.init(selectionStart, ms.selectionStartKind, startLeftover, position, leftover);
        }

        const ms = modelState.?;
        if (viewState == null) {
            const viewSelectionStart1 = context.coordinatesConverter.convertModelPositionToViewPosition(
                context.coordinatesConverter.context,
                Position.init(ms.selectionStart.startLineNumber, ms.selectionStart.startColumn),
                .None,
                false,
                false,
            );
            const viewSelectionStart2 = context.coordinatesConverter.convertModelPositionToViewPosition(
                context.coordinatesConverter.context,
                Position.init(ms.selectionStart.endLineNumber, ms.selectionStart.endColumn),
                .None,
                false,
                false,
            );
            const viewSelectionStart = Range.init(viewSelectionStart1.lineNumber, viewSelectionStart1.column, viewSelectionStart2.lineNumber, viewSelectionStart2.column);
            const viewPosition = context.coordinatesConverter.convertModelPositionToViewPosition(
                context.coordinatesConverter.context,
                ms.position,
                .None,
                false,
                false,
            );
            viewState = SingleCursorState.init(viewSelectionStart, ms.selectionStartKind, ms.selectionStartLeftoverVisibleColumns, viewPosition, ms.leftoverVisibleColumns);
        } else {
            const vs = viewState.?;
            const viewSelectionStart = context.coordinatesConverter.validateViewRange(context.coordinatesConverter.context, vs.selectionStart, ms.selectionStart);
            const viewPosition = context.coordinatesConverter.validateViewPosition(context.coordinatesConverter.context, vs.position, ms.position);
            viewState = SingleCursorState.init(viewSelectionStart, ms.selectionStartKind, ms.selectionStartLeftoverVisibleColumns, viewPosition, ms.leftoverVisibleColumns);
        }

        self.modelState = modelState.?;
        self.viewState = viewState.?;
        try self._updateTrackedRange(context);
    }
};

fn selectionIsEmpty(selection: Selection) bool {
    return selection.startLineNumber == selection.endLineNumber and selection.startColumn == selection.endColumn;
}

fn rangesEqual(a: Range, b: Range) bool {
    return a.startLineNumber == b.startLineNumber and a.startColumn == b.startColumn and
        a.endLineNumber == b.endLineNumber and a.endColumn == b.endColumn;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const cursorCommon = @import("../cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const ICursorSimpleModel = cursorCommon.ICursorSimpleModel;
const IColumnSelectData = cursorCommon.IColumnSelectData;
const SelectionStartKind = cursorCommon.SelectionStartKind;
const SingleCursorState = cursorCommon.SingleCursorState;

pub const IColumnSelectResult = struct {
    viewStates: []SingleCursorState,
    reversed: bool,
    fromLineNumber: usize,
    fromVisualColumn: usize,
    toLineNumber: usize,
    toVisualColumn: usize,

    pub fn deinit(self: *IColumnSelectResult, allocator: Allocator) void {
        allocator.free(self.viewStates);
    }
};

pub const ColumnSelection = struct {
    pub fn columnSelect(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        fromLineNumber: usize,
        fromVisibleColumn: usize,
        toLineNumber: usize,
        toVisibleColumn: usize,
    ) !IColumnSelectResult {
        const lineCount = (if (toLineNumber >= fromLineNumber) toLineNumber - fromLineNumber else fromLineNumber - toLineNumber) + 1;
        const reversed = fromLineNumber > toLineNumber;
        const isRTL = fromVisibleColumn > toVisibleColumn;
        const isLTR = fromVisibleColumn < toVisibleColumn;

        var result = ArrayList(SingleCursorState).init(allocator);
        errdefer result.deinit();

        for (0..lineCount) |i| {
            const lineNumber = if (reversed) fromLineNumber - i else fromLineNumber + i;
            const startColumn = config.columnFromVisibleColumn(model, lineNumber, fromVisibleColumn);
            const endColumn = config.columnFromVisibleColumn(model, lineNumber, toVisibleColumn);
            const visibleStartColumn = config.visibleColumnFromColumn(model, Position.init(lineNumber, startColumn));
            const visibleEndColumn = config.visibleColumnFromColumn(model, Position.init(lineNumber, endColumn));

            if (isLTR) {
                if (visibleStartColumn > toVisibleColumn) continue;
                if (visibleEndColumn < fromVisibleColumn) continue;
            }
            if (isRTL) {
                if (visibleEndColumn > fromVisibleColumn) continue;
                if (visibleStartColumn < toVisibleColumn) continue;
            }

            try result.append(SingleCursorState.init(
                Range.init(lineNumber, startColumn, lineNumber, startColumn),
                .Simple,
                0,
                Position.init(lineNumber, endColumn),
                0,
            ));
        }

        if (result.items.len == 0) {
            for (0..lineCount) |i| {
                const lineNumber = if (reversed) fromLineNumber - i else fromLineNumber + i;
                const maxColumn = model.getLineMaxColumn(model.context, lineNumber);
                try result.append(SingleCursorState.init(
                    Range.init(lineNumber, maxColumn, lineNumber, maxColumn),
                    .Simple,
                    0,
                    Position.init(lineNumber, maxColumn),
                    0,
                ));
            }
        }

        return .{
            .viewStates = try result.toOwnedSlice(),
            .reversed = reversed,
            .fromLineNumber = fromLineNumber,
            .fromVisualColumn = fromVisibleColumn,
            .toLineNumber = toLineNumber,
            .toVisualColumn = toVisibleColumn,
        };
    }

    pub fn columnSelectLeft(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        prev: IColumnSelectData,
    ) !IColumnSelectResult {
        const toViewVisualColumn = if (prev.toViewVisualColumn > 0) prev.toViewVisualColumn - 1 else 0;
        return columnSelect(allocator, config, model, prev.fromViewLineNumber, prev.fromViewVisualColumn, prev.toViewLineNumber, toViewVisualColumn);
    }

    pub fn columnSelectRight(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        prev: IColumnSelectData,
    ) !IColumnSelectResult {
        const minLine = @min(prev.fromViewLineNumber, prev.toViewLineNumber);
        const maxLine = @max(prev.fromViewLineNumber, prev.toViewLineNumber);
        var maxVisualViewColumn: usize = 0;
        var lineNumber = minLine;
        while (lineNumber <= maxLine) : (lineNumber += 1) {
            const lineMaxColumn = model.getLineMaxColumn(model.context, lineNumber);
            const lineMaxVisualViewColumn = config.visibleColumnFromColumn(model, Position.init(lineNumber, lineMaxColumn));
            maxVisualViewColumn = @max(maxVisualViewColumn, lineMaxVisualViewColumn);
        }

        const toViewVisualColumn = if (prev.toViewVisualColumn < maxVisualViewColumn) prev.toViewVisualColumn + 1 else prev.toViewVisualColumn;
        return columnSelect(allocator, config, model, prev.fromViewLineNumber, prev.fromViewVisualColumn, prev.toViewLineNumber, toViewVisualColumn);
    }

    pub fn columnSelectUp(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        prev: IColumnSelectData,
        isPaged: bool,
    ) !IColumnSelectResult {
        const linesCount = if (isPaged) config.pageSize else 1;
        const toViewLineNumber = if (prev.toViewLineNumber > linesCount) prev.toViewLineNumber - linesCount else 1;
        return columnSelect(allocator, config, model, prev.fromViewLineNumber, prev.fromViewVisualColumn, toViewLineNumber, prev.toViewVisualColumn);
    }

    pub fn columnSelectDown(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: ICursorSimpleModel,
        prev: IColumnSelectData,
        isPaged: bool,
    ) !IColumnSelectResult {
        const linesCount = if (isPaged) config.pageSize else 1;
        const toViewLineNumber = @min(model.getLineCount(model.context), prev.toViewLineNumber + linesCount);
        return columnSelect(allocator, config, model, prev.fromViewLineNumber, prev.fromViewVisualColumn, toViewLineNumber, prev.toViewVisualColumn);
    }
};

const TestModel = struct {
    lines: []const []const u8,

    fn getLineCount(context: *anyopaque) usize {
        const self: *TestModel = @ptrCast(@alignCast(context));
        return self.lines.len;
    }
    fn getLineContent(context: *anyopaque, lineNumber: usize) []const u8 {
        const self: *TestModel = @ptrCast(@alignCast(context));
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
    fn normalizePosition(_: *anyopaque, position: Position, _: @import("../model.zig").PositionAffinity) Position {
        return position;
    }
    fn getLineIndentColumn(context: *anyopaque, lineNumber: usize) usize {
        return getLineFirstNonWhitespaceColumn(context, lineNumber) + 1;
    }

    fn interface(self: *TestModel) ICursorSimpleModel {
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

test "cursor column selection: basic and fallback" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{ "abc", "de", "" };
    var model = TestModel{ .lines = &lines };
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 2 };
    const cursor_model = model.interface();

    var result = try ColumnSelection.columnSelect(allocator, &config, cursor_model, 1, 0, 1, 3);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.viewStates.len);
    try std.testing.expectEqual(@as(usize, 1), result.viewStates[0].selection.startColumn);
    try std.testing.expectEqual(@as(usize, 4), result.viewStates[0].selection.endColumn);

    var fallback = try ColumnSelection.columnSelect(allocator, &config, cursor_model, 1, 10, 3, 20);
    defer fallback.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), fallback.viewStates.len);
    try std.testing.expectEqual(@as(usize, 4), fallback.viewStates[0].selection.endColumn);
    try std.testing.expectEqual(@as(usize, 3), fallback.viewStates[1].selection.endColumn);
    try std.testing.expectEqual(@as(usize, 1), fallback.viewStates[2].selection.endColumn);
}

test "cursor column selection: left/right and page moves" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{ "abc", "defg", "h" };
    var model = TestModel{ .lines = &lines };
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };
    const cursor_model = model.interface();
    const previous = IColumnSelectData{
        .isReal = true,
        .fromViewLineNumber = 1,
        .fromViewVisualColumn = 0,
        .toViewLineNumber = 2,
        .toViewVisualColumn = 1,
    };

    var right = try ColumnSelection.columnSelectRight(allocator, &config, cursor_model, previous);
    defer right.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), right.toVisualColumn);

    var left = try ColumnSelection.columnSelectLeft(allocator, &config, cursor_model, previous);
    defer left.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), left.toVisualColumn);

    var up = try ColumnSelection.columnSelectUp(allocator, &config, cursor_model, previous, false);
    defer up.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), up.toLineNumber);

    var down = try ColumnSelection.columnSelectDown(allocator, &config, cursor_model, previous, false);
    defer down.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), down.toLineNumber);
}

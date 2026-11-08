const std = @import("std");
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const Selection = @import("../core/selection.zig").Selection;
const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;
const cursorCommon = @import("../cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const ICursorSimpleModel = cursorCommon.ICursorSimpleModel;
const MoveOperations = @import("./cursorMoveOperations.zig").MoveOperations;

pub const DeleteResult = struct {
    shouldPushStackElementBefore: bool,
    commands: []const ?cursorCommon.ReplaceCommand,

    pub fn deinit(self: *DeleteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.commands);
    }
};

pub const DeleteOperations = struct {
    pub fn deleteRight(allocator: std.mem.Allocator, prevEditOperationType: cursorCommon.EditOperationType, config: *const CursorConfiguration, model: ICursorSimpleModel, selections: []const Selection) !DeleteResult {
        const commands = try allocator.alloc(?cursorCommon.ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        var should_push = prevEditOperationType != .DeletingRight;

        for (selections, 0..) |selection, i| {
            const delete_selection = getDeleteRightRange(selection, model, config);
            if (delete_selection.isEmpty()) {
                commands[i] = null;
                continue;
            }
            if (delete_selection.startLineNumber != delete_selection.endLineNumber) should_push = true;
            commands[i] = cursorCommon.ReplaceCommand.init(delete_selection, "");
        }

        return .{ .shouldPushStackElementBefore = should_push, .commands = commands };
    }

    pub fn deleteLeft(allocator: std.mem.Allocator, prevEditOperationType: cursorCommon.EditOperationType, config: *const CursorConfiguration, model: ICursorSimpleModel, selections: []const Selection) !DeleteResult {
        const commands = try allocator.alloc(?cursorCommon.ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        var should_push = prevEditOperationType != .DeletingLeft;

        for (selections, 0..) |selection, i| {
            const delete_selection = getDeleteLeftRange(selection, model, config);
            if (delete_selection.isEmpty()) {
                commands[i] = null;
                continue;
            }
            if (delete_selection.startLineNumber != delete_selection.endLineNumber) should_push = true;
            commands[i] = cursorCommon.ReplaceCommand.init(delete_selection, "");
        }

        return .{ .shouldPushStackElementBefore = should_push, .commands = commands };
    }

    pub fn getDeleteRightRange(selection: Selection, model: ICursorSimpleModel, config: *const CursorConfiguration) Range {
        if (!selection.isEmpty()) {
            return Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
        }

        const position = selection.getPosition();
        const rightOfPosition = MoveOperations.rightPosition(model, position.lineNumber, position.column);

        if (config.trimWhitespaceOnDelete and rightOfPosition.lineNumber != position.lineNumber) {
            const currentLineHasContent = model.getLineFirstNonWhitespaceColumn(model.context, position.lineNumber) > 0;
            const firstNonWhitespaceColumn = model.getLineFirstNonWhitespaceColumn(model.context, rightOfPosition.lineNumber);
            if (currentLineHasContent and firstNonWhitespaceColumn > 0) {
                return Range.init(rightOfPosition.lineNumber, firstNonWhitespaceColumn, position.lineNumber, position.column);
            }
        }

        return Range.init(rightOfPosition.lineNumber, rightOfPosition.column, position.lineNumber, position.column);
    }

    pub fn getDeleteLeftRange(selection: Selection, model: ICursorSimpleModel, config: *const CursorConfiguration) Range {
        if (!selection.isEmpty()) {
            return Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
        }

        const position = selection.getPosition();

        if (config.useTabStops and position.column > 1) {
            const lineContent = model.getLineContent(model.context, position.lineNumber);
            const first_non_whitespace = firstNonWhitespaceIndex(lineContent);
            const lastIndentationColumn = if (first_non_whitespace == null)
                lineContent.len + 1
            else
                first_non_whitespace.? + 1;

            if (position.column <= lastIndentationColumn) {
                const fromVisibleColumn = config.visibleColumnFromColumn(model, position);
                const toVisibleColumn = CursorColumns.prevIndentTabStop(fromVisibleColumn, config.indentSize);
                const toColumn = config.columnFromVisibleColumn(model, position.lineNumber, toVisibleColumn);
                return Range.init(position.lineNumber, toColumn, position.lineNumber, position.column);
            }
        }

        const afterDelete = getPositionAfterDeleteLeft(model, position);
        return Range.init(afterDelete.lineNumber, afterDelete.column, position.lineNumber, position.column);
    }

    fn getPositionAfterDeleteLeft(model: ICursorSimpleModel, position: Position) Position {
        if (position.column > 1) {
            const line = model.getLineContent(model.context, position.lineNumber);
            const index = position.column - 1;
            var offset = index;
            if (offset > 0) {
                offset -= 1;
                while (offset > 0 and (line[offset] & 0xC0) == 0x80) offset -= 1;
            }
            return Position.init(position.lineNumber, offset + 1);
        } else if (position.lineNumber > 1) {
            const newLine = position.lineNumber - 1;
            return Position.init(newLine, model.getLineMaxColumn(model.context, newLine));
        }
        return position;
    }
};

fn firstNonWhitespaceIndex(text: []const u8) ?usize {
    for (text, 0..) |ch, i| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return i;
    }
    return null;
}

const DeleteTestModel = struct {
    lines: []const []const u8,
    fn getLineCount(context: *anyopaque) usize {
        const self: *DeleteTestModel = @ptrCast(@alignCast(context));
        return self.lines.len;
    }
    fn getLineContent(context: *anyopaque, lineNumber: usize) []const u8 {
        const self: *DeleteTestModel = @ptrCast(@alignCast(context));
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
    fn getLineLastNonWhitespaceColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn normalizePosition(_: *anyopaque, position: Position, _: @import("../model.zig").PositionAffinity) Position {
        return position;
    }
    fn getLineIndentColumn(context: *anyopaque, lineNumber: usize) usize {
        return getLineFirstNonWhitespaceColumn(context, lineNumber);
    }
    fn interface(self: *DeleteTestModel) ICursorSimpleModel {
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

test "cursor delete: left and right ranges" {
    const lines = [_][]const u8{ "abc", "  def" };
    var test_model = DeleteTestModel{ .lines = &lines };
    const model = test_model.interface();
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };

    const right = DeleteOperations.getDeleteRightRange(Selection.init(1, 2, 1, 2), model, &config);
    try std.testing.expectEqual(@as(usize, 2), right.startColumn);
    try std.testing.expectEqual(@as(usize, 3), right.endColumn);

    const left = DeleteOperations.getDeleteLeftRange(Selection.init(1, 2, 1, 2), model, &config);
    try std.testing.expectEqual(@as(usize, 1), left.startColumn);
    try std.testing.expectEqual(@as(usize, 2), left.endColumn);

    const join = DeleteOperations.getDeleteLeftRange(Selection.init(2, 1, 2, 1), model, &config);
    try std.testing.expectEqual(@as(usize, 1), join.startLineNumber);
    try std.testing.expectEqual(@as(usize, 4), join.startColumn);
    try std.testing.expectEqual(@as(usize, 2), join.endLineNumber);
}

test "cursor delete: trim line join and tab-stop indentation" {
    const lines = [_][]const u8{ "abc", "  def", "    x" };
    var test_model = DeleteTestModel{ .lines = &lines };
    const model = test_model.interface();

    var trim_config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };
    trim_config.trimWhitespaceOnDelete = true;
    const trimmed = DeleteOperations.getDeleteRightRange(Selection.init(1, 4, 1, 4), model, &trim_config);
    try std.testing.expectEqual(@as(usize, 1), trimmed.startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), trimmed.endLineNumber);
    try std.testing.expectEqual(@as(usize, 3), trimmed.endColumn);

    var tab_config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };
    tab_config.useTabStops = true;
    const indent_delete = DeleteOperations.getDeleteLeftRange(Selection.init(3, 5, 3, 5), model, &tab_config);
    try std.testing.expectEqual(@as(usize, 1), indent_delete.startColumn);
    try std.testing.expectEqual(@as(usize, 5), indent_delete.endColumn);
}

test "cursor delete: command assembly" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{"abc"};
    var test_model = DeleteTestModel{ .lines = &lines };
    const model = test_model.interface();
    const config = CursorConfiguration{ .tabSize = 4, .indentSize = 4, .insertSpaces = true, .pageSize = 1 };

    var right = try DeleteOperations.deleteRight(allocator, .Other, &config, model, &[_]Selection{Selection.init(1, 2, 1, 2)});
    defer right.deinit(allocator);
    try std.testing.expect(right.shouldPushStackElementBefore);
    try std.testing.expectEqual(@as(usize, 1), right.commands.len);
    try std.testing.expect(right.commands[0] != null);
    try std.testing.expectEqual(@as(usize, 2), right.commands[0].?.range.startColumn);

    var left = try DeleteOperations.deleteLeft(allocator, .DeletingLeft, &config, model, &[_]Selection{Selection.init(1, 2, 1, 2)});
    defer left.deinit(allocator);
    try std.testing.expect(!left.shouldPushStackElementBefore);
    try std.testing.expect(left.commands[0] != null);
    try std.testing.expectEqual(@as(usize, 1), left.commands[0].?.range.startColumn);
}

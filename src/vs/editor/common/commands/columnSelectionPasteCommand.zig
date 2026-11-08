// Port of `src/vs/editor/common/commands/columnSelectionPasteCommand.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const cursor_columns = @import("../core/cursorColumns.zig");
const CursorColumns = cursor_columns.CursorColumns;

const range_module = @import("../core/range.zig");
const Range = range_module.Range;

const selection_module = @import("../core/selection.zig");
const Selection = selection_module.Selection;

const editor_common = @import("../editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;

const replace_command = @import("./replaceCommand.zig");
const ReplaceCommand = replace_command.ReplaceCommand;
const ReplaceOvertypeCommand = replace_command.ReplaceOvertypeCommand;

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;

/// Pastes a block of lines over a column selection, padding every line of the
/// block so that it starts at the same visible column.
pub const ColumnSelectionPasteCommand = struct {
    allocator: Allocator,
    selection: Selection,
    /// The pasted lines. Borrowed for the lifetime of the command.
    text: []const []const u8,
    tabSize: usize,
    overtype: bool,

    pub fn init(
        allocator: Allocator,
        selection: Selection,
        text: []const []const u8,
        tab_size: usize,
        overtype: bool,
    ) ColumnSelectionPasteCommand {
        return .{
            .allocator = allocator,
            .selection = selection,
            .text = text,
            .tabSize = tab_size,
            .overtype = overtype,
        };
    }

    pub fn getEditOperations(self: *ColumnSelectionPasteCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var start_line_content = try model.getLineContent(self.selection.startLineNumber);
        defer start_line_content.deinit();

        const visible_column = CursorColumns.visibleColumnFromColumn(
            start_line_content.items,
            self.selection.startColumn,
            self.tabSize,
        );

        var text = try self.padTextToBlockWidth(visible_column);
        defer {
            for (text.items) |line| {
                self.allocator.free(line);
            }
            text.deinit();
        }

        const line_count = model.getLineCount();

        var i: usize = 0;
        while (i < text.items.len) : (i += 1) {
            const line_number = self.selection.endLineNumber + i;
            if (line_number > line_count) {
                const end_column = model.getLineMaxColumn(line_count);
                const appended_text = try self.buildAppendedText(text.items[i..], visible_column);
                defer self.allocator.free(appended_text);
                try builder.addTrackedEditOperation(Range.init(line_count, end_column, line_count, end_column), appended_text, false);
                break;
            }

            var range: Range = undefined;
            var line_text_temp: ?[]u8 = null;
            defer if (line_text_temp) |temporary| self.allocator.free(temporary);

            if (i == 0) {
                range = Range.init(
                    self.selection.startLineNumber,
                    self.selection.startColumn,
                    self.selection.endLineNumber,
                    self.selection.endColumn,
                );
            } else {
                var line_content = try model.getLineContent(line_number);
                defer line_content.deinit();

                const column = CursorColumns.columnFromVisibleColumn(line_content.items, visible_column, self.tabSize);
                range = Range.init(line_number, column, line_number, column);
                if (column == model.getLineMaxColumn(line_number)) {
                    const end_visible_column = CursorColumns.visibleColumnFromColumn(line_content.items, column, self.tabSize);
                    const padding_count = if (visible_column > end_visible_column) visible_column - end_visible_column else 0;
                    const padding = try self.spaces(padding_count);
                    defer self.allocator.free(padding);
                    line_text_temp = try std.mem.concat(self.allocator, u8, &.{ padding, text.items[i] });
                }
            }

            const line_text: []const u8 = if (line_text_temp) |temporary| temporary else text.items[i];
            if (self.overtype) {
                var command = ReplaceOvertypeCommand.init(range, line_text, false);
                try command.getEditOperations(model, builder);
            } else {
                var command = ReplaceCommand.init(range, line_text, false);
                try command.getEditOperations(model, builder);
            }
        }
    }

    /// Pads every pasted line so that all of them end at the same visible
    /// column. The returned slices are owned by the caller.
    fn padTextToBlockWidth(self: *ColumnSelectionPasteCommand, visible_column: usize) !ArrayList([]u8) {
        const prefix = try self.spaces(visible_column);
        defer self.allocator.free(prefix);

        var end_visible_columns = ArrayList(usize).init(self.allocator);
        defer end_visible_columns.deinit();
        try end_visible_columns.ensureTotalCapacity(self.text.len);

        var block_end_visible_column = visible_column;
        for (self.text) |line| {
            const text_with_prefix = try std.mem.concat(self.allocator, u8, &.{ prefix, line });
            defer self.allocator.free(text_with_prefix);

            const end_visible_column = CursorColumns.visibleColumnFromColumn(text_with_prefix, text_with_prefix.len + 1, self.tabSize);
            end_visible_columns.appendAssumeCapacity(end_visible_column);
            block_end_visible_column = @max(block_end_visible_column, end_visible_column);
        }

        var result = ArrayList([]u8).init(self.allocator);
        errdefer {
            for (result.items) |line| {
                self.allocator.free(line);
            }
            result.deinit();
        }

        try result.ensureTotalCapacity(self.text.len);
        for (self.text, 0..) |line, index| {
            const padding = try self.spaces(block_end_visible_column - end_visible_columns.items[index]);
            defer self.allocator.free(padding);
            result.appendAssumeCapacity(try std.mem.concat(self.allocator, u8, &.{ line, padding }));
        }

        return result;
    }

    /// Builds `"\n" + padding + lines.join("\n" + padding)`.
    fn buildAppendedText(self: *ColumnSelectionPasteCommand, lines: []const []const u8, visible_column: usize) ![]u8 {
        var result = ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        try result.append('\n');
        for (lines, 0..) |line, index| {
            if (index > 0) {
                try result.append('\n');
            }
            try result.appendNTimes(' ', visible_column);
            try result.appendSlice(line);
        }
        return result.toOwnedSlice();
    }

    fn spaces(self: *ColumnSelectionPasteCommand, count: usize) ![]u8 {
        const result = try self.allocator.alloc(u8, count);
        @memset(result, ' ');
        return result;
    }

    pub fn computeCursorState(self: *ColumnSelectionPasteCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = self;
        _ = model;
        const operations = helper.getInverseEditOperations();
        return selection_module.fromPositions(operations[operations.len - 1].range.getEndPosition(), null);
    }
};

comptime {
    _ = commandOf(ColumnSelectionPasteCommand).of;
}

test "ColumnSelectionPasteCommand: pads the block to a common width" {
    const allocator = std.testing.allocator;

    var command = ColumnSelectionPasteCommand.init(
        allocator,
        Selection.init(1, 3, 1, 3),
        &.{ "ab", "abcdef" },
        4,
        false,
    );
    try std.testing.expectEqual(@as(usize, 4), command.tabSize);
    try std.testing.expect(!command.overtype);

    var padded = try command.padTextToBlockWidth(2);
    defer {
        for (padded.items) |line| allocator.free(line);
        padded.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), padded.items.len);
    try std.testing.expectEqualStrings("ab    ", padded.items[0]);
    try std.testing.expectEqualStrings("abcdef", padded.items[1]);
}

test "ColumnSelectionPasteCommand: appends text below the model" {
    const allocator = std.testing.allocator;

    var command = ColumnSelectionPasteCommand.init(allocator, Selection.init(1, 1, 1, 1), &.{ "a", "b" }, 4, false);
    const appended = try command.buildAppendedText(&.{ "a", "b" }, 3);
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("\n   a\n   b", appended);
}

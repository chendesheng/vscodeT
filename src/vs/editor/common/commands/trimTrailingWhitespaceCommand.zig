// Port of `src/vs/editor/common/commands/trimTrailingWhitespaceCommand.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const strings = @import("../../../base/common/strings.zig");

const edit_operation = @import("../core/editOperation.zig");
const EditOperation = edit_operation.EditOperation;
const ISingleEditOperation = edit_operation.ISingleEditOperation;

const position_module = @import("../core/position.zig");
const Position = position_module.Position;

const range_module = @import("../core/range.zig");
const Range = range_module.Range;

const selection_module = @import("../core/selection.zig");
const Selection = selection_module.Selection;

const encoded_token_attributes = @import("../encodedTokenAttributes.zig");
const StandardTokenType = encoded_token_attributes.StandardTokenType;

const editor_common = @import("../editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;

pub const TrimTrailingWhitespaceCommand = struct {
    selection: Selection,
    cursors: []const Position,
    trimInRegexesAndStrings: bool,
    selection_id: ?u64,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        selection: Selection,
        cursors: []const Position,
        trim_in_regexes_and_strings: bool,
    ) TrimTrailingWhitespaceCommand {
        return .{
            .selection = selection,
            .cursors = cursors,
            .trimInRegexesAndStrings = trim_in_regexes_and_strings,
            .selection_id = null,
            .allocator = allocator,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *TrimTrailingWhitespaceCommand) ICommand {
        return commandOf(TrimTrailingWhitespaceCommand).of(self);
    }

    pub fn getEditOperations(self: *TrimTrailingWhitespaceCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var ops = try trimTrailingWhitespace(self.allocator, model, self.cursors, self.trimInRegexesAndStrings);
        defer ops.deinit();

        for (ops.items) |op| {
            try builder.addEditOperation(op.range, op.text, op.forceMoveMarkers);
        }

        self.selection_id = builder.trackSelection(self.selection);
    }

    pub fn computeCursorState(self: *TrimTrailingWhitespaceCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        return helper.getTrackedSelection(self.selection_id.?);
    }
};

/// Generates the edits that trim trailing whitespace on a model, skipping the
/// lines the cursors are sitting on.
///
/// The returned operations borrow no memory (`text` is always `null`); the list
/// itself is owned by the caller. Unlike the TypeScript implementation, the
/// caller's `cursors` slice is left untouched.
pub fn trimTrailingWhitespace(
    allocator: Allocator,
    model: *TextModel,
    cursors: []const Position,
    trim_in_regexes_and_strings: bool,
) !ArrayList(ISingleEditOperation) {
    // Copy and sort the cursors ascending.
    var sorted_cursors = ArrayList(Position).init(allocator);
    defer sorted_cursors.deinit();
    try sorted_cursors.appendSlice(cursors);
    std.mem.sort(Position, sorted_cursors.items, {}, lessThanPosition);

    // Reduce multiple cursors on the same line and only keep the last one on the
    // line.
    var deduped = ArrayList(Position).init(allocator);
    defer deduped.deinit();
    for (sorted_cursors.items) |cursor| {
        if (deduped.items.len > 0 and deduped.items[deduped.items.len - 1].lineNumber == cursor.lineNumber) {
            deduped.items[deduped.items.len - 1] = cursor;
        } else {
            try deduped.append(cursor);
        }
    }

    var result = ArrayList(ISingleEditOperation).init(allocator);
    errdefer result.deinit();

    var cursor_index: usize = 0;
    const cursor_len = deduped.items.len;

    var line_number: usize = 1;
    const line_count = model.getLineCount();
    while (line_number <= line_count) : (line_number += 1) {
        var line_content = try model.getLineContent(line_number);
        defer line_content.deinit();

        const max_line_column = line_content.items.len + 1;
        var min_edit_column: usize = 0;

        if (cursor_index < cursor_len and deduped.items[cursor_index].lineNumber == line_number) {
            min_edit_column = deduped.items[cursor_index].column;
            cursor_index += 1;
            if (min_edit_column == max_line_column) {
                // The cursor is at the end of the line => no edits for sure on this line
                continue;
            }
        }

        if (line_content.items.len == 0) {
            continue;
        }

        const last_non_whitespace_index = strings.lastNonWhitespaceIndex(line_content.items);

        var from_column: usize = 0;
        if (last_non_whitespace_index == null) {
            // Entire line is whitespace
            from_column = 1;
        } else if (last_non_whitespace_index.? != line_content.items.len - 1) {
            // There is trailing whitespace
            from_column = last_non_whitespace_index.? + 2;
        } else {
            // There is no trailing whitespace
            continue;
        }

        if (!trim_in_regexes_and_strings) {
            if (!model.tokenization().hasAccurateTokensForLine(line_number)) {
                // We don't want to force line tokenization, as that can be
                // expensive, but we also don't want to trim trailing whitespace
                // in lines that are not tokenized yet, as that can be wrong and
                // trim whitespace from lines that the user requested we don't.
                // So we bail out if the tokens are not accurate for this line.
                continue;
            }

            var line_tokens = try model.tokenization().getLineTokens(line_number);
            defer line_tokens.deinit();
            const from_column_type = line_tokens.getStandardTokenType(line_tokens.findTokenIndexAtOffset(from_column));

            if (from_column_type == .String or from_column_type == .RegEx) {
                continue;
            }
        }

        from_column = @max(min_edit_column, from_column);
        try result.append(EditOperation.delete(Range.init(line_number, from_column, line_number, max_line_column)));
    }

    return result;
}

fn lessThanPosition(_: void, a: Position, b: Position) bool {
    if (a.lineNumber == b.lineNumber) {
        return a.column < b.column;
    }
    return a.lineNumber < b.lineNumber;
}

comptime {
    _ = commandOf(TrimTrailingWhitespaceCommand).of;
}

test "trimTrailingWhitespace: trims trailing whitespace" {
    const test_support = @import("../../test/common/port/testSupport.zig");
    var test_model = try test_support.TestModel.init(std.testing.allocator, "a   \nb\n  \nc d  ", "plaintext");
    defer test_model.deinit();

    var ops = try trimTrailingWhitespace(std.testing.allocator, test_model.model, &.{}, true);
    defer ops.deinit();

    try std.testing.expectEqual(@as(usize, 3), ops.items.len);
    try std.testing.expectEqual(@as(usize, 1), ops.items[0].range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), ops.items[0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 5), ops.items[0].range.endColumn);
    try std.testing.expectEqual(@as(usize, 3), ops.items[1].range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 1), ops.items[1].range.startColumn);
    // Line 2 has no trailing whitespace, so it is skipped.
    try std.testing.expectEqual(@as(usize, 4), ops.items[2].range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 4), ops.items[2].range.startColumn);
}

test "trimTrailingWhitespace: a cursor at the end of the line disables the edit" {
    const test_support = @import("../../test/common/port/testSupport.zig");
    var test_model = try test_support.TestModel.init(std.testing.allocator, "a   \nb  ", "plaintext");
    defer test_model.deinit();

    var ops = try trimTrailingWhitespace(std.testing.allocator, test_model.model, &.{Position.init(1, 5)}, true);
    defer ops.deinit();

    try std.testing.expectEqual(@as(usize, 1), ops.items.len);
    try std.testing.expectEqual(@as(usize, 2), ops.items[0].range.startLineNumber);
}

test "trimTrailingWhitespace: the cursor column bounds the edit" {
    const test_support = @import("../../test/common/port/testSupport.zig");
    var test_model = try test_support.TestModel.init(std.testing.allocator, "a   ", "plaintext");
    defer test_model.deinit();

    var ops = try trimTrailingWhitespace(std.testing.allocator, test_model.model, &.{ Position.init(1, 3), Position.init(1, 2) }, true);
    defer ops.deinit();

    // Multiple cursors on the same line collapse to the last (right-most) one.
    try std.testing.expectEqual(@as(usize, 1), ops.items.len);
    try std.testing.expectEqual(@as(usize, 3), ops.items[0].range.startColumn);
    try std.testing.expectEqual(@as(usize, 5), ops.items[0].range.endColumn);
}

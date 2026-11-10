// Port of `src/vs/editor/common/commands/shiftCommand.ts`.
//
// The TypeScript implementation memoizes repeated indent strings in a
// module-level cache (`cachedStringRepeat`). In this port every indent string is
// freshly allocated and owned by the caller, which keeps the ownership rules
// simple; callers free the result with the same allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;

const strings = @import("../../../base/common/strings.zig");

const cursor_columns = @import("../core/cursorColumns.zig");
const CursorColumns = cursor_columns.CursorColumns;

const range_module = @import("../core/range.zig");
const Range = range_module.Range;

const selection_module = @import("../core/selection.zig");
const Selection = selection_module.Selection;
const SelectionDirection = selection_module.SelectionDirection;

const editor_common = @import("../editorCommon.zig");
const ICommand = editor_common.ICommand;
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;

const editor_options = @import("../config/editorOptions.zig");
const EditorAutoIndentStrategy = editor_options.EditorAutoIndentStrategy;

const enter_action = @import("../languages/enterAction.zig");
const getEnterAction = enter_action.getEnterAction;

const registry = @import("../languages/languageConfigurationRegistry.zig");
const ILanguageConfigurationService = registry.ILanguageConfigurationService;

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;

pub const IShiftCommandOpts = struct {
    isUnshift: bool,
    tabSize: usize,
    indentSize: usize,
    insertSpaces: bool,
    useTabStops: bool,
    autoIndent: EditorAutoIndentStrategy,
};

/// Returns the string made of `count` repetitions of `str`.
fn stringRepeat(allocator: Allocator, str: []const u8, count: usize) ![]u8 {
    if (count == 0 or str.len == 0) {
        return allocator.alloc(u8, 0);
    }

    const result = try allocator.alloc(u8, str.len * count);
    if (str.len == 1) {
        @memset(result, str[0]);
        return result;
    }
    for (0..count) |i| {
        @memcpy(result[i * str.len ..][0..str.len], str);
    }
    return result;
}

/// Computes the indentation that outdents the line at `column` by one indent
/// level.
pub fn unshiftIndent(
    allocator: Allocator,
    line: []const u8,
    column: usize,
    tab_size: usize,
    indent_size: usize,
    insert_spaces: bool,
) ![]u8 {
    // Determine the visible column where the content starts
    const content_start_visible_column = CursorColumns.visibleColumnFromColumn(line, column, tab_size);

    if (insert_spaces) {
        const indent = try stringRepeat(allocator, " ", indent_size);
        defer allocator.free(indent);
        const desired_tab_stop = CursorColumns.prevIndentTabStop(content_start_visible_column, indent_size);
        const indent_count = desired_tab_stop / indent_size; // will be an integer
        return stringRepeat(allocator, indent, indent_count);
    } else {
        const indent = "\t";
        const desired_tab_stop = CursorColumns.prevRenderTabStop(content_start_visible_column, tab_size);
        const indent_count = desired_tab_stop / tab_size; // will be an integer
        return stringRepeat(allocator, indent, indent_count);
    }
}

/// Computes the indentation that indents the line at `column` by one indent
/// level.
pub fn shiftIndent(
    allocator: Allocator,
    line: []const u8,
    column: usize,
    tab_size: usize,
    indent_size: usize,
    insert_spaces: bool,
) ![]u8 {
    // Determine the visible column where the content starts
    const content_start_visible_column = CursorColumns.visibleColumnFromColumn(line, column, tab_size);

    if (insert_spaces) {
        const indent = try stringRepeat(allocator, " ", indent_size);
        defer allocator.free(indent);
        const desired_tab_stop = CursorColumns.nextIndentTabStop(content_start_visible_column, indent_size);
        const indent_count = desired_tab_stop / indent_size; // will be an integer
        return stringRepeat(allocator, indent, indent_count);
    } else {
        const indent = "\t";
        const desired_tab_stop = CursorColumns.nextRenderTabStop(content_start_visible_column, tab_size);
        const indent_count = desired_tab_stop / tab_size; // will be an integer
        return stringRepeat(allocator, indent, indent_count);
    }
}

pub const ShiftCommand = struct {
    opts: IShiftCommandOpts,
    selection: Selection,
    selection_id: ?u64,
    useLastEditRangeForCursorEndPosition: bool,
    selectionStartColumnStaysPut: bool,
    /// The allocator used for temporary strings and for `getEnterAction`.
    allocator: Allocator,
    language_configuration_service: ILanguageConfigurationService,

    pub fn init(
        allocator: Allocator,
        range: Selection,
        opts: IShiftCommandOpts,
        language_configuration_service: ILanguageConfigurationService,
    ) ShiftCommand {
        return .{
            .opts = opts,
            .selection = range,
            .selection_id = null,
            .useLastEditRangeForCursorEndPosition = false,
            .selectionStartColumnStaysPut = false,
            .allocator = allocator,
            .language_configuration_service = language_configuration_service,
        };
    }

    fn addEditOperation(self: *ShiftCommand, builder: IEditOperationBuilder, range: Range, text: ?[]const u8) !void {
        if (self.useLastEditRangeForCursorEndPosition) {
            try builder.addTrackedEditOperation(range, text, false);
        } else {
            try builder.addEditOperation(range, text, false);
        }
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ShiftCommand) ICommand {
        return commandOf(ShiftCommand).of(self);
    }

    pub fn getEditOperations(self: *ShiftCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        const start_line = self.selection.startLineNumber;

        var end_line = self.selection.endLineNumber;
        if (self.selection.endColumn == 1 and start_line != end_line) {
            end_line = end_line - 1;
        }

        const tab_size = self.opts.tabSize;
        const indent_size = self.opts.indentSize;
        const insert_spaces = self.opts.insertSpaces;
        const should_indent_empty_lines = (start_line == end_line);

        if (self.opts.useTabStops) {
            // if indenting or outdenting on a whitespace only line
            const start_line_content = try model.getLineContent(start_line);
            defer start_line_content.deinit();
            if (self.selection.isEmpty()) {
                if (isWhitespaceOnly(start_line_content.items)) {
                    self.useLastEditRangeForCursorEndPosition = true;
                }
            }

            // keep track of previous line's "miss-alignment"
            var previous_line_extra_spaces: usize = 0;
            var extra_spaces: usize = 0;

            var line_number = start_line;
            while (line_number <= end_line) : (line_number += 1) {
                defer previous_line_extra_spaces = extra_spaces;
                extra_spaces = 0;

                var line_text = try model.getLineContent(line_number);
                defer line_text.deinit();

                var indentation_end_index: usize = strings.firstNonWhitespaceIndex(line_text.items) orelse line_text.items.len;

                if (self.opts.isUnshift and (line_text.items.len == 0 or indentation_end_index == 0)) {
                    // empty line or line with no leading whitespace => nothing to do
                    continue;
                }

                if (!should_indent_empty_lines and !self.opts.isUnshift and line_text.items.len == 0) {
                    // do not indent empty lines => nothing to do
                    continue;
                }

                if (line_number > 1) {
                    const content_start_visible_column = CursorColumns.visibleColumnFromColumn(line_text.items, indentation_end_index + 1, tab_size);
                    if (content_start_visible_column % indent_size != 0) {
                        // The current line is "miss-aligned", so let's see if this is expected...
                        // This can only happen when it has trailing commas in the indent
                        if (model.tokenization().isCheapToTokenize(line_number - 1)) {
                            const range = Range.init(
                                line_number - 1,
                                model.getLineMaxColumn(line_number - 1),
                                line_number - 1,
                                model.getLineMaxColumn(line_number - 1),
                            );
                            const enter_action_result = try getEnterAction(
                                self.allocator,
                                self.opts.autoIndent,
                                model,
                                range,
                                self.language_configuration_service,
                            );
                            if (enter_action_result) |result| {
                                var mutable_result = result;
                                defer mutable_result.deinit(self.allocator);

                                extra_spaces = previous_line_extra_spaces;
                                for (mutable_result.appendText) |character| {
                                    if (extra_spaces >= indent_size) {
                                        break;
                                    }
                                    if (character == ' ') {
                                        extra_spaces += 1;
                                    } else {
                                        break;
                                    }
                                }
                                if (mutable_result.removeText > 0) {
                                    extra_spaces -= @min(extra_spaces, mutable_result.removeText);
                                }

                                // Act as if `prefixSpaces` is not part of the indentation
                                var j: usize = 0;
                                while (j < extra_spaces) : (j += 1) {
                                    if (indentation_end_index == 0 or line_text.items[indentation_end_index - 1] != ' ') {
                                        break;
                                    }
                                    indentation_end_index -= 1;
                                }
                            }
                        }
                    }
                }

                if (self.opts.isUnshift and indentation_end_index == 0) {
                    // line with no leading whitespace => nothing to do
                    continue;
                }

                const desired_indent = if (self.opts.isUnshift)
                    try unshiftIndent(self.allocator, line_text.items, indentation_end_index + 1, tab_size, indent_size, insert_spaces)
                else
                    try shiftIndent(self.allocator, line_text.items, indentation_end_index + 1, tab_size, indent_size, insert_spaces);
                defer self.allocator.free(desired_indent);

                try self.addEditOperation(builder, Range.init(line_number, 1, line_number, indentation_end_index + 1), desired_indent);
                if (line_number == start_line and !self.selection.isEmpty()) {
                    // Force the startColumn to stay put because we're inserting after it
                    self.selectionStartColumnStaysPut = (self.selection.startColumn <= indentation_end_index + 1);
                }
            }
        } else {
            if (!self.opts.isUnshift and self.selection.isEmpty() and model.getLineLength(start_line) == 0) {
                self.useLastEditRangeForCursorEndPosition = true;
            }

            const one_indent = if (insert_spaces) try stringRepeat(self.allocator, " ", indent_size) else try self.allocator.dupe(u8, "\t");
            defer self.allocator.free(one_indent);

            var line_number = start_line;
            while (line_number <= end_line) : (line_number += 1) {
                var line_text = try model.getLineContent(line_number);
                defer line_text.deinit();

                var indentation_end_index: usize = strings.firstNonWhitespaceIndex(line_text.items) orelse line_text.items.len;

                if (self.opts.isUnshift and (line_text.items.len == 0 or indentation_end_index == 0)) {
                    // empty line or line with no leading whitespace => nothing to do
                    continue;
                }

                if (!should_indent_empty_lines and !self.opts.isUnshift and line_text.items.len == 0) {
                    // do not indent empty lines => nothing to do
                    continue;
                }

                if (self.opts.isUnshift) {
                    indentation_end_index = @min(indentation_end_index, indent_size);
                    for (0..indentation_end_index) |i| {
                        if (line_text.items[i] == '\t') {
                            indentation_end_index = i + 1;
                            break;
                        }
                    }

                    try self.addEditOperation(builder, Range.init(line_number, 1, line_number, indentation_end_index + 1), "");
                } else {
                    try self.addEditOperation(builder, Range.init(line_number, 1, line_number, 1), one_indent);
                    if (line_number == start_line and !self.selection.isEmpty()) {
                        // Force the startColumn to stay put because we're inserting after it
                        self.selectionStartColumnStaysPut = (self.selection.startColumn == 1);
                    }
                }
            }
        }

        self.selection_id = builder.trackSelection(self.selection);
    }

    pub fn computeCursorState(self: *ShiftCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        if (self.useLastEditRangeForCursorEndPosition) {
            const last_op = helper.getInverseEditOperations()[0];
            return Selection.init(
                last_op.range.endLineNumber,
                last_op.range.endColumn,
                last_op.range.endLineNumber,
                last_op.range.endColumn,
            );
        }
        const result = helper.getTrackedSelection(self.selection_id.?);

        if (self.selectionStartColumnStaysPut) {
            // The selection start should not move
            const initial_start_column = self.selection.startColumn;
            const result_start_column = result.startColumn;
            if (result_start_column <= initial_start_column) {
                return result;
            }

            if (result.getDirection() == .LTR) {
                return Selection.init(result.startLineNumber, initial_start_column, result.endLineNumber, result.endColumn);
            }
            return Selection.init(result.endLineNumber, result.endColumn, result.startLineNumber, initial_start_column);
        }

        return result;
    }
};

fn isWhitespaceOnly(text: []const u8) bool {
    for (text) |character| {
        if (character != ' ' and character != '\t') {
            return false;
        }
    }
    return true;
}

comptime {
    _ = commandOf(ShiftCommand).of;
}

test "ShiftCommand: shiftIndent adds one indent level" {
    const allocator = std.testing.allocator;

    const spaces = try shiftIndent(allocator, "    a", 5, 4, 4, true);
    defer allocator.free(spaces);
    try std.testing.expectEqualStrings("        ", spaces);

    const partial = try shiftIndent(allocator, "  a", 3, 4, 4, true);
    defer allocator.free(partial);
    try std.testing.expectEqualStrings("    ", partial);

    const tabs = try shiftIndent(allocator, "\ta", 2, 4, 4, false);
    defer allocator.free(tabs);
    try std.testing.expectEqualStrings("\t\t", tabs);
}

test "ShiftCommand: unshiftIndent removes one indent level" {
    const allocator = std.testing.allocator;

    const spaces = try unshiftIndent(allocator, "        a", 9, 4, 4, true);
    defer allocator.free(spaces);
    try std.testing.expectEqualStrings("    ", spaces);

    // Less than one indent level of leading whitespace is removed entirely.
    const partial = try unshiftIndent(allocator, "  a", 3, 4, 4, true);
    defer allocator.free(partial);
    try std.testing.expectEqualStrings("", partial);

    const tabs = try unshiftIndent(allocator, "\t\ta", 3, 4, 4, false);
    defer allocator.free(tabs);
    try std.testing.expectEqualStrings("\t", tabs);
}

test "ShiftCommand: empty repetition allocates an empty string" {
    const allocator = std.testing.allocator;

    const empty = try stringRepeat(allocator, " ", 0);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const repeated = try stringRepeat(allocator, "ab", 3);
    defer allocator.free(repeated);
    try std.testing.expectEqualStrings("ababab", repeated);
}

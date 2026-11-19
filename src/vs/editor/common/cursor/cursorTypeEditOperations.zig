const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Selection = @import("../core/selection.zig").Selection;
const Range = @import("../core/range.zig").Range;
const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;
const strings = @import("../../../base/common/strings.zig");
const eol_counter = @import("../core/misc/eolCounter.zig");
const cursorCommon = @import("../cursorCommon.zig");
const CursorConfiguration = cursorCommon.CursorConfiguration;
const EditOperationResult = cursorCommon.EditOperationResult;
const EditOperationType = cursorCommon.EditOperationType;
const ReplaceCommand = cursorCommon.ReplaceCommand;
const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;
const enter_action = @import("../languages/enterAction.zig");
const auto_indent = @import("../languages/autoIndent.zig");
const IIndentConverter = auto_indent.IIndentConverter;
const language_configuration_registry = @import("../languages/languageConfigurationRegistry.zig");
const shift_command = @import("../commands/shiftCommand.zig");
const EditorAutoIndentStrategy = @import("../config/editorOptions.zig").EditorAutoIndentStrategy;

pub fn getTypingOperation(typedText: []const u8, previousTypingOperation: EditOperationType) EditOperationType {
    if (std.mem.eql(u8, typedText, " ")) {
        return if (previousTypingOperation == .TypingFirstSpace or previousTypingOperation == .TypingConsecutiveSpace)
            .TypingConsecutiveSpace
        else
            .TypingFirstSpace;
    }
    return .TypingOther;
}

pub fn shouldPushStackElementBetween(previousTypingOperation: EditOperationType, typingOperation: EditOperationType) bool {
    if (isTypingOperation(previousTypingOperation) and !isTypingOperation(typingOperation)) return true;
    if (previousTypingOperation == .TypingFirstSpace) return false;
    return normalizeOperationType(previousTypingOperation) != normalizeOperationType(typingOperation);
}

fn normalizeOperationType(operation: EditOperationType) EditOperationType {
    return if (operation == .TypingConsecutiveSpace or operation == .TypingFirstSpace) .TypingOther else operation;
}

fn isTypingOperation(operation: EditOperationType) bool {
    return operation == .TypingOther or operation == .TypingFirstSpace or operation == .TypingConsecutiveSpace;
}

pub const TypeWithoutInterceptorsOperation = struct {
    pub fn getEdits(allocator: Allocator, prevEditOperationType: EditOperationType, selections: []const Selection, str: []const u8) !EditOperationResult {
        const commands = try allocator.alloc(?ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        for (selections, 0..) |selection, i| {
            commands[i] = ReplaceCommand.init(rangeFromSelection(selection), str);
        }
        const op_type = getTypingOperation(str, prevEditOperationType);
        return .{
            .type = op_type,
            .commands = commands,
            .shouldPushStackElementBefore = shouldPushStackElementBetween(prevEditOperationType, op_type),
            .shouldPushStackElementAfter = false,
        };
    }
};

pub const SimpleCharacterTypeOperation = struct {
    pub fn getEdits(
        allocator: Allocator,
        config: *const CursorConfiguration,
        prevEditOperationType: EditOperationType,
        selections: []const Selection,
        ch: []const u8,
        isDoingComposition: bool,
    ) !EditOperationResult {
        _ = config;
        _ = isDoingComposition;
        // Overtype replacement is not wired yet; both paths use ReplaceCommand here.
        const commands = try allocator.alloc(?ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        for (selections, 0..) |selection, i| {
            commands[i] = ReplaceCommand.init(rangeFromSelection(selection), ch);
        }
        const op_type = getTypingOperation(ch, prevEditOperationType);
        return .{
            .type = op_type,
            .commands = commands,
            .shouldPushStackElementBefore = shouldPushStackElementBetween(prevEditOperationType, op_type),
            .shouldPushStackElementAfter = false,
        };
    }
};

const IndentConverter = struct {
    config: *const CursorConfiguration,

    fn shift(context: *anyopaque, allocator: Allocator, indentation: []const u8) anyerror![]u8 {
        const self: *IndentConverter = @ptrCast(@alignCast(context));
        return shift_command.shiftIndent(
            allocator,
            indentation,
            indentation.len + 1,
            self.config.tabSize,
            self.config.indentSize,
            self.config.insertSpaces,
        );
    }

    fn unshift(context: *anyopaque, allocator: Allocator, indentation: []const u8) anyerror![]u8 {
        const self: *IndentConverter = @ptrCast(@alignCast(context));
        return shift_command.unshiftIndent(
            allocator,
            indentation,
            indentation.len + 1,
            self.config.tabSize,
            self.config.indentSize,
            self.config.insertSpaces,
        );
    }

    fn interface(self: *IndentConverter) IIndentConverter {
        return .{
            .context = self,
            .shiftIndentFn = shift,
            .unshiftIndentFn = unshift,
        };
    }
};

fn leadingWhitespaceUpTo(line: []const u8, column: usize) []const u8 {
    const leading = strings.getLeadingWhitespace(line);
    return leading[0..@min(leading.len, column -| 1)];
}

fn lineCommand(allocator: Allocator, range: Range, eol: []const u8, indentation: []const u8) !ReplaceCommand {
    var text = ArrayList(u8).init(allocator);
    errdefer text.deinit();
    try text.appendSlice(eol);
    try text.appendSlice(indentation);
    return ReplaceCommand.initOwned(range, try text.toOwnedSlice());
}

fn normalizedLineCommand(
    allocator: Allocator,
    config: *const CursorConfiguration,
    range: Range,
    eol: []const u8,
    indentation: []const u8,
) !ReplaceCommand {
    const normalized = try config.normalizeIndentation(allocator, indentation);
    defer allocator.free(normalized);
    return lineCommand(allocator, range, eol, normalized);
}

fn combinedIndentation(allocator: Allocator, indentation: []const u8, append_text: []const u8) ![]u8 {
    var combined = ArrayList(u8).init(allocator);
    errdefer combined.deinit();
    try combined.appendSlice(indentation);
    try combined.appendSlice(append_text);
    return combined.toOwnedSlice();
}

/// Port of `AutoIndentOperation` from
/// `src/vs/editor/common/cursor/cursorTypeEditOperations.ts`.
///
/// Upstream combines the indentation edit with an auto-closing pair when both
/// apply. The terminal's auto-closing path only opens single-character pairs,
/// and this operation is reached for the closing character of a bracket pair,
/// so the combined command is not needed; the indentation edit inserts `ch`
/// itself.
pub const AutoIndentOperation = struct {
    pub fn getEdits(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: *TextModel,
        selections: []const Selection,
        ch: []const u8,
        is_doing_composition: bool,
    ) !?EditOperationResult {
        if (is_doing_composition or !isAutoIndentType(config, model, selections)) return null;

        const indents = try allocator.alloc(?[]u8, selections.len);
        defer {
            for (indents) |*indentation| {
                if (indentation.*) |value| allocator.free(value);
            }
            allocator.free(indents);
        }
        @memset(indents, null);
        for (selections, 0..) |selection, i| {
            indents[i] = try findActualIndentationForSelection(allocator, config, model, selection, ch) orelse return null;
        }

        const commands = try allocator.alloc(?ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        var initialized: usize = 0;
        errdefer {
            for (commands[0..initialized]) |*command| {
                if (command.*) |*value| value.deinit(allocator);
            }
        }
        for (selections, 0..) |selection, i| {
            commands[i] = try editFromIndentationAndSelection(
                allocator,
                config,
                model,
                indents[i].?,
                selection,
                ch,
                true,
            );
            initialized += 1;
        }

        return .{
            .type = .TypingOther,
            .commands = commands,
            .shouldPushStackElementBefore = true,
            .shouldPushStackElementAfter = false,
        };
    }

    fn isAutoIndentType(config: *const CursorConfiguration, model: *TextModel, selections: []const Selection) bool {
        if (@backingInt(config.autoIndent) < @backingInt(EditorAutoIndentStrategy.Full)) return false;
        for (selections) |selection| {
            const position = selection.getEndPosition();
            if (!model.tokenization().isCheapToTokenize(position.lineNumber)) return false;
        }
        return true;
    }

    fn findActualIndentationForSelection(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: *TextModel,
        selection: Selection,
        ch: []const u8,
    ) !?[]u8 {
        const service = config.languageConfigurationService orelse return null;
        var converter = IndentConverter{ .config = config };
        const actual = try auto_indent.getIndentActionForType(
            allocator,
            .{ .autoIndent = config.autoIndent },
            model,
            rangeFromSelection(selection),
            ch,
            converter.interface(),
            service,
        ) orelse return null;
        errdefer allocator.free(actual);

        const current = try language_configuration_registry.getIndentationAtPosition(
            allocator,
            model,
            selection.startLineNumber,
            selection.startColumn,
        );
        defer allocator.free(current);
        const normalized = try config.normalizeIndentation(allocator, current);
        defer allocator.free(normalized);

        if (std.mem.eql(u8, actual, normalized)) {
            allocator.free(actual);
            return null;
        }
        return actual;
    }

    fn editFromIndentationAndSelection(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: *TextModel,
        indentation: []const u8,
        selection: Selection,
        ch: []const u8,
        include_ch: bool,
    ) !ReplaceCommand {
        const start_line_number = selection.startLineNumber;
        const first_non_whitespace_column = model.getLineFirstNonWhitespaceColumn(start_line_number) catch 0;

        var text = ArrayList(u8).init(allocator);
        errdefer text.deinit();

        const normalized = try config.normalizeIndentation(allocator, indentation);
        defer allocator.free(normalized);
        try text.appendSlice(normalized);

        if (first_non_whitespace_column != 0) {
            const line = try model.getLineContent(start_line_number);
            defer line.deinit();
            const start = @min(first_non_whitespace_column - 1, line.items.len);
            const end = @min(selection.startColumn - 1, line.items.len);
            if (end > start) try text.appendSlice(line.items[start..end]);
        }

        if (include_ch) try text.appendSlice(ch);

        return ReplaceCommand.initOwned(
            Range.init(start_line_number, 1, selection.endLineNumber, selection.endColumn),
            try text.toOwnedSlice(),
        );
    }
};

/// Port of `EnterOperation` from
/// `src/vs/editor/common/cursor/cursorTypeEditOperations.ts`.
///
/// The TUI applies the returned replace commands directly; cursor offsets are
/// the terminal equivalent of `ReplaceCommandWithOffsetCursorState`.
pub const EnterOperation = struct {
    pub fn getEdits(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: *TextModel,
        selections: []const Selection,
        ch: []const u8,
        is_doing_composition: bool,
    ) !?EditOperationResult {
        if (is_doing_composition or !std.mem.eql(u8, ch, "\n")) return null;

        const commands = try allocator.alloc(?ReplaceCommand, selections.len);
        errdefer allocator.free(commands);
        var initialized: usize = 0;
        errdefer {
            for (commands[0..initialized]) |*command| {
                if (command.*) |*value| value.deinit(allocator);
            }
        }
        for (selections, 0..) |selection, i| {
            commands[i] = try enter(allocator, config, model, false, rangeFromSelection(selection));
            initialized += 1;
        }

        return .{
            .type = .TypingOther,
            .commands = commands,
            .shouldPushStackElementBefore = true,
            .shouldPushStackElementAfter = false,
        };
    }

    fn enter(
        allocator: Allocator,
        config: *const CursorConfiguration,
        model: *TextModel,
        keep_position: bool,
        range: Range,
    ) !ReplaceCommand {
        const eol = eol_counter.eolToString(model.getEOL());
        if (config.autoIndent == .None) return lineCommand(allocator, range, eol, "");

        const service = config.languageConfigurationService orelse {
            const line = try model.getLineContent(range.startLineNumber);
            defer line.deinit();
            return normalizedLineCommand(allocator, config, range, eol, leadingWhitespaceUpTo(line.items, range.startColumn));
        };

        if (!model.tokenization().isCheapToTokenize(range.startLineNumber) or config.autoIndent == .Keep) {
            const line = try model.getLineContent(range.startLineNumber);
            defer line.deinit();
            return normalizedLineCommand(allocator, config, range, eol, leadingWhitespaceUpTo(line.items, range.startColumn));
        }

        var action = try enter_action.getEnterAction(allocator, config.autoIndent, model, range, service);
        if (action) |*enter_action_value| {
            defer enter_action_value.deinit(allocator);
            switch (enter_action_value.indentAction) {
                .None, .Indent => {
                    const combined = try combinedIndentation(
                        allocator,
                        enter_action_value.indentation,
                        enter_action_value.appendText,
                    );
                    defer allocator.free(combined);
                    const normalized = try config.normalizeIndentation(allocator, combined);
                    defer allocator.free(normalized);
                    return lineCommand(allocator, range, eol, normalized);
                },
                .IndentOutdent => {
                    const normal_indent = try config.normalizeIndentation(allocator, enter_action_value.indentation);
                    defer allocator.free(normal_indent);
                    const combined = try combinedIndentation(
                        allocator,
                        enter_action_value.indentation,
                        enter_action_value.appendText,
                    );
                    defer allocator.free(combined);
                    const increased_indent = try config.normalizeIndentation(allocator, combined);
                    defer allocator.free(increased_indent);

                    var text = ArrayList(u8).init(allocator);
                    errdefer text.deinit();
                    try text.appendSlice(eol);
                    try text.appendSlice(increased_indent);
                    try text.appendSlice(eol);
                    try text.appendSlice(normal_indent);

                    var command = ReplaceCommand.initOwned(range, try text.toOwnedSlice());
                    if (!keep_position) {
                        command.cursor_line_offset = -1;
                        command.cursor_column_offset =
                            @as(isize, @intCast(increased_indent.len)) - @as(isize, @intCast(normal_indent.len));
                    }
                    return command;
                },
                .Outdent => {
                    const actual_indentation = try shift_command.unshiftIndent(
                        allocator,
                        enter_action_value.indentation,
                        enter_action_value.indentation.len + 1,
                        config.tabSize,
                        config.indentSize,
                        config.insertSpaces,
                    );
                    defer allocator.free(actual_indentation);
                    const combined = try combinedIndentation(
                        allocator,
                        actual_indentation,
                        enter_action_value.appendText,
                    );
                    defer allocator.free(combined);
                    const normalized = try config.normalizeIndentation(allocator, combined);
                    defer allocator.free(normalized);
                    return lineCommand(allocator, range, eol, normalized);
                },
            }
        }

        const line = try model.getLineContent(range.startLineNumber);
        defer line.deinit();
        const indentation = leadingWhitespaceUpTo(line.items, range.startColumn);

        if (@backingInt(config.autoIndent) >= @backingInt(EditorAutoIndentStrategy.Full)) {
            var converter = IndentConverter{ .config = config };
            var indent_result = try auto_indent.getIndentForEnter(
                allocator,
                config.autoIndent,
                model,
                range,
                converter.interface(),
                service,
            );
            if (indent_result) |*result| {
                defer result.deinit(allocator);

                var adjusted_range = range;
                var first_non_whitespace: ?usize = null;
                if (!keep_position) {
                    const end_line = try model.getLineContent(range.endLineNumber);
                    defer end_line.deinit();
                    first_non_whitespace = strings.firstNonWhitespaceIndex(end_line.items);
                    const end_column = if (first_non_whitespace) |index|
                        @max(range.endColumn, index + 1)
                    else
                        model.getLineMaxColumn(range.endLineNumber);
                    var range_copy = range;
                    adjusted_range = range_copy.setEndPosition(range.endLineNumber, end_column);
                }

                const normalized = try config.normalizeIndentation(allocator, result.afterEnter);
                defer allocator.free(normalized);
                var command = try lineCommand(allocator, adjusted_range, eol, normalized);

                if (!keep_position) {
                    if (first_non_whitespace) |index| {
                        if (range.endColumn <= index + 1) {
                            const end_line = try model.getLineContent(range.endLineNumber);
                            defer end_line.deinit();
                            var old_end_view_column = CursorColumns.visibleColumnFromColumn(
                                end_line.items,
                                range.endColumn,
                                config.tabSize,
                            );
                            if (!config.insertSpaces) {
                                old_end_view_column = (old_end_view_column + config.indentSize - 1) / config.indentSize;
                            }
                            command.cursor_column_offset = @min(
                                @as(isize, @intCast(old_end_view_column + 1)) -
                                    @as(isize, @intCast(normalized.len)) - 1,
                                0,
                            );
                        }
                    }
                }
                return command;
            }
        }

        return normalizedLineCommand(allocator, config, range, eol, indentation);
    }
};

fn rangeFromSelection(selection: Selection) Range {
    return Range.init(
        selection.startLineNumber,
        selection.startColumn,
        selection.endLineNumber,
        selection.endColumn,
    );
}

test "cursor type edit: typing operation grouping" {
    try std.testing.expectEqual(EditOperationType.TypingFirstSpace, getTypingOperation(" ", .Other));
    try std.testing.expectEqual(EditOperationType.TypingConsecutiveSpace, getTypingOperation(" ", .TypingFirstSpace));
    try std.testing.expectEqual(EditOperationType.TypingOther, getTypingOperation("a", .Other));
    try std.testing.expect(!shouldPushStackElementBetween(.TypingFirstSpace, .TypingConsecutiveSpace));
    try std.testing.expect(shouldPushStackElementBetween(.TypingConsecutiveSpace, .DeletingLeft));
}

test "cursor type edit: type without interceptors" {
    const allocator = std.testing.allocator;
    const selections = [_]Selection{Selection.init(1, 1, 1, 1)};
    var result = try TypeWithoutInterceptorsOperation.getEdits(allocator, .TypingOther, &selections, "x");
    defer result.deinit(allocator);
    try std.testing.expectEqual(EditOperationType.TypingOther, result.type);
    try std.testing.expectEqual(@as(usize, 1), result.commands.len);
    try std.testing.expectEqualStrings("x", result.commands[0].?.text);
}

// Port of `src/vs/editor/common/commands/surroundSelectionCommand.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const position_module = @import("../core/position.zig");
const Position = position_module.Position;
const range_module = @import("../core/range.zig");
const Range = range_module.Range;
const selection_module = @import("../core/selection.zig");
const Selection = selection_module.Selection;

const editor_common = @import("../editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;

/// Wraps the selected text in `charBeforeSelection`/`charAfterSelection` and
/// keeps it selected.
pub const SurroundSelectionCommand = struct {
    range: Selection,
    charBeforeSelection: []const u8,
    charAfterSelection: []const u8,

    pub fn init(range: Selection, char_before_selection: []const u8, char_after_selection: []const u8) SurroundSelectionCommand {
        return .{
            .range = range,
            .charBeforeSelection = char_before_selection,
            .charAfterSelection = char_after_selection,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *SurroundSelectionCommand) ICommand {
        return commandOf(SurroundSelectionCommand).of(self);
    }

    pub fn getEditOperations(self: *const SurroundSelectionCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        try builder.addTrackedEditOperation(Range.init(
            self.range.startLineNumber,
            self.range.startColumn,
            self.range.startLineNumber,
            self.range.startColumn,
        ), self.charBeforeSelection, false);

        // `addTrackedEditOperation` ignores us if the text is empty, which
        // would cause a chain of errors in `computeCursorState`, so an empty
        // `charAfterSelection` is passed as a delete (`null`).
        const char_after: ?[]const u8 = if (self.charAfterSelection.len == 0) null else self.charAfterSelection;
        try builder.addTrackedEditOperation(Range.init(
            self.range.endLineNumber,
            self.range.endColumn,
            self.range.endLineNumber,
            self.range.endColumn,
        ), char_after, false);
    }

    pub fn computeCursorState(self: *const SurroundSelectionCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const first_operation_range = inverse_edit_operations[0].range;
        const second_operation_range = inverse_edit_operations[1].range;

        return Selection.init(
            first_operation_range.endLineNumber,
            first_operation_range.endColumn,
            second_operation_range.endLineNumber,
            second_operation_range.endColumn - self.charAfterSelection.len,
        );
    }
};

/// A surround selection command that runs after composition finished.
pub const CompositionSurroundSelectionCommand = struct {
    position: Position,
    text: []const u8,
    charAfter: []const u8,
    /// Used for the temporary `text + charAfter` buffer.
    allocator: Allocator,

    pub fn init(allocator: Allocator, position: Position, text: []const u8, char_after: []const u8) CompositionSurroundSelectionCommand {
        return .{
            .position = position,
            .text = text,
            .charAfter = char_after,
            .allocator = allocator,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *CompositionSurroundSelectionCommand) ICommand {
        return commandOf(CompositionSurroundSelectionCommand).of(self);
    }

    pub fn getEditOperations(self: *const CompositionSurroundSelectionCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        const text_with_after = try std.mem.concat(self.allocator, u8, &.{ self.text, self.charAfter });
        defer self.allocator.free(text_with_after);

        try builder.addTrackedEditOperation(Range.init(
            self.position.lineNumber,
            self.position.column,
            self.position.lineNumber,
            self.position.column,
        ), text_with_after, false);
    }

    pub fn computeCursorState(self: *const CompositionSurroundSelectionCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const op_range = inverse_edit_operations[0].range;

        return Selection.init(
            op_range.endLineNumber,
            op_range.startColumn,
            op_range.endLineNumber,
            op_range.endColumn - self.charAfter.len,
        );
    }
};

comptime {
    _ = commandOf(SurroundSelectionCommand).of;
    _ = commandOf(CompositionSurroundSelectionCommand).of;
}

test "SurroundSelectionCommand: keeps the selection around the wrapped text" {
    const command = SurroundSelectionCommand.init(Selection.init(1, 3, 1, 7), "(", ")");
    try std.testing.expectEqualStrings("(", command.charBeforeSelection);
    try std.testing.expectEqualStrings(")", command.charAfterSelection);
    try std.testing.expectEqual(@as(usize, 3), command.range.startColumn);
}

test "CompositionSurroundSelectionCommand: appends the trailing character" {
    const command = CompositionSurroundSelectionCommand.init(std.testing.allocator, Position.init(2, 5), "ab", ")");
    try std.testing.expectEqualStrings("ab", command.text);
    try std.testing.expectEqualStrings(")", command.charAfter);
    try std.testing.expectEqual(@as(usize, 1), command.charAfter.len);
}

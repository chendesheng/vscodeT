// Port of `src/vs/editor/common/commands/replaceCommand.ts`.
const std = @import("std");

const position_module = @import("../core/position.zig");
const Position = position_module.Position;
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

const text_model = @import("../model/textModel.zig");
const TextModel = text_model.TextModel;

/// Replaces `range` with `text` and puts the cursor at the end of the replaced
/// range.
pub const ReplaceCommand = struct {
    range: Range,
    text: []const u8,
    insertsAutoWhitespace: bool,

    pub fn init(range: Range, text: []const u8, inserts_auto_whitespace: bool) ReplaceCommand {
        return .{
            .range = range,
            .text = text,
            .insertsAutoWhitespace = inserts_auto_whitespace,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ReplaceCommand) ICommand {
        return commandOf(ReplaceCommand).of(self);
    }

    pub fn getEditOperations(self: *const ReplaceCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        try builder.addTrackedEditOperation(self.range, self.text, false);
    }

    pub fn computeCursorState(self: *const ReplaceCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = self;
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const src_range = inverse_edit_operations[0].range;
        return selection_module.fromPositions(src_range.getEndPosition(), null);
    }
};

/// Replaces `range` with `text`, consuming the characters that follow the
/// range (overtype mode).
pub const ReplaceOvertypeCommand = struct {
    range: Range,
    text: []const u8,
    insertsAutoWhitespace: bool,

    pub fn init(range: Range, text: []const u8, inserts_auto_whitespace: bool) ReplaceOvertypeCommand {
        return .{
            .range = range,
            .text = text,
            .insertsAutoWhitespace = inserts_auto_whitespace,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ReplaceOvertypeCommand) ICommand {
        return commandOf(ReplaceOvertypeCommand).of(self);
    }

    pub fn getEditOperations(self: *const ReplaceOvertypeCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        const initial_start_position = self.range.getStartPosition();
        const initial_end_position = self.range.getEndPosition();
        const initial_end_line_number = initial_end_position.lineNumber;
        const offset_delta: isize = @as(isize, @intCast(self.text.len)) + (if (self.range.isEmpty()) @as(isize, 0) else @as(isize, -1));

        var end_position = try addPositiveOffsetToModelPosition(model, initial_end_position, offset_delta);
        if (end_position.lineNumber > initial_end_line_number) {
            end_position = Position.init(initial_end_line_number, model.getLineMaxColumn(initial_end_line_number));
        }

        const replace_range = range_module.fromPositions(initial_start_position, end_position);
        try builder.addTrackedEditOperation(replace_range, self.text, false);
    }

    pub fn computeCursorState(self: *const ReplaceOvertypeCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = self;
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const src_range = inverse_edit_operations[0].range;
        return selection_module.fromPositions(src_range.getEndPosition(), null);
    }
};

/// Replaces `range` with `text` and selects the replaced text afterwards.
pub const ReplaceCommandThatSelectsText = struct {
    range: Range,
    text: []const u8,

    pub fn init(range: Range, text: []const u8) ReplaceCommandThatSelectsText {
        return .{ .range = range, .text = text };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ReplaceCommandThatSelectsText) ICommand {
        return commandOf(ReplaceCommandThatSelectsText).of(self);
    }

    pub fn getEditOperations(self: *const ReplaceCommandThatSelectsText, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        try builder.addTrackedEditOperation(self.range, self.text, false);
    }

    pub fn computeCursorState(self: *const ReplaceCommandThatSelectsText, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = self;
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const src_range = inverse_edit_operations[0].range;
        return selection_module.fromRange(src_range, .LTR);
    }
};

/// Replaces `range` with `text` and keeps the cursor where it was (at the start
/// of the replaced range).
pub const ReplaceCommandWithoutChangingPosition = struct {
    range: Range,
    text: []const u8,
    insertsAutoWhitespace: bool,

    pub fn init(range: Range, text: []const u8, inserts_auto_whitespace: bool) ReplaceCommandWithoutChangingPosition {
        return .{
            .range = range,
            .text = text,
            .insertsAutoWhitespace = inserts_auto_whitespace,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ReplaceCommandWithoutChangingPosition) ICommand {
        return commandOf(ReplaceCommandWithoutChangingPosition).of(self);
    }

    pub fn getEditOperations(self: *const ReplaceCommandWithoutChangingPosition, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        try builder.addTrackedEditOperation(self.range, self.text, false);
    }

    pub fn computeCursorState(self: *const ReplaceCommandWithoutChangingPosition, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = self;
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const src_range = inverse_edit_operations[0].range;
        return selection_module.fromPositions(src_range.getStartPosition(), null);
    }
};

/// Replaces `range` with `text` and offsets the cursor from the end of the
/// replaced range.
pub const ReplaceCommandWithOffsetCursorState = struct {
    range: Range,
    text: []const u8,
    columnDeltaOffset: isize,
    lineNumberDeltaOffset: isize,
    insertsAutoWhitespace: bool,

    pub fn init(
        range: Range,
        text: []const u8,
        line_number_delta_offset: isize,
        column_delta_offset: isize,
        inserts_auto_whitespace: bool,
    ) ReplaceCommandWithOffsetCursorState {
        return .{
            .range = range,
            .text = text,
            .columnDeltaOffset = column_delta_offset,
            .lineNumberDeltaOffset = line_number_delta_offset,
            .insertsAutoWhitespace = inserts_auto_whitespace,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ReplaceCommandWithOffsetCursorState) ICommand {
        return commandOf(ReplaceCommandWithOffsetCursorState).of(self);
    }

    pub fn getEditOperations(self: *const ReplaceCommandWithOffsetCursorState, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        try builder.addTrackedEditOperation(self.range, self.text, false);
    }

    pub fn computeCursorState(self: *const ReplaceCommandWithOffsetCursorState, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const src_range = inverse_edit_operations[0].range;
        const end_position = src_range.getEndPosition().delta(self.lineNumberDeltaOffset, self.columnDeltaOffset);
        return selection_module.fromPositions(end_position, null);
    }
};

/// Deletes the characters that follow `range`, as a completion of an overtype
/// session that ended with an IME composition.
pub const ReplaceOvertypeCommandOnCompositionEnd = struct {
    range: Range,

    pub fn init(range: Range) ReplaceOvertypeCommandOnCompositionEnd {
        return .{ .range = range };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ReplaceOvertypeCommandOnCompositionEnd) ICommand {
        return commandOf(ReplaceOvertypeCommandOnCompositionEnd).of(self);
    }

    pub fn getEditOperations(self: *const ReplaceOvertypeCommandOnCompositionEnd, model: *TextModel, builder: IEditOperationBuilder) !void {
        var text = try model.getValueInRange(self.range, null);
        defer text.deinit();

        const initial_end_position = self.range.getEndPosition();
        const initial_end_line_number = initial_end_position.lineNumber;
        const offset_delta: isize = @intCast(text.items.len);

        var end_position = try addPositiveOffsetToModelPosition(model, initial_end_position, offset_delta);
        if (end_position.lineNumber > initial_end_line_number) {
            end_position = Position.init(initial_end_line_number, model.getLineMaxColumn(initial_end_line_number));
        }

        const replace_range = range_module.fromPositions(initial_end_position, end_position);
        try builder.addTrackedEditOperation(replace_range, "", false);
    }

    pub fn computeCursorState(self: *const ReplaceOvertypeCommandOnCompositionEnd, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = self;
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        const src_range = inverse_edit_operations[0].range;
        return selection_module.fromPositions(src_range.getEndPosition(), null);
    }
};

/// Replaces `range` with `text` and keeps `initialSelection` selected.
pub const ReplaceCommandThatPreservesSelection = struct {
    range: Range,
    text: []const u8,
    initialSelection: Selection,
    forceMoveMarkers: bool,
    selection_id: ?u64,

    pub fn init(edit_range: Range, text: []const u8, initial_selection: Selection, force_move_markers: bool) ReplaceCommandThatPreservesSelection {
        return .{
            .range = edit_range,
            .text = text,
            .initialSelection = initial_selection,
            .forceMoveMarkers = force_move_markers,
            .selection_id = null,
        };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *ReplaceCommandThatPreservesSelection) ICommand {
        return commandOf(ReplaceCommandThatPreservesSelection).of(self);
    }

    pub fn getEditOperations(self: *ReplaceCommandThatPreservesSelection, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        try builder.addTrackedEditOperation(self.range, self.text, self.forceMoveMarkers);
        self.selection_id = builder.trackSelection(self.initialSelection);
    }

    pub fn computeCursorState(self: *ReplaceCommandThatPreservesSelection, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        return helper.getTrackedSelection(self.selection_id.?);
    }
};

/// Adds `offset` (a character count, never negative) to `position`.
///
/// A negative delta is the sign of a bug: `ReplaceOvertypeCommand` computes
/// `text.length - 1` for a non-empty range, which goes negative when the
/// replacement text is empty.
fn addPositiveOffsetToModelPosition(model: *TextModel, position: Position, offset: isize) !Position {
    if (offset < 0) {
        return error.NegativeDelta;
    }

    const line_count = model.getLineCount();
    var end_position = Position.init(line_count, model.getLineMaxColumn(line_count));
    var remaining_offset = offset;

    var line_number = position.lineNumber;
    while (line_number <= line_count) : (line_number += 1) {
        if (line_number == position.lineNumber) {
            const future_offset = remaining_offset - @as(isize, @intCast(model.getLineMaxColumn(position.lineNumber))) +
                @as(isize, @intCast(position.column));
            if (future_offset <= 0) {
                end_position = Position.init(position.lineNumber, @intCast(@as(isize, @intCast(position.column)) + remaining_offset));
                break;
            }
            remaining_offset = future_offset;
        } else {
            const future_offset = remaining_offset - @as(isize, @intCast(model.getLineMaxColumn(line_number)));
            if (future_offset <= 0) {
                end_position = Position.init(line_number, @intCast(remaining_offset));
                break;
            }
            remaining_offset = future_offset;
        }
    }
    return end_position;
}

// Compile-time checks: every command must satisfy the `ICommand` shape used by
// `commandOf`.
comptime {
    const commands = .{
        ReplaceCommand,
        ReplaceOvertypeCommand,
        ReplaceCommandThatSelectsText,
        ReplaceCommandWithoutChangingPosition,
        ReplaceCommandWithOffsetCursorState,
        ReplaceOvertypeCommandOnCompositionEnd,
        ReplaceCommandThatPreservesSelection,
    };
    for (commands) |Command| {
        _ = commandOf(Command).of;
    }
}

test "ReplaceCommand: cursor lands at the end of the replaced range" {
    const helper_mod = @import("../core/range.zig");
    var command = ReplaceCommand.init(helper_mod.Range.init(1, 1, 1, 4), "abc", false);
    try std.testing.expect(!command.insertsAutoWhitespace);

    const iface = commandOf(ReplaceCommand).of(&command);
    try std.testing.expectEqual(@as(?bool, false), iface.inserts_auto_whitespace);
    try std.testing.expectEqualStrings("abc", command.text);
}

test "ReplaceCommandWithOffsetCursorState: keeps its offsets" {
    var command = ReplaceCommandWithOffsetCursorState.init(Range.init(2, 3, 2, 3), "x", 1, -2, true);
    const iface = commandOf(ReplaceCommandWithOffsetCursorState).of(&command);
    try std.testing.expectEqual(@as(?bool, true), iface.inserts_auto_whitespace);
    try std.testing.expectEqual(@as(isize, 1), command.lineNumberDeltaOffset);
    try std.testing.expectEqual(@as(isize, -2), command.columnDeltaOffset);
}

test "ReplaceCommandThatPreservesSelection: tracks its selection lazily" {
    const command = ReplaceCommandThatPreservesSelection.init(
        Range.init(1, 1, 1, 5),
        "hello",
        Selection.init(1, 2, 1, 4),
        true,
    );
    try std.testing.expectEqual(@as(?u64, null), command.selection_id);
    try std.testing.expect(command.forceMoveMarkers);
}

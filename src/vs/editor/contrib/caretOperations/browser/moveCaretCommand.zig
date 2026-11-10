// Port of `src/vs/editor/contrib/caretOperations/browser/moveCaretCommand.ts`.
const std = @import("std");

const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const editor_common = @import("../../../common/editorCommon.zig");
const ICommand = editor_common.ICommand;
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;

pub const MoveCaretCommand = struct {
    selection: Selection,
    is_moving_left: bool,

    pub fn init(selection: Selection, is_moving_left: bool) MoveCaretCommand {
        return .{ .selection = selection, .is_moving_left = is_moving_left };
    }

    pub fn interface(self: *MoveCaretCommand) ICommand {
        return commandOf(MoveCaretCommand).of(self);
    }

    pub fn getEditOperations(self: *const MoveCaretCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        if (self.selection.startLineNumber != self.selection.endLineNumber or self.selection.isEmpty()) return;

        const line_number = self.selection.startLineNumber;
        const start_column = self.selection.startColumn;
        const end_column = self.selection.endColumn;
        if (self.is_moving_left and start_column == 1) return;
        if (!self.is_moving_left and end_column == model.getLineMaxColumn(line_number)) return;

        if (self.is_moving_left) {
            const range_before = Range.init(line_number, start_column - 1, line_number, start_column);
            const char_before = try model.getValueInRange(range_before, null);
            defer char_before.deinit();
            try builder.addEditOperation(range_before, null, false);
            try builder.addEditOperation(Range.init(line_number, end_column, line_number, end_column), char_before.items, false);
        } else {
            const range_after = Range.init(line_number, end_column, line_number, end_column + 1);
            const char_after = try model.getValueInRange(range_after, null);
            defer char_after.deinit();
            try builder.addEditOperation(range_after, null, false);
            try builder.addEditOperation(Range.init(line_number, start_column, line_number, start_column), char_after.items, false);
        }
    }

    pub fn computeCursorState(self: *const MoveCaretCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        _ = helper;
        const delta: isize = if (self.is_moving_left) -1 else 1;
        return Selection.init(
            self.selection.startLineNumber,
            @intCast(@as(isize, @intCast(self.selection.startColumn)) + delta),
            self.selection.endLineNumber,
            @intCast(@as(isize, @intCast(self.selection.endColumn)) + delta),
        );
    }
};

test "moveCaretCommand: shifts one column" {
    try std.testing.expectEqual(@as(usize, 2), blk: {
        const cmd = MoveCaretCommand.init(Selection.init(1, 3, 1, 5), true);
        const state = try cmd.computeCursorState(undefined, undefined);
        break :blk state.startColumn;
    });
}

const std = @import("std");

// Port of `src/vs/editor/contrib/inPlaceReplace/browser/inPlaceReplaceCommand.ts`.
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const editor_common = @import("../../../common/editorCommon.zig");
const ICommand = editor_common.ICommand;
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;

pub const InPlaceReplaceCommand = struct {
    edit_range: Range,
    original_selection: Selection,
    text: []const u8,

    pub fn init(edit_range: Range, original_selection: Selection, text: []const u8) InPlaceReplaceCommand {
        return .{
            .edit_range = edit_range,
            .original_selection = original_selection,
            .text = text,
        };
    }

    pub fn interface(self: *InPlaceReplaceCommand) ICommand {
        return commandOf(InPlaceReplaceCommand).of(self);
    }

    pub fn getEditOperations(self: *InPlaceReplaceCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        _ = model;
        try builder.addTrackedEditOperation(self.edit_range, self.text, false);
    }

    pub fn computeCursorState(self: *InPlaceReplaceCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        const inverse_edit_operations = helper.getInverseEditOperations();
        if (inverse_edit_operations.len == 0) {
            return self.original_selection;
        }
        const src_range = inverse_edit_operations[0].range;

        if (!self.original_selection.isEmpty()) {
            // Preserve selection and extend to the typed text.
            return Selection.init(
                src_range.endLineNumber,
                src_range.endColumn -| self.text.len,
                src_range.endLineNumber,
                src_range.endColumn,
            );
        }

        return Selection.init(
            src_range.endLineNumber,
            @min(self.original_selection.positionColumn, src_range.endColumn),
            src_range.endLineNumber,
            @min(self.original_selection.positionColumn, src_range.endColumn),
        );
    }
};

test "InPlaceReplaceCommand: exposes the command interface" {
    var command = InPlaceReplaceCommand.init(
        Range.init(1, 1, 1, 5),
        Selection.init(1, 1, 1, 5),
        "false",
    );
    const iface = command.interface();
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&command)), iface.context);
}

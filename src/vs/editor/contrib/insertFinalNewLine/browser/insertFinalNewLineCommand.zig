// Port of `src/vs/editor/contrib/insertFinalNewLine/browser/insertFinalNewLineCommand.ts`.
const std = @import("std");

const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const selection_mod = @import("../../../common/core/selection.zig");
const Selection = selection_mod.Selection;
const edit_operation = @import("../../../common/core/editOperation.zig");
const ISingleEditOperation = edit_operation.ISingleEditOperation;
const eolCounter = @import("../../../common/core/misc/eolCounter.zig");

const editor_common = @import("../../../common/editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;

pub const InsertFinalNewLineCommand = struct {
    selection: Selection,
    selection_id: ?u64 = null,

    pub fn init(selection: Selection) InsertFinalNewLineCommand {
        return .{ .selection = selection };
    }

    /// Type-erased command interface used by the command runner.
    pub fn interface(self: *InsertFinalNewLineCommand) ICommand {
        return commandOf(InsertFinalNewLineCommand).of(self);
    }

    pub fn getEditOperations(self: *InsertFinalNewLineCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        if (insertFinalNewLine(model)) |op| {
            try builder.addEditOperation(op.range, op.text, false);
        }
        self.selection_id = builder.trackSelection(self.selection);
    }

    pub fn computeCursorState(self: *InsertFinalNewLineCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        return helper.getTrackedSelection(self.selection_id.?);
    }
};

/// Generates the edit that appends the model EOL at the end of the buffer.
/// Returns null only when the model cannot describe a final line.
pub fn insertFinalNewLine(model: *TextModel) ?ISingleEditOperation {
    const line_count = model.getLineCount();
    if (line_count == 0) return null;
    return edit_operation.EditOperation.insert(
        Position.init(line_count, model.getLineMaxColumn(line_count)),
        eolCounter.eolToString(model.getEOL()),
    );
}

comptime {
    _ = commandOf(InsertFinalNewLineCommand).of;
}

test "InsertFinalNewLineCommand: inserts the model EOL at the end" {
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    const command_runner = @import("../../../common/commands/commandRunner.zig");

    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "hello", "nullLanguage");
    defer ctx.deinit();

    var command = InsertFinalNewLineCommand.init(Selection.init(1, 3, 1, 3));
    const selections = try command_runner.executeCommands(
        allocator,
        ctx.model,
        &[_]?editor_common.ICommand{command.interface()},
        &[_]Selection{Selection.init(1, 3, 1, 3)},
    );
    defer if (selections) |value| allocator.free(value);

    const value = try ctx.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("hello\n", value.items);
    try std.testing.expect(selections != null);
}

// Port of `src/vs/editor/contrib/linesOperations/browser/moveLinesCommand.ts`.
//
// Only the plain line-move path is ported. VS Code's `Full` auto-indent branch
// needs the virtual indentation model and is intentionally left for the
// indentation contribution batch.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Range = @import("../../../common/core/range.zig").Range;
const selection_mod = @import("../../../common/core/selection.zig");
const Selection = selection_mod.Selection;

const editor_options = @import("../../../common/config/editorOptions.zig");
const EditorAutoIndentStrategy = editor_options.EditorAutoIndentStrategy;

const editor_common = @import("../../../common/editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;

pub const MoveLinesCommand = struct {
    allocator: Allocator,
    selection: Selection,
    is_moving_down: bool,
    auto_indent: EditorAutoIndentStrategy,

    selection_id: ?u64 = null,
    move_end_position_down: bool = false,
    move_end_line_selection_shrink: bool = false,

    pub fn init(
        allocator: Allocator,
        selection: Selection,
        is_moving_down: bool,
        auto_indent: EditorAutoIndentStrategy,
    ) MoveLinesCommand {
        return .{
            .allocator = allocator,
            .selection = selection,
            .is_moving_down = is_moving_down,
            .auto_indent = auto_indent,
        };
    }

    fn withEndPosition(selection: Selection, endLineNumber: usize, endColumn: usize) Selection {
        if (selection.getDirection() == .LTR) {
            return Selection.init(selection.startLineNumber, selection.startColumn, endLineNumber, endColumn);
        }
        return Selection.init(endLineNumber, endColumn, selection.startLineNumber, selection.startColumn);
    }

    pub fn getEditOperations(self: *MoveLinesCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        // The full virtual-model indentation path is not ported yet. All
        // strategies behave like upstream's non-`Full` line move.
        _ = self.auto_indent;

        const model_line_count = model.getLineCount();

        if (self.is_moving_down and self.selection.endLineNumber == model_line_count) {
            self.selection_id = builder.trackSelection(self.selection);
            return;
        }
        if (!self.is_moving_down and self.selection.startLineNumber == 1) {
            self.selection_id = builder.trackSelection(self.selection);
            return;
        }

        self.move_end_position_down = false;
        var s = self.selection;

        if (s.startLineNumber < s.endLineNumber and s.endColumn == 1) {
            self.move_end_position_down = true;
            s = withEndPosition(s, s.endLineNumber - 1, model.getLineMaxColumn(s.endLineNumber - 1));
        }

        if (s.startLineNumber == s.endLineNumber and model.getLineMaxColumn(s.startLineNumber) == 1) {
            const line_number = s.startLineNumber;
            const other_line_number = if (self.is_moving_down) line_number + 1 else line_number - 1;

            if (model.getLineMaxColumn(other_line_number) == 1) {
                // Both lines are empty. Upstream adds a no-op to force the
                // command to run; our command runner can simply do nothing.
            } else {
                const other_line = try model.getLineContent(other_line_number);
                defer other_line.deinit();

                try builder.addEditOperation(Range.init(line_number, 1, line_number, 1), other_line.items, false);
                try builder.addEditOperation(
                    Range.init(other_line_number, 1, other_line_number, model.getLineMaxColumn(other_line_number)),
                    null,
                    false,
                );
            }
            s = Selection.init(other_line_number, 1, other_line_number, 1);
        } else if (self.is_moving_down) {
            const moving_line_number = s.endLineNumber + 1;
            const moving_line = try model.getLineContent(moving_line_number);
            defer moving_line.deinit();

            try builder.addEditOperation(
                Range.init(
                    moving_line_number - 1,
                    model.getLineMaxColumn(moving_line_number - 1),
                    moving_line_number,
                    model.getLineMaxColumn(moving_line_number),
                ),
                null,
                false,
            );

            var insertion = ArrayList(u8).init(self.allocator);
            defer insertion.deinit();
            try insertion.appendSlice(moving_line.items);
            try insertion.append('\n');
            try builder.addEditOperation(Range.init(s.startLineNumber, 1, s.startLineNumber, 1), insertion.items, false);
        } else {
            const moving_line_number = s.startLineNumber - 1;
            const moving_line = try model.getLineContent(moving_line_number);
            defer moving_line.deinit();

            try builder.addEditOperation(
                Range.init(moving_line_number, 1, moving_line_number + 1, 1),
                null,
                false,
            );

            var insertion = ArrayList(u8).init(self.allocator);
            defer insertion.deinit();
            try insertion.append('\n');
            try insertion.appendSlice(moving_line.items);
            try builder.addEditOperation(
                Range.init(
                    s.endLineNumber,
                    model.getLineMaxColumn(s.endLineNumber),
                    s.endLineNumber,
                    model.getLineMaxColumn(s.endLineNumber),
                ),
                insertion.items,
                false,
            );
        }

        self.selection_id = builder.trackSelection(s);
    }

    pub fn computeCursorState(self: *MoveLinesCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        var result = helper.getTrackedSelection(self.selection_id orelse return self.selection);

        if (self.move_end_position_down) {
            result = withEndPosition(result, result.endLineNumber + 1, 1);
        }

        if (self.move_end_line_selection_shrink and result.startLineNumber < result.endLineNumber) {
            result = withEndPosition(result, result.endLineNumber, 2);
        }

        return result;
    }
};

comptime {
    _ = commandOf(MoveLinesCommand).of;
}

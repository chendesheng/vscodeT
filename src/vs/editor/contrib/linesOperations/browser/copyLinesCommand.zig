// Port of `src/vs/editor/contrib/linesOperations/browser/copyLinesCommand.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Range = @import("../../../common/core/range.zig").Range;
const selection_mod = @import("../../../common/core/selection.zig");
const Selection = selection_mod.Selection;
const SelectionDirection = selection_mod.SelectionDirection;

const editor_common = @import("../../../common/editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;

pub const CopyLinesCommand = struct {
    allocator: Allocator,
    selection: Selection,
    is_copying_down: bool,
    noop: bool,
    selection_direction: SelectionDirection = .LTR,
    selection_id: ?u64 = null,
    start_line_number_delta: isize = 0,
    end_line_number_delta: isize = 0,

    pub fn init(allocator: Allocator, selection: Selection, is_copying_down: bool, noop: bool) CopyLinesCommand {
        return .{
            .allocator = allocator,
            .selection = selection,
            .is_copying_down = is_copying_down,
            .noop = noop,
        };
    }

    fn withEndPosition(selection: Selection, endLineNumber: usize, endColumn: usize) Selection {
        if (selection.getDirection() == .LTR) {
            return Selection.init(selection.startLineNumber, selection.startColumn, endLineNumber, endColumn);
        }
        return Selection.init(endLineNumber, endColumn, selection.startLineNumber, selection.startColumn);
    }

    pub fn getEditOperations(self: *CopyLinesCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        var s = self.selection;

        self.start_line_number_delta = 0;
        self.end_line_number_delta = 0;
        if (s.startLineNumber < s.endLineNumber and s.endColumn == 1) {
            self.end_line_number_delta = 1;
            s = withEndPosition(s, s.endLineNumber - 1, model.getLineMaxColumn(s.endLineNumber - 1));
        }

        var source_text = ArrayList(u8).init(self.allocator);
        defer source_text.deinit();
        var line_number = s.startLineNumber;
        while (line_number <= s.endLineNumber) : (line_number += 1) {
            if (line_number > s.startLineNumber) try source_text.append('\n');
            const line = try model.getLineContent(line_number);
            defer line.deinit();
            try source_text.appendSlice(line.items);
        }

        if (source_text.items.len == 0 and self.is_copying_down) {
            self.start_line_number_delta += 1;
            self.end_line_number_delta += 1;
        }

        if (self.noop) {
            const end_column = model.getLineMaxColumn(s.endLineNumber);
            const text: []const u8 = if (s.endLineNumber == model.getLineCount()) "" else "\n";
            try builder.addEditOperation(
                Range.init(s.endLineNumber, end_column, s.endLineNumber + 1, 1),
                text,
                false,
            );
        } else if (!self.is_copying_down) {
            var insertion = ArrayList(u8).init(self.allocator);
            defer insertion.deinit();
            try insertion.append('\n');
            try insertion.appendSlice(source_text.items);
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
        } else {
            var insertion = ArrayList(u8).init(self.allocator);
            defer insertion.deinit();
            try insertion.appendSlice(source_text.items);
            try insertion.append('\n');
            try builder.addEditOperation(
                Range.init(s.startLineNumber, 1, s.startLineNumber, 1),
                insertion.items,
                false,
            );
        }

        self.selection_id = builder.trackSelection(s);
        self.selection_direction = s.getDirection();
    }

    pub fn computeCursorState(self: *CopyLinesCommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        _ = model;
        var result = helper.getTrackedSelection(self.selection_id orelse return self.selection);

        if (self.start_line_number_delta != 0 or self.end_line_number_delta != 0) {
            var start_line = result.startLineNumber;
            var start_column = result.startColumn;
            var end_line = result.endLineNumber;
            var end_column = result.endColumn;

            if (self.start_line_number_delta != 0) {
                start_line = @intCast(@as(isize, @intCast(start_line)) + self.start_line_number_delta);
                start_column = 1;
            }
            if (self.end_line_number_delta != 0) {
                end_line = @intCast(@as(isize, @intCast(end_line)) + self.end_line_number_delta);
                end_column = 1;
            }

            result = selection_mod.createWithDirection(start_line, start_column, end_line, end_column, self.selection_direction);
        }

        return result;
    }
};

comptime {
    _ = commandOf(CopyLinesCommand).of;
}

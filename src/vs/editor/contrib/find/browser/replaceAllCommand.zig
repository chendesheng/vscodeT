// Port of `src/vs/editor/contrib/find/browser/replaceAllCommand.ts`.

const std = @import("std");
const range_module = @import("../../../common/core/range.zig");
const Range = range_module.Range;
const Selection = @import("../../../common/core/selection.zig").Selection;

const editor_common = @import("../../../common/editorCommon.zig");
const ICursorStateComputerData = editor_common.ICursorStateComputerData;
const IEditOperationBuilder = editor_common.IEditOperationBuilder;
const ICommand = editor_common.ICommand;
const commandOf = editor_common.commandOf;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;

const EditOperation = struct {
    range: Range,
    text: []const u8,
};

pub const ReplaceAllCommand = struct {
    editor_selection: Selection,
    ranges: []const Range,
    replace_strings: []const []const u8,
    tracked_editor_selection_id: u64 = 0,

    pub fn init(
        editor_selection: Selection,
        ranges: []const Range,
        replace_strings: []const []const u8,
    ) ReplaceAllCommand {
        return .{
            .editor_selection = editor_selection,
            .ranges = ranges,
            .replace_strings = replace_strings,
        };
    }

    pub fn interface(self: *ReplaceAllCommand) ICommand {
        return commandOf(ReplaceAllCommand).of(self);
    }

    pub fn getEditOperations(self: *ReplaceAllCommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        if (self.ranges.len > 0) {
            const allocator = model.getAllocator();
            const operations = try allocator.alloc(EditOperation, self.ranges.len);
            defer allocator.free(operations);

            for (self.ranges, 0..) |range, index| {
                operations[index] = .{ .range = range, .text = self.replace_strings[index] };
            }
            std.mem.sort(EditOperation, operations, {}, lessThanByStart);

            // Adjacent ranges are non-overlapping and may be passed as separate
            // operations; merging them (as the browser command does) would need
            // concatenated strings that outlive `getEditOperations`.
            for (operations) |operation| {
                try builder.addEditOperation(operation.range, operation.text, false);
            }
        }

        self.tracked_editor_selection_id = builder.trackSelection(self.editor_selection);
    }

    pub fn computeCursorState(self: *const ReplaceAllCommand, model: *TextModel, helper: ICursorStateComputerData) Selection {
        _ = model;
        return helper.getTrackedSelection(self.tracked_editor_selection_id);
    }
};

fn lessThanByStart(_: void, a: EditOperation, b: EditOperation) bool {
    return range_module.compareRangesUsingStarts(&a.range, &b.range) < 0;
}

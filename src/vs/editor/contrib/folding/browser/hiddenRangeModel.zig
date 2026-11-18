// Port of `src/vs/editor/contrib/folding/browser/hiddenRangeModel.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const FoldingModel = @import("./foldingModel.zig").FoldingModel;

pub const HiddenRangeModel = struct {
    allocator: Allocator,
    folding_model: *FoldingModel,
    hidden_ranges: ArrayList(Range),
    has_line_changes: bool = false,

    pub fn init(allocator: Allocator, folding_model: *FoldingModel) HiddenRangeModel {
        return .{
            .allocator = allocator,
            .folding_model = folding_model,
            .hidden_ranges = ArrayList(Range).init(allocator),
        };
    }

    /// Call after the HiddenRangeModel has been placed at its final address.
    pub fn listen(self: *HiddenRangeModel) void {
        self.folding_model.setListener(self, updateFromListener);
        self.updateHiddenRanges();
    }

    pub fn deinit(self: *HiddenRangeModel) void {
        self.hidden_ranges.deinit();
    }

    fn updateFromListener(context: *anyopaque) void {
        const self: *HiddenRangeModel = @ptrCast(@alignCast(context));
        self.updateHiddenRanges();
    }

    pub fn updateHiddenRanges(self: *HiddenRangeModel) void {
        const regions = if (self.folding_model.regions) |*r| r else {
            self.hidden_ranges.clearRetainingCapacity();
            return;
        };
        var new_ranges = ArrayList(Range).init(self.allocator);
        defer new_ranges.deinit();

        var last_collapsed_start: usize = std.math.maxInt(usize);
        var last_collapsed_end: usize = 0;
        for (0..regions.length()) |i| {
            if (!regions.isCollapsed(i)) continue;
            const start_line = regions.getStartLineNumber(i) + 1;
            const end_line = regions.getEndLineNumber(i);
            if (last_collapsed_start <= start_line and end_line <= last_collapsed_end) continue;
            new_ranges.append(Range.init(start_line, 1, end_line, 1)) catch return;
            last_collapsed_start = start_line;
            last_collapsed_end = end_line;
        }

        self.hidden_ranges.clearRetainingCapacity();
        self.hidden_ranges.appendSlice(new_ranges.items) catch return;
        self.has_line_changes = false;
    }

    pub fn hasRanges(self: *const HiddenRangeModel) bool {
        return self.hidden_ranges.items.len > 0;
    }

    fn findRange(self: *const HiddenRangeModel, line: usize) ?Range {
        for (self.hidden_ranges.items, 0..) |range, i| {
            if (line < range.startLineNumber) {
                if (i == 0) return null;
                const previous = self.hidden_ranges.items[i - 1];
                return if (previous.endLineNumber >= line) previous else null;
            }
        }
        if (self.hidden_ranges.items.len > 0) {
            const last = self.hidden_ranges.items[self.hidden_ranges.items.len - 1];
            if (last.endLineNumber >= line) return last;
        }
        return null;
    }

    pub fn isHidden(self: *const HiddenRangeModel, line: usize) bool {
        return self.findRange(line) != null;
    }

    pub fn adjustSelections(self: *HiddenRangeModel, selections: []Selection) bool {
        var changed = false;
        for (selections) |*selection| {
            var hidden_line: ?usize = null;
            if (self.findRange(selection.startLineNumber)) |range| {
                hidden_line = range.startLineNumber - 1;
            }
            if (self.findRange(selection.endLineNumber)) |range| {
                hidden_line = range.startLineNumber - 1;
            }
            if (hidden_line) |line| {
                selection.* = Selection.init(line, 1, line, 1);
                changed = true;
            }
        }
        return changed;
    }

    pub fn notifyChangeModelContent(self: *HiddenRangeModel, has_line_changes: bool) void {
        if (self.hidden_ranges.items.len > 0 and !self.has_line_changes) self.has_line_changes = has_line_changes;
    }
};

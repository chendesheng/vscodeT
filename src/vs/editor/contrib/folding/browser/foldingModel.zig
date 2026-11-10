// Reduced port of `src/vs/editor/contrib/folding/browser/foldingModel.ts`.
// The decoration/editor-facing pieces are not portable; the region state and
// collapse transitions are kept here.
const std = @import("std");
const Allocator = std.mem.Allocator;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const folding_ranges = @import("./foldingRanges.zig");
const FoldingRegions = folding_ranges.FoldingRegions;

pub const FoldingModel = struct {
    allocator: Allocator,
    text_model: *TextModel,
    regions: ?FoldingRegions = null,
    on_change: ?struct { context: *anyopaque, callback: *const fn (*anyopaque) void } = null,

    pub fn init(allocator: Allocator, text_model: *TextModel) FoldingModel {
        return .{ .allocator = allocator, .text_model = text_model };
    }

    pub fn deinit(self: *FoldingModel) void {
        if (self.regions) |*regions| regions.deinit();
    }

    pub fn setListener(self: *FoldingModel, context: *anyopaque, callback: *const fn (*anyopaque) void) void {
        self.on_change = .{ .context = context, .callback = callback };
    }

    fn fireChange(self: *FoldingModel) void {
        if (self.on_change) |listener| listener.callback(listener.context);
    }

    /// Takes ownership of `regions`.
    pub fn update(self: *FoldingModel, regions: FoldingRegions) void {
        if (self.regions) |*old| old.deinit();
        self.regions = regions;
        self.fireChange();
    }

    pub fn getRegionAtLine(self: *FoldingModel, line: usize) ?usize {
        const regions = if (self.regions) |*r| r else return null;
        const index = regions.findRange(line) catch return null;
        if (index < 0) return null;
        return @intCast(index);
    }

    pub fn toggleCollapseState(self: *FoldingModel, indexes: []const usize) void {
        const regions = if (self.regions) |*r| r else return;
        for (indexes) |index| {
            if (index < regions.length()) regions.setCollapsed(index, !regions.isCollapsed(index));
        }
        self.fireChange();
    }

    pub fn collapseAll(self: *FoldingModel) void {
        const regions = if (self.regions) |*r| r else return;
        for (0..regions.length()) |i| regions.setCollapsed(i, true);
        self.fireChange();
    }

    pub fn expandAll(self: *FoldingModel) void {
        const regions = if (self.regions) |*r| r else return;
        for (0..regions.length()) |i| regions.setCollapsed(i, false);
        self.fireChange();
    }
};

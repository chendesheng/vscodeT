// Port of the model-facing part of
// `src/vs/editor/contrib/folding/browser/foldingModel.ts`.
//
// The browser class also owns decorations through its `IDecorationProvider`.
// Cells render the folding controls from the regions directly, so that layer
// is intentionally absent; region state, collapse transitions, merging with
// the previous folded ranges and the region queries are kept here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Selection = @import("../../../common/core/selection.zig").Selection;
const folding_ranges = @import("./foldingRanges.zig");
const FoldingRegions = folding_ranges.FoldingRegions;
const FoldRange = folding_ranges.FoldRange;
const FoldSource = folding_ranges.FoldSource;
const SelectedLines = folding_ranges.SelectedLines;

pub const FoldingRegion = struct {
    regionIndex: usize,
    startLineNumber: usize,
    endLineNumber: usize,
    type: ?[]const u8,
    isCollapsed: bool,
    source: FoldSource,
    parentIndex: isize,

    pub fn containsLine(self: FoldingRegion, line: usize) bool {
        return self.startLineNumber <= line and line <= self.endLineNumber;
    }

    pub fn containedBy(self: FoldingRegion, other: FoldingRegion) bool {
        return other.startLineNumber <= self.startLineNumber and
            self.endLineNumber <= other.endLineNumber;
    }
};

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

    /// Takes ownership of `regions`, preserving the previously folded and
    /// manually created ranges, like upstream `FoldingModel.update`.
    pub fn update(self: *FoldingModel, regions: FoldingRegions) !void {
        try self.updateWithSelection(regions, null);
    }

    /// Takes ownership of `regions`. `selection` is used to avoid restoring a
    /// collapsed range that would hide the caret, like upstream
    /// `toSelectedLines`/`sanitizeAndMerge`.
    pub fn updateWithSelection(self: *FoldingModel, regions: FoldingRegions, selection: ?[]const Selection) !void {
        var incoming = regions;
        defer incoming.deinit();

        var folded = ArrayList(FoldRange).init(self.allocator);
        defer folded.deinit();
        if (self.regions) |*old| {
            for (0..old.length()) |index| {
                const source = old.getSource(index);
                if (!old.isCollapsed(index) and source == .provider) continue;
                const fold_range = old.toFoldRange(index);
                // A provider range that moved to another start line (for
                // example after inserting a line above the fold) cannot be
                // matched reliably without upstream's tracked decorations.
                // Drop the stale collapsed range instead of duplicating it;
                // manual ranges are kept because no provider owns them.
                if (source == .provider) {
                    const provider_index = incoming.findRange(fold_range.startLineNumber) catch -1;
                    if (provider_index < 0 or
                        incoming.getStartLineNumber(@intCast(provider_index)) != fold_range.startLineNumber)
                    {
                        continue;
                    }
                }
                try folded.append(fold_range);
            }
        }

        const selected = if (selection) |selections| SelectedLines{ .selections = selections } else null;
        const merged = try folding_ranges.sanitizeAndMerge(
            self.allocator,
            .{ .regions = &incoming },
            .{ .ranges = folded.items },
            self.text_model.getLineCount(),
            selected,
        );
        defer self.allocator.free(merged);

        const new_regions = try FoldingRegions.fromFoldRanges(self.allocator, merged);
        self.updatePost(new_regions);
    }

    /// Replaces the regions without merging, like upstream `updatePost`.
    /// Takes ownership of `regions`.
    pub fn updatePost(self: *FoldingModel, regions: FoldingRegions) void {
        if (self.regions) |*old| old.deinit();
        self.regions = regions;
        self.fireChange();
    }

    pub fn length(self: *const FoldingModel) usize {
        const regions = if (self.regions) |*r| r else return 0;
        return regions.length();
    }

    /// The region at `index`, with its cached parent index.
    pub fn getRegion(self: *FoldingModel, index: usize) ?FoldingRegion {
        const regions = if (self.regions) |*r| r else return null;
        if (index >= regions.length()) return null;
        return .{
            .regionIndex = index,
            .startLineNumber = regions.getStartLineNumber(index),
            .endLineNumber = regions.getEndLineNumber(index),
            .type = regions.getType(index),
            .isCollapsed = regions.isCollapsed(index),
            .source = regions.getSource(index),
            .parentIndex = regions.getParentIndex(index) catch -1,
        };
    }

    /// Port of `FoldingModel.getRegionAtLine`.
    pub fn getRegionAtLine(self: *FoldingModel, line: usize) ?FoldingRegion {
        const regions = if (self.regions) |*r| r else return null;
        const index = regions.findRange(line) catch return null;
        if (index < 0) return null;
        return self.getRegion(@intCast(index));
    }

    /// Port of `FoldingModel.getAllRegionsAtLine`: the innermost region that
    /// contains the line followed by its parents.
    pub fn getAllRegionsAtLine(self: *FoldingModel, line: usize) ![]FoldingRegion {
        const regions = if (self.regions) |*r| r else return self.allocator.alloc(FoldingRegion, 0);
        var result = ArrayList(FoldingRegion).init(self.allocator);
        errdefer result.deinit();
        var index = try regions.findRange(line);
        while (index >= 0) {
            const region = self.getRegion(@intCast(index)) orelse break;
            try result.append(region);
            index = region.parentIndex;
        }
        return try result.toOwnedSlice();
    }

    /// Regions strictly inside `parent` (or all regions when `parent` is
    /// null), at most `levels` levels below it. `levels` is relative to the
    /// parent, matching the filter used by the folding actions.
    pub fn getRegionsInside(self: *FoldingModel, parent: ?FoldingRegion, levels: usize) ![]FoldingRegion {
        const regions = if (self.regions) |*r| r else return self.allocator.alloc(FoldingRegion, 0);
        var result = ArrayList(FoldingRegion).init(self.allocator);
        errdefer result.deinit();

        const start_index = if (parent) |p| p.regionIndex + 1 else 0;
        const end_line = if (parent) |p| p.endLineNumber else std.math.maxInt(usize);
        var index = start_index;
        while (index < regions.length()) : (index += 1) {
            if (regions.getStartLineNumber(index) >= end_line) break;
            const region = self.getRegion(index) orelse continue;
            if (parent) |p| {
                var level: usize = 1;
                var current = region;
                while (current.parentIndex != @as(isize, @intCast(p.regionIndex))) {
                    if (current.parentIndex < 0) break;
                    level += 1;
                    current = self.getRegion(@intCast(current.parentIndex)) orelse break;
                }
                if (current.regionIndex != p.regionIndex) continue;
                if (level > levels) continue;
            }
            try result.append(region);
        }
        return try result.toOwnedSlice();
    }

    pub fn toggleCollapseState(self: *FoldingModel, indexes: []const usize) void {
        const regions = if (self.regions) |*r| r else return;
        for (indexes) |index| {
            if (index < regions.length()) regions.setCollapsed(index, !regions.isCollapsed(index));
        }
        self.fireChange();
    }

    pub fn setCollapsed(self: *FoldingModel, indexes: []const usize, collapsed: bool) void {
        const regions = if (self.regions) |*r| r else return;
        for (indexes) |index| {
            if (index < regions.length() and regions.isCollapsed(index) != collapsed) {
                regions.setCollapsed(index, collapsed);
            }
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

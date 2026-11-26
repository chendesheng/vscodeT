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

/// Portable representation of the upstream CollapseMemento. Checksums are
/// optional for older persisted data; a missing checksum restores by range.
pub const ILineMemento = struct {
    startLineNumber: usize,
    endLineNumber: usize,
    isCollapsed: bool = true,
    source: FoldSource = .provider,
    checksum: ?i32 = null,
};

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

    /// Port of `toggleCollapseState(foldingModel, levels, lineNumbers)`.
    pub fn toggleCollapseStateLevels(self: *FoldingModel, levels: usize, line_numbers: []const usize) !void {
        var indexes = ArrayList(usize).init(self.allocator);
        defer indexes.deinit();
        for (line_numbers) |line| {
            const region = self.getRegionAtLine(line) orelse continue;
            const collapse = !region.isCollapsed;
            try indexes.append(region.regionIndex);
            if (levels > 1) {
                const inside = try self.getRegionsInside(region, levels - 1);
                defer self.allocator.free(inside);
                for (inside) |child| {
                    if (child.isCollapsed != collapse) try indexes.append(child.regionIndex);
                }
            }
        }
        self.toggleCollapseState(indexes.items);
    }

    /// Port of `setCollapseStateLevelsDown`: collapse/expand the region at
    /// each line and its descendants up to `levels`.
    pub fn setCollapseStateLevelsDown(
        self: *FoldingModel,
        collapse: bool,
        levels: usize,
        line_numbers: []const usize,
    ) !void {
        var indexes = ArrayList(usize).init(self.allocator);
        defer indexes.deinit();
        for (line_numbers) |line| {
            const region = self.getRegionAtLine(line) orelse continue;
            if (region.isCollapsed != collapse) try indexes.append(region.regionIndex);
            if (levels > 1) {
                const inside = try self.getRegionsInside(region, levels - 1);
                defer self.allocator.free(inside);
                for (inside) |child| {
                    if (child.isCollapsed != collapse) try indexes.append(child.regionIndex);
                }
            }
        }
        self.setCollapsed(indexes.items, collapse);
    }

    /// Port of `setCollapseStateLevelsUp`: collapse/expand the parents of each
    /// line up to `levels`, including the region at the line.
    pub fn setCollapseStateLevelsUp(
        self: *FoldingModel,
        collapse: bool,
        levels: usize,
        line_numbers: []const usize,
    ) !void {
        var indexes = ArrayList(usize).init(self.allocator);
        defer indexes.deinit();
        for (line_numbers) |line| {
            const regions = try self.getAllRegionsAtLine(line);
            defer self.allocator.free(regions);
            for (regions, 0..) |region, level| {
                if (level + 1 > levels) break;
                if (region.isCollapsed != collapse) try indexes.append(region.regionIndex);
            }
        }
        self.setCollapsed(indexes.items, collapse);
    }

    /// Port of `setCollapseStateUp`: toggle the innermost matching region at
    /// each line, falling back to the first matching parent.
    pub fn setCollapseStateUp(self: *FoldingModel, collapse: bool, line_numbers: []const usize) !void {
        var indexes = ArrayList(usize).init(self.allocator);
        defer indexes.deinit();
        for (line_numbers) |line| {
            const regions = try self.getAllRegionsAtLine(line);
            defer self.allocator.free(regions);
            for (regions) |region| {
                if (region.isCollapsed != collapse) {
                    try indexes.append(region.regionIndex);
                    break;
                }
            }
        }
        self.setCollapsed(indexes.items, collapse);
    }

    /// Port of `FoldRangeFromSelectionAction`: merge manual user-defined
    /// collapsed ranges into the current model.
    pub fn addManualRanges(self: *FoldingModel, ranges: []const FoldRange) !void {
        const current = if (self.regions) |*regions| regions else null;
        const new_regions = try folding_ranges.sanitizeAndMerge(
            self.allocator,
            if (current) |regions| .{ .regions = regions } else .{ .ranges = &.{} },
            .{ .ranges = ranges },
            self.text_model.getLineCount(),
            null,
        );
        defer self.allocator.free(new_regions);
        const merged = try FoldingRegions.fromFoldRanges(self.allocator, new_regions);
        self.updatePost(merged);
    }

    /// Port of `FoldingModel.removeManualRanges`: remove user-defined ranges
    /// selected by the cursors, while keeping every provider range.
    pub fn removeManualRanges(self: *FoldingModel, ranges: []const Selection) !void {
        const regions = if (self.regions) |*r| r else return;
        var remove_indexes = std.AutoHashMap(usize, void).init(self.allocator);
        defer remove_indexes.deinit();
        var remove_all = false;
        for (ranges) |range| {
            if (!range.isEmpty()) continue;
            var index = regions.findRange(range.startLineNumber) catch -1;
            while (index != -1 and regions.getSource(@intCast(index)) == .provider) {
                index = regions.getParentIndex(@intCast(index)) catch -1;
            }
            if (index == -1) {
                remove_all = true;
            } else {
                try remove_indexes.put(@intCast(index), {});
            }
        }
        const intersects = struct {
            fn call(selection_ranges: []const Selection, fold_range: FoldRange) bool {
                for (selection_ranges) |selection| {
                    if (selection.isEmpty()) continue;
                    if (selection.startLineNumber <= fold_range.endLineNumber and
                        fold_range.startLineNumber <= selection.endLineNumber)
                    {
                        return true;
                    }
                }
                return false;
            }
        }.call;

        var kept = ArrayList(FoldRange).init(self.allocator);
        defer kept.deinit();
        for (0..regions.length()) |index| {
            const fold_range = regions.toFoldRange(index);
            if (fold_range.source == .provider) {
                try kept.append(fold_range);
                continue;
            }
            if (remove_all or remove_indexes.contains(index) or intersects(ranges, fold_range)) continue;
            try kept.append(fold_range);
        }
        const merged = try FoldingRegions.fromFoldRanges(self.allocator, kept.items);
        self.updatePost(merged);
    }

    pub fn getMemento(self: *FoldingModel, allocator: Allocator) ![]ILineMemento {
        var result: std.ArrayList(ILineMemento) = .empty;
        errdefer result.deinit(allocator);
        if (self.regions) |*regions| for (0..regions.length()) |index| {
            const range = regions.toFoldRange(index);
            if (!range.isCollapsed and range.source == .provider) continue;
            if (range.startLineNumber < 1 or range.startLineNumber >= range.endLineNumber or range.endLineNumber > self.text_model.getLineCount()) continue;
            try result.append(allocator, .{
                .startLineNumber = range.startLineNumber,
                .endLineNumber = range.endLineNumber,
                .isCollapsed = range.isCollapsed,
                .source = range.source,
                .checksum = try self.getLinesChecksum(range.startLineNumber + 1, range.endLineNumber),
            });
        };
        return result.toOwnedSlice(allocator);
    }

    pub fn applyMemento(self: *FoldingModel, state: []const ILineMemento) !void {
        var ranges: std.ArrayList(FoldRange) = .empty;
        defer ranges.deinit(self.allocator);
        const max_line = self.text_model.getLineCount();
        for (state) |range| {
            if (range.startLineNumber < 1 or range.startLineNumber >= range.endLineNumber or range.endLineNumber > max_line) continue;
            const checksum = try self.getLinesChecksum(range.startLineNumber + 1, range.endLineNumber);
            if (range.checksum) |stored| if (stored != 0 and stored != checksum) continue;
            try ranges.append(self.allocator, .{ .startLineNumber = range.startLineNumber, .endLineNumber = range.endLineNumber, .isCollapsed = range.isCollapsed, .source = range.source });
        }
        const existing: folding_ranges.RangeInput = if (self.regions) |*regions| .{ .regions = regions } else .{ .ranges = &.{} };
        const merged = try folding_ranges.sanitizeAndMerge(self.allocator, existing, .{ .ranges = ranges.items }, max_line, null);
        defer self.allocator.free(merged);
        self.updatePost(try FoldingRegions.fromFoldRanges(self.allocator, merged));
    }

    fn getLinesChecksum(self: *FoldingModel, first: usize, last: usize) !i32 {
        const hash = @import("../../../../base/common/hash.zig");
        // JS hashes UTF-16 code units, while the text model stores UTF-8.
        var value = hash.numberHash(149417, 0);
        for ([_]usize{ first, last }) |line| {
            var content = try self.text_model.getLineContent(line);
            defer content.deinit();
            var iter = std.unicode.Utf8View.initUnchecked(content.items).iterator();
            while (iter.nextCodepoint()) |cp| {
                if (cp <= 0xffff) {
                    value = hash.numberHash(@intCast(cp), value);
                } else {
                    value = hash.numberHash(@intCast(0xd800 + ((cp - 0x10000) >> 10)), value);
                    value = hash.numberHash(@intCast(0xdc00 + ((cp - 0x10000) & 0x3ff)), value);
                }
            }
        }
        return @rem(value, 1000000);
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

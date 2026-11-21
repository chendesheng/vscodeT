// Terminal-facing core of
// `src/vs/editor/contrib/folding/browser/folding.ts`.
//
// The browser controller owns decorations, mouse handling, view state and the
// language feature provider. This port keeps the range computation, collapse
// actions and hidden-area projection that the TUI needs; `codeEditorWidgetTerminal.zig`
// supplies the language folding rules and applies the resulting hidden ranges
// to its own view model.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Selection = @import("../../../common/core/selection.zig").Selection;
const Range = @import("../../../common/core/range.zig").Range;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const FoldingRules = @import("../../../common/languages/languageConfiguration.zig").FoldingRules;
const ProjectedViewModelLines = @import("../../../common/viewModel/viewModelLines.zig").ProjectedViewModelLines;
const FoldingModel = @import("./foldingModel.zig").FoldingModel;
const FoldingRegion = @import("./foldingModel.zig").FoldingRegion;
const FoldRange = @import("./foldingRanges.zig").FoldRange;
const FoldSource = @import("./foldingRanges.zig").FoldSource;
const HiddenRangeModel = @import("./hiddenRangeModel.zig").HiddenRangeModel;
const indent_range_provider = @import("./indentRangeProvider.zig");

pub const FoldState = enum {
    none,
    expanded,
    collapsed,
};

pub const Direction = enum { up, down };

pub const Controller = struct {
    allocator: Allocator,
    model: *TextModel,
    lines: *ProjectedViewModelLines,
    folding_model: *FoldingModel,
    hidden_model: *HiddenRangeModel,
    rules: FoldingRules = .{ .offSide = null, .markers = null },
    maximum_regions: usize = indent_range_provider.MAX_FOLDING_REGIONS_FOR_INDENT_DEFAULT,

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        lines: *ProjectedViewModelLines,
    ) !*Controller {
        const self = try allocator.create(Controller);
        errdefer allocator.destroy(self);

        const folding_model = try allocator.create(FoldingModel);
        errdefer allocator.destroy(folding_model);
        folding_model.* = FoldingModel.init(allocator, model);
        errdefer folding_model.deinit();

        const hidden_model = try allocator.create(HiddenRangeModel);
        errdefer allocator.destroy(hidden_model);
        hidden_model.* = HiddenRangeModel.init(allocator, folding_model);
        errdefer hidden_model.deinit();

        self.* = .{
            .allocator = allocator,
            .model = model,
            .lines = lines,
            .folding_model = folding_model,
            .hidden_model = hidden_model,
        };
        return self;
    }

    pub fn deinit(self: *Controller) void {
        self.hidden_model.deinit();
        self.allocator.destroy(self.hidden_model);
        self.folding_model.deinit();
        self.allocator.destroy(self.folding_model);
        self.allocator.destroy(self);
    }

    pub fn setFoldingRules(self: *Controller, rules: FoldingRules) void {
        self.rules = rules;
    }

    /// Recomputes provider ranges and preserves folded/manual ranges. The
    /// caller supplies the current selections, matching
    /// `FoldingController.triggerFoldingModelChanged`.
    pub fn refresh(self: *Controller, selections: ?[]const Selection) !void {
        var reporter = indent_range_provider.FoldingLimitReporter{ .limit = self.maximum_regions };
        const ranges = try indent_range_provider.computeRanges(
            self.allocator,
            self.model,
            self.rules.offSide orelse false,
            self.rules.markers,
            &reporter,
        );
        try self.folding_model.updateWithSelection(ranges, selections);
        self.hidden_model.updateHiddenRanges();
    }

    pub fn foldStateAtLine(self: *Controller, line: usize) FoldState {
        const region = self.regionStartingAt(line) orelse return .none;
        return if (region.isCollapsed) .collapsed else .expanded;
    }

    pub fn regionStartingAt(self: *Controller, line: usize) ?FoldingRegion {
        const region = self.folding_model.getRegionAtLine(line) orelse return null;
        if (region.startLineNumber != line) return null;
        return region;
    }

    pub fn hasHiddenRanges(self: *const Controller) bool {
        return self.hidden_model.hasRanges();
    }

    pub fn hiddenRanges(self: *const Controller) []const Range {
        return self.hidden_model.hidden_ranges.items;
    }

    pub fn adjustSelections(self: *Controller, selections: []Selection) bool {
        return self.hidden_model.adjustSelections(selections);
    }

    /// Gutter click: toggles the region that starts on `line`.
    pub fn toggleAtLine(self: *Controller, line: usize) bool {
        const region = self.regionStartingAt(line) orelse return false;
        self.folding_model.toggleCollapseState(&[_]usize{region.regionIndex});
        self.hidden_model.updateHiddenRanges();
        return true;
    }

    /// Port of `toggleCollapseState(foldingModel, levels, lineNumbers)`.
    pub fn toggleLine(self: *Controller, line: usize, levels: usize) !void {
        const region = self.folding_model.getRegionAtLine(line) orelse return;
        const do_collapse = !region.isCollapsed;
        var indexes = std.array_list.Managed(usize).init(self.allocator);
        defer indexes.deinit();
        try indexes.append(region.regionIndex);
        if (levels > 1) {
            const inside = try self.folding_model.getRegionsInside(region, levels - 1);
            defer self.allocator.free(inside);
            for (inside) |child| {
                if (child.isCollapsed != do_collapse) try indexes.append(child.regionIndex);
            }
        }
        self.folding_model.toggleCollapseState(indexes.items);
        self.hidden_model.updateHiddenRanges();
    }

    /// Port of `setCollapseStateUp`: folds the innermost region at the line,
    /// or the first expanded parent when that region is already collapsed.
    pub fn foldLine(self: *Controller, line: usize) !void {
        const regions = try self.folding_model.getAllRegionsAtLine(line);
        defer self.allocator.free(regions);
        for (regions) |region| {
            if (!region.isCollapsed) {
                self.folding_model.setCollapsed(&[_]usize{region.regionIndex}, true);
                self.hidden_model.updateHiddenRanges();
                return;
            }
        }
    }

    /// Port of `setCollapseStateLevelsDown(..., false, 1, lineNumbers)`.
    pub fn unfoldLine(self: *Controller, line: usize) void {
        const region = self.folding_model.getRegionAtLine(line) orelse return;
        if (!region.isCollapsed) return;
        self.folding_model.setCollapsed(&[_]usize{region.regionIndex}, false);
        self.hidden_model.updateHiddenRanges();
    }

    /// Port of the `editor.fold` command with optional `levels`/`direction`.
    /// With neither argument, upstream uses `setCollapseStateUp`.
    pub fn foldLevels(self: *Controller, line: usize, levels: ?usize, direction: ?Direction) !void {
        if (levels == null and direction == null) {
            try self.folding_model.setCollapseStateUp(true, &[_]usize{line});
        } else if (direction == .up) {
            try self.folding_model.setCollapseStateLevelsUp(true, levels orelse 1, &[_]usize{line});
        } else {
            try self.folding_model.setCollapseStateLevelsDown(true, levels orelse 1, &[_]usize{line});
        }
        self.hidden_model.updateHiddenRanges();
    }

    /// Port of the `editor.unfold` command with optional `levels`/`direction`.
    pub fn unfoldLevels(self: *Controller, line: usize, levels: ?usize, direction: ?Direction) !void {
        if (direction == .up) {
            try self.folding_model.setCollapseStateLevelsUp(false, levels orelse 1, &[_]usize{line});
        } else {
            try self.folding_model.setCollapseStateLevelsDown(false, levels orelse 1, &[_]usize{line});
        }
        self.hidden_model.updateHiddenRanges();
    }

    pub fn toggleLevels(self: *Controller, line: usize, levels: usize) !void {
        try self.folding_model.toggleCollapseStateLevels(levels, &[_]usize{line});
        self.hidden_model.updateHiddenRanges();
    }

    /// Port of `FoldRangeFromSelectionAction`: create collapsed user-defined
    /// ranges from multi-line selections and move each cursor to line start.
    pub fn createManualRanges(self: *Controller, selections: []const Selection) !void {
        var ranges = std.array_list.Managed(FoldRange).init(self.allocator);
        defer ranges.deinit();
        for (selections) |selection| {
            var end_line = selection.endLineNumber;
            if (selection.endColumn == 1 and end_line > 1) end_line -= 1;
            if (end_line <= selection.startLineNumber) continue;
            try ranges.append(.{
                .startLineNumber = selection.startLineNumber,
                .endLineNumber = end_line,
                .isCollapsed = true,
                .source = .user_defined,
            });
        }
        if (ranges.items.len == 0) return;
        std.mem.sort(FoldRange, ranges.items, {}, struct {
            fn lessThan(_: void, a: FoldRange, b: FoldRange) bool {
                return a.startLineNumber < b.startLineNumber;
            }
        }.lessThan);
        try self.folding_model.addManualRanges(ranges.items);
        self.hidden_model.updateHiddenRanges();
    }

    pub fn removeManualRanges(self: *Controller, selections: []const Selection) !void {
        try self.folding_model.removeManualRanges(selections);
        self.hidden_model.updateHiddenRanges();
    }

    pub fn foldRecursively(self: *Controller, line: usize) !void {
        const region = self.folding_model.getRegionAtLine(line) orelse return;
        var indexes = std.array_list.Managed(usize).init(self.allocator);
        defer indexes.deinit();
        try indexes.append(region.regionIndex);
        const inside = try self.folding_model.getRegionsInside(region, std.math.maxInt(usize));
        defer self.allocator.free(inside);
        for (inside) |child| try indexes.append(child.regionIndex);
        self.folding_model.setCollapsed(indexes.items, true);
        self.hidden_model.updateHiddenRanges();
    }

    pub fn unfoldRecursively(self: *Controller, line: usize) !void {
        const region = self.folding_model.getRegionAtLine(line) orelse return;
        var indexes = std.array_list.Managed(usize).init(self.allocator);
        defer indexes.deinit();
        try indexes.append(region.regionIndex);
        const inside = try self.folding_model.getRegionsInside(region, std.math.maxInt(usize));
        defer self.allocator.free(inside);
        for (inside) |child| try indexes.append(child.regionIndex);
        self.folding_model.setCollapsed(indexes.items, false);
        self.hidden_model.updateHiddenRanges();
    }

    pub fn foldAll(self: *Controller) void {
        self.folding_model.collapseAll();
        self.hidden_model.updateHiddenRanges();
    }

    pub fn unfoldAll(self: *Controller) void {
        self.folding_model.expandAll();
        self.hidden_model.updateHiddenRanges();
    }

    pub fn toggleAll(self: *Controller) void {
        const length = self.folding_model.length();
        var indexes = std.array_list.Managed(usize).init(self.allocator);
        defer indexes.deinit();
        for (0..length) |index| indexes.append(index) catch return;
        self.folding_model.toggleCollapseState(indexes.items);
        self.hidden_model.updateHiddenRanges();
    }
};

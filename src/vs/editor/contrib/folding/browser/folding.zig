// Terminal-facing core of
// `src/vs/editor/contrib/folding/browser/folding.ts`.
//
// The controller owns syntax providers, range computation, collapse actions
// and hidden-area projection; `codeEditorWidgetTerminal.zig`
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
const languages = @import("../../../common/languages.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.FoldingRangeProvider);
const FoldingRegions = @import("foldingRanges.zig").FoldingRegions;
const SyntaxRangeProvider = @import("syntaxRangeProvider.zig").SyntaxRangeProvider;
const time = @import("../../../../base/common/timeCompat.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const indent_range_provider = @import("./indentRangeProvider.zig");

pub const FoldState = enum {
    none,
    expanded,
    collapsed,
};

pub const Direction = enum { up, down };

pub const FoldingStateMemento = struct {
    collapsedRegions: []@import("./foldingModel.zig").ILineMemento = &.{},
    lineCount: usize = 0,
    foldedImports: bool = false,

    pub fn deinit(self: *FoldingStateMemento, allocator: Allocator) void {
        allocator.free(self.collapsedRegions);
        self.collapsedRegions = &.{};
    }
};

pub const Controller = struct {
    allocator: Allocator,
    model: *TextModel,
    lines: *ProjectedViewModelLines,
    folding_model: *FoldingModel,
    hidden_model: *HiddenRangeModel,
    rules: FoldingRules = .{ .offSide = null, .markers = null },
    maximum_regions: usize = indent_range_provider.MAX_FOLDING_REGIONS_FOR_INDENT_DEFAULT,
    use_syntax: bool = true,
    fold_imports_by_default: bool = false,
    folded_imports: bool = false,
    registry: ?*Registry = null,
    registry_listener: ?usize = null,
    provider_listeners: std.ArrayList(ProviderListener) = .empty,
    syntax_request: ?*SyntaxRangeProvider = null,
    syntax_started: i64 = 0,
    host: ?Host = null,

    const ProviderListener = struct { event: *Emitter(void), id: usize };
    pub const Host = struct {
        context: *anyopaque,
        changed: *const fn (*anyopaque) void,
        complete: *const fn (*anyopaque, anyerror!?FoldingRegions, i64) void,
    };

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
        self.cancelPending();
        self.unlistenProviders();
        self.provider_listeners.deinit(self.allocator);
        if (self.registry_listener) |id| self.registry.?.on_did_change.unlisten(id);
        self.hidden_model.deinit();
        self.allocator.destroy(self.hidden_model);
        self.folding_model.deinit();
        self.allocator.destroy(self.folding_model);
        self.allocator.destroy(self);
    }

    pub fn bindRegistry(self: *Controller, registry: ?*Registry, host: Host) !void {
        self.host = host;
        if (self.registry == registry) return;
        self.cancelPending();
        self.unlistenProviders();
        if (self.registry_listener) |id| self.registry.?.on_did_change.unlisten(id);
        self.registry_listener = null;
        self.registry = registry;
        if (registry) |value| self.registry_listener = try value.on_did_change.listen(self, registryChanged);
        try self.updateProviders();
        host.changed(host.context);
    }

    fn unlistenProviders(self: *Controller) void {
        for (self.provider_listeners.items) |listener| listener.event.unlisten(listener.id);
        self.provider_listeners.clearRetainingCapacity();
    }

    pub fn updateProviders(self: *Controller) !void {
        self.unlistenProviders();
        const registry = self.registry orelse return;
        const providers = try registry.ordered(self.allocator, self.model, false);
        defer self.allocator.free(providers);
        for (providers) |provider| {
            const event = provider.on_did_change orelse continue;
            const id = try event.listen(self, providerChanged);
            errdefer event.unlisten(id);
            try self.provider_listeners.append(self.allocator, .{ .event = event, .id = id });
        }
    }

    fn registryChanged(_: usize, self: *Controller) !void {
        self.cancelPending();
        try self.updateProviders();
        if (self.host) |host| host.changed(host.context);
    }

    fn providerChanged(_: void, self: *Controller) !void {
        self.cancelPending();
        if (self.host) |host| host.changed(host.context);
    }

    pub fn cancelPending(self: *Controller) void {
        if (self.syntax_request) |request| request.deinit();
        self.syntax_request = null;
    }

    pub fn requestSyntax(self: *Controller) !bool {
        const registry = self.registry orelse return false;
        if (!self.use_syntax) return false;
        if (self.host == null) return false;
        self.cancelPending();
        const providers = try registry.ordered(self.allocator, self.model, false);
        defer self.allocator.free(providers);
        if (providers.len == 0) return false;
        const request = try SyntaxRangeProvider.init(self.allocator, self.model, self.maximum_regions, .{ .context = self, .complete = syntaxReady });
        self.syntax_request = request;
        self.syntax_started = time.milliTimestamp(self.model.clockIo());
        errdefer self.cancelPending();
        try request.compute(providers);
        return true;
    }

    fn syntaxReady(context: *anyopaque, result: anyerror!?FoldingRegions) void {
        const self: *Controller = @ptrCast(@alignCast(context));
        const request = self.syntax_request orelse return;
        self.syntax_request = null;
        defer request.deinit();
        if (self.host) |host| host.complete(host.context, result, time.milliTimestamp(self.model.clockIo()) - self.syntax_started) else if (result) |maybe| {
            if (maybe) |regions| {
                var owned = regions;
                owned.deinit();
            }
        } else |_| {}
    }

    pub fn updateSyntax(self: *Controller, regions: FoldingRegions, selections: ?[]const Selection) !void {
        var incoming = regions;
        if (self.fold_imports_by_default and !self.folded_imports) self.folded_imports = incoming.setCollapsedAllOfType("imports", true);
        try self.folding_model.updateWithSelection(incoming, selections);
        self.hidden_model.updateHiddenRanges();
    }

    pub fn saveViewState(self: *Controller, allocator: Allocator) !FoldingStateMemento {
        return .{ .collapsedRegions = try self.folding_model.getMemento(allocator), .lineCount = self.model.getLineCount(), .foldedImports = self.folded_imports };
    }

    pub fn restoreViewState(self: *Controller, state: FoldingStateMemento) !void {
        self.folded_imports = state.foldedImports;
        if (state.collapsedRegions.len != 0) {
            try self.folding_model.applyMemento(state.collapsedRegions);
            self.hidden_model.updateHiddenRanges();
        }
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

const ActionEditor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ActionCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const action_registry = @import("../../../../platform/actions/common/actions.zig");

pub const editor_actions = [_]action_registry.Action2{
    ActionCommand.action(.{ .id = "editor.fold", .title = "Fold", .category = "Editor" }, false, ActionEditor.foldAtCursor),
    ActionCommand.action(.{ .id = "editor.unfold", .title = "Unfold", .category = "Editor" }, false, ActionEditor.unfoldAtCursor),
    ActionCommand.action(.{ .id = "editor.toggleFold", .title = "Toggle Fold", .category = "Editor" }, false, ActionEditor.toggleFoldAtCursor),
    ActionCommand.action(.{ .id = "editor.foldRecursively", .title = "Fold Recursively", .category = "Editor" }, false, ActionEditor.foldRecursivelyAtCursor),
    ActionCommand.action(.{ .id = "editor.unfoldRecursively", .title = "Unfold Recursively", .category = "Editor" }, false, ActionEditor.unfoldRecursivelyAtCursor),
    ActionCommand.action(.{ .id = "editor.foldAll", .title = "Fold All", .category = "Editor" }, false, ActionEditor.foldAll),
    ActionCommand.action(.{ .id = "editor.unfoldAll", .title = "Unfold All", .category = "Editor" }, false, ActionEditor.unfoldAll),
};

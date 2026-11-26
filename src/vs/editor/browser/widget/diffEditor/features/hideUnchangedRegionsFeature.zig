// Port of src/vs/editor/browser/widget/diffEditor/features/hideUnchangedRegionsFeature.ts.
// The terminal displays the disclosure controls in a single cell row, attached
// to the same model-anchored view zones as the upstream overlay widgets.
const std = @import("std");
const ui = @import("ui");
const css = @import("../style_css.zig");
const vm = @import("../diffEditorViewModel.zig");
const Options = @import("../diffEditorOptions.zig").Options;
const Alignment = @import("../components/diffEditorViewZones/diffEditorViewZones.zig").DiffEditorViewZones;
const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ViewZones = @import("../../../viewParts/viewZones/viewZones.zig").ViewZones;
const browser = @import("../../../editorBrowser.zig");
const model_mod = @import("../../../../common/model.zig");
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;
const languages = @import("../../../../common/languages.zig");
const Range = @import("../../../../common/core/range.zig").Range;
const EventHandler = @import("../../../../common/viewEventHandler.zig").ViewEventHandler;
const events = @import("../../../../common/viewEvents.zig");

pub const BreadcrumbItem = struct {
    name: []const u8,
    kind: u32,
    start_line_number: usize,
};

pub const BreadcrumbsListener = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
};

/// The contribution returns owned lists whose labels borrow the current outline.
pub const IDiffEditorBreadcrumbsSource = struct {
    context: *anyopaque,
    get_breadcrumb_items: *const fn (*anyopaque, std.mem.Allocator, LineRange) anyerror![]BreadcrumbItem,
    get_at: *const fn (*anyopaque, std.mem.Allocator, usize) anyerror![]BreadcrumbItem,
    dispose_fn: *const fn (*anyopaque) void,

    pub fn dispose(self: IDiffEditorBreadcrumbsSource) void {
        self.dispose_fn(self.context);
    }
};

/// The upstream contribution supplies a factory through instantiation; the
/// terminal composition passes that same factory explicitly to the widget.
pub const BreadcrumbsSourceFactory = struct {
    context: *anyopaque,
    create_source: *const fn (*anyopaque, *TextModel, BreadcrumbsListener) anyerror!IDiffEditorBreadcrumbsSource,
    dispose_fn: *const fn (*anyopaque) void,

    pub fn dispose(self: BreadcrumbsSourceFactory) void {
        self.dispose_fn(self.context);
    }
};

pub const HideUnchangedRegionsFeature = struct {
    allocator: std.mem.Allocator,
    model: *vm.DiffEditorViewModel,
    alignment: *Alignment,
    original: Pane,
    modified: Pane,
    options: Options,
    subscription: ?usize = null,
    initialized: bool = true,
    updating: bool = false,
    drag: ?Drag = null,
    breadcrumbs_source: ?IDiffEditorBreadcrumbsSource = null,
    side_by_side: bool = true,

    unchanged_decoration: model_mod.ModelDecorationOptions = blk: {
        var options = model_mod.ModelDecorationOptions.init("unchanged lines", .AlwaysGrowsWhenTypingAtEdges);
        options.className = "diff-unchanged-lines";
        options.isWholeLine = true;
        break :blk options;
    },
    fold_decoration: model_mod.ModelDecorationOptions = blk: {
        var options = model_mod.ModelDecorationOptions.init("Fold Unchanged", .AlwaysGrowsWhenTypingAtEdges);
        options.glyphMarginClassName = "fold-unchanged codicon codicon-fold";
        options.glyphMarginHoverMessage = "Fold Unchanged Region";
        options.zIndex = 10001;
        break :blk options;
    },

    const Drag = struct {
        binding: *Binding,
        top: bool,
        start_y: ?usize = null,
        initial_count: usize,
        moved: bool = false,
    };

    const Pane = struct {
        owner: *HideUnchangedRegionsFeature,
        original: bool,
        editor: *Editor,
        zones: *ViewZones,
        handler: EventHandler = undefined,
        bindings: []Binding = &.{},
        decoration_ids: []u64 = &.{},
    };
    const Binding = struct {
        pane: *Pane,
        index: usize,
        id: ?[]const u8 = null,

        fn region(self: *Binding) *vm.UnchangedRegion {
            return &self.pane.owner.model.unchangedRegions()[self.index];
        }

        fn build(context: ?*anyopaque, doc: *ui.Document, info: browser.IViewZone.RenderInfo) anyerror!*ui.Node {
            const self: *Binding = @ptrCast(@alignCast(context.?));
            const node = try doc.createElement(.div);
            errdefer doc.destroy(node);
            node.asElement().focusable = true;
            node.asElement().tab_index = 0;
            try node.setAttribute("role", "button");
            try node.setAttribute("class", "disclosure-toggle");
            var index_buffer: [32]u8 = undefined;
            try node.setAttribute("data-region-index", try std.fmt.bufPrint(&index_buffer, "{d}", .{self.index}));
            try node.addEventListener(.{ .context = self, .mouse_down = onMouse, .key_down = onKey });
            try update(context, node, info);
            return node;
        }

        fn appendLabel(node: *ui.Node, label: []const u8) !*ui.Node {
            const child = try node.document.createElement(.span);
            errdefer node.document.destroy(child);
            try child.setTextContent(label);
            _ = try node.appendChild(child);
            return child;
        }

        fn appendControl(self: *Binding, node: *ui.Node, top: bool) !void {
            const button = try appendLabel(node, if (top) "↑" else "↓");
            try button.addClass(if (top) css.Class.top else css.Class.bottom);
            try button.setAttribute("aria-label", if (top) "Click or drag to show more above" else "Click or drag to show more below");
            try button.addEventListener(.{ .context = self, .mouse_down = if (top) onTop else onBottom });
        }

        fn update(context: ?*anyopaque, node: *ui.Node, _: browser.IViewZone.RenderInfo) anyerror!void {
            const self: *Binding = @ptrCast(@alignCast(context.?));
            const r = self.region();
            const count = r.getHiddenModifiedRange().length();
            const options = self.pane.owner.options;
            const hidden_original = self.pane.original and !self.pane.owner.side_by_side;
            const compact = options.variant == .compact;
            const compact_mode = !compact and options.compact_mode;
            var buffer: [128]u8 = undefined;
            const label = if (compact)
                if (count == 0)
                    try std.fmt.bufPrint(&buffer, "▾ Collapse {d} unchanged lines", .{r.line_count})
                else
                    try std.fmt.bufPrint(&buffer, "▸ Show {d} unchanged lines", .{count})
            else if (compact_mode)
                try std.fmt.bufPrint(&buffer, "{d} hidden lines", .{count})
            else
                try std.fmt.bufPrint(&buffer, "{d} hidden lines  ·  Show all", .{count});
            try node.addClass(css.Class.diff_hidden_lines);
            if (compact_mode) try node.addClass(css.Class.diff_hidden_lines_compact) else node.removeClass(css.Class.diff_hidden_lines_compact);
            node.asElement().focusable = !compact_mode and !hidden_original;
            node.asElement().tab_index = if (compact_mode or hidden_original) -1 else 0;
            if (compact_mode or hidden_original) node.removeAttribute("role") else try node.setAttribute("role", "button");
            node.document.destroyChildren(node);
            if (hidden_original) {
                node.removeAttribute("aria-label");
                node.removeAttribute("aria-expanded");
                return;
            }
            if (!compact_mode) try self.appendControl(node, true);
            const center = try appendLabel(node, label);
            try center.addClass(css.Class.center);
            if (!compact_mode and count != 0) try self.appendBreadcrumbs(node, compact, r.getHiddenModifiedRange());
            if (!compact_mode) try self.appendControl(node, false);
            try node.setAttribute("aria-label", label);
            try node.setAttribute("aria-expanded", if (count == 0) "true" else "false");
        }

        fn appendBreadcrumbs(self: *Binding, node: *ui.Node, compact: bool, range: LineRange) !void {
            const source = self.pane.owner.breadcrumbs_source orelse return;
            const allocator = self.pane.owner.allocator;
            const items = try source.get_breadcrumb_items(source.context, allocator, range);
            defer allocator.free(items);
            if (items.len == 0) return;
            _ = try appendLabel(node, if (compact) "·" else "|");
            for (items, 0..) |item, i| {
                const button = try appendLabel(node, "");
                try button.addClass(css.Class.breadcrumb_item);
                const title = try std.fmt.allocPrint(allocator, "{s} {s}{s}", .{ languages.SymbolKinds.terminalGlyph(item.kind), item.name, if (i + 1 < items.len) " ›" else "" });
                defer allocator.free(title);
                try button.setTextContent(title);
                var buffer: [32]u8 = undefined;
                try button.setAttribute("data-breadcrumb-line", try std.fmt.bufPrint(&buffer, "{d}", .{item.start_line_number}));
                const aria_label = try std.fmt.allocPrint(allocator, "Go to {s}", .{item.name});
                defer allocator.free(aria_label);
                try button.setAttribute("aria-label", aria_label);
                try button.addEventListener(.{ .context = self, .mouse_down = onBreadcrumbMouse, .key_down = onBreadcrumbKey });
                if (compact) {
                    button.asElement().focusable = true;
                    button.asElement().tab_index = 0;
                    try button.setAttribute("role", "button");
                }
            }
        }

        fn revealBreadcrumb(self: *Binding, target: *ui.Node) void {
            const line = std.fmt.parseInt(usize, target.getAttribute("data-breadcrumb-line") orelse return, 10) catch return;
            const model = self.pane.owner.model;
            if (model.ensureLineVisibleWithPreference(false, line, .from_bottom)) model.notifyUnchangedRegions() catch |err| self.pane.editor.setMessage("unchanged regions: {s}", .{@errorName(err)});
        }

        fn onBreadcrumbMouse(context: ?*anyopaque, event: *ui.MouseEvent) void {
            if (event.button != .left) return;
            const self: *Binding = @ptrCast(@alignCast(context.?));
            const target = event.current_target orelse return;
            event.preventDefault();
            event.stopPropagation();
            self.revealBreadcrumb(target);
        }

        fn onBreadcrumbKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
            switch (event.key) {
                .enter => {},
                .char => |c| if (c != ' ') return,
                .text => |text| if (!std.mem.eql(u8, text, " ")) return,
                else => return,
            }
            const self: *Binding = @ptrCast(@alignCast(context.?));
            const target = event.current_target orelse return;
            event.preventDefault();
            event.stopPropagation();
            self.revealBreadcrumb(target);
        }

        fn toggle(self: *Binding) void {
            const r = self.region();
            if (r.getHiddenModifiedRange().isEmpty()) r.collapseAll() else r.showAll();
            self.pane.owner.model.notifyUnchangedRegions() catch |err| self.pane.editor.setMessage("unchanged regions: {s}", .{@errorName(err)});
        }

        fn beginDrag(self: *Binding, event: *ui.MouseEvent, top: bool) void {
            if (event.button != .left) return;
            event.preventDefault();
            event.stopPropagation();
            const r = self.region();
            r.is_dragged = if (top) .top else .bottom;
            self.pane.owner.drag = .{ .binding = self, .top = top, .initial_count = if (top) r.visible_line_count_top else r.visible_line_count_bottom };
        }

        fn onTop(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Binding = @ptrCast(@alignCast(context.?));
            self.beginDrag(event, true);
        }

        fn onBottom(context: ?*anyopaque, event: *ui.MouseEvent) void {
            const self: *Binding = @ptrCast(@alignCast(context.?));
            self.beginDrag(event, false);
        }

        fn onMouse(context: ?*anyopaque, event: *ui.MouseEvent) void {
            if (event.button != .left) return;
            const self: *Binding = @ptrCast(@alignCast(context.?));
            if (self.pane.owner.options.variant != .compact and self.pane.owner.options.compact_mode) return;
            if (event.current_target) |target| _ = target.focus();
            event.preventDefault();
            event.stopPropagation();
            self.toggle();
        }

        fn onKey(context: ?*anyopaque, event: *ui.KeyEvent) void {
            switch (event.key) {
                .enter => {},
                .char => |c| if (c != ' ') return,
                .text => |s| if (!std.mem.eql(u8, s, " ")) return,
                else => return,
            }
            event.preventDefault();
            event.stopPropagation();
            const self: *Binding = @ptrCast(@alignCast(context.?));
            if (self.pane.owner.options.variant != .compact and self.pane.owner.options.compact_mode) return;
            self.toggle();
        }
    };

    /// The first down is routed through the pane DOM; subsequent drag
    /// motion/release is captured by the diff widget even outside that pane.
    pub fn captureDragStart(self: *HideUnchangedRegionsFeature, y: usize) void {
        if (self.drag) |*drag| if (drag.start_y == null) {
            drag.start_y = y;
        };
    }

    /// CollapsedCodeOverlayWidget._runWithLowerScrollAnchor: bottom-edge
    /// reveal keeps the first line below the unchanged region stationary.
    /// Layout offsets are cells; the content-height fallback covers EOF.
    const LowerScrollAnchor = struct {
        editor: *Editor,
        line: usize,
        scroll_top: usize,
        top: f64,

        fn capture(binding: *Binding) LowerScrollAnchor {
            const r = binding.region();
            const range = if (binding.pane.original) r.originalUnchangedRange() else r.modifiedUnchangedRange();
            const editor = binding.pane.editor;
            return .{ .editor = editor, .line = range.endLineNumberExclusive, .scroll_top = editor.scrollTop(), .top = topForLine(editor, range.endLineNumberExclusive) };
        }

        fn topForLine(editor: *Editor, line: usize) f64 {
            if (line > editor.model.getLineCount()) return editor.viewLayout().lines_layout.getLinesTotalHeight() catch editor.viewLayout().getScrollHeight();
            const pos = editor.viewPositionOfModelPosition(.{ .lineNumber = line, .column = 1 });
            return editor.viewLayout().getVerticalOffsetForLineNumber(pos.lineNumber, false);
        }

        fn restore(self: LowerScrollAnchor) void {
            const delta = topForLine(self.editor, self.line) - self.top;
            _ = self.editor.setScrollTop(@intFromFloat(@max(0, @as(f64, @floatFromInt(self.scroll_top)) + delta)));
        }
    };

    pub fn dispatchDrag(self: *HideUnchangedRegionsFeature, event: *ui.MouseEvent) bool {
        const drag = if (self.drag) |*value| value else return false;
        const start = drag.start_y orelse return false;
        const r = drag.binding.region();
        var anchor: ?LowerScrollAnchor = null;
        if (event.kind == .move) {
            const delta = @as(i64, @intCast(event.y)) - @as(i64, @intCast(start));
            if (delta != 0) drag.moved = true;
            const initial: i64 = @intCast(drag.initial_count);
            const value: usize = @intCast(@max(0, initial + if (drag.top) delta else -delta));
            if (drag.top) {
                const next = @min(value, r.getMaxVisibleLineCountTop());
                if (next == r.visible_line_count_top) return true;
                r.setState(next, r.visible_line_count_bottom);
            } else {
                const next = @min(value, r.getMaxVisibleLineCountBottom());
                if (next == r.visible_line_count_bottom) return true;
                anchor = LowerScrollAnchor.capture(drag.binding);
                r.setState(r.visible_line_count_top, next);
            }
        } else if (event.kind == .up) {
            if (!drag.moved) {
                if (self.options.variant == .compact and r.getHiddenModifiedRange().isEmpty()) {
                    r.collapseAll();
                } else if (drag.top) {
                    r.showMoreAbove(self.options.hide_unchanged_regions_reveal_line_count);
                } else {
                    anchor = LowerScrollAnchor.capture(drag.binding);
                    r.showMoreBelow(self.options.hide_unchanged_regions_reveal_line_count);
                }
            }
            r.is_dragged = null;
            self.drag = null;
        } else return true;
        self.model.notifyUnchangedRegions() catch |err| self.modified.editor.setMessage("unchanged regions: {s}", .{@errorName(err)});
        if (anchor) |value| value.restore();
        return true;
    }

    pub fn init(self: *HideUnchangedRegionsFeature, allocator: std.mem.Allocator, model: *vm.DiffEditorViewModel, alignment: *Alignment, original: *Editor, original_zones: *ViewZones, modified: *Editor, modified_zones: *ViewZones, options: Options) !void {
        self.* = .{
            .allocator = allocator,
            .model = model,
            .alignment = alignment,
            .options = options,
            .original = .{ .owner = self, .original = true, .editor = original, .zones = original_zones },
            .modified = .{ .owner = self, .original = false, .editor = modified, .zones = modified_zones },
        };
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            pane.handler = EventHandler.init(pane, .{ .onCursorStateChanged = onCursorStateChanged });
            pane.editor.addViewEventHandler(&pane.handler);
        }
        errdefer self.deinit();
        self.subscription = try model.on_did_change_unchanged_regions.listen(self, onModelChanged);
        try self.apply();
    }

    pub fn deinit(self: *HideUnchangedRegionsFeature) void {
        if (!self.initialized) return;
        self.initialized = false;
        self.drag = null;
        self.detachBreadcrumbs();
        if (self.subscription) |id| self.model.on_did_change_unchanged_regions.unlisten(id);
        self.alignment.beginBatch();
        defer self.alignment.endBatch();
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            pane.editor.removeViewEventHandler(&pane.handler);
            pane.zones.changeViewZones(pane, removeZones) catch {};
            self.allocator.free(pane.bindings);
            const ids = pane.editor.model.deltaDecorations(pane.decoration_ids, &.{}, if (pane.original) 1002 else 1003) catch &.{};
            self.allocator.free(ids);
            self.allocator.free(pane.decoration_ids);
        }
    }

    pub fn attachBreadcrumbs(self: *HideUnchangedRegionsFeature, factory: BreadcrumbsSourceFactory) !void {
        self.detachBreadcrumbs();
        self.breadcrumbs_source = try factory.create_source(factory.context, self.modified.editor.model, .{ .context = self, .changed = onBreadcrumbsChanged });
        self.invalidateBreadcrumbs();
    }

    pub fn detachBreadcrumbs(self: *HideUnchangedRegionsFeature) void {
        if (self.breadcrumbs_source) |source| source.dispose();
        self.breadcrumbs_source = null;
    }

    pub fn setSideBySide(self: *HideUnchangedRegionsFeature, side_by_side: bool) void {
        if (self.side_by_side == side_by_side) return;
        self.side_by_side = side_by_side;
        self.invalidateBreadcrumbs();
    }

    fn onBreadcrumbsChanged(context: *anyopaque) void {
        const self: *HideUnchangedRegionsFeature = @ptrCast(@alignCast(context));
        self.invalidateBreadcrumbs();
    }

    fn invalidateBreadcrumbs(self: *HideUnchangedRegionsFeature) void {
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            for (pane.bindings) |binding| if (binding.id) |id| pane.zones.invalidateZoneContent(id);
            pane.editor.emitViewEvent(.{ .ViewZonesChanged = .{} });
        }
    }

    pub fn updateOptions(self: *HideUnchangedRegionsFeature, options: Options) !void {
        const changed = self.options.variant != options.variant or self.options.compact_mode != options.compact_mode;
        self.options = options;
        if (changed) {
            if (self.drag) |drag| drag.binding.region().is_dragged = null;
            self.drag = null;
            try self.apply();
        }
    }

    fn removeZones(pane: *Pane, accessor: browser.IViewZoneChangeAccessor) anyerror!void {
        for (pane.bindings) |*binding| {
            if (binding.id) |id| try accessor.removeZone(id);
            binding.id = null;
        }
    }

    fn onModelChanged(change: vm.UnchangedRegionsChange, self: *HideUnchangedRegionsFeature) anyerror!void {
        if (change == .replaced) {
            // The upstream derivedDisposable owns each region's gesture
            // listeners. A new collection disposes the old bindings even
            // when it contains the same number of ranges.
            self.drag = null;
            self.alignment.beginBatch();
            defer self.alignment.endBatch();
            for ([_]*Pane{ &self.original, &self.modified }) |pane| {
                try pane.zones.changeViewZones(pane, removeZones);
                self.allocator.free(pane.bindings);
                pane.bindings = &.{};
            }
            try self.apply();
        } else try self.apply();
    }

    fn onCursorStateChanged(context: *anyopaque, event: *const events.ViewCursorStateChangedEvent) bool {
        const pane: *Pane = @ptrCast(@alignCast(context));
        const self = pane.owner;
        if (self.updating or event.reason == .ContentFlush) return false;
        var changed = false;
        for (event.modelSelections) |selection| {
            if (self.model.ensureLineVisible(pane.original, selection.startLineNumber)) changed = true;
            if (self.model.ensureLineVisible(pane.original, selection.endLineNumber)) changed = true;
        }
        if (changed) self.model.notifyUnchangedRegions() catch |err| pane.editor.setMessage("unchanged regions: {s}", .{@errorName(err)});
        return false;
    }

    fn regionCount(self: *HideUnchangedRegionsFeature) usize {
        const regions = self.model.unchangedRegions();
        if (regions.len == 1 and regions[0].modified_line_number == 1 and regions[0].line_count == self.modified.editor.model.getLineCount()) return 0;
        return regions.len;
    }

    fn apply(self: *HideUnchangedRegionsFeature) !void {
        if (self.updating) return;
        self.updating = true;
        defer self.updating = false;
        self.alignment.beginBatch();
        defer self.alignment.endBatch();
        const count = self.regionCount();
        for ([_]*Pane{ &self.original, &self.modified }) |pane| {
            if (pane.bindings.len != count) {
                try pane.zones.changeViewZones(pane, removeZones);
                const bindings = try self.allocator.alloc(Binding, count);
                self.allocator.free(pane.bindings);
                pane.bindings = bindings;
                for (bindings, 0..) |*binding, i| binding.* = .{ .pane = pane, .index = i };
            }
            var hidden: std.ArrayList(Range) = .empty;
            defer hidden.deinit(self.allocator);
            for (self.model.unchangedRegions()[0..count]) |r| {
                const range = if (pane.original) r.getHiddenOriginalRange() else r.getHiddenModifiedRange();
                if (range.toInclusiveRange()) |inclusive| try hidden.append(self.allocator, inclusive);
            }
            try pane.editor.setHiddenAreas(hidden.items);
            try pane.zones.changeViewZones(pane, updateZones);
            try self.updateDecorations(pane);
        }
    }

    fn updateDecorations(self: *HideUnchangedRegionsFeature, pane: *Pane) !void {
        var decorations: std.ArrayList(model_mod.ModelDeltaDecoration) = .empty;
        defer decorations.deinit(self.allocator);
        for (pane.bindings) |*binding| {
            const r = binding.region();
            const range = if (pane.original) r.originalUnchangedRange() else r.modifiedUnchangedRange();
            if (range.toInclusiveRange()) |inclusive| {
                try decorations.append(self.allocator, .{ .range = inclusive, .options = &self.unchanged_decoration });
            }
            if (self.options.variant != .compact and r.shouldHideControls()) {
                const line = range.startLineNumber;
                try decorations.append(self.allocator, .{ .range = Range.init(line, 1, line, 1), .options = &self.fold_decoration });
            }
        }
        const ids = try pane.editor.model.deltaDecorations(pane.decoration_ids, decorations.items, if (pane.original) 1002 else 1003);
        self.allocator.free(pane.decoration_ids);
        pane.decoration_ids = ids;
    }

    /// Upstream's editor mouse-up listener reacts only to the fold-unchanged
    /// glyph. Terminal glyphs own the left margin cell rather than icon DOM.
    pub fn dispatchFoldGlyph(self: *HideUnchangedRegionsFeature, original: bool, event: *ui.MouseEvent, target: browser.MouseTarget) bool {
        if (event.kind != .up or event.button == .right or self.options.variant == .compact or target.type != .gutter_glyph_margin) return false;
        const pane = if (original) &self.original else &self.modified;
        const line = pane.editor.modelLineNumber((target.position orelse return false).lineNumber);
        for (pane.bindings) |*binding| {
            const region = binding.region();
            if (region.shouldHideControls() and line == (if (original) region.original_line_number else region.modified_line_number)) {
                region.collapseAll();
                self.model.notifyUnchangedRegions() catch |err| pane.editor.setMessage("unchanged regions: {s}", .{@errorName(err)});
                event.preventDefault();
                event.stopPropagation();
                return true;
            }
        }
        return false;
    }

    fn updateZones(pane: *Pane, accessor: browser.IViewZoneChangeAccessor) anyerror!void {
        const options = pane.owner.options;
        for (pane.bindings) |*binding| {
            const r = binding.region();
            const compact = options.variant == .compact;
            const hide = (!compact and r.shouldHideControls()) or (!compact and options.compact_mode and (binding.index == 0 or binding.index + 1 == pane.bindings.len));
            if (hide) {
                if (binding.id) |id| try accessor.removeZone(id);
                binding.id = null;
                continue;
            }
            const range = if (pane.original) r.getHiddenOriginalRange() else r.getHiddenModifiedRange();
            const delegate: browser.IViewZone = .{
                .after_line_number = range.startLineNumber - 1,
                .height_in_lines = 1,
                .show_in_hidden_areas = true,
                .suppress_mouse_down = true,
                .context = binding,
                .build = Binding.build,
                .update = Binding.update,
            };
            if (binding.id) |id| try accessor.layoutZone(id, delegate) else binding.id = try accessor.addZone(delegate);
        }
    }
};

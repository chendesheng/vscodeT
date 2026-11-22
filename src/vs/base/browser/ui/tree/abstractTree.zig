// Port of the core view behavior of `src/vs/base/browser/ui/tree/abstractTree.ts`.
//
// Terminal adaptation: rows are painted through `ListWidget` into a CellGrid
// instead of DOM rows. `AbstractTreeForModel` keeps the view model-agnostic so
// `CompressibleObjectTree` can drive it with `CompressedObjectTreeModel`, the
// same composition as upstream's `CompressibleObjectTree extends ObjectTree`.
// Filtering lives in the tree models; async nodes, drag/drop, context menus
// and the browser accessibility layer are not ported yet.
//
// Sticky scroll is ported from `StickyScrollController`/`StickyScrollWidget`/
// `StickyScrollFocus`. The terminal has no retained DOM overlay, so the
// controller recomputes the pinned ancestor rows before every paint and paints
// them over the list through the same renderer. Rows are whole cells, so a
// pinned row that upstream would clip in pixels at the viewport edge is either
// painted whole or hidden (see `docs/terminal-ui.md`).

const std = @import("std");
const ui = @import("ui");
const list = @import("../list/list.zig");
const list_widget = @import("../list/listWidget.zig");
const object_tree = @import("./objectTreeModel.zig");

pub fn AbstractTree(comptime T: type) type {
    return AbstractTreeForModel(T, object_tree.ObjectTreeModel(T));
}

/// Port of upstream `RenderIndentGuides` from `abstractTree.ts`.
pub const RenderIndentGuides = enum {
    none,
    on_hover,
    always,

    pub fn fromString(value: []const u8) RenderIndentGuides {
        if (std.mem.eql(u8, value, "always")) return .always;
        if (std.mem.eql(u8, value, "none")) return .none;
        return .on_hover;
    }
};

/// Port of `IStickyScrollNodeSourceRange`. Positions are rows in the terminal.
pub const StickyScrollNodeSourceRange = struct {
    start: f64 = 0,
    end: f64 = 0,
    sticky_node_height: ?f64 = null,
    estimated: bool = false,
};

/// Port of `stickyScrollNodeSourceRangeProvider`. The element is type-erased
/// because `Options` is shared by every tree instance; the provider casts it
/// back to its tree element type.
pub const StickyScrollNodeSourceRangeProvider = struct {
    context: *anyopaque,
    get: *const fn (
        context: *anyopaque,
        element: *const anyopaque,
        default_range: StickyScrollNodeSourceRange,
    ) ?StickyScrollNodeSourceRange,
};

/// Terminal tree options. `indent` is in cells (upstream uses pixels) and
/// `render_indent_guides` follows `workbench.tree.renderIndentGuides`.
///
/// Sticky scroll mirrors upstream's `enableStickyScroll` /
/// `stickyScrollMaxItemCount` / `stickyScrollMaxNodeHeight` options. The
/// low-level tree defaults it off, like upstream's `AbstractTree`; the
/// Explorer enables it from `workbench.tree.enableStickyScroll` (default
/// true).
pub const Options = struct {
    indent: usize = 2,
    render_indent_guides: RenderIndentGuides = .on_hover,
    enable_sticky_scroll: bool = false,
    sticky_scroll_max_item_count: usize = 7,
    sticky_scroll_max_node_height: ?f64 = null,
    sticky_scroll_node_source_range_provider: ?StickyScrollNodeSourceRangeProvider = null,
};

/// Port of `StickyScrollNode` from `abstractTree.ts`. Heights and positions are
/// terminal rows rather than pixels.
pub fn StickyScrollNode(comptime Node: type) type {
    return struct {
        node: *const Node,
        start_index: usize,
        end_index: usize,
        height: f64,
        position: f64,
        source_node_end: f64,
        source_node_partially_visible: bool,
        has_explicit_height: bool,
    };
}

/// Port of `IStickyScrollDelegate`. The delegate may synthesize nodes (the
/// compressible tree replaces an overflowing ancestor chain with one compressed
/// row), so it owns those allocations and releases them in `reset`.
pub fn StickyScrollDelegate(comptime Node: type) type {
    const StickyNode = StickyScrollNode(Node);
    return struct {
        context: *anyopaque,
        constrain: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            sticky_nodes: []const StickyNode,
            sticky_scroll_max_item_count: usize,
            max_widget_height: f64,
            out: *std.array_list.Managed(StickyNode),
        ) anyerror!void,
        reset: *const fn (context: *anyopaque) void,
    };
}

/// View over any model exposing `Node`, `collectRendered` and
/// `setCollapsedElement`. This mirrors upstream `AbstractTree`'s use of the
/// `ITreeModel` contract instead of a concrete object model.
pub fn AbstractTreeForModel(comptime T: type, comptime Model: type) type {
    const Node = Model.Node;

    return struct {
        pub const StickyNode = StickyScrollNode(Node);
        pub const StickyDelegate = StickyScrollDelegate(Node);

        /// Window of rendered-row indexes covered by a node
        /// (`getNodeRange` upstream).
        pub const NodeRange = struct {
            start_index: usize,
            end_index: usize,
        };

        pub const RenderRow = *const fn (
            context: *anyopaque,
            row: *const list.Row,
            node: *const Node,
        ) void;

        pub const Renderer = struct {
            context: *anyopaque,
            render: RenderRow,
        };

        allocator: std.mem.Allocator,
        model: *Model,
        widget: list_widget.ListWidget,
        renderer: Renderer,
        options: Options = .{},
        rendered: std.array_list.Managed(*Node),
        selection_context: ?*anyopaque = null,
        on_activate: ?*const fn (context: ?*anyopaque, element: T) void = null,

        /// Current sticky-scroll projection, top row first. Upstream keeps the
        /// same state in `StickyScrollController`; the terminal recomputes it
        /// before each paint because there is no retained DOM tree.
        sticky_nodes: std.array_list.Managed(StickyNode),
        sticky_constrained: std.array_list.Managed(StickyNode),
        sticky_height: f64 = 0,
        sticky_delegate: ?StickyDelegate = null,
        sticky_focused: bool = false,
        sticky_focused_index: isize = -1,
        sticky_hovered_index: ?usize = null,
        /// List rectangle used by the last sticky paint; hit testing and
        /// painting must agree on the clipped row geometry.
        sticky_rect: ui.Rect = .{},

        pub fn init(
            allocator: std.mem.Allocator,
            model: *Model,
            renderer: Renderer,
            options: Options,
        ) !*AbstractTreeForModel(T, Model) {
            const self = try allocator.create(AbstractTreeForModel(T, Model));
            errdefer allocator.destroy(self);
            // Port of `validateStickySettings`: the sticky item count is at
            // least one.
            var validated_options = options;
            validated_options.sticky_scroll_max_item_count =
                @max(1, validated_options.sticky_scroll_max_item_count);
            self.* = .{
                .allocator = allocator,
                .model = model,
                .widget = list_widget.ListWidget.init(allocator, .{
                    .context = undefined,
                    .get_height = getHeight,
                    .get_template_id = getTemplateId,
                }, .{
                    .context = undefined,
                    .render = renderCallback,
                }),
                .renderer = renderer,
                .options = validated_options,
                .rendered = std.array_list.Managed(*Node).init(allocator),
                .sticky_nodes = std.array_list.Managed(StickyNode).init(allocator),
                .sticky_constrained = std.array_list.Managed(StickyNode).init(allocator),
            };
            self.widget.view.delegate.context = @ptrCast(self);
            self.widget.view.renderer.context = @ptrCast(self);
            try self.refresh();
            return self;
        }

        pub fn deinit(self: *AbstractTreeForModel(T, Model)) void {
            self.invalidateStickyScroll();
            self.sticky_constrained.deinit();
            self.sticky_nodes.deinit();
            self.rendered.deinit();
            self.widget.deinit();
            self.allocator.destroy(self);
        }

        fn getHeight(context: *anyopaque, _: list.Element) f64 {
            _ = context;
            return 1;
        }

        fn getTemplateId(context: *anyopaque, _: list.Element) usize {
            _ = context;
            return 0;
        }

        fn renderCallback(context: *anyopaque, row: *const list.Row, element: list.Element) void {
            const self: *AbstractTreeForModel(T, Model) = @ptrCast(@alignCast(context));
            const node: *const Node = @ptrCast(@alignCast(element));
            self.renderNodeRow(row, node);
        }

        fn renderNodeRow(self: *AbstractTreeForModel(T, Model), row: *const list.Row, node: *const Node) void {
            var options_row = row.*;
            options_row.indent = self.options.indent;
            options_row.render_indent_guides = switch (self.options.render_indent_guides) {
                .none => false,
                .always => true,
                .on_hover => row.list_hovered,
            };
            self.renderer.render(self.renderer.context, &options_row, node);
        }

        /// Installs the sticky-scroll delegate. `CompressibleObjectTree` sets
        /// the compressible delegate after construction because `Options` is
        /// not generic over the node type.
        pub fn setStickyScrollDelegate(self: *AbstractTreeForModel(T, Model), delegate: ?StickyDelegate) void {
            self.sticky_delegate = delegate;
            self.invalidateStickyScroll();
        }

        pub fn stickyScrollNodes(self: *const AbstractTreeForModel(T, Model)) []const StickyNode {
            return self.sticky_nodes.items;
        }

        pub fn stickyScrollHeight(self: *const AbstractTreeForModel(T, Model)) f64 {
            return self.sticky_height;
        }

        pub fn stickyScrollFocused(self: *const AbstractTreeForModel(T, Model)) bool {
            return self.sticky_focused;
        }

        /// Port of `StickyScrollFocus.getFocus`.
        pub fn stickyScrollFocus(self: *const AbstractTreeForModel(T, Model)) ?*const Node {
            if (!self.sticky_focused or self.sticky_focused_index < 0) return null;
            const index: usize = @intCast(self.sticky_focused_index);
            if (index >= self.sticky_nodes.items.len) return null;
            return self.sticky_nodes.items[index].node;
        }

        /// Port of `AbstractTree.handleStickyScrollMouseEvent`: a click on a
        /// pinned row reveals and selects the original node in the tree, so
        /// the row jumps back into the list under the remaining sticky rows.
        fn activateStickyNode(self: *AbstractTreeForModel(T, Model), sticky_index: usize) void {
            if (sticky_index >= self.sticky_nodes.items.len) return;
            const sticky = self.sticky_nodes.items[sticky_index];
            const node_index = self.getNodeIndex(sticky.node) orelse return;

            const element_scroll_top = self.widget.view.range_map.positionAt(@intCast(node_index));
            const element_target_view_top = self.nodePositionTopBelowWidget(sticky.node);
            self.widget.view.setScrollTop(element_scroll_top - element_target_view_top);
            self.clearStickyScrollFocus();
            self.widget.setFocus(true);
            self.widget.setSelection(node_index);
        }

        /// Port of `StickyScrollFocus.domFocus`. The terminal has no DOM focus,
        /// so this only moves the tree's focus marker to the sticky widget.
        pub fn focusStickyScroll(self: *AbstractTreeForModel(T, Model)) bool {
            if (self.sticky_nodes.items.len == 0) return false;
            if (!self.sticky_focused) {
                self.sticky_focused = true;
                if (self.sticky_focused_index < 0) {
                    self.sticky_focused_index = 0;
                } else {
                    self.sticky_focused_index = @min(
                        self.sticky_focused_index,
                        @as(isize, @intCast(self.sticky_nodes.items.len - 1)),
                    );
                }
            }
            self.widget.setFocus(true);
            return true;
        }

        /// Leaves the sticky widget and returns the focus marker to the list.
        /// Upstream does this from `view.onDidFocus` and `onBlur`; it keeps the
        /// passive sticky index so Tab returns to the same pinned row.
        pub fn clearStickyScrollFocus(self: *AbstractTreeForModel(T, Model)) void {
            self.sticky_focused = false;
        }

        /// Row of the sticky widget under viewport cell `(x, y)`, if any.
        pub fn stickyRowAt(self: *const AbstractTreeForModel(T, Model), x: usize, y: usize) ?usize {
            if (self.sticky_nodes.items.len == 0) return null;
            const left = ui.cell.snap(self.sticky_rect.x);
            const top = ui.cell.snap(self.sticky_rect.y);
            const width = ui.cell.snap(self.sticky_rect.w);
            const height = ui.cell.snap(self.sticky_rect.h);
            if (x < left or x >= left + width or y < top or y >= top + height) return null;
            const row: f64 = @floatFromInt(y - top);
            for (self.sticky_nodes.items, 0..) |sticky, index| {
                const visible_top = @ceil(sticky.position);
                if (row >= visible_top and row < @floor(sticky.position + sticky.height)) return index;
            }
            return null;
        }

        /// Port of `StickyScrollController.update`. Returns nothing and keeps
        /// the previous (empty) state on allocation failure, like a paint-time
        /// widget that simply does not appear.
        fn updateStickyScroll(self: *AbstractTreeForModel(T, Model)) void {
            if (!self.options.enable_sticky_scroll) {
                self.invalidateStickyScroll();
                return;
            }

            self.resetStickyState();
            if (self.widget.view.viewport_height <= 0 or self.widget.view.scroll_top <= 0) {
                self.clampStickyScrollFocus();
                return;
            }

            const first_visible = self.getNodeAtHeight(0) orelse {
                self.clampStickyScrollFocus();
                return;
            };

            self.findStickyState(first_visible) catch {
                self.resetStickyState();
            };
            self.clampStickyScrollFocus();
        }

        fn resetStickyState(self: *AbstractTreeForModel(T, Model)) void {
            if (self.sticky_delegate) |delegate| delegate.reset(delegate.context);
            self.sticky_nodes.clearRetainingCapacity();
            self.sticky_constrained.clearRetainingCapacity();
            self.sticky_height = 0;
        }

        fn invalidateStickyScroll(self: *AbstractTreeForModel(T, Model)) void {
            self.resetStickyState();
            self.sticky_focused = false;
            self.sticky_focused_index = -1;
            self.sticky_hovered_index = null;
        }

        fn clampStickyScrollFocus(self: *AbstractTreeForModel(T, Model)) void {
            if (self.sticky_nodes.items.len == 0) {
                self.sticky_focused = false;
                self.sticky_focused_index = -1;
                self.sticky_hovered_index = null;
                return;
            }
            if (self.sticky_focused_index >= @as(isize, @intCast(self.sticky_nodes.items.len))) {
                self.sticky_focused_index = @as(isize, @intCast(self.sticky_nodes.items.len - 1));
            }
            if (self.sticky_focused and self.sticky_focused_index < 0) {
                self.sticky_focused_index = 0;
            }
            if (self.sticky_hovered_index) |hovered| {
                if (hovered >= self.sticky_nodes.items.len) self.sticky_hovered_index = null;
            }
        }

        fn getNodeAtHeight(self: *AbstractTreeForModel(T, Model), height: f64) ?*Node {
            const position = if (height == 0)
                self.widget.view.scroll_top
            else
                height + self.widget.view.scroll_top;
            const index = self.widget.view.range_map.indexAt(position);
            if (index < 0) return null;
            const value: usize = @intCast(index);
            if (value >= self.rendered.items.len) return null;
            return self.rendered.items[value];
        }

        fn findStickyState(self: *AbstractTreeForModel(T, Model), first_visible: *Node) !void {
            var first_under: *Node = first_visible;
            var sticky_nodes_height: f64 = 0;
            var previous: ?*const Node = null;

            var next = self.getNextStickyNode(first_under, previous, sticky_nodes_height);
            while (next) |sticky| {
                try self.sticky_nodes.append(sticky);
                sticky_nodes_height += sticky.height;

                if (self.sticky_nodes.items.len <= self.options.sticky_scroll_max_item_count) {
                    first_under = self.getNextVisibleNode(sticky) orelse break;
                }

                previous = sticky.node;
                next = self.getNextStickyNode(first_under, previous, sticky_nodes_height);
            }

            try self.constrainStickyNodes();
            if (self.sticky_nodes.items.len > 0) {
                const last = self.sticky_nodes.items[self.sticky_nodes.items.len - 1];
                self.sticky_height = @max(0, last.position + last.height);
            }
        }

        fn getNextVisibleNode(self: *AbstractTreeForModel(T, Model), previous: StickyNode) ?*Node {
            return self.getNodeAtHeight(previous.position + previous.height);
        }

        fn getNextStickyNode(
            self: *AbstractTreeForModel(T, Model),
            first_visible_under: *Node,
            previous: ?*const Node,
            sticky_nodes_height: f64,
        ) ?StickyNode {
            const next_node = self.getAncestorUnderPrevious(first_visible_under, previous) orelse return null;

            if (next_node == first_visible_under and !self.nodeIsUncollapsedParent(first_visible_under)) {
                return null;
            }

            const source_range = self.getStickyScrollNodeSourceRange(next_node) orelse return null;
            if (!std.math.isFinite(source_range.start) or
                !std.math.isFinite(source_range.end) or
                source_range.end <= source_range.start)
            {
                return null;
            }

            const index = self.getNodeIndex(next_node) orelse return null;
            const source_node_top = self.widget.view.range_map.positionAt(@intCast(index));
            const sticky_viewport_bottom = self.widget.view.scroll_top + sticky_nodes_height;
            if (sticky_viewport_bottom <= source_node_top + source_range.start) return null;

            const height = self.getStickyScrollNodeHeight(source_range, sticky_nodes_height);
            const source_node_partially_visible =
                sticky_viewport_bottom + height < source_node_top + source_range.end;

            const range = self.getNodeRange(next_node) orelse return null;
            return self.createStickyScrollNode(
                next_node,
                range,
                sticky_nodes_height,
                height,
                source_range.end,
                source_node_partially_visible,
                source_range.sticky_node_height != null,
            );
        }

        fn getStickyScrollNodeSourceRange(
            self: *AbstractTreeForModel(T, Model),
            node: *const Node,
        ) ?StickyScrollNodeSourceRange {
            const default_range = StickyScrollNodeSourceRange{
                .start = 0,
                .end = self.getNodeHeight(node),
            };
            const provider = self.options.sticky_scroll_node_source_range_provider orelse return default_range;
            const element = node.element orelse return default_range;
            var value = element;
            return provider.get(provider.context, @ptrCast(&value), default_range);
        }

        fn getStickyScrollNodeHeight(
            self: *AbstractTreeForModel(T, Model),
            source_range: StickyScrollNodeSourceRange,
            current_sticky_nodes_height: f64,
        ) f64 {
            const height = self.clampNodeHeight(
                source_range.sticky_node_height orelse (source_range.end - source_range.start),
            );
            if (!source_range.estimated) return height;

            const available = @max(
                1,
                self.widget.view.viewport_height * 0.4 - current_sticky_nodes_height,
            );
            return @min(height, available);
        }

        fn getNodeHeight(self: *AbstractTreeForModel(T, Model), node: *const Node) f64 {
            return self.widget.view.delegate.height(@ptrCast(node));
        }

        fn clampNodeHeight(self: *AbstractTreeForModel(T, Model), height: f64) f64 {
            const max = self.options.sticky_scroll_max_node_height orelse return height;
            return @min(height, max);
        }

        fn createStickyScrollNode(
            self: *AbstractTreeForModel(T, Model),
            node: *Node,
            range: NodeRange,
            current_sticky_nodes_height: f64,
            height: f64,
            source_node_end: f64,
            source_node_partially_visible: bool,
            has_explicit_height: bool,
        ) StickyNode {
            return .{
                .node = node,
                .position = self.calculateStickyNodePosition(range.end_index, current_sticky_nodes_height, height),
                .height = height,
                .start_index = range.start_index,
                .end_index = range.end_index,
                .source_node_end = source_node_end,
                .source_node_partially_visible = source_node_partially_visible,
                .has_explicit_height = has_explicit_height,
            };
        }

        fn getNodeIndex(self: *const AbstractTreeForModel(T, Model), node: *const Node) ?usize {
            for (self.rendered.items, 0..) |candidate, index| {
                if (candidate == node) return index;
            }
            return null;
        }

        fn getNodeRange(self: *const AbstractTreeForModel(T, Model), node: *const Node) ?NodeRange {
            const start_index = self.getNodeIndex(node) orelse return null;
            const render_count = node.render_node_count;
            if (render_count == 0) return null;
            return .{
                .start_index = start_index,
                .end_index = start_index + render_count - 1,
            };
        }

        fn getAncestorUnderPrevious(
            self: *const AbstractTreeForModel(T, Model),
            node: *const Node,
            previous: ?*const Node,
        ) ?*Node {
            var current: *Node = @constCast(node);
            var parent = self.getParentNode(current);
            while (parent) |value| {
                if (previous) |expected| {
                    if (expected == value) return current;
                }
                current = value;
                parent = self.getParentNode(current);
            }
            if (previous == null) return current;
            return null;
        }

        fn getParentNode(self: *const AbstractTreeForModel(T, Model), node: *Node) ?*Node {
            _ = self;
            const parent = node.parent orelse return null;
            // The virtual model root has no element and is never a sticky row.
            // Upstream's object model exposes it as the null element.
            if (parent.parent == null) return null;
            return parent;
        }

        fn nodeIsUncollapsedParent(self: *const AbstractTreeForModel(T, Model), node: *const Node) bool {
            _ = self;
            return node.render_node_count > 1;
        }

        fn calculateStickyNodePosition(
            self: *AbstractTreeForModel(T, Model),
            last_descendant_index: usize,
            sticky_row_position_top: f64,
            sticky_node_height: f64,
        ) f64 {
            const last_child_height = self.widget.view.delegate.height(@ptrCast(self.rendered.items[last_descendant_index]));
            const bottom_of_last_child =
                self.widget.view.range_map.positionAt(@intCast(last_descendant_index)) +
                last_child_height - self.widget.view.scroll_top;

            if (sticky_row_position_top + sticky_node_height > bottom_of_last_child and
                sticky_row_position_top <= bottom_of_last_child)
            {
                return bottom_of_last_child - sticky_node_height;
            }

            return sticky_row_position_top;
        }

        fn constrainStickyNodes(self: *AbstractTreeForModel(T, Model)) !void {
            if (self.sticky_nodes.items.len == 0) return;

            const maximum_sticky_widget_height = self.widget.view.viewport_height * 0.4;
            const last = self.sticky_nodes.items[self.sticky_nodes.items.len - 1];
            if (self.sticky_nodes.items.len <= self.options.sticky_scroll_max_item_count and
                last.position + last.height <= maximum_sticky_widget_height)
            {
                return;
            }

            if (self.sticky_delegate) |delegate| {
                self.sticky_constrained.clearRetainingCapacity();
                try delegate.constrain(
                    delegate.context,
                    self.allocator,
                    self.sticky_nodes.items,
                    self.options.sticky_scroll_max_item_count,
                    maximum_sticky_widget_height,
                    &self.sticky_constrained,
                );
                self.sticky_nodes.clearRetainingCapacity();
                try self.sticky_nodes.appendSlice(self.sticky_constrained.items);
            } else {
                // Port of `DefaultStickyScrollDelegate`.
                var keep: usize = self.sticky_nodes.items.len;
                for (self.sticky_nodes.items, 0..) |sticky, index| {
                    const bottom = sticky.position + sticky.height;
                    if (bottom > maximum_sticky_widget_height or
                        index >= self.options.sticky_scroll_max_item_count)
                    {
                        keep = index;
                        break;
                    }
                }
                self.sticky_nodes.shrinkRetainingCapacity(keep);
            }

            if (self.sticky_nodes.items.len == 0) return;
            const constrained_last = self.sticky_nodes.items[self.sticky_nodes.items.len - 1];
            if (self.sticky_nodes.items.len > self.options.sticky_scroll_max_item_count or
                constrained_last.position + constrained_last.height > maximum_sticky_widget_height)
            {
                // Upstream throws when a delegate violates the sticky
                // constraints; keep the failure typed and hide the widget.
                return error.StickyScrollDelegateViolation;
            }
        }

        /// Port of `StickyScrollController.nodePositionTopBelowWidget`: the
        /// number of rows hidden by the sticky widget above `node`.
        pub fn nodePositionTopBelowWidget(self: *AbstractTreeForModel(T, Model), node: *const Node) f64 {
            var widget_height: f64 = 0;
            var ancestor_count: usize = 0;
            var current = self.getParentNode(@constCast(node));
            while (current) |ancestor| {
                if (ancestor_count >= self.options.sticky_scroll_max_item_count) break;
                if (self.getStickyScrollNodeSourceRange(ancestor)) |source_range| {
                    widget_height += self.getStickyScrollNodeHeight(source_range, widget_height);
                }
                ancestor_count += 1;
                current = self.getParentNode(ancestor);
            }
            return widget_height;
        }

        fn lastStickyNodePartiallyVisible(self: *const AbstractTreeForModel(T, Model)) bool {
            const sticky_count = self.sticky_nodes.items.len;
            if (sticky_count == 0) return false;
            const last = self.sticky_nodes.items[sticky_count - 1];
            if (sticky_count == 1) return last.position != 0;
            const second_last = self.sticky_nodes.items[sticky_count - 2];
            return second_last.position + second_last.height != last.position;
        }

        fn setStickyFocusedElement(self: *AbstractTreeForModel(T, Model), sticky_index: usize) void {
            if (sticky_index >= self.sticky_nodes.items.len) return;
            self.sticky_focused_index = @intCast(sticky_index);
            self.sticky_focused = true;

            if (sticky_index + 1 == self.sticky_nodes.items.len and self.lastStickyNodePartiallyVisible()) {
                const last = self.sticky_nodes.items[sticky_index];
                self.scrollNodeUnderWidget(last.end_index + 1);
            }
        }

        fn scrollNodeUnderWidget(self: *AbstractTreeForModel(T, Model), node_index: usize) void {
            const sticky_count = self.sticky_nodes.items.len;
            if (sticky_count == 0) return;
            if (node_index >= self.rendered.items.len) return;
            const last = self.sticky_nodes.items[sticky_count - 1];
            const second_last: ?StickyNode = if (sticky_count > 1) self.sticky_nodes.items[sticky_count - 2] else null;

            const element_scroll_top = self.widget.view.range_map.positionAt(@intCast(node_index));
            const element_target_view_top = if (second_last) |value|
                value.position + value.height + last.height
            else
                last.height;
            self.widget.view.setScrollTop(element_scroll_top - element_target_view_top);
        }

        fn moveStickyFocusIntoTree(self: *AbstractTreeForModel(T, Model)) void {
            const sticky_count = self.sticky_nodes.items.len;
            if (sticky_count == 0) return;
            const last = self.sticky_nodes.items[sticky_count - 1];
            // Upstream `onKeyDown`: move into the first child of the last
            // sticky node (startIndex + 1), not past its whole subtree.
            const node_index = last.start_index + 1;
            if (node_index >= self.rendered.items.len) return;
            self.clearStickyScrollFocus();
            self.widget.setSelection(node_index);
            self.scrollNodeUnderWidget(node_index);
        }

        /// Port of `revealFocusedStickyScroll`: focus/select the sticky node in
        /// the tree, optionally collapsing it (`list.stickyScroll.collapse`).
        fn revealFocusedSticky(self: *AbstractTreeForModel(T, Model), collapse: bool) void {
            const node = self.stickyScrollFocus() orelse return;
            self.setSelectionNode(@constCast(node));
            self.widget.setFocus(true);
            self.clearStickyScrollFocus();
            if (!collapse) return;

            const element = node.element orelse return;
            _ = self.model.setCollapsedElement(element, true, false) catch return;
            self.refresh() catch {};
        }

        fn onStickyScrollKey(self: *AbstractTreeForModel(T, Model), event: *const ui.KeyEvent) bool {
            self.updateStickyScroll();
            if (self.sticky_nodes.items.len == 0) {
                self.clearStickyScrollFocus();
                return false;
            }

            const sticky_count = self.sticky_nodes.items.len;
            const current: isize = @max(0, self.sticky_focused_index);
            switch (event.key) {
                .up => {
                    self.setStickyFocusedElement(@intCast(@max(0, current - 1)));
                    return true;
                },
                .down, .right => {
                    if (current >= @as(isize, @intCast(sticky_count - 1))) {
                        self.moveStickyFocusIntoTree();
                    } else {
                        self.setStickyFocusedElement(@intCast(current + 1));
                    }
                    return true;
                },
                // `list.stickyScroll.collapse` (higher priority than
                // list.collapse while the sticky widget is focused).
                .left => {
                    self.revealFocusedSticky(true);
                    return true;
                },
                // `list.stickyScrollselect` / `list.stickyScrolltoggleExpand`:
                // reveal the sticky node in the tree.
                .enter => {
                    self.revealFocusedSticky(false);
                    return true;
                },
                .char => |ch| {
                    if (ch == ' ') {
                        self.revealFocusedSticky(false);
                        return true;
                    }
                },
                // Terminal adaptation: upstream leaves the widget with Tab.
                .tab, .backtab, .escape => {
                    self.clearStickyScrollFocus();
                    return true;
                },
                else => {},
            }
            return false;
        }

        pub fn setFocus(self: *AbstractTreeForModel(T, Model), focus: bool) void {
            if (!focus) self.clearStickyScrollFocus();
            self.widget.setFocus(focus);
        }

        pub fn focused(self: *const AbstractTreeForModel(T, Model)) bool {
            return self.widget.focused;
        }

        pub fn count(self: *const AbstractTreeForModel(T, Model)) usize {
            return self.widget.count();
        }

        pub fn selection(self: *AbstractTreeForModel(T, Model)) ?*Node {
            const index = self.widget.selection() orelse return null;
            if (index >= self.rendered.items.len) return null;
            return self.rendered.items[index];
        }

        pub fn setSelectionNode(self: *AbstractTreeForModel(T, Model), node: ?*Node) void {
            if (node) |value| {
                for (self.rendered.items, 0..) |candidate, index| {
                    if (candidate == value) {
                        self.widget.setSelectionWithPadding(index, self.selectionPadding(value));
                        return;
                    }
                }
            }
            self.widget.setSelection(null);
        }

        /// Restores a selection without revealing it, used by model splices
        /// (`refresh`) and Explorer child updates. Upstream splices preserve
        /// the viewport; only explicit reveal/selection calls scroll.
        pub fn setSelectionNodeNoReveal(self: *AbstractTreeForModel(T, Model), node: ?*Node) void {
            if (node) |value| {
                for (self.rendered.items, 0..) |candidate, index| {
                    if (candidate == value) {
                        self.widget.selectOnly(index);
                        return;
                    }
                }
            }
            self.widget.selectOnly(null);
        }

        /// Rows hidden by the sticky widget above `node`, applied when
        /// revealing a selection so the revealed row is not pinned underneath
        /// the sticky headers (upstream `view.reveal(index, top, paddingTop)`).
        fn selectionPadding(self: *AbstractTreeForModel(T, Model), node: *const Node) f64 {
            if (!self.options.enable_sticky_scroll) return 0;
            return self.nodePositionTopBelowWidget(node);
        }

        /// Rebuilds the rendered row projection after a model mutation.
        ///
        /// The selected row index is preserved without revealing it. The
        /// compressible model rebuilds its nodes, so a node pointer captured
        /// before the splice may dangle; upstream lists preserve their
        /// selection across a splice and never scroll because of one.
        pub fn refresh(self: *AbstractTreeForModel(T, Model)) !void {
            self.invalidateStickyScroll();
            const selected_index = self.widget.selection();
            self.rendered.clearRetainingCapacity();
            try self.model.collectRendered(&self.rendered);

            var elements = try self.allocator.alloc(list.Element, self.rendered.items.len);
            defer self.allocator.free(elements);
            for (self.rendered.items, 0..) |node, i| elements[i] = @ptrCast(node);

            const old_count = self.widget.count();
            try self.widget.splice(0, old_count, elements);

            const new_count = self.widget.count();
            if (selected_index) |index| {
                if (new_count == 0) {
                    self.widget.selectOnly(null);
                } else {
                    self.widget.selectOnly(@min(index, new_count - 1));
                }
            } else if (new_count > 0) {
                self.widget.selectOnly(0);
            } else {
                self.widget.selectOnly(null);
            }
        }

        pub fn render(self: *AbstractTreeForModel(T, Model), grid: *ui.CellGrid, rect: ui.Rect) void {
            self.widget.render(grid, rect);
            self.updateStickyScroll();
            self.renderStickyScroll(grid, rect);
        }

        /// Port of `StickyScrollWidget.renderState`: paint each sticky row
        /// through the same tree renderer as a normal row, after the list rows
        /// so it overlays them. Rows are whole cells, so a sticky node whose
        /// source is scrolling out is clipped to the rows it still covers
        /// (upstream clips in pixels).
        fn renderStickyScroll(self: *AbstractTreeForModel(T, Model), grid: *ui.CellGrid, rect: ui.Rect) void {
            if (self.sticky_nodes.items.len == 0) return;
            const x = ui.cell.snap(rect.x);
            const y = ui.cell.snap(rect.y);
            const width = ui.cell.snap(rect.w);
            const height = ui.cell.snap(rect.h);
            if (width == 0 or height == 0) return;
            self.sticky_rect = rect;

            var last_painted: ?usize = null;
            for (self.sticky_nodes.items, 0..) |sticky, index| {
                const visible_top = @ceil(sticky.position);
                const visible_bottom = @floor(sticky.position + sticky.height);
                if (visible_bottom <= 0 or visible_top >= @as(f64, @floatFromInt(height))) continue;
                last_painted = index;
            }

            for (self.sticky_nodes.items, 0..) |sticky, index| {
                const visible_top = @ceil(sticky.position);
                const visible_bottom = @floor(sticky.position + sticky.height);
                if (visible_bottom <= 0 or visible_top >= @as(f64, @floatFromInt(height))) continue;
                const clipped_top = @max(visible_top, 0);
                const clipped_bottom = @min(visible_bottom, @as(f64, @floatFromInt(height)));
                if (clipped_bottom <= clipped_top) continue;

                const row_top: usize = @intFromFloat(clipped_top);
                const row_bottom: usize = @intFromFloat(clipped_bottom);
                var row = list.Row{
                    .grid = grid,
                    .x = x,
                    .y = y + row_top,
                    .width = width,
                    .height = row_bottom - row_top,
                    .index = sticky.start_index,
                    .selected = false,
                    .focused = false,
                    .focused_selection = false,
                    .hovered = self.sticky_hovered_index != null and self.sticky_hovered_index.? == index,
                    .list_hovered = self.sticky_hovered_index != null,
                    .sticky = true,
                    .sticky_focused = self.sticky_focused and self.sticky_focused_index == @as(isize, @intCast(index)),
                    .sticky_hovered = self.sticky_hovered_index != null and self.sticky_hovered_index.? == index,
                    .sticky_last = last_painted != null and last_painted.? == index,
                };
                self.renderNodeRow(&row, sticky.node);
            }
        }

        pub fn handleKey(self: *AbstractTreeForModel(T, Model), event: *const ui.KeyEvent) bool {
            if (self.sticky_focused) {
                if (self.onStickyScrollKey(event)) return true;
            }
            if (self.options.enable_sticky_scroll and event.key == .page_up) {
                // Upstream `focusPreviousPage` reserves the sticky widget
                // height, so page-up does not land a row underneath it.
                return self.widget.handleKeyWithPadding(event, self.sticky_height);
            }
            if (!self.widget.focused) return false;
            switch (event.key) {
                .left => {
                    const node = self.selection() orelse return true;
                    const element = node.element orelse return true;
                    if (node.collapsible and !node.collapsed) {
                        if (@hasDecl(Model, "setCollapsedElement")) {
                            _ = self.model.setCollapsedElement(element, true, false) catch {};
                        } else {
                            _ = self.model.setCollapsed(element, true, false) catch {};
                        }
                        self.refresh() catch {};
                    } else if (node.parent) |parent| {
                        if (parent.element != null) self.setSelectionNode(parent);
                    }
                    return true;
                },
                .right => {
                    const node = self.selection() orelse return true;
                    const element = node.element orelse return true;
                    if (node.collapsible and node.collapsed) {
                        if (@hasDecl(Model, "setCollapsedElement")) {
                            _ = self.model.setCollapsedElement(element, false, false) catch {};
                        } else {
                            _ = self.model.setCollapsed(element, false, false) catch {};
                        }
                        self.refresh() catch {};
                    } else if (node.children.items.len > 0) {
                        self.setSelectionNode(node.children.items[0]);
                    }
                    return true;
                },
                else => return self.widget.handleKey(event),
            }
        }

        pub fn handleMouse(self: *AbstractTreeForModel(T, Model), event: *const ui.MouseEvent) bool {
            if (self.stickyRowAt(event.x, event.y)) |index| {
                switch (event.kind) {
                    .move => {
                        self.sticky_hovered_index = index;
                        return true;
                    },
                    .down => {
                        if (event.button == .left) {
                            self.activateStickyNode(index);
                            return true;
                        }
                    },
                    // The sticky widget overlays the scrollable list; a wheel
                    // event over it still scrolls the tree, like upstream.
                    .wheel => {},
                    else => {},
                }
            } else if (event.kind == .move or event.kind == .down) {
                self.sticky_hovered_index = null;
            }

            if (event.kind == .down) self.clearStickyScrollFocus();
            return self.widget.handleMouse(event);
        }

        pub fn clearHover(self: *AbstractTreeForModel(T, Model)) void {
            self.sticky_hovered_index = null;
            self.widget.clearHover();
        }

        pub fn selectedElement(self: *AbstractTreeForModel(T, Model)) ?T {
            const node = self.selection() orelse return null;
            return node.element;
        }

        pub fn setActivateHandler(
            self: *AbstractTreeForModel(T, Model),
            context: ?*anyopaque,
            handler: *const fn (context: ?*anyopaque, element: T) void,
        ) void {
            self.selection_context = context;
            self.on_activate = handler;
            self.widget.activation_context = @ptrCast(self);
            self.widget.on_activate = activateCallback;
        }

        fn activateCallback(context: ?*anyopaque, _: usize) void {
            const self: *AbstractTreeForModel(T, Model) = @ptrCast(@alignCast(context orelse return));
            const node = self.selection() orelse return;
            if (node.element) |element| {
                if (self.on_activate) |handler| handler(self.selection_context, element);
            }
        }
    };
}

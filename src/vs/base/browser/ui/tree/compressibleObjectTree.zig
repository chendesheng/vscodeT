// Port of `CompressibleObjectTree` and the compressed renderer wrapper from
// `src/vs/base/browser/ui/tree/objectTree.ts`.
//
// Terminal adaptation: `CompressibleRenderer` is folded into this adapter.
// Callers receive compressed-model nodes from the render callback and can
// branch on `node.element.elements.len`, exactly like upstream's renderer
// choosing between `renderElement` and `renderCompressedElements`. Selection
// and activation expose the final element (upstream's default `ElementMapper`).
// `CompressibleStickyScrollDelegate` is ported as well: when the sticky widget
// would overflow, the ancestor chain renders as one compressed row. The
// compressed navigation controller (per-segment focus/hover) is not ported.

const std = @import("std");
const ui = @import("ui");
const list = @import("../list/list.zig");
const compressed_model = @import("./compressedObjectTreeModel.zig");
const abstract_tree = @import("./abstractTree.zig");
const tree = @import("./tree.zig");

/// Port of `CompressibleStickyScrollDelegate` from `objectTree.ts`.
///
/// The delegate synthesizes a compressed node for the overflowing ancestor
/// rows. It owns that node and its element slice; both are released by
/// `reset`, which the sticky controller calls before every new state.
fn CompressibleStickyScrollDelegate(comptime T: type) type {
    const Model = compressed_model.CompressedObjectTreeModel(T);
    const CompressedNode = compressed_model.CompressedTreeNode(T);
    const Node = Model.Node;
    const StickyNode = abstract_tree.StickyScrollNode(Node);
    const Delegate = abstract_tree.StickyScrollDelegate(Node);

    return struct {
        allocator: std.mem.Allocator,
        model: *Model,
        synthesized_nodes: std.array_list.Managed(*Node),
        synthesized_elements: std.array_list.Managed([]const T),

        const Self = @This();

        fn init(allocator: std.mem.Allocator, model: *Model) Self {
            return .{
                .allocator = allocator,
                .model = model,
                .synthesized_nodes = std.array_list.Managed(*Node).init(allocator),
                .synthesized_elements = std.array_list.Managed([]const T).init(allocator),
            };
        }

        fn deinit(self: *Self) void {
            self.resetNodes();
            self.synthesized_nodes.deinit();
            self.synthesized_elements.deinit();
        }

        fn interface(self: *Self) Delegate {
            return .{
                .context = @ptrCast(self),
                .constrain = constrain,
                .reset = reset,
            };
        }

        fn reset(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.resetNodes();
        }

        fn resetNodes(self: *Self) void {
            for (self.synthesized_elements.items) |elements| self.allocator.free(elements);
            self.synthesized_elements.clearRetainingCapacity();
            for (self.synthesized_nodes.items) |node| {
                node.children.deinit();
                self.allocator.destroy(node);
            }
            self.synthesized_nodes.clearRetainingCapacity();
        }

        fn constrain(
            context: *anyopaque,
            allocator: std.mem.Allocator,
            sticky_nodes: []const StickyNode,
            sticky_scroll_max_item_count: usize,
            max_widget_height: f64,
            out: *std.array_list.Managed(StickyNode),
        ) anyerror!void {
            _ = allocator;
            const self: *Self = @ptrCast(@alignCast(context));
            if (sticky_nodes.len == 0) return;

            const max_item_count = @max(1, sticky_scroll_max_item_count);
            for (sticky_nodes, 0..) |sticky, index| {
                const sticky_node_bottom = sticky.position + sticky.height;
                const following_reaches_max_height =
                    index + 1 < sticky_nodes.len and
                    sticky_node_bottom + sticky_nodes[index + 1].height > max_widget_height;

                if (following_reaches_max_height or
                    (index >= max_item_count - 1 and max_item_count < sticky_nodes.len))
                {
                    try out.appendSlice(sticky_nodes[0..index]);
                    try out.append(try self.compressStickyNodes(sticky_nodes[index..]));
                    return;
                }
            }

            try out.appendSlice(sticky_nodes);
        }

        fn compressStickyNodes(self: *Self, sticky_nodes: []const StickyNode) !StickyNode {
            const first = sticky_nodes[0];
            if (!self.model.isCompressionEnabled()) return first;

            var elements: std.array_list.Managed(T) = .init(self.allocator);
            for (sticky_nodes, 0..) |sticky, index| {
                const compressed = sticky.node.element orelse continue;
                if (compressed.elements.len == 0) continue;
                // An incompressible element cannot merge with its parent, so
                // the compressed chain stops before it (after the first row).
                if (index != 0 and compressed.incompressible) break;
                try elements.appendSlice(compressed.elements);
            }

            if (elements.items.len < 2) {
                elements.deinit();
                return first;
            }

            const owned_elements = try elements.toOwnedSlice();
            self.synthesized_elements.append(owned_elements) catch |err| {
                self.allocator.free(owned_elements);
                return err;
            };

            const node = try self.allocator.create(Node);
            node.* = .{
                .element = CompressedNode{ .elements = owned_elements, .incompressible = false },
                .parent = first.node.parent,
                .children = std.array_list.Managed(*Node).init(self.allocator),
                .depth = first.node.depth,
                .collapsible = first.node.collapsible,
                .collapsed = first.node.collapsed,
                .render_node_count = first.node.render_node_count,
                .visibility = first.node.visibility,
                .visible = first.node.visible,
            };
            self.synthesized_nodes.append(node) catch |err| {
                node.children.deinit();
                self.allocator.destroy(node);
                return err;
            };

            const last = sticky_nodes[sticky_nodes.len - 1];
            var source_node_partially_visible = false;
            for (sticky_nodes) |sticky| {
                source_node_partially_visible =
                    source_node_partially_visible or sticky.source_node_partially_visible;
            }

            return .{
                .node = node,
                .start_index = first.start_index,
                .end_index = last.end_index,
                .height = first.height,
                .position = first.position,
                .source_node_end = first.source_node_end,
                .source_node_partially_visible = source_node_partially_visible,
                .has_explicit_height = first.has_explicit_height,
            };
        }
    };
}

pub fn CompressibleObjectTree(comptime T: type) type {
    const Model = compressed_model.CompressedObjectTreeModel(T);
    const CompressedNode = compressed_model.CompressedTreeNode(T);
    const View = abstract_tree.AbstractTreeForModel(CompressedNode, Model);
    const StickyCompression = CompressibleStickyScrollDelegate(T);

    return struct {
        pub const Element = compressed_model.CompressedTreeElement(T);
        pub const Node = Model.Node;
        pub const ViewType = View;

        allocator: std.mem.Allocator,
        model: *Model,
        view: *View,
        /// Owned compressible sticky delegate, installed only when sticky
        /// scroll is enabled.
        sticky_compression: ?*StickyCompression = null,
        activation_context: ?*anyopaque = null,
        on_activate: ?*const fn (context: ?*anyopaque, element: T) void = null,

        pub fn init(
            allocator: std.mem.Allocator,
            user: []const u8,
            compression_enabled: bool,
            renderer: View.Renderer,
            options: abstract_tree.Options,
        ) !*CompressibleObjectTree(T) {
            const self = try allocator.create(CompressibleObjectTree(T));
            errdefer allocator.destroy(self);

            const model = try allocator.create(Model);
            errdefer allocator.destroy(model);
            model.* = try Model.init(allocator, user, compression_enabled);
            errdefer model.deinit();

            const view = try View.init(allocator, model, renderer, options);
            errdefer view.deinit();

            var sticky_compression: ?*StickyCompression = null;
            if (options.enable_sticky_scroll) {
                const compression = try allocator.create(StickyCompression);
                errdefer allocator.destroy(compression);
                compression.* = StickyCompression.init(allocator, model);
                view.setStickyScrollDelegate(compression.interface());
                sticky_compression = compression;
            }

            self.* = .{
                .allocator = allocator,
                .model = model,
                .view = view,
                .sticky_compression = sticky_compression,
            };
            return self;
        }

        pub fn deinit(self: *CompressibleObjectTree(T)) void {
            self.view.deinit();
            if (self.sticky_compression) |compression| {
                compression.deinit();
                self.allocator.destroy(compression);
            }
            self.model.deinit();
            self.allocator.destroy(self.model);
            self.allocator.destroy(self);
        }

        /// Upstream `DefaultElementMapper`: a compressed node resolves to its
        /// last element, so callers keep seeing plain `T` values.
        pub fn elementOfNode(node: *const Node) ?T {
            const compressed = node.element orelse return null;
            if (compressed.elements.len == 0) return null;
            return compressed.elements[compressed.elements.len - 1];
        }

        pub fn setChildren(self: *CompressibleObjectTree(T), element: ?T, children: []const Element) !void {
            try self.model.setChildren(element, children);
            try self.view.refresh();
        }

        pub fn setFilter(self: *CompressibleObjectTree(T), filter: ?tree.TreeFilter(T)) !void {
            try self.model.setFilter(filter);
            try self.view.refresh();
        }

        pub fn refilter(self: *CompressibleObjectTree(T)) !void {
            try self.model.refilter();
            try self.view.refresh();
        }

        pub fn has(self: *CompressibleObjectTree(T), element: ?T) bool {
            return self.model.has(element);
        }

        pub fn count(self: *const CompressibleObjectTree(T)) usize {
            return self.view.count();
        }

        pub fn isCompressionEnabled(self: *const CompressibleObjectTree(T)) bool {
            return self.model.isCompressionEnabled();
        }

        pub fn setCompressionEnabled(self: *CompressibleObjectTree(T), enabled: bool) !void {
            if (self.model.isCompressionEnabled() == enabled) return;
            try self.model.setCompressionEnabled(enabled);
            try self.view.refresh();
        }

        pub fn isCollapsed(self: *CompressibleObjectTree(T), element: ?T) bool {
            return self.model.isCollapsed(element);
        }

        pub fn setCollapsed(self: *CompressibleObjectTree(T), element: ?T, collapsed: bool, recursive: bool) !bool {
            const changed = try self.model.setCollapsed(element, collapsed, recursive);
            if (changed) try self.view.refresh();
            return changed;
        }

        pub fn isCollapsible(self: *CompressibleObjectTree(T), element: ?T) bool {
            return self.model.isCollapsible(element);
        }

        pub fn selectionNode(self: *CompressibleObjectTree(T)) ?*Node {
            return self.view.selection();
        }

        pub fn selectionElement(self: *CompressibleObjectTree(T)) ?T {
            const node = self.view.selection() orelse return null;
            return elementOfNode(node);
        }

        pub fn setSelectionNode(self: *CompressibleObjectTree(T), node: ?*Node) void {
            self.view.setSelectionNode(node);
        }

        pub fn setSelectionElement(self: *CompressibleObjectTree(T), element: ?T) void {
            var node: ?*Node = null;
            if (element) |value| node = self.model.getNode(value) catch null;
            self.view.setSelectionNode(node);
        }

        /// Restores the selection after a child update without scrolling.
        pub fn setSelectionElementNoReveal(self: *CompressibleObjectTree(T), element: ?T) void {
            var node: ?*Node = null;
            if (element) |value| node = self.model.getNode(value) catch null;
            self.view.setSelectionNodeNoReveal(node);
        }

        pub fn renderedNode(self: *CompressibleObjectTree(T), index: usize) ?*Node {
            if (index >= self.view.rendered.items.len) return null;
            return self.view.rendered.items[index];
        }

        pub fn setFocus(self: *CompressibleObjectTree(T), focus: bool) void {
            self.view.setFocus(focus);
        }

        /// Sticky-scroll state after the last paint. Mirrors upstream
        /// `AbstractTree.getStickyScrollFocus()` / `stickyScrollDomNode`.
        pub fn stickyScrollNodes(self: *const CompressibleObjectTree(T)) []const View.StickyNode {
            return self.view.stickyScrollNodes();
        }

        pub fn stickyScrollFocused(self: *const CompressibleObjectTree(T)) bool {
            return self.view.stickyScrollFocused();
        }

        pub fn stickyScrollFocus(self: *const CompressibleObjectTree(T)) ?*const Node {
            return self.view.stickyScrollFocus();
        }

        pub fn focusStickyScroll(self: *CompressibleObjectTree(T)) bool {
            return self.view.focusStickyScroll();
        }

        pub fn clearStickyScrollFocus(self: *CompressibleObjectTree(T)) void {
            self.view.clearStickyScrollFocus();
        }

        pub fn stickyRowAt(self: *const CompressibleObjectTree(T), x: usize, y: usize) ?usize {
            return self.view.stickyRowAt(x, y);
        }

        pub fn render(self: *CompressibleObjectTree(T), grid: *ui.CellGrid, rect: ui.Rect) void {
            self.view.render(grid, rect);
        }

        pub fn handleKey(self: *CompressibleObjectTree(T), event: *const ui.KeyEvent) bool {
            return self.view.handleKey(event);
        }

        pub fn handleMouse(self: *CompressibleObjectTree(T), event: *const ui.MouseEvent) bool {
            return self.view.handleMouse(event);
        }

        pub fn clearHover(self: *CompressibleObjectTree(T)) void {
            self.view.clearHover();
        }

        pub fn setActivateHandler(
            self: *CompressibleObjectTree(T),
            context: ?*anyopaque,
            handler: *const fn (context: ?*anyopaque, element: T) void,
        ) void {
            self.activation_context = context;
            self.on_activate = handler;
            self.view.setActivateHandler(self, activateCallback);
        }

        fn activateCallback(context: ?*anyopaque, compressed: CompressedNode) void {
            const self: *CompressibleObjectTree(T) = @ptrCast(@alignCast(context orelse return));
            const handler = self.on_activate orelse return;
            if (compressed.elements.len == 0) return;
            handler(self.activation_context, compressed.elements[compressed.elements.len - 1]);
        }
    };
}

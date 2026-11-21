// Port of `CompressibleObjectTree` and the compressed renderer wrapper from
// `src/vs/base/browser/ui/tree/objectTree.ts`.
//
// Terminal adaptation: `CompressibleRenderer` is folded into this adapter.
// Callers receive compressed-model nodes from the render callback and can
// branch on `node.element.elements.len`, exactly like upstream's renderer
// choosing between `renderElement` and `renderCompressedElements`. Selection
// and activation expose the final element (upstream's default `ElementMapper`).
// Sticky scroll and the compressed navigation controller are not ported.

const std = @import("std");
const ui = @import("ui");
const list = @import("../list/list.zig");
const compressed_model = @import("./compressedObjectTreeModel.zig");
const abstract_tree = @import("./abstractTree.zig");
const tree = @import("./tree.zig");

pub fn CompressibleObjectTree(comptime T: type) type {
    const Model = compressed_model.CompressedObjectTreeModel(T);
    const CompressedNode = compressed_model.CompressedTreeNode(T);
    const View = abstract_tree.AbstractTreeForModel(CompressedNode, Model);

    return struct {
        pub const Element = compressed_model.CompressedTreeElement(T);
        pub const Node = Model.Node;
        pub const ViewType = View;

        allocator: std.mem.Allocator,
        model: *Model,
        view: *View,
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

            self.* = .{
                .allocator = allocator,
                .model = model,
                .view = view,
            };
            return self;
        }

        pub fn deinit(self: *CompressibleObjectTree(T)) void {
            self.view.deinit();
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

        pub fn renderedNode(self: *CompressibleObjectTree(T), index: usize) ?*Node {
            if (index >= self.view.rendered.items.len) return null;
            return self.view.rendered.items[index];
        }

        pub fn setFocus(self: *CompressibleObjectTree(T), focus: bool) void {
            self.view.setFocus(focus);
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

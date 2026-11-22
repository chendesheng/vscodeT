// Port of the portable state machine of
// `src/vs/base/browser/ui/tree/asyncDataTree.ts`.
//
// Terminal adaptation: upstream's `Iterable<T> | Promise<Iterable<T>>` data
// source contract is represented by `Children(T)`: a synchronous borrowed slice
// or a `Pending(T)` request that the event-loop tick polls. There is no DOM,
// find controller, drag/drop, accessibility layer or sticky scroll here; the
// tree still renders through `CompressibleObjectTree` and the terminal list.
//
// Lazy loading follows upstream:
// - a node starts `stale` and is loaded when it is expanded, revealed or
//   explicitly refreshed;
// - a collapsed node that is refreshed forgets its children and becomes stale
//   again instead of calling the data source;
// - concurrent refresh/expand requests join the node's pending request;
// - `autoExpandSingleChildren` and `autoExpandCompressedChildren` request the
//   single child subtree, matching the workbench options.

const std = @import("std");
const ui = @import("ui");
const list = @import("../list/list.zig");
const compressed_model = @import("./compressedObjectTreeModel.zig");
const compressible_tree = @import("./compressibleObjectTree.zig");
const abstract_tree = @import("./abstractTree.zig");
const tree = @import("./tree.zig");

/// Element passed to `IAsyncDataSource.getChildren`: the tree input for the
/// root, or a plain element for a node.
pub fn DataElement(comptime TInput: type, comptime T: type) type {
    return union(enum) {
        input: TInput,
        item: T,
    };
}

/// One asynchronous `getChildren` request. `poll` returns null while the
/// request is still running. Returned `owned` slices are freed by the tree
/// after it has copied the element pointers; `items` slices stay owned by the
/// data source (the synchronous fast path).
pub fn Pending(comptime T: type) type {
    return struct {
        context: *anyopaque,
        poll: *const fn (context: *anyopaque) ?Result(T),
        cancel: *const fn (context: *anyopaque) void,
    };
}

pub fn Result(comptime T: type) type {
    return union(enum) {
        items: []const T,
        owned: []T,
        err: anyerror,
    };
}

pub fn Children(comptime T: type) type {
    return union(enum) {
        items: []const T,
        pending: Pending(T),
    };
}

pub fn IAsyncDataSource(comptime TInput: type, comptime T: type) type {
    return struct {
        context: *anyopaque,
        has_children: *const fn (context: *anyopaque, element: T) bool,
        get_children: *const fn (
            context: *anyopaque,
            element: DataElement(TInput, T),
        ) Children(T),
    };
}

pub fn CompressionDelegate(comptime T: type) type {
    return struct {
        context: *anyopaque,
        is_incompressible: *const fn (context: *anyopaque, element: T) bool,
    };
}

pub fn CollapseByDefault(comptime T: type) type {
    return struct {
        context: *anyopaque,
        callback: *const fn (context: *anyopaque, element: T) bool,
    };
}

/// Terminal tree options. Compression is a property of the concrete tree type
/// (`AsyncDataTree` versus `CompressibleAsyncDataTree`).
pub const Options = struct {
    compression_enabled: bool = true,
    auto_expand_single_children: bool = false,
    auto_expand_compressed_children: bool = false,
    indent: usize = 2,
    render_indent_guides: abstract_tree.RenderIndentGuides = .on_hover,
    enable_sticky_scroll: bool = false,
    sticky_scroll_max_item_count: usize = 7,
    sticky_scroll_max_node_height: ?f64 = null,
    sticky_scroll_node_source_range_provider: ?abstract_tree.StickyScrollNodeSourceRangeProvider = null,
};

fn AsyncNode(comptime T: type) type {
    return struct {
        const Self = @This();

        element: ?T = null,
        parent: ?*Self = null,
        depth: usize = 0,
        children: std.array_list.Managed(*Self),
        /// `IAsyncDataTreeNode.hasChildren`: the data source's cheap answer,
        /// not whether the children are loaded yet.
        has_children: bool = false,
        /// Children are unknown and must be requested before they can render.
        stale: bool = true,
        /// Set while the node's request is in the pending list.
        pending: bool = false,
        request: ?Pending(T) = null,
        slow: bool = false,
        /// Default collapse state for a newly created wrapper. Preserve the
        /// existing tree state after the node has been rendered once.
        default_collapsed: bool = true,
        initialized: bool = false,
        force_expanded: bool = false,
        collapsed: bool = true,
        loaded: bool = false,
    };
}

pub fn AsyncDataTree(comptime TInput: type, comptime T: type) type {
    return AsyncTree(TInput, T, false);
}

pub fn CompressibleAsyncDataTree(comptime TInput: type, comptime T: type) type {
    return AsyncTree(TInput, T, true);
}

pub fn NavigatorFor(comptime Tree: type) type {
    return struct {
        tree: *Tree,
        index: isize,

        pub fn current(self: *const @This()) ?Tree.ElementType {
            const count: isize = @intCast(self.tree.count());
            if (self.index < 0 or self.index >= count) return null;
            return self.tree.renderedItem(@intCast(self.index));
        }

        pub fn previous(self: *@This()) ?Tree.ElementType {
            self.index -= 1;
            return self.current();
        }

        pub fn next(self: *@This()) ?Tree.ElementType {
            self.index += 1;
            return self.current();
        }

        pub fn first(self: *@This()) ?Tree.ElementType {
            self.index = 0;
            return self.current();
        }

        pub fn last(self: *@This()) ?Tree.ElementType {
            const count: isize = @intCast(self.tree.count());
            self.index = count - 1;
            return self.current();
        }
    };
}

fn AsyncTree(comptime TInput: type, comptime T: type, comptime compressible: bool) type {
    const NodeType = AsyncNode(T);
    const CompressedTree = compressible_tree.CompressibleObjectTree(*NodeType);
    const CompressedNode = compressed_model.CompressedTreeNode(*NodeType);
    const CompressedElement = compressed_model.CompressedTreeElement(*NodeType);
    const Element = DataElement(TInput, T);
    const DataSource = IAsyncDataSource(TInput, T);

    return struct {
        const Self = @This();

        pub const Input = TInput;
        pub const ElementType = T;
        pub const Node = NodeType;
        pub const Tree = CompressedTree;
        pub const RenderRow = *const fn (
            context: *anyopaque,
            row: *const list.Row,
            node: *NodeType,
            elements: []const *NodeType,
        ) void;
        pub const Renderer = struct {
            context: *anyopaque,
            render: RenderRow,
        };

        allocator: std.mem.Allocator,
        user: []const u8,
        data_source: DataSource,
        tree: *CompressedTree,
        renderer: Renderer,
        options: Options,
        compression_delegate: ?CompressionDelegate(T) = null,
        collapse_by_default: ?CollapseByDefault(T) = null,
        filter: ?tree.TreeFilter(T) = null,
        activation_context: ?*anyopaque = null,
        on_activate: ?*const fn (context: ?*anyopaque, element: T) void = null,
        nodes: std.AutoHashMap(T, *NodeType),
        root: *NodeType,
        input: ?TInput = null,
        pending: std.array_list.Managed(*NodeType),

        pub fn init(
            allocator: std.mem.Allocator,
            user: []const u8,
            data_source: DataSource,
            renderer: Renderer,
            options: Options,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const root = try allocator.create(NodeType);
            errdefer allocator.destroy(root);
            root.* = .{
                .children = std.array_list.Managed(*NodeType).init(allocator),
                .has_children = true,
                .stale = false,
                .collapsed = false,
                .loaded = true,
            };

            const tree_renderer: CompressedTree.ViewType.Renderer = .{
                .context = @ptrCast(self),
                .render = renderCallback,
            };
            const view = try CompressedTree.init(allocator, user, compressible and options.compression_enabled, tree_renderer, .{
                .indent = options.indent,
                .render_indent_guides = options.render_indent_guides,
                .enable_sticky_scroll = options.enable_sticky_scroll,
                .sticky_scroll_max_item_count = options.sticky_scroll_max_item_count,
                .sticky_scroll_max_node_height = options.sticky_scroll_max_node_height,
                .sticky_scroll_node_source_range_provider = options.sticky_scroll_node_source_range_provider,
            });
            errdefer view.deinit();

            self.* = .{
                .allocator = allocator,
                .user = user,
                .data_source = data_source,
                .tree = view,
                .renderer = renderer,
                .options = options,
                .nodes = std.AutoHashMap(T, *NodeType).init(allocator),
                .root = root,
                .pending = std.array_list.Managed(*NodeType).init(allocator),
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.cancelAllRefreshPromises(true);
            self.destroyChildren(self.root);
            self.root.children.deinit();
            self.nodes.deinit();
            self.pending.deinit();
            self.tree.deinit();
            self.allocator.destroy(self.root);
            self.allocator.destroy(self);
        }

        pub fn setCompressionDelegate(self: *Self, delegate: ?CompressionDelegate(T)) void {
            self.compression_delegate = delegate;
        }

        pub fn setCollapseByDefault(self: *Self, callback: ?CollapseByDefault(T)) void {
            self.collapse_by_default = callback;
        }

        pub fn setFilter(self: *Self, filter: ?tree.TreeFilter(T)) !void {
            self.filter = filter;
            if (filter == null) {
                try self.tree.setFilter(null);
            } else {
                try self.tree.setFilter(.{
                    .context = @ptrCast(self),
                    .filter = filterNode,
                });
            }
        }

        pub fn getInput(self: *const Self) ?TInput {
            return self.input;
        }

        /// Starts loading `input`. Returns true when a request is still pending
        /// after the call; the caller must poll the tree for completion.
        pub fn setInput(self: *Self, input: ?TInput) !bool {
            self.cancelAllRefreshPromises(true);
            self.destroyChildren(self.root);
            try self.tree.setChildren(null, &.{});
            self.input = input;
            self.root.stale = true;
            self.root.loaded = false;
            self.root.has_children = true;
            if (input == null) {
                try self.renderNode(self.root);
                return false;
            }
            try self.refreshNode(self.root, true);
            return self.hasPending();
        }

        pub fn hasPending(self: *const Self) bool {
            return self.pending.items.len > 0;
        }

        pub fn pendingCount(self: *const Self) usize {
            return self.pending.items.len;
        }

        /// Drains completed requests and applies their children. Returns true
        /// when at least one node produced a render update.
        pub fn poll(self: *Self) bool {
            var changed = false;
            var index: usize = 0;
            while (index < self.pending.items.len) {
                const node = self.pending.items[index];
                const request = node.request orelse {
                    _ = self.pending.swapRemove(index);
                    node.pending = false;
                    continue;
                };
                if (request.poll(request.context)) |result| {
                    node.request = null;
                    node.pending = false;
                    _ = self.pending.swapRemove(index);
                    self.applyResult(node, result);
                    changed = true;
                } else {
                    index += 1;
                }
            }
            return changed;
        }

        fn applyResult(self: *Self, node: *NodeType, result: Result(T)) void {
            switch (result) {
                .items => |items| {
                    self.setNodeChildren(node, items, false) catch {};
                },
                .owned => |items| {
                    defer self.allocator.free(items);
                    self.setNodeChildren(node, items, false) catch {};
                },
                .err => {
                    node.stale = false;
                    node.loaded = true;
                    node.pending = false;
                    if (node != self.root) {
                        _ = self.tree.setCollapsed(node, true, false) catch false;
                    }
                    self.setNodeChildren(node, &.{}, false) catch {};
                },
            }
        }

        pub fn hasNode(self: *const Self, element: T) bool {
            return self.nodes.contains(element);
        }

        pub fn getNode(self: *Self, element: T) !*NodeType {
            return self.nodes.get(element) orelse error.TreeNotFound;
        }

        pub fn inputNode(self: *const Self) *NodeType {
            return self.root;
        }

        pub fn count(self: *const Self) usize {
            return self.tree.count();
        }

        pub fn scrollTop(self: *const Self) f64 {
            return self.tree.view.widget.view.scroll_top;
        }

        pub fn indexAt(self: *const Self, position: f64) i64 {
            return self.tree.view.widget.view.range_map.indexAt(position);
        }

        pub fn renderedItem(self: *Self, index: usize) ?T {
            const node = self.renderedNode(index) orelse return null;
            return node.element;
        }

        pub fn renderedNode(self: *Self, index: usize) ?*NodeType {
            const model_node = self.tree.renderedNode(index) orelse return null;
            const compressed_node = model_node.element orelse return null;
            return compressedLast(&compressed_node);
        }

        pub fn selectionElement(self: *Self) ?T {
            const node = self.selectionNode() orelse return null;
            return node.element;
        }

        pub fn selectionNode(self: *Self) ?*NodeType {
            const model_node = self.tree.selectionNode() orelse return null;
            const compressed_node = model_node.element orelse return null;
            return compressedLast(&compressed_node);
        }

        pub fn selectionDepth(self: *Self) ?usize {
            const model_node = self.tree.selectionNode() orelse return null;
            return model_node.depth;
        }

        pub fn setSelectionElement(self: *Self, element: ?T) void {
            if (element) |value| {
                if (self.nodes.get(value)) |node| {
                    self.tree.setSelectionElement(node);
                } else {
                    self.tree.setSelectionElement(null);
                }
            } else {
                self.tree.setSelectionElement(null);
            }
        }

        pub fn setFocus(self: *Self, focus: bool) void {
            self.tree.setFocus(focus);
        }

        pub fn focused(self: *const Self) bool {
            return self.tree.view.focused();
        }

        pub fn render(self: *Self, grid: *ui.CellGrid, rect: ui.Rect) void {
            self.tree.render(grid, rect);
        }

        pub fn isCollapsible(self: *Self, element: T) bool {
            const node = self.nodes.get(element) orelse return false;
            return node.has_children;
        }

        pub fn isCollapsed(self: *Self, element: T) bool {
            const node = self.nodes.get(element) orelse return false;
            if (self.tree.has(node)) return self.tree.isCollapsed(node);
            return node.collapsed;
        }

        pub fn collapse(self: *Self, element: T, recursive: bool) bool {
            const node = self.nodes.get(element) orelse return false;
            if (!node.has_children) return false;
            const changed = self.tree.setCollapsed(node, true, recursive) catch false;
            node.collapsed = true;
            if (recursive) self.markCollapsed(node.children.items);
            return changed;
        }

        /// Expands `element` and starts loading its children when they are
        /// stale. Returns true once the node is expanded; loading may still be
        /// pending.
        pub fn expand(self: *Self, element: T, recursive: bool) bool {
            const node = self.nodes.get(element) orelse return false;
            if (!node.has_children) return false;
            var changed = false;
            if (self.isCollapsed(element)) {
                changed = self.tree.setCollapsed(node, false, recursive) catch false;
                node.collapsed = false;
            }
            if (node.stale) {
                self.refreshNode(node, recursive) catch {};
            }
            return changed or !self.isCollapsed(element);
        }

        pub fn expandElement(self: *Self, element: T) bool {
            return self.expand(element, false);
        }

        pub fn toggleCollapsed(self: *Self, element: T, recursive: bool) bool {
            if (self.isCollapsed(element)) return self.expand(element, recursive);
            return self.collapse(element, recursive);
        }

        pub fn expandTo(self: *Self, element: T) void {
            var chain = std.array_list.Managed(*NodeType).init(self.allocator);
            defer chain.deinit();
            var current = self.nodes.get(element) orelse return;
            while (current.parent) |parent| {
                chain.append(current) catch return;
                current = parent;
            }
            var index = chain.items.len;
            while (index > 0) {
                index -= 1;
                const node = chain.items[index];
                if (node.element) |value| _ = self.expand(value, false);
            }
        }

        pub fn collapseAll(self: *Self) void {
            for (self.root.children.items) |child| {
                if (child.element) |value| _ = self.collapse(value, true);
            }
        }

        pub fn updateChildren(self: *Self, element: ?T, recursive: bool, rerender: bool) !bool {
            const node = if (element) |value|
                self.nodes.get(value) orelse return error.TreeNotFound
            else
                self.root;
            try self.refreshNode(node, recursive);
            if (rerender) try self.renderNode(node);
            return self.hasPending();
        }

        fn refreshNode(self: *Self, node: *NodeType, recursive: bool) anyerror!void {
            if (node != self.root and !node.force_expanded and self.nodeCollapsed(node)) {
                node.has_children = self.data_source.has_children(self.data_source.context, node.element.?);
                node.stale = true;
                node.loaded = false;
                try self.setNodeChildren(node, &.{}, recursive);
                return;
            }
            if (node.pending) return;

            node.has_children = if (node == self.root)
                true
            else
                self.data_source.has_children(self.data_source.context, node.element.?);

            if (!node.has_children) {
                node.stale = false;
                node.loaded = true;
                try self.setNodeChildren(node, &.{}, recursive);
                return;
            }

            const source_element: Element = if (node == self.root)
                .{ .input = self.input orelse return }
            else
                .{ .item = node.element.? };
            const children = self.data_source.get_children(self.data_source.context, source_element);
            switch (children) {
                .items => |items| {
                    node.pending = false;
                    node.stale = false;
                    node.loaded = true;
                    try self.setNodeChildren(node, items, recursive);
                },
                .pending => |request| {
                    node.request = request;
                    node.pending = true;
                    try self.pending.append(node);
                },
            }
        }

        fn setNodeChildren(self: *Self, node: *NodeType, items: []const T, recursive: bool) anyerror!void {
            self.cancelNodePending(node);
            var candidates = std.AutoHashMap(T, *NodeType).init(self.allocator);
            defer candidates.deinit();
            for (node.children.items) |child| {
                if (child.element) |value| candidates.put(value, child) catch {};
            }

            var next = std.array_list.Managed(*NodeType).init(self.allocator);
            errdefer next.deinit();
            var refresh = std.array_list.Managed(*NodeType).init(self.allocator);
            defer refresh.deinit();

            for (items) |element| {
                if (candidates.fetchRemove(element)) |found| {
                    const child = found.value;
                    child.parent = node;
                    child.depth = node.depth + 1;
                    child.has_children = self.data_source.has_children(self.data_source.context, element);
                    if (recursive and self.nodeCollapsed(child)) {
                        self.destroyChildren(child);
                        child.stale = true;
                        child.loaded = false;
                    } else if (recursive and child.has_children and !child.stale) {
                        try refresh.append(child);
                    }
                    try next.append(child);
                } else {
                    const child = try self.allocator.create(NodeType);
                    errdefer self.allocator.destroy(child);
                    child.* = .{
                        .element = element,
                        .parent = node,
                        .depth = node.depth + 1,
                        .children = std.array_list.Managed(*NodeType).init(self.allocator),
                        .has_children = self.data_source.has_children(self.data_source.context, element),
                        .stale = true,
                        .default_collapsed = self.defaultCollapsed(element),
                        .collapsed = true,
                        .loaded = false,
                    };
                    if (child.has_children and !child.default_collapsed) {
                        try refresh.append(child);
                    }
                    try next.append(child);
                }
            }

            var iterator = candidates.valueIterator();
            while (iterator.next()) |child| self.destroyNodeTree(child.*);

            for (next.items) |child| {
                if (child.element) |value| try self.nodes.put(value, child);
            }
            node.children.clearRetainingCapacity();
            node.children.deinit();
            node.children = next;
            node.stale = false;
            node.loaded = true;
            node.pending = false;

            if (node.force_expanded and node != self.root and self.tree.has(node)) {
                node.force_expanded = false;
                _ = self.tree.setCollapsed(node, false, false) catch false;
            }

            if (node != self.root and node.children.items.len == 1 and refresh.items.len == 0) {
                const only = node.children.items[0];
                if (self.shouldAutoExpandSingleChild(only)) {
                    only.force_expanded = true;
                    try refresh.append(only);
                }
            }

            try self.renderNode(node);

            for (refresh.items) |child| {
                try self.refreshNode(child, recursive);
            }
        }

        fn shouldAutoExpandSingleChild(self: *const Self, node: *NodeType) bool {
            if (self.options.auto_expand_compressed_children and
                self.tree.isCompressionEnabled() and
                !self.isIncompressible(node.element.?))
            {
                return true;
            }
            return self.options.auto_expand_single_children;
        }

        fn defaultCollapsed(self: *const Self, element: T) bool {
            const callback = self.collapse_by_default orelse return true;
            return callback.callback(callback.context, element);
        }

        fn isIncompressible(self: *const Self, element: T) bool {
            const delegate = self.compression_delegate orelse return !self.data_source.has_children(self.data_source.context, element);
            return delegate.is_incompressible(delegate.context, element);
        }

        fn nodeCollapsed(self: *Self, node: *NodeType) bool {
            if (node == self.root) return false;
            if (node.force_expanded) return false;
            if (self.tree.has(node)) return self.tree.isCollapsed(node);
            return node.collapsed;
        }

        fn markCollapsed(self: *Self, children: []const *NodeType) void {
            for (children) |child| {
                child.collapsed = true;
                self.markCollapsed(child.children.items);
            }
        }

        fn renderNode(self: *Self, node: *NodeType) !void {
            if (node != self.root and !self.tree.has(node)) return;
            // The compressed model recreates its `Model.Node`s on every
            // `setChildren`, so the list view cannot preserve selection by
            // pointer across the refresh. Restore the selected async wrapper.
            const selected = self.selectionNode();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var elements = std.array_list.Managed(CompressedElement).init(arena.allocator());
            for (node.children.items) |child| {
                try elements.append(try self.asTreeElement(arena.allocator(), child));
            }
            if (node == self.root) {
                try self.tree.setChildren(null, elements.items);
            } else {
                try self.tree.setChildren(node, elements.items);
            }
            if (selected) |value| {
                if (value.element != null and self.tree.has(value)) self.tree.setSelectionElement(value);
            }
        }

        fn asTreeElement(self: *Self, allocator: std.mem.Allocator, node: *NodeType) !CompressedElement {
            var children = std.array_list.Managed(CompressedElement).init(allocator);
            if (!node.stale and node.has_children) {
                for (node.children.items) |child| {
                    try children.append(try self.asTreeElement(allocator, child));
                }
            }

            const collapsed: ?bool = if (node.stale)
                true
            else if (node.force_expanded) blk: {
                node.force_expanded = false;
                break :blk false;
            } else if (!node.initialized)
                node.default_collapsed
            else
                null;
            node.initialized = true;
            return .{
                .element = node,
                .children = try children.toOwnedSlice(),
                .collapsible = node.has_children,
                .collapsed = collapsed,
                .incompressible = node.element != null and self.isIncompressible(node.element.?),
            };
        }

        fn renderCallback(context: *anyopaque, row: *const list.Row, model_node: *const CompressedTree.Node) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const compressed = model_node.element orelse return;
            const elements = compressed.elements;
            if (elements.len == 0) return;
            self.renderer.render(self.renderer.context, row, elements[elements.len - 1], elements);
        }

        fn compressedLast(compressed: *const CompressedNode) ?*NodeType {
            if (compressed.elements.len == 0) return null;
            return compressed.elements[compressed.elements.len - 1];
        }

        fn filterNode(context: *anyopaque, model_node: ?*NodeType, parent_visibility: tree.TreeVisibility) tree.TreeVisibility {
            const self: *Self = @ptrCast(@alignCast(context));
            const node = model_node orelse return parent_visibility;
            const value = node.element orelse return parent_visibility;
            const filter = self.filter orelse return parent_visibility;
            return filter.filter(filter.context, value, parent_visibility);
        }

        fn destroyChildren(self: *Self, node: *NodeType) void {
            for (node.children.items) |child| self.destroyNodeTree(child);
            node.children.clearRetainingCapacity();
            node.stale = true;
            node.loaded = false;
            node.pending = false;
            node.request = null;
        }

        fn destroyNodeTree(self: *Self, node: *NodeType) void {
            self.cancelNodePending(node);
            for (node.children.items) |child| self.destroyNodeTree(child);
            if (node.element) |value| {
                if (self.nodes.get(value)) |candidate| {
                    if (candidate == node) _ = self.nodes.remove(value);
                }
            }
            node.children.deinit();
            self.allocator.destroy(node);
        }

        fn cancelNodePending(self: *Self, node: *NodeType) void {
            if (!node.pending) return;
            if (node.request) |request| request.cancel(request.context);
            node.request = null;
            node.pending = false;
            var index: usize = 0;
            while (index < self.pending.items.len) : (index += 1) {
                if (self.pending.items[index] == node) {
                    _ = self.pending.swapRemove(index);
                    return;
                }
            }
        }

        pub fn cancelAllRefreshPromises(self: *Self, include_subtrees: bool) void {
            _ = include_subtrees;
            for (self.pending.items) |node| {
                if (node.request) |request| request.cancel(request.context);
                node.request = null;
                node.pending = false;
            }
            self.pending.clearRetainingCapacity();
        }

        pub fn handleKey(self: *Self, event: *const ui.KeyEvent) bool {
            if (!self.focused()) return false;
            const selected = self.selectionNode() orelse return self.tree.handleKey(event);
            switch (event.key) {
                .left => {
                    if (selected.element) |element| {
                        if (selected.has_children and !self.isCollapsed(element)) {
                            _ = self.collapse(element, false);
                            return true;
                        }
                    }
                    if (selected.parent) |parent| {
                        if (parent.element) |value| {
                            self.setSelectionElement(value);
                            return true;
                        }
                    }
                    return true;
                },
                .right => {
                    if (selected.element) |element| {
                        if (selected.has_children and self.isCollapsed(element)) {
                            _ = self.expand(element, false);
                            return true;
                        }
                        if (selected.children.items.len > 0) {
                            const child = selected.children.items[0];
                            if (child.element) |value| self.setSelectionElement(value);
                            return true;
                        }
                    }
                    return true;
                },
                else => return self.tree.handleKey(event),
            }
        }

        pub fn handleMouse(self: *Self, event: *const ui.MouseEvent) bool {
            return self.tree.handleMouse(event);
        }

        pub fn clearHover(self: *Self) void {
            self.tree.clearHover();
        }

        pub fn hasHoveredRow(self: *const Self) bool {
            return self.tree.view.hasHoveredRow();
        }

        pub fn stickyScrollNodes(self: *const Self) []const CompressedTree.ViewType.StickyNode {
            return self.tree.stickyScrollNodes();
        }

        pub fn stickyScrollHeight(self: *const Self) f64 {
            return self.tree.view.stickyScrollHeight();
        }

        pub fn stickyScrollFocused(self: *const Self) bool {
            return self.tree.view.stickyScrollFocused();
        }

        pub fn stickyRowAt(self: *const Self, x: usize, y: usize) ?usize {
            return self.tree.view.stickyRowAt(x, y);
        }

        pub fn focusStickyScroll(self: *Self) bool {
            return self.tree.view.focusStickyScroll();
        }

        pub fn clearStickyScrollFocus(self: *Self) void {
            self.tree.view.clearStickyScrollFocus();
        }

        pub fn setActivateHandler(
            self: *Self,
            context: ?*anyopaque,
            handler: *const fn (context: ?*anyopaque, element: T) void,
        ) void {
            self.activation_context = context;
            self.on_activate = handler;
            self.tree.setActivateHandler(self, activateCallback);
        }

        fn activateCallback(context: ?*anyopaque, node: *NodeType) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            const callback = self.on_activate orelse return;
            if (node.element) |value| callback(self.activation_context, value);
        }

        pub fn nav(self: *Self, start: ?T) NavigatorFor(Self) {
            var index: isize = -1;
            if (start) |element| {
                for (0..self.count()) |i| {
                    if (self.renderedItem(i)) |candidate| {
                        if (candidate == element) {
                            index = @intCast(i);
                            break;
                        }
                    }
                }
            }
            return .{ .tree = self, .index = index };
        }
    };
}

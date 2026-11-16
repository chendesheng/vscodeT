// Port of `src/vs/base/browser/ui/tree/compressedObjectTreeModel.ts`.
//
// Terminal adaptation: compression works on owned slices instead of JS
// iterables. Upstream mutates compressed nodes in place through smart splices;
// this port keeps an uncompressed raw tree (with the `incompressible` flag) and
// rebuilds the compressed model from it after each child update. Rebuilding is
// safe because the raw tree preserves collapse state per element, including
// the collapse state of a compressed group, so expanding a group and then
// loading children does not collapse it again.

const std = @import("std");
const object_tree = @import("./objectTreeModel.zig");
const tree = @import("./tree.zig");

pub fn CompressedTreeElement(comptime T: type) type {
    return struct {
        element: T,
        children: []const CompressedTreeElement(T) = &.{},
        collapsible: ?bool = null,
        collapsed: ?bool = null,
        incompressible: bool = false,
    };
}

pub fn CompressedTreeNode(comptime T: type) type {
    return struct {
        elements: []const T,
        incompressible: bool = false,
    };
}

pub fn compress(comptime T: type, allocator: std.mem.Allocator, element: CompressedTreeElement(T)) !CompressedTreeElement(CompressedTreeNode(T)) {
    return compressAt(T, allocator, element);
}

fn compressAt(comptime T: type, allocator: std.mem.Allocator, start: CompressedTreeElement(T)) !CompressedTreeElement(CompressedTreeNode(T)) {
    const Node = CompressedTreeNode(T);
    const Out = CompressedTreeElement(Node);

    var elements = std.array_list.Managed(T).init(allocator);
    errdefer elements.deinit();
    try elements.append(start.element);

    var current = start;
    while (true) {
        if (current.children.len != 1) break;
        if (current.children[0].incompressible) break;
        current = current.children[0];
        try elements.append(current.element);
    }

    const owned_elements = try elements.toOwnedSlice();
    errdefer allocator.free(owned_elements);

    var children = std.array_list.Managed(Out).init(allocator);
    errdefer {
        for (children.items) |child| freeCompressed(T, allocator, child);
        children.deinit();
    }
    for (current.children) |child| {
        try children.append(try compressAt(T, allocator, child));
    }

    return .{
        .element = .{ .elements = owned_elements, .incompressible = start.incompressible },
        .children = try children.toOwnedSlice(),
        .collapsible = current.collapsible,
        .collapsed = current.collapsed,
    };
}

pub fn noCompress(comptime T: type, allocator: std.mem.Allocator, element: CompressedTreeElement(T)) !CompressedTreeElement(CompressedTreeNode(T)) {
    const Node = CompressedTreeNode(T);
    const Out = CompressedTreeElement(Node);

    const owned_elements = try allocator.alloc(T, 1);
    errdefer allocator.free(owned_elements);
    owned_elements[0] = element.element;

    var children = std.array_list.Managed(Out).init(allocator);
    errdefer {
        for (children.items) |child| freeCompressed(T, allocator, child);
        children.deinit();
    }
    for (element.children) |child| {
        try children.append(try noCompress(T, allocator, child));
    }

    return .{
        .element = .{ .elements = owned_elements, .incompressible = element.incompressible },
        .children = try children.toOwnedSlice(),
        .collapsible = element.collapsible,
        .collapsed = element.collapsed,
    };
}

pub fn decompress(comptime T: type, allocator: std.mem.Allocator, element: CompressedTreeElement(CompressedTreeNode(T))) !CompressedTreeElement(T) {
    return decompressAt(T, allocator, element, 0);
}

fn decompressAt(
    comptime T: type,
    allocator: std.mem.Allocator,
    element: CompressedTreeElement(CompressedTreeNode(T)),
    index: usize,
) !CompressedTreeElement(T) {
    const Out = CompressedTreeElement(T);
    if (index >= element.element.elements.len) return error.InvalidCompressedNode;

    var children = std.array_list.Managed(Out).init(allocator);
    errdefer {
        for (children.items) |child| freeDecompressed(T, allocator, child);
        children.deinit();
    }
    if (index < element.element.elements.len - 1) {
        try children.append(try decompressAt(T, allocator, element, index + 1));
    } else {
        for (element.children) |child| {
            try children.append(try decompressAt(T, allocator, child, 0));
        }
    }

    const incompressible = index == 0 and element.element.incompressible;
    return .{
        .element = element.element.elements[index],
        .children = try children.toOwnedSlice(),
        .collapsible = element.collapsible,
        .collapsed = element.collapsed,
        .incompressible = incompressible,
    };
}

pub fn freeCompressed(comptime T: type, allocator: std.mem.Allocator, element: CompressedTreeElement(CompressedTreeNode(T))) void {
    for (element.children) |child| freeCompressed(T, allocator, child);
    allocator.free(element.children);
    allocator.free(element.element.elements);
}

pub fn freeDecompressed(comptime T: type, allocator: std.mem.Allocator, element: CompressedTreeElement(T)) void {
    for (element.children) |child| freeDecompressed(T, allocator, child);
    allocator.free(element.children);
}

pub fn CompressedObjectTreeModel(comptime T: type) type {
    const CompressedNode = CompressedTreeNode(T);
    const NodeContext = struct {
        pub fn hash(_: @This(), key: CompressedNode) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.elements.len));
            hasher.update(std.mem.asBytes(&key.elements.ptr));
            return hasher.final();
        }
        pub fn eql(_: @This(), a: CompressedNode, b: CompressedNode) bool {
            return a.elements.len == b.elements.len and a.elements.ptr == b.elements.ptr;
        }
    };
    const Model = object_tree.ObjectTreeModelWithHash(CompressedNode, NodeContext);
    const Compressed = CompressedTreeElement(CompressedNode);
    const ModelElement = object_tree.ObjectTreeElement(CompressedNode);

    // Uncompressed source node. Unlike `ObjectTreeElement`, it keeps
    // `incompressible`, which compression needs across rebuilds, and its
    // per-element collapse state, which lets an expanded compressed group
    // survive a child update.
    const RawNode = struct {
        element: T,
        parent: ?*@This(),
        children: std.array_list.Managed(*@This()),
        collapsible: ?bool = null,
        collapsed: ?bool = null,
        incompressible: bool = false,
    };

    return struct {
        pub const Node = Model.Node;
        pub const ModelNode = Model.Node;
        pub const Element = CompressedTreeElement(T);

        allocator: std.mem.Allocator,
        user: []const u8,
        enabled: bool,
        model: Model,
        root_children: std.array_list.Managed(*RawNode),
        raw_nodes: std.AutoHashMap(T, *RawNode),
        nodes: std.AutoHashMap(T, CompressedNode),
        retained: std.array_list.Managed(Compressed),
        filter: ?tree.TreeFilter(T) = null,

        pub fn init(allocator: std.mem.Allocator, user: []const u8, compression_enabled: bool) !CompressedObjectTreeModel(T) {
            return .{
                .allocator = allocator,
                .user = user,
                .enabled = compression_enabled,
                .model = try Model.init(allocator, user, false),
                .root_children = std.array_list.Managed(*RawNode).init(allocator),
                .raw_nodes = std.AutoHashMap(T, *RawNode).init(allocator),
                .nodes = std.AutoHashMap(T, CompressedNode).init(allocator),
                .retained = std.array_list.Managed(Compressed).init(allocator),
            };
        }

        pub fn deinit(self: *CompressedObjectTreeModel(T)) void {
            for (self.root_children.items) |child| self.destroyRawSubtree(child);
            self.root_children.deinit();
            self.freeRetained();
            self.retained.deinit();
            self.raw_nodes.deinit();
            self.nodes.deinit();
            self.model.deinit();
        }

        fn freeRetained(self: *CompressedObjectTreeModel(T)) void {
            for (self.retained.items) |element| freeCompressed(T, self.allocator, element);
            self.retained.clearRetainingCapacity();
        }

        pub fn size(self: *const CompressedObjectTreeModel(T)) usize {
            return self.nodes.count();
        }

        fn buildRaw(self: *CompressedObjectTreeModel(T), element: CompressedTreeElement(T), preserve: bool) !*RawNode {
            const node = try self.allocator.create(RawNode);
            errdefer self.allocator.destroy(node);

            var collapsed = element.collapsed;
            var collapsible = element.collapsible;
            if (preserve) {
                if (self.raw_nodes.get(element.element)) |old| {
                    if (collapsed == null) collapsed = old.collapsed;
                    if (collapsible == null) collapsible = old.collapsible;
                }
            }

            node.* = .{
                .element = element.element,
                .parent = null,
                .children = std.array_list.Managed(*RawNode).init(self.allocator),
                .collapsible = collapsible,
                .collapsed = collapsed,
                .incompressible = element.incompressible,
            };
            errdefer {
                for (node.children.items) |child| self.destroyRawSubtree(child);
                node.children.deinit();
            }
            for (element.children) |child| {
                const raw_child = try self.buildRaw(child, preserve);
                raw_child.parent = node;
                try node.children.append(raw_child);
            }
            return node;
        }

        fn registerRaw(self: *CompressedObjectTreeModel(T), node: *RawNode) !void {
            try self.raw_nodes.put(node.element, node);
            for (node.children.items) |child| try self.registerRaw(child);
        }

        fn destroyRawSubtree(self: *CompressedObjectTreeModel(T), node: *RawNode) void {
            for (node.children.items) |child| self.destroyRawSubtree(child);
            node.children.deinit();
            if (self.raw_nodes.get(node.element)) |candidate| {
                if (candidate == node) _ = self.raw_nodes.remove(node.element);
            }
            self.allocator.destroy(node);
        }

        /// Copies the compressed model's collapse state back into the raw
        /// tree. A compressed group's state belongs to every element in it,
        /// matching `decompress()`, so regrouping keeps the same expansion.
        fn captureCollapseState(self: *CompressedObjectTreeModel(T)) void {
            self.captureNodeCollapse(self.model.model.root);
        }

        fn captureNodeCollapse(self: *CompressedObjectTreeModel(T), node: *Model.Node) void {
            if (node.element) |compressed_node| {
                for (compressed_node.elements) |element| {
                    if (self.raw_nodes.get(element)) |raw| raw.collapsed = node.collapsed;
                }
            }
            for (node.children.items) |child| self.captureNodeCollapse(child);
        }

        /// Replaces children of `element` in the uncompressed source tree, then
        /// recompresses the whole model. Recompression from the root matches the
        /// upstream behavior that a child edit can change how ancestors group.
        pub fn setChildren(
            self: *CompressedObjectTreeModel(T),
            element: ?T,
            children: []const CompressedTreeElement(T),
        ) !void {
            self.captureCollapseState();
            const parent: ?*RawNode = if (element) |value|
                self.raw_nodes.get(value) orelse return error.TreeNotFound
            else
                null;
            try self.replaceRawChildren(parent, children);
            try self.rebuild();
        }

        fn replaceRawChildren(
            self: *CompressedObjectTreeModel(T),
            parent: ?*RawNode,
            children: []const CompressedTreeElement(T),
        ) !void {
            var new_children = std.array_list.Managed(*RawNode).init(self.allocator);
            errdefer {
                for (new_children.items) |child| self.destroyRawSubtree(child);
                new_children.deinit();
            }
            for (children) |child| {
                const raw = try self.buildRaw(child, true);
                try self.registerRaw(raw);
                try new_children.append(raw);
            }

            if (parent) |value| {
                for (value.children.items) |old| self.destroyRawSubtree(old);
                value.children.deinit();
                value.children = new_children;
            } else {
                for (self.root_children.items) |old| self.destroyRawSubtree(old);
                self.root_children.deinit();
                self.root_children = new_children;
            }
        }

        fn rebuild(self: *CompressedObjectTreeModel(T)) !void {
            self.model.deinit();
            self.model = try Model.init(self.allocator, self.user, false);
            self.nodes.clearRetainingCapacity();
            self.freeRetained();

            const retained_before = self.retained.items.len;
            errdefer {
                while (self.retained.items.len > retained_before) {
                    const retained = self.retained.pop().?;
                    freeCompressed(T, self.allocator, retained);
                }
            }

            var elements = std.array_list.Managed(ModelElement).init(self.allocator);
            defer elements.deinit();
            for (self.root_children.items) |raw_node| {
                const raw_element = try self.fromRawNode(raw_node);
                defer freeDecompressed(T, self.allocator, raw_element);
                const compressed = if (self.enabled)
                    try compress(T, self.allocator, raw_element)
                else
                    try noCompress(T, self.allocator, raw_element);
                try self.retained.append(compressed);
                try elements.append(try self.toModelElement(compressed));
            }
            defer {
                for (elements.items) |element| self.freeModelElement(element);
            }
            try self.model.setChildren(null, elements.items);
            if (self.filter != null) {
                try self.model.setFilter(.{
                    .context = @ptrCast(self),
                    .filter = filterNode,
                });
            }
            for (self.model.model.root.children.items) |node| self.mapNode(node);
        }

        fn fromRawNode(self: *CompressedObjectTreeModel(T), node: *RawNode) !CompressedTreeElement(T) {
            var children = std.array_list.Managed(CompressedTreeElement(T)).init(self.allocator);
            errdefer {
                for (children.items) |child| freeDecompressed(T, self.allocator, child);
                children.deinit();
            }
            for (node.children.items) |child| {
                try children.append(try self.fromRawNode(child));
            }
            return .{
                .element = node.element,
                .children = try children.toOwnedSlice(),
                .collapsible = node.collapsible,
                .collapsed = node.collapsed,
                .incompressible = node.incompressible,
            };
        }

        fn toModelElement(self: *CompressedObjectTreeModel(T), element: Compressed) !ModelElement {
            var children = std.array_list.Managed(ModelElement).init(self.allocator);
            errdefer {
                for (children.items) |child| self.freeModelElement(child);
                children.deinit();
            }
            for (element.children) |child| try children.append(try self.toModelElement(child));
            return .{
                .element = element.element,
                .children = try children.toOwnedSlice(),
                .collapsible = element.collapsible,
                .collapsed = element.collapsed,
            };
        }

        fn freeModelElement(self: *CompressedObjectTreeModel(T), element: ModelElement) void {
            for (element.children) |child| self.freeModelElement(child);
            self.allocator.free(element.children);
        }

        fn mapNode(self: *CompressedObjectTreeModel(T), node: *Model.Node) void {
            if (node.element) |compressed_node| {
                for (compressed_node.elements) |element| self.nodes.put(element, compressed_node) catch {};
            }
            for (node.children.items) |child| self.mapNode(child);
        }

        fn filterNode(context: *anyopaque, node: ?CompressedNode, parent_visibility: tree.TreeVisibility) tree.TreeVisibility {
            const self: *CompressedObjectTreeModel(T) = @ptrCast(@alignCast(context));
            const value = node orelse return .visible;
            const filter = self.filter orelse return .visible;
            if (value.elements.len == 0) return .visible;

            // Upstream mapOptions(): run the user filter along the compressed
            // path, threading the accumulated visibility into the next element.
            var visibility = parent_visibility;
            var index: usize = 0;
            while (index + 1 < value.elements.len) : (index += 1) {
                visibility = filter.filter(filter.context, value.elements[index], visibility);
            }
            return filter.filter(filter.context, value.elements[value.elements.len - 1], visibility);
        }

        pub fn setFilter(self: *CompressedObjectTreeModel(T), filter: ?tree.TreeFilter(T)) !void {
            self.filter = filter;
            if (filter == null) {
                try self.model.setFilter(null);
            } else {
                try self.model.setFilter(.{
                    .context = @ptrCast(self),
                    .filter = filterNode,
                });
            }
        }

        pub fn refilter(self: *CompressedObjectTreeModel(T)) !void {
            try self.model.refilter();
        }

        pub fn has(self: *CompressedObjectTreeModel(T), element: ?T) bool {
            if (element == null) return true;
            return self.nodes.contains(element.?);
        }

        fn compressedNode(self: *CompressedObjectTreeModel(T), element: ?T) !CompressedNode {
            if (element == null) return error.TreeNotFound;
            return self.nodes.get(element.?) orelse error.TreeNotFound;
        }

        pub fn getNode(self: *CompressedObjectTreeModel(T), element: ?T) !*Model.Node {
            if (element == null) return self.model.model.root;
            return self.model.getNode(try self.compressedNode(element));
        }

        /// Alias matching upstream `getCompressedTreeNode`.
        pub fn getCompressedTreeNode(self: *CompressedObjectTreeModel(T), element: ?T) !*Model.Node {
            return self.getNode(element);
        }

        pub fn getListIndex(self: *CompressedObjectTreeModel(T), element: ?T) !?usize {
            return self.model.getListIndex(try self.compressedNode(element));
        }

        pub fn getListRenderCount(self: *CompressedObjectTreeModel(T), element: ?T) !usize {
            return self.model.getListRenderCount(try self.compressedNode(element));
        }

        pub fn isCollapsed(self: *CompressedObjectTreeModel(T), element: ?T) bool {
            const compressed_node = self.compressedNode(element) catch return false;
            return self.model.isCollapsed(compressed_node);
        }

        pub fn setCollapsed(self: *CompressedObjectTreeModel(T), element: ?T, collapsed: bool, recursive: bool) !bool {
            return self.model.setCollapsed(try self.compressedNode(element), collapsed, recursive);
        }

        /// Model-agnostic collapse entry point used by `AbstractTreeForModel`.
        /// The element here is the compressed node's element, not a raw `T`.
        pub fn setCollapsedElement(self: *CompressedObjectTreeModel(T), element: ?CompressedNode, collapsed: bool, recursive: bool) !bool {
            return self.model.setCollapsed(element, collapsed, recursive);
        }

        pub fn isCollapsible(self: *CompressedObjectTreeModel(T), element: ?T) bool {
            const compressed_node = self.compressedNode(element) catch return false;
            return self.model.isCollapsible(compressed_node);
        }

        pub fn setCollapsible(self: *CompressedObjectTreeModel(T), element: ?T, collapsible: bool) !bool {
            return self.model.setCollapsible(try self.compressedNode(element), collapsible);
        }

        pub fn collectRendered(self: *CompressedObjectTreeModel(T), out: *std.array_list.Managed(*Model.Node)) !void {
            try self.model.collectRendered(out);
        }

        pub fn isCompressionEnabled(self: *const CompressedObjectTreeModel(T)) bool {
            return self.enabled;
        }

        pub fn setCompressionEnabled(self: *CompressedObjectTreeModel(T), enabled: bool) !void {
            if (self.enabled == enabled) return;
            self.captureCollapseState();
            self.enabled = enabled;
            try self.rebuild();
        }
    };
}

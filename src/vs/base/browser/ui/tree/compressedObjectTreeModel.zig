// Port of `src/vs/base/browser/ui/tree/compressedObjectTreeModel.ts`.
//
// Terminal adaptation: compression works on owned slices instead of JS
// iterables. This file currently ports the compressed element/node types and
// the pure compress/decompress transforms; the model wrapper is added on top
// of `objectTreeModel.zig` in the next slice.

const std = @import("std");

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

const object_tree = @import("./objectTreeModel.zig");

pub fn CompressedObjectTreeModel(comptime T: type) type {
    const Node = CompressedTreeNode(T);
    const NodeContext = struct {
        pub fn hash(_: @This(), key: Node) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.elements.len));
            hasher.update(std.mem.asBytes(&key.elements.ptr));
            return hasher.final();
        }
        pub fn eql(_: @This(), a: Node, b: Node) bool {
            return a.elements.len == b.elements.len and a.elements.ptr == b.elements.ptr;
        }
    };
    const Raw = object_tree.ObjectTreeModel(T);
    const Model = object_tree.ObjectTreeModelWithHash(Node, NodeContext);
    const Compressed = CompressedTreeElement(Node);
    const RawElement = object_tree.ObjectTreeElement(T);
    const ModelElement = object_tree.ObjectTreeElement(Node);

    return struct {
        pub const ModelNode = Model.Node;

        allocator: std.mem.Allocator,
        user: []const u8,
        enabled: bool,
        raw: Raw,
        model: Model,
        nodes: std.AutoHashMap(T, Node),
        retained: std.array_list.Managed(Compressed),

        pub fn init(allocator: std.mem.Allocator, user: []const u8, compression_enabled: bool) !CompressedObjectTreeModel(T) {
            return .{
                .allocator = allocator,
                .user = user,
                .enabled = compression_enabled,
                .raw = try Raw.init(allocator, user, false),
                .model = try Model.init(allocator, user, false),
                .nodes = std.AutoHashMap(T, Node).init(allocator),
                .retained = std.array_list.Managed(Compressed).init(allocator),
            };
        }

        pub fn deinit(self: *CompressedObjectTreeModel(T)) void {
            self.freeRetained();
            self.retained.deinit();
            self.nodes.deinit();
            self.model.deinit();
            self.raw.deinit();
        }

        fn freeRetained(self: *CompressedObjectTreeModel(T)) void {
            for (self.retained.items) |element| freeCompressed(T, self.allocator, element);
            self.retained.clearRetainingCapacity();
        }

        pub fn size(self: *const CompressedObjectTreeModel(T)) usize {
            return self.nodes.count();
        }

        fn toRaw(self: *CompressedObjectTreeModel(T), element: CompressedTreeElement(T)) !RawElement {
            var children = std.array_list.Managed(RawElement).init(self.allocator);
            errdefer {
                for (children.items) |child| self.freeRaw(child);
                children.deinit();
            }
            for (element.children) |child| {
                try children.append(try self.toRaw(child));
            }
            return .{
                .element = element.element,
                .children = try children.toOwnedSlice(),
                .collapsible = element.collapsible,
                .collapsed = element.collapsed,
            };
        }

        fn freeRaw(self: *CompressedObjectTreeModel(T), element: RawElement) void {
            for (element.children) |child| self.freeRaw(child);
            self.allocator.free(element.children);
        }

        fn fromRawNode(self: *CompressedObjectTreeModel(T), node: *Raw.Node) !CompressedTreeElement(T) {
            var children = std.array_list.Managed(CompressedTreeElement(T)).init(self.allocator);
            errdefer {
                for (children.items) |child| freeDecompressed(T, self.allocator, child);
                children.deinit();
            }
            for (node.children.items) |child| {
                try children.append(try self.fromRawNode(child));
            }
            return .{
                .element = node.element orelse return error.MissingElement,
                .children = try children.toOwnedSlice(),
                .collapsible = node.collapsible,
                .collapsed = node.collapsed,
            };
        }

        /// Replaces children of `element` in the uncompressed source tree, then
        /// recompresses the whole model. Recompression from the root matches the
        /// upstream behavior that a child edit can change how ancestors group.
        pub fn setChildren(
            self: *CompressedObjectTreeModel(T),
            element: ?T,
            children: []const CompressedTreeElement(T),
        ) !void {
            var raw_children = std.array_list.Managed(RawElement).init(self.allocator);
            defer {
                for (raw_children.items) |child| self.freeRaw(child);
                raw_children.deinit();
            }
            for (children) |child| try raw_children.append(try self.toRaw(child));
            try self.raw.setChildren(element, raw_children.items);
            try self.rebuild();
        }

        fn rebuild(self: *CompressedObjectTreeModel(T)) !void {
            self.model.deinit();
            self.model = try Model.init(self.allocator, self.user, false);
            self.nodes.clearRetainingCapacity();
            self.freeRetained();

            var elements = std.array_list.Managed(ModelElement).init(self.allocator);
            defer elements.deinit();
            for (self.raw.model.root.children.items) |raw_node| {
                const raw_element = try self.fromRawNode(raw_node);
                const compressed = if (self.enabled)
                    try compress(T, self.allocator, raw_element)
                else
                    try noCompress(T, self.allocator, raw_element);
                freeDecompressed(T, self.allocator, raw_element);
                try self.retained.append(compressed);
                try elements.append(try self.toModelElement(compressed));
            }
            defer {
                for (elements.items) |element| self.freeModelElement(element);
            }
            try self.model.setChildren(null, elements.items);
            for (self.model.model.root.children.items) |node| self.mapNode(node);
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

        pub fn has(self: *CompressedObjectTreeModel(T), element: ?T) bool {
            if (element == null) return true;
            return self.nodes.contains(element.?);
        }

        fn compressedNode(self: *CompressedObjectTreeModel(T), element: ?T) !Node {
            if (element == null) return error.TreeNotFound;
            return self.nodes.get(element.?) orelse error.TreeNotFound;
        }

        pub fn getNode(self: *CompressedObjectTreeModel(T), element: ?T) !*Model.Node {
            if (element == null) return self.model.root;
            return self.model.getNode(try self.compressedNode(element));
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
            self.enabled = enabled;
            try self.rebuild();
        }
    };
}

// Port of `src/vs/base/browser/ui/tree/compressedObjectTreeModel.ts`.
//
// Terminal adaptation: compression works on owned slices instead of JS
// iterables. The port keeps an uncompressed raw tree (with the `incompressible`
// flag) as the authoritative source and follows upstream's branch update:
// decompress the affected compressed group, splice the changed element, then
// recompress and replace either that group's children or the group inside its
// parent. A full rebuild is reserved for compression/filter configuration
// changes and for periodically reclaiming stale compressed branches.

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

        const DiffContext = struct {
            arena: *std.heap.ArenaAllocator,

            fn getId(context: *anyopaque, compressed: CompressedNode) []const u8 {
                const self: *DiffContext = @ptrCast(@alignCast(context));
                var hasher = std.hash.Wyhash.init(0);
                for (compressed.elements) |element| std.hash.autoHash(&hasher, element);
                return std.fmt.allocPrint(self.arena.allocator(), "{x}", .{hasher.final()}) catch "";
            }
        };

        const NodeMapCallbacks = struct {
            model: *CompressedObjectTreeModel(T),
            inserted: *std.AutoHashMap(T, void),

            fn create(context: *anyopaque, node: *Model.Node) void {
                const self: *NodeMapCallbacks = @ptrCast(@alignCast(context));
                const compressed = node.element orelse return;
                for (compressed.elements) |element| {
                    self.model.nodes.put(element, compressed) catch {};
                    self.inserted.put(element, {}) catch {};
                }
            }

            fn delete(context: *anyopaque, node: *Model.Node) void {
                const self: *NodeMapCallbacks = @ptrCast(@alignCast(context));
                const compressed = node.element orelse return;
                for (compressed.elements) |element| {
                    if (self.inserted.contains(element)) continue;
                    _ = self.model.nodes.remove(element);
                }
            }
        };

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
        /// recompresses only the compressed branch that contains `element`.
        /// This is the terminal port of upstream `CompressedObjectTreeModel.setChildren`:
        /// decompress the affected group, splice in the new children, recompress,
        /// and update the compressed node itself or its parent when the group
        /// membership changed.
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

            if (element == null) {
                try self.replaceRawChildren(null, children);
                try self.recompressRootChildren();
                return;
            }

            const compressed_node = self.nodes.get(element.?) orelse return error.TreeNotFound;
            const model_node = try self.model.getNode(compressed_node);
            const compressed_element = try self.modelNodeToCompressedElement(model_node);
            defer self.freeModelDerivedCompressed(compressed_element);

            const decompressed = try decompress(T, self.allocator, compressed_element);
            defer freeDecompressed(T, self.allocator, decompressed);

            var spliced = try self.spliceDecompressed(decompressed, element.?, children);
            defer freeDecompressed(T, self.allocator, spliced);
            self.applyRawCollapse(&spliced);

            const recompressed = if (self.enabled)
                try compress(T, self.allocator, spliced)
            else
                try noCompress(T, self.allocator, spliced);

            try self.replaceRawChildren(parent, children);
            try self.applyRecompressed(model_node, compressed_element.element.elements, recompressed);
            // Branch updates keep the old compressed root elements alive for
            // reading; compact once the retained set grows large so a long
            // session does not accumulate stale compressed trees.
            if (self.retained.items.len > 512) try self.rebuild();
        }

        /// Rebuilds the root-level compressed elements after a root child
        /// update. Other branches are untouched.
        fn recompressRootChildren(self: *CompressedObjectTreeModel(T)) !void {
            var elements = std.array_list.Managed(ModelElement).init(self.allocator);
            defer elements.deinit();
            const retained_before = self.retained.items.len;
            errdefer {
                while (self.retained.items.len > retained_before) {
                    const retained = self.retained.pop().?;
                    freeCompressed(T, self.allocator, retained);
                }
            }
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
            var inserted = std.AutoHashMap(T, void).init(self.allocator);
            defer inserted.deinit();
            try self.setModelChildren(null, elements.items, 0, &inserted);
        }

        /// Applies a recompressed branch to the object model. If the compressed
        /// group membership is unchanged, only its children are replaced;
        /// otherwise the group is replaced in its parent's child list, exactly
        /// like upstream.
        fn applyRecompressed(
            self: *CompressedObjectTreeModel(T),
            model_node: *Model.Node,
            old_elements: []const T,
            recompressed: Compressed,
        ) !void {
            if (std.mem.eql(T, old_elements, recompressed.element.elements)) {
                try self.retained.append(recompressed);
                var children = std.array_list.Managed(ModelElement).init(self.allocator);
                defer children.deinit();
                defer for (children.items) |child| self.freeModelElement(child);
                for (recompressed.children) |child| try children.append(try self.toModelElement(child));
                var inserted = std.AutoHashMap(T, void).init(self.allocator);
                defer inserted.deinit();
                try self.setModelChildren(model_node.element, children.items, 1, &inserted);
                return;
            }

            const parent_model = model_node.parent orelse return error.TreeNotFound;
            try self.retained.append(recompressed);
            var parent_children = std.array_list.Managed(ModelElement).init(self.allocator);
            defer parent_children.deinit();
            defer for (parent_children.items) |child| self.freeModelElement(child);
            for (parent_model.children.items) |child| {
                if (child == model_node) {
                    try parent_children.append(try self.toModelElement(recompressed));
                } else {
                    try parent_children.append(try self.modelNodeToModelElement(child));
                }
            }
            var inserted = std.AutoHashMap(T, void).init(self.allocator);
            defer inserted.deinit();
            const depth = if (model_node.depth > parent_model.depth) model_node.depth - parent_model.depth else 1;
            try self.setModelChildren(parent_model.element, parent_children.items, depth, &inserted);
        }

        fn setModelChildren(
            self: *CompressedObjectTreeModel(T),
            node: ?CompressedNode,
            children: []const ModelElement,
            diff_depth: usize,
            inserted: *std.AutoHashMap(T, void),
        ) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var diff = DiffContext{ .arena = &arena };
            var callbacks = NodeMapCallbacks{ .model = self, .inserted = inserted };
            try self.model.setChildrenWithOptions(node, children, .{
                .diff_identity_provider = .{
                    .context = &diff,
                    .get_id = DiffContext.getId,
                },
                .diff_depth = diff_depth,
                .on_did_create_node = NodeMapCallbacks.create,
                .on_did_delete_node = NodeMapCallbacks.delete,
                .callback_context = &callbacks,
            });
            inserted.clearRetainingCapacity();
            self.refreshNodeMap();
        }

        fn refreshNodeMap(self: *CompressedObjectTreeModel(T)) void {
            self.nodes.clearRetainingCapacity();
            for (self.model.model.root.children.items) |node| self.mapNode(node);
        }

        fn modelNodeToCompressedElement(self: *CompressedObjectTreeModel(T), node: *Model.Node) !Compressed {
            var children = std.array_list.Managed(Compressed).init(self.allocator);
            errdefer {
                for (children.items) |child| freeCompressed(T, self.allocator, child);
                children.deinit();
            }
            for (node.children.items) |child| {
                try children.append(try self.modelNodeToCompressedElement(child));
            }
            return .{
                .element = node.element orelse return error.TreeNotFound,
                .children = try children.toOwnedSlice(),
                .collapsible = node.collapsible,
                .collapsed = node.collapsed,
                .incompressible = if (node.element) |value| value.incompressible else false,
            };
        }

        fn modelNodeToModelElement(self: *CompressedObjectTreeModel(T), node: *Model.Node) !ModelElement {
            var children = std.array_list.Managed(ModelElement).init(self.allocator);
            errdefer {
                for (children.items) |child| self.freeModelElement(child);
                children.deinit();
            }
            for (node.children.items) |child| {
                try children.append(try self.modelNodeToModelElement(child));
            }
            return .{
                .element = node.element orelse return error.TreeNotFound,
                .children = try children.toOwnedSlice(),
                .collapsible = node.collapsible,
                .collapsed = node.collapsed,
            };
        }

        fn cloneDecompressed(self: *CompressedObjectTreeModel(T), element: CompressedTreeElement(T)) !CompressedTreeElement(T) {
            var children = std.array_list.Managed(CompressedTreeElement(T)).init(self.allocator);
            errdefer {
                for (children.items) |child| freeDecompressed(T, self.allocator, child);
                children.deinit();
            }
            for (element.children) |child| try children.append(try self.cloneDecompressed(child));
            return .{
                .element = element.element,
                .children = try children.toOwnedSlice(),
                .collapsible = element.collapsible,
                .collapsed = element.collapsed,
                .incompressible = element.incompressible,
            };
        }

        fn spliceDecompressed(
            self: *CompressedObjectTreeModel(T),
            source: CompressedTreeElement(T),
            element: T,
            children: []const CompressedTreeElement(T),
        ) !CompressedTreeElement(T) {
            var out = std.array_list.Managed(CompressedTreeElement(T)).init(self.allocator);
            errdefer {
                for (out.items) |child| freeDecompressed(T, self.allocator, child);
                out.deinit();
            }
            if (source.element == element) {
                for (children) |child| try out.append(try self.cloneDecompressed(child));
            } else {
                for (source.children) |child| {
                    try out.append(try self.spliceDecompressed(child, element, children));
                }
            }
            return .{
                .element = source.element,
                .children = try out.toOwnedSlice(),
                .collapsible = source.collapsible,
                .collapsed = source.collapsed,
                .incompressible = source.incompressible,
            };
        }

        /// The compressed element tree built from model nodes borrows the
        /// model-owned `elements` slices. Only its own children arrays are
        /// owned, so it must not go through `freeCompressed`.
        fn freeModelDerivedCompressed(self: *CompressedObjectTreeModel(T), element: Compressed) void {
            for (element.children) |child| self.freeModelDerivedCompressed(child);
            self.allocator.free(element.children);
        }

        fn applyRawCollapse(self: *CompressedObjectTreeModel(T), element: *CompressedTreeElement(T)) void {
            if (self.raw_nodes.get(element.element)) |raw| element.collapsed = raw.collapsed;
            const mutable: [*]CompressedTreeElement(T) = @constCast(element.children.ptr);
            for (0..element.children.len) |index| self.applyRawCollapse(&mutable[index]);
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

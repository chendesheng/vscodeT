// Port of `src/vs/base/browser/ui/tree/indexTreeModel.ts`.
//
// Terminal adaptation: this slice ports the model's node/splice/collapse/render
// projection, identity-aware smart splicing and create/delete callbacks used by
// the object/compressed models. Event emitters are not ported; storage is an
// allocated node tree instead of JS objects.

const std = @import("std");
const tree = @import("./tree.zig");

pub fn IndexTreeModel(comptime T: type) type {
    return struct {
        pub const Element = tree.TreeElement(T);

        pub const Node = struct {
            element: T,
            parent: ?*Node = null,
            children: std.array_list.Managed(*Node),
            depth: usize,
            collapsible: bool = false,
            collapsed: bool = false,
            render_node_count: usize = 0,
            visibility: tree.TreeVisibility = .visible,
            visible: bool = true,
        };

        pub const Options = struct {
            collapse_by_default: bool = false,
            allow_non_collapsible_parents: bool = false,
            filter: ?tree.TreeFilter(T) = null,
        };

        pub const NodeCallback = *const fn (context: *anyopaque, node: *Node) void;
        pub const SpliceOptions = struct {
            identity_provider: ?tree.IdentityProvider(T) = null,
            diff_depth: usize = 0,
            on_did_create_node: ?NodeCallback = null,
            on_did_delete_node: ?NodeCallback = null,
            callback_context: ?*anyopaque = null,
        };

        allocator: std.mem.Allocator,
        user: []const u8,
        root: *Node,
        options: Options,

        pub fn init(
            allocator: std.mem.Allocator,
            user: []const u8,
            root_element: T,
            options: Options,
        ) !IndexTreeModel(T) {
            const root = try allocator.create(Node);
            errdefer allocator.destroy(root);
            root.* = .{
                .element = root_element,
                .children = std.array_list.Managed(*Node).init(allocator),
                .depth = 0,
            };
            var model = IndexTreeModel(T){
                .allocator = allocator,
                .user = user,
                .root = root,
                .options = options,
            };
            _ = try model.updateRenderCount(root, .visible);
            return model;
        }

        pub fn deinit(self: *IndexTreeModel(T)) void {
            self.destroyNode(self.root);
        }

        fn destroyNode(self: *IndexTreeModel(T), node: *Node) void {
            for (node.children.items) |child| self.destroyNode(child);
            node.children.deinit();
            self.allocator.destroy(node);
        }

        fn destroyNodeWithOptions(self: *IndexTreeModel(T), node: *Node, options: SpliceOptions) void {
            if (options.on_did_delete_node) |callback| {
                const context = options.callback_context orelse @as(*anyopaque, @ptrCast(self));
                callback(context, node);
            }
            for (node.children.items) |child| self.destroyNodeWithOptions(child, options);
            node.children.deinit();
            self.allocator.destroy(node);
        }

        pub fn getNode(self: *IndexTreeModel(T), location: []const usize) tree.TreeError!*Node {
            var node = self.root;
            for (location) |index| {
                if (index >= node.children.items.len) return error.TreeNotFound;
                node = node.children.items[index];
            }
            return node;
        }

        pub fn has(self: *IndexTreeModel(T), location: []const usize) bool {
            _ = self.getNode(location) catch return false;
            return true;
        }

        fn appendElement(
            self: *IndexTreeModel(T),
            parent: *Node,
            element: Element,
            options: SpliceOptions,
        ) !*Node {
            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);
            node.* = .{
                .element = element.element,
                .parent = parent,
                .children = std.array_list.Managed(*Node).init(self.allocator),
                .depth = parent.depth + 1,
                .collapsible = element.collapsible or element.children.len > 0,
                .collapsed = element.collapsed orelse self.options.collapse_by_default,
            };
            try parent.children.append(node);
            errdefer _ = parent.children.pop();
            for (element.children) |child| {
                _ = try self.appendElement(node, child, options);
            }
            if (options.on_did_create_node) |callback| {
                const context = options.callback_context orelse @as(*anyopaque, @ptrCast(self));
                callback(context, node);
            }
            return node;
        }

        /// Replaces `delete_count` children at `location` with `children`.
        /// `location` is the parent path; the last index is the insertion point.
        pub fn splice(
            self: *IndexTreeModel(T),
            location: []const usize,
            delete_count: usize,
            children: []const Element,
        ) !void {
            return self.spliceWithOptions(location, delete_count, children, .{});
        }

        pub fn spliceWithOptions(
            self: *IndexTreeModel(T),
            location: []const usize,
            delete_count: usize,
            children: []const Element,
            options: SpliceOptions,
        ) !void {
            if (location.len == 0) return error.InvalidTreeLocation;
            const parent_location = location[0 .. location.len - 1];
            const parent = try self.getNode(parent_location);
            const index = location[location.len - 1];
            if (index > parent.children.items.len) return error.InvalidTreeLocation;

            const end = if (delete_count >= parent.children.items.len - index)
                parent.children.items.len
            else
                index + delete_count;

            if (options.identity_provider) |provider| {
                try self.spliceSmart(parent, index, end, children, provider, options.diff_depth, options);
            } else {
                for (parent.children.items[index..end]) |child| self.destroyNodeWithOptions(child, options);
                _ = try parent.children.replaceRange(index, end - index, &.{});
                var insertion_index = index;
                for (children) |child| {
                    const node = try self.appendElement(parent, child, options);
                    _ = parent.children.pop();
                    try parent.children.insert(insertion_index, node);
                    insertion_index += 1;
                }
            }
            _ = try self.updateRenderCount(self.root, .visible);
        }

        fn spliceSmart(
            self: *IndexTreeModel(T),
            parent: *Node,
            index: usize,
            end: usize,
            children: []const Element,
            provider: tree.IdentityProvider(T),
            depth: usize,
            options: SpliceOptions,
        ) !void {
            var removed = std.array_list.Managed(*Node).init(self.allocator);
            defer removed.deinit();
            try removed.appendSlice(parent.children.items[index..end]);

            // Index removed nodes by identity so a splice over a large sibling
            // list stays linear, matching upstream's diff rather than scanning
            // every removed node for every inserted element.
            var removed_by_id = std.StringHashMap(*Node).init(self.allocator);
            defer removed_by_id.deinit();
            for (removed.items) |candidate| {
                removed_by_id.put(provider.get_id(provider.context, candidate.element), candidate) catch {};
            }

            var used = std.AutoHashMap(*Node, void).init(self.allocator);
            defer used.deinit();
            var next = std.array_list.Managed(*Node).init(self.allocator);
            errdefer next.deinit();
            try next.appendSlice(parent.children.items[0..index]);

            for (children) |element| {
                const id = provider.get_id(provider.context, element.element);
                if (removed_by_id.fetchRemove(id)) |entry| {
                    const node = entry.value;
                    used.put(node, {}) catch {};
                    node.element = element.element;
                    node.collapsible = element.collapsible or element.children.len > 0;
                    if (depth > 0) try self.mergeChildrenSmart(node, element.children, provider, depth - 1, options);
                    try next.append(node);
                } else {
                    const node = try self.appendElement(parent, element, options);
                    _ = parent.children.pop();
                    try next.append(node);
                }
            }
            try next.appendSlice(parent.children.items[end..]);

            for (removed.items) |node| {
                if (!used.contains(node)) self.destroyNodeWithOptions(node, options);
            }
            parent.children.deinit();
            parent.children = next;
        }

        fn mergeChildrenSmart(
            self: *IndexTreeModel(T),
            node: *Node,
            children: []const Element,
            provider: tree.IdentityProvider(T),
            depth: usize,
            options: SpliceOptions,
        ) !void {
            var by_id = std.StringHashMap(*Node).init(self.allocator);
            defer by_id.deinit();
            for (node.children.items) |child| {
                by_id.put(provider.get_id(provider.context, child.element), child) catch {};
            }
            var next = std.array_list.Managed(*Node).init(self.allocator);
            errdefer next.deinit();
            for (children) |element| {
                const id = provider.get_id(provider.context, element.element);
                if (by_id.fetchRemove(id)) |entry| {
                    const child_node = entry.value;
                    child_node.element = element.element;
                    child_node.collapsible = element.collapsible or element.children.len > 0;
                    if (depth > 0) try self.mergeChildrenSmart(child_node, element.children, provider, depth - 1, options);
                    try next.append(child_node);
                } else {
                    const child_node = try self.appendElement(node, element, options);
                    _ = node.children.pop();
                    try next.append(child_node);
                }
            }
            var leftover = by_id.valueIterator();
            while (leftover.next()) |child| self.destroyNodeWithOptions(child.*, options);
            node.children.deinit();
            node.children = next;
        }

        fn updateRenderCount(
            self: *IndexTreeModel(T),
            node: *Node,
            parent_visibility: tree.TreeVisibility,
        ) !usize {
            var own_visible = true;
            var visibility = tree.TreeVisibility.visible;
            if (node.parent != null) {
                if (self.options.filter) |filter| {
                    visibility = filter.filter(filter.context, node.element, parent_visibility);
                    switch (visibility) {
                        .hidden => {
                            node.visibility = .hidden;
                            node.visible = false;
                            node.render_node_count = 0;
                            return 0;
                        },
                        .visible => own_visible = true,
                        .recurse => own_visible = false,
                    }
                }
            }
            node.visibility = visibility;

            var child_count: usize = 0;
            var any_child_visible = false;
            for (node.children.items) |child| {
                const child_rows = try self.updateRenderCount(child, visibility);
                child_count += child_rows;
                if (child_rows > 0) any_child_visible = true;
            }
            if (visibility == .recurse) own_visible = any_child_visible;
            node.visible = own_visible;
            node.render_node_count = (if (own_visible and node.parent != null) @as(usize, 1) else 0) +
                (if (node.collapsed) @as(usize, 0) else child_count);
            return node.render_node_count;
        }

        pub fn getListRenderCount(self: *IndexTreeModel(T), node: *Node) usize {
            _ = self;
            return node.render_node_count;
        }

        /// The zero-based rendered-row index of `node`, or null when filtered.
        pub fn getListIndex(self: *IndexTreeModel(T), node: *Node) ?usize {
            if (!node.visible) return null;
            var index: usize = 0;
            var current = node;
            while (current.parent) |parent| {
                for (parent.children.items) |sibling| {
                    if (sibling == current) break;
                    index += sibling.render_node_count;
                }
                if (parent != self.root) index += 1;
                current = parent;
            }
            return index;
        }

        pub fn isCollapsible(self: *IndexTreeModel(T), location: []const usize) bool {
            const node = self.getNode(location) catch return false;
            return node.collapsible;
        }

        pub fn setCollapsible(self: *IndexTreeModel(T), location: []const usize, collapsible: bool) bool {
            const node = self.getNode(location) catch return false;
            if (node.collapsible == collapsible) return false;
            node.collapsible = collapsible;
            return true;
        }

        pub fn isCollapsed(self: *IndexTreeModel(T), location: []const usize) bool {
            const node = self.getNode(location) catch return false;
            return node.collapsed;
        }

        pub fn setCollapsed(
            self: *IndexTreeModel(T),
            location: []const usize,
            collapsed: bool,
            recursive: bool,
        ) !bool {
            const node = try self.getNode(location);
            const changed = try self.setCollapsedRecursive(node, collapsed, recursive);
            if (changed) _ = try self.updateRenderCount(self.root, .visible);
            return changed;
        }

        fn setCollapsedRecursive(
            self: *IndexTreeModel(T),
            node: *Node,
            collapsed: bool,
            recursive: bool,
        ) !bool {
            var changed = false;
            // Upstream _setNodeCollapseState leaves the synthetic root and
            // non-collapsible nodes unchanged but still recurses into children.
            if (node != self.root and node.collapsible and node.collapsed != collapsed) {
                node.collapsed = collapsed;
                changed = true;
            }
            if (recursive) {
                for (node.children.items) |child| {
                    if (try self.setCollapsedRecursive(child, collapsed, true)) changed = true;
                }
            }
            return changed;
        }

        pub fn expandTo(self: *IndexTreeModel(T), location: []const usize) !void {
            var node = self.root;
            for (location) |index| {
                if (node.collapsed) node.collapsed = false;
                if (index >= node.children.items.len) return error.TreeNotFound;
                node = node.children.items[index];
            }
            _ = try self.updateRenderCount(self.root, .visible);
        }

        pub fn refilter(self: *IndexTreeModel(T)) !void {
            _ = try self.updateRenderCount(self.root, .visible);
        }

        pub fn setFilter(self: *IndexTreeModel(T), filter: ?tree.TreeFilter(T)) !void {
            self.options.filter = filter;
            _ = try self.updateRenderCount(self.root, .visible);
        }

        pub fn getFirstElementChild(_: *IndexTreeModel(T), node: *Node) ?T {
            if (node.collapsed or node.children.items.len == 0) return null;
            return node.children.items[0].element;
        }

        pub fn getLastElementAncestor(_: *IndexTreeModel(T), node: ?*Node) ?T {
            var current = node;
            var last: ?T = null;
            while (current) |value| : (current = value.parent) last = value.element;
            return last;
        }

        /// Flattens the currently rendered nodes in list order.
        pub fn collectRendered(self: *IndexTreeModel(T), out: *std.array_list.Managed(*Node)) !void {
            try self.collectNode(self.root, out, false);
        }

        fn collectNode(
            self: *IndexTreeModel(T),
            node: *Node,
            out: *std.array_list.Managed(*Node),
            include_self: bool,
        ) !void {
            if (include_self and !node.visible) return;
            if (include_self and node.visible) try out.append(node);
            if (node.collapsed) return;
            for (node.children.items) |child| {
                try self.collectNode(child, out, true);
            }
        }

        pub fn rerender(self: *IndexTreeModel(T), node: *Node) !void {
            _ = try self.updateRenderCount(node, .visible);
        }
    };
}

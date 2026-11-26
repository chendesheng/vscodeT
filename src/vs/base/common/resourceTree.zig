// Port of `src/vs/base/common/resourceTree.ts`.
//
// Terminal adaptations:
// - Nodes are keyed by path strings instead of `URI`; the SCM view builds its
//   change tree from repository-relative paths.
// - Children are kept in insertion order so the rendered tree matches the
//   upstream `Map` order. Lookup is a linear scan because a commit has few
//   changed files.
// - Nodes live until `deinit`; `delete` and `clear` only detach them. This
//   keeps the ownership model simple for a tree that is rebuilt per history
//   item instead of exposing JavaScript's garbage-collected nodes.
//
// Upstream's `ResourceTree.isResourceNode` type guard has no Zig equivalent;
// callers distinguish tree nodes from plain elements with their own union/tag.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Node(comptime T: type, comptime C: type) type {
    return struct {
        allocator: Allocator,
        /// Full path used to add the node (root-relative after normalization).
        path: []u8,
        /// Path below the tree root, without a leading separator.
        relative_path: []u8,
        name: []u8,
        element: ?T = null,
        children: std.array_list.Managed(*Self),
        parent: ?*Self = null,
        context: C,

        const Self = @This();

        /// Number of direct children.
        pub fn childrenCount(self: *const Self) usize {
            return self.children.items.len;
        }

        /// Direct children in insertion order.
        pub fn childNodes(self: *const Self) []const *Self {
            return self.children.items;
        }

        /// Looks up a direct child by its basename.
        pub fn get(self: *const Self, child_name: []const u8) ?*Self {
            for (self.children.items) |child| {
                if (std.mem.eql(u8, child.name, child_name)) return child;
            }
            return null;
        }

        fn deinit(self: *Self) void {
            self.children.deinit();
            self.allocator.free(self.path);
            self.allocator.free(self.relative_path);
            self.allocator.free(self.name);
        }
    };
}

pub fn ResourceTree(comptime T: type, comptime C: type) type {
    return struct {
        allocator: Allocator,
        root_path: []u8,
        root: *Node(T, C),
        /// Every node ever allocated, so `deinit` does not need to walk the
        /// current child links.
        nodes: std.array_list.Managed(*Node(T, C)),

        const Self = @This();
        pub const NodeType = Node(T, C);

        pub fn init(allocator: Allocator, context: C, root_path: []const u8) !Self {
            const owned_root = try allocator.dupe(u8, root_path);
            errdefer allocator.free(owned_root);

            const node = try allocator.create(NodeType);
            errdefer allocator.destroy(node);
            const root_relative = try allocator.dupe(u8, "");
            errdefer allocator.free(root_relative);
            const root_name = try allocator.dupe(u8, "");
            errdefer allocator.free(root_name);

            node.* = .{
                .allocator = allocator,
                .path = try allocator.dupe(u8, root_path),
                .relative_path = root_relative,
                .name = root_name,
                .children = std.array_list.Managed(*NodeType).init(allocator),
                .context = context,
            };

            var nodes = std.array_list.Managed(*NodeType).init(allocator);
            errdefer nodes.deinit();
            try nodes.append(node);

            return .{
                .allocator = allocator,
                .root_path = owned_root,
                .root = node,
                .nodes = nodes,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |node| {
                node.deinit();
                self.allocator.destroy(node);
            }
            self.nodes.deinit();
            self.allocator.free(self.root_path);
            self.* = undefined;
        }

        /// Adds `path` to the tree. Intermediate folders are created without an
        /// element; adding an existing path replaces the element. Returns the
        /// leaf node.
        pub fn add(self: *Self, path: []const u8, element: T) !*NodeType {
            const relative = try self.relativePath(path);
            defer self.allocator.free(relative);

            var node = self.root;
            var iterator = SegmentIterator{ .path = relative };

            while (iterator.next()) |name| {
                const last = !iterator.hasNext();
                if (node.get(name)) |existing| {
                    node = existing;
                } else {
                    const child = try self.createNode(node, name);
                    try node.children.append(child);
                    node = child;
                }
                if (last) {
                    node.element = element;
                }
            }

            return node;
        }

        /// Detaches the node at `path` and returns its element, if any. Empty
        /// parents are pruned like upstream. Detached nodes stay allocated
        /// until `deinit`.
        pub fn delete(self: *Self, path: []const u8) !?T {
            const relative = try self.relativePath(path);
            defer self.allocator.free(relative);

            var segments = std.array_list.Managed([]const u8).init(self.allocator);
            defer segments.deinit();
            var iterator = SegmentIterator{ .path = relative };
            while (iterator.next()) |name| try segments.append(name);
            if (segments.items.len == 0) return null;

            var node = self.root;
            var index: usize = 0;
            while (index + 1 < segments.items.len) : (index += 1) {
                node = node.get(segments.items[index]) orelse return null;
            }

            const parent = node;
            const name = segments.items[segments.items.len - 1];
            const child = parent.get(name) orelse return null;
            detach(parent, child);
            child.parent = null;
            const result = child.element;

            // Upstream `_delete` removes a parent that becomes empty because of
            // the removal, all the way up to (but not including) the root.
            var current = parent;
            while (current != self.root and current.childrenCount() == 0) {
                const grandparent = current.parent orelse break;
                detach(grandparent, current);
                current.parent = null;
                current = grandparent;
            }

            return result;
        }

        fn detach(parent: *NodeType, child: *NodeType) void {
            for (parent.children.items, 0..) |candidate, child_index| {
                if (candidate != child) continue;
                _ = parent.children.orderedRemove(child_index);
                return;
            }
        }

        pub fn clear(self: *Self) void {
            for (self.root.children.items) |child| child.parent = null;
            self.root.children.clearRetainingCapacity();
            self.root.element = null;
        }

        pub fn getNode(self: *Self, path: []const u8) ?*NodeType {
            const relative = self.relativePath(path) catch return null;
            defer self.allocator.free(relative);

            var node = self.root;
            var iterator = SegmentIterator{ .path = relative };
            while (iterator.next()) |name| {
                node = node.get(name) orelse return null;
            }
            return node;
        }

        /// Walks up to the root of `node`.
        pub fn getRoot(node: *NodeType) *NodeType {
            var current = node;
            while (current.parent) |parent| current = parent;
            return current;
        }

        /// Pre-order element collection in child insertion order.
        pub fn collect(self: *Self, node: *NodeType) ![]T {
            var result = std.array_list.Managed(T).init(self.allocator);
            errdefer result.deinit();
            try collectInto(node, &result);
            return result.toOwnedSlice();
        }

        fn collectInto(node: *NodeType, result: *std.array_list.Managed(T)) !void {
            if (node.element) |element| try result.append(element);
            for (node.children.items) |child| try collectInto(child, result);
        }

        fn relativePath(self: *const Self, path: []const u8) ![]u8 {
            var relative = path;
            if (self.root_path.len > 0) {
                const root = std.mem.trimEnd(u8, self.root_path, "/\\");
                if (root.len > 0 and std.mem.startsWith(u8, relative, root) and (relative.len == root.len or relative[root.len] == '/' or relative[root.len] == '\\')) {
                    relative = relative[root.len..];
                }
            }
            while (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) {
                relative = relative[1..];
            }
            const trimmed = std.mem.trimEnd(u8, relative, "/\\");
            return self.allocator.dupe(u8, trimmed);
        }

        fn createNode(self: *Self, parent: *NodeType, name: []const u8) !*NodeType {
            const node = try self.allocator.create(NodeType);
            errdefer self.allocator.destroy(node);

            const relative = if (parent == self.root)
                try self.allocator.dupe(u8, name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent.relative_path, name });
            errdefer self.allocator.free(relative);

            const full_path = if (parent == self.root)
                try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ self.root_path, if (self.root_path.len == 0 or std.mem.endsWith(u8, self.root_path, "/")) "" else "/", name })
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent.path, name });
            errdefer self.allocator.free(full_path);

            node.* = .{
                .allocator = self.allocator,
                .path = full_path,
                .relative_path = relative,
                .name = try self.allocator.dupe(u8, name),
                .element = null,
                .children = std.array_list.Managed(*NodeType).init(self.allocator),
                .parent = parent,
                .context = self.root.context,
            };
            errdefer self.allocator.free(node.name);

            try self.nodes.append(node);
            return node;
        }
    };
}

/// Splits a normalized relative path on `/` (and `\` on Windows-style input),
/// skipping empty segments like upstream `PathIterator`.
const SegmentIterator = struct {
    path: []const u8,
    position: usize = 0,
    next_position: ?usize = null,

    fn next(self: *SegmentIterator) ?[]const u8 {
        if (self.next_position) |position| {
            self.position = position;
            self.next_position = null;
        }
        while (self.position < self.path.len) {
            var end = self.position;
            while (end < self.path.len and self.path[end] != '/' and self.path[end] != '\\') : (end += 1) {}
            if (end > self.position) {
                self.next_position = end + 1;
                return self.path[self.position..end];
            }
            self.position += 1;
        }
        return null;
    }

    fn hasNext(self: *SegmentIterator) bool {
        var position = self.next_position orelse self.position;
        while (position < self.path.len) : (position += 1) {
            if (self.path[position] != '/' and self.path[position] != '\\') return true;
        }
        return false;
    }
};

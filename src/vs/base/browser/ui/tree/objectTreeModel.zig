// Port of `src/vs/base/browser/ui/tree/objectTreeModel.ts`.
//
// Terminal adaptation: the element map uses `std.AutoHashMap` instead of a JS
// Map. Collapse-state preservation, setChildren/resort order and the index-tree
// projection follow upstream. Identity providers and smart diffing are not
// ported yet.

const std = @import("std");
const tree = @import("./tree.zig");
const index_model = @import("./indexTreeModel.zig");

pub fn ObjectTreeElement(comptime T: type) type {
    return struct {
        element: T,
        children: []const ObjectTreeElement(T) = &.{},
        collapsible: ?bool = null,
        collapsed: ?bool = null,
    };
}

pub fn ObjectTreeModel(comptime T: type) type {
    return ObjectTreeModelWithHash(T, std.hash_map.AutoContext(T));
}

pub fn ObjectTreeModelWithHash(comptime T: type, comptime Context: type) type {
    return struct {
        pub const Index = index_model.IndexTreeModel(?T);
        pub const Node = Index.Node;
        pub const Element = tree.TreeElement(?T);

        allocator: std.mem.Allocator,
        model: Index,
        nodes: std.HashMap(T, *Node, Context, 80),
        collapse_by_default: bool,

        pub fn init(allocator: std.mem.Allocator, user: []const u8, collapse_by_default: bool) !ObjectTreeModelWithHash(T, Context) {
            return .{
                .allocator = allocator,
                .model = try Index.init(allocator, user, null, .{
                    .collapse_by_default = collapse_by_default,
                }),
                .nodes = std.HashMap(T, *Node, Context, 80).init(allocator),
                .collapse_by_default = collapse_by_default,
            };
        }

        pub fn deinit(self: *ObjectTreeModelWithHash(T, Context)) void {
            self.nodes.deinit();
            self.model.deinit();
        }

        pub fn size(self: *const ObjectTreeModelWithHash(T, Context)) usize {
            return self.nodes.count();
        }

        fn locationOf(self: *ObjectTreeModelWithHash(T, Context), element: ?T) ![]usize {
            if (element == null) return self.allocator.alloc(usize, 0);
            const node = self.nodes.get(element.?) orelse return error.TreeNotFound;
            var depth: usize = 0;
            var current: ?*Node = node;
            while (current) |value| : (current = value.parent) {
                if (value.parent != null) depth += 1;
            }
            const location = try self.allocator.alloc(usize, depth);
            var index = depth;
            current = node;
            while (current) |value| {
                if (value.parent) |parent| {
                    var child_index: usize = 0;
                    for (parent.children.items, 0..) |child, i| {
                        if (child == value) {
                            child_index = i;
                            break;
                        }
                    }
                    index -= 1;
                    location[index] = child_index;
                }
                current = value.parent;
            }
            return location;
        }

        fn buildElements(
            self: *ObjectTreeModelWithHash(T, Context),
            children: []const ObjectTreeElement(T),
            preserve: bool,
        ) ![]Element {
            var list = std.array_list.Managed(Element).init(self.allocator);
            errdefer {
                for (list.items) |element| self.freeElement(element);
                list.deinit();
            }
            for (children) |child| {
                var collapsed = child.collapsed;
                var collapsible = child.collapsible;
                if (preserve) {
                    if (self.nodes.get(child.element)) |old| {
                        if (collapsed == null) collapsed = old.collapsed;
                        if (collapsible == null) collapsible = old.collapsible;
                    }
                }
                try list.append(.{
                    .element = child.element,
                    .children = try self.buildElements(child.children, preserve),
                    .collapsible = collapsible orelse (child.children.len > 0),
                    .collapsed = collapsed orelse self.collapse_by_default,
                });
            }
            return list.toOwnedSlice();
        }

        fn freeElement(self: *ObjectTreeModelWithHash(T, Context), element: Element) void {
            self.freeElements(element.children);
            self.allocator.free(element.children);
        }

        fn freeElements(self: *ObjectTreeModelWithHash(T, Context), elements: []const Element) void {
            for (elements) |element| self.freeElement(element);
        }

        pub fn setChildren(
            self: *ObjectTreeModelWithHash(T, Context),
            element: ?T,
            children: []const ObjectTreeElement(T),
        ) !void {
            const parent_location = try self.locationOf(element);
            defer self.allocator.free(parent_location);

            const elements = try self.buildElements(children, true);
            defer {
                self.freeElements(elements);
                self.allocator.free(elements);
            }

            var location = try self.allocator.alloc(usize, parent_location.len + 1);
            defer self.allocator.free(location);
            @memcpy(location[0..parent_location.len], parent_location);
            location[parent_location.len] = 0;

            try self.model.splice(location, std.math.maxInt(usize), elements);
            self.rebuildNodeMap();
        }

        fn rebuildNodeMap(self: *ObjectTreeModelWithHash(T, Context)) void {
            self.nodes.clearRetainingCapacity();
            for (self.model.root.children.items) |child| self.addNode(child);
        }

        fn addNode(self: *ObjectTreeModelWithHash(T, Context), node: *Node) void {
            if (node.element) |element| self.nodes.put(element, node) catch {};
            for (node.children.items) |child| self.addNode(child);
        }

        pub fn getNode(self: *ObjectTreeModelWithHash(T, Context), element: ?T) !*Node {
            if (element == null) return self.model.root;
            return self.nodes.get(element.?) orelse error.TreeNotFound;
        }

        pub fn has(self: *ObjectTreeModelWithHash(T, Context), element: ?T) bool {
            if (element == null) return true;
            return self.nodes.contains(element.?);
        }

        pub fn getListIndex(self: *ObjectTreeModelWithHash(T, Context), element: ?T) !?usize {
            const node = try self.getNode(element);
            return self.model.getListIndex(node);
        }

        pub fn getListRenderCount(self: *ObjectTreeModelWithHash(T, Context), element: ?T) !usize {
            const node = try self.getNode(element);
            return self.model.getListRenderCount(node);
        }

        pub fn isCollapsed(self: *ObjectTreeModelWithHash(T, Context), element: ?T) bool {
            const node = self.getNode(element) catch return false;
            return node.collapsed;
        }

        pub fn setCollapsed(self: *ObjectTreeModelWithHash(T, Context), element: ?T, collapsed: bool, recursive: bool) !bool {
            const location = try self.locationOf(element);
            defer self.allocator.free(location);
            return self.model.setCollapsed(location, collapsed, recursive);
        }

        pub fn isCollapsible(self: *ObjectTreeModelWithHash(T, Context), element: ?T) bool {
            const node = self.getNode(element) catch return false;
            return node.collapsible;
        }

        pub fn setCollapsible(self: *ObjectTreeModelWithHash(T, Context), element: ?T, collapsible: bool) !bool {
            const location = try self.locationOf(element);
            defer self.allocator.free(location);
            return self.model.setCollapsible(location, collapsible);
        }

        pub fn expandTo(self: *ObjectTreeModelWithHash(T, Context), element: ?T) !void {
            const location = try self.locationOf(element);
            defer self.allocator.free(location);
            try self.model.expandTo(location);
        }

        pub fn collectRendered(self: *ObjectTreeModelWithHash(T, Context), out: *std.array_list.Managed(*Node)) !void {
            try self.model.collectRendered(out);
        }

        pub fn refilter(self: *ObjectTreeModelWithHash(T, Context)) !void {
            try self.model.refilter();
        }

        pub fn setFilter(self: *ObjectTreeModelWithHash(T, Context), filter: ?tree.TreeFilter(T)) !void {
            try self.model.setFilter(filter);
        }
    };
}

// Port of `src/vs/workbench/contrib/search/test/browser/mockSearchTree.ts`.
//
// The terminal action helpers talk to `searchActionsBase.Viewer`; this mock
// keeps the same array-navigator shape as upstream's `MockObjectTree`.

const std = @import("std");
const tree = @import("../../browser/searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const base = @import("../../browser/searchActionsBase.zig");
const Viewer = base.Viewer;

pub const MockObjectTree = struct {
    allocator: std.mem.Allocator,
    elements: []Node,
    selected_node: ?Node = null,
    collapsed: std.array_list.Managed(Node),

    pub fn init(allocator: std.mem.Allocator, elements: []Node) !*MockObjectTree {
        const self = try allocator.create(MockObjectTree);
        self.* = .{
            .allocator = allocator,
            .elements = elements,
            .collapsed = std.array_list.Managed(Node).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *MockObjectTree) void {
        self.collapsed.deinit();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *MockObjectTree) Viewer {
        return .{
            .context = self,
            .row_count = rowCount,
            .row_at = rowAt,
            .index_of = indexOf,
            .last_visible = lastVisible,
            .is_collapsed = isCollapsed,
            .expand = expand,
            .collapse = collapse,
            .collapse_all = collapseAll,
            .expand_all = expandAll,
            .selected = selected,
            .set_selected = setSelected,
            .focus = focus,
            .refresh = refresh,
        };
    }

    fn rowCount(context: *anyopaque) usize {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        return self.elements.len;
    }

    fn rowAt(context: *anyopaque, index: usize) ?Node {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        if (index >= self.elements.len) return null;
        return self.elements[index];
    }

    fn indexOf(context: *anyopaque, node: Node) ?usize {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        for (self.elements, 0..) |element, index| {
            if (tree.nodeEql(element, node)) return index;
        }
        return null;
    }

    fn lastVisible(context: *anyopaque) ?Node {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        if (self.elements.len == 0) return null;
        return self.elements[self.elements.len - 1];
    }

    fn isCollapsed(context: *anyopaque, node: Node) bool {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        for (self.collapsed.items) |element| {
            if (tree.nodeEql(element, node)) return true;
        }
        return false;
    }

    fn expand(context: *anyopaque, node: Node, recursive: bool) bool {
        _ = recursive;
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        for (self.collapsed.items, 0..) |element, index| {
            if (!tree.nodeEql(element, node)) continue;
            _ = self.collapsed.orderedRemove(index);
            return true;
        }
        return false;
    }

    fn collapse(context: *anyopaque, node: Node, recursive: bool) bool {
        _ = recursive;
        if (isCollapsed(context, node)) return false;
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        self.collapsed.append(node) catch {};
        return true;
    }

    fn collapseAll(context: *anyopaque) void {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        self.collapsed.clearRetainingCapacity();
        for (self.elements) |element| self.collapsed.append(element) catch {};
    }

    fn expandAll(context: *anyopaque) void {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        self.collapsed.clearRetainingCapacity();
    }

    fn selected(context: *anyopaque) ?Node {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        return self.selected_node;
    }

    fn setSelected(context: *anyopaque, node: ?Node) void {
        const self: *MockObjectTree = @ptrCast(@alignCast(context));
        self.selected_node = node;
    }

    fn focus(_: *anyopaque) void {}

    fn refresh(_: *anyopaque) void {}
};

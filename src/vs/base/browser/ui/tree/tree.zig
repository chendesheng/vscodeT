// Port of the portable tree contracts in `src/vs/base/browser/ui/tree/tree.ts`.
//
// Terminal adaptation: filter data and drag/drop types are omitted until their
// consumers are ported. The index model keeps the upstream node shape and row
// projection; renderers receive tree nodes and indent from the view layer.

const std = @import("std");

pub const TreeVisibility = enum { hidden, visible, recurse };

pub fn IdentityProvider(comptime T: type) type {
    return struct {
        context: *anyopaque,
        get_id: *const fn (context: *anyopaque, element: T) []const u8,
    };
}

pub fn TreeFilter(comptime T: type) type {
    return struct {
        context: *anyopaque,
        filter: *const fn (context: *anyopaque, element: T, parent_visibility: TreeVisibility) TreeVisibility,
    };
}

pub const TreeError = error{
    InvalidTreeLocation,
    TreeNotFound,
};

pub fn TreeElement(comptime T: type) type {
    return struct {
        element: T,
        children: []const TreeElement(T) = &.{},
        collapsible: bool = false,
        collapsed: ?bool = null,
    };
}

pub fn TreeNode(comptime T: type) type {
    return struct {
        element: T,
        children: []TreeNode(T) = &.{},
        depth: usize = 0,
        visible_children_count: usize = 0,
        visible_child_index: i64 = -1,
        collapsible: bool = false,
        collapsed: bool = false,
        render_node_count: usize = 0,
        visibility: TreeVisibility = .visible,
        visible: bool = true,
    };
}

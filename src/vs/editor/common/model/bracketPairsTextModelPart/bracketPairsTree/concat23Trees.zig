// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/concat23Trees.ts`.
//
// Shared list paths are copied before mutation; unshared nodes are reused.
// This is the upstream (2,3) tree concatenation algorithm with native ownership.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ast = @import("./ast.zig");
const AstNode = ast.AstNode;

/// Concatenates a list of (2,3) AstNodes into a single (2,3) AstNode. The
/// input slice is not mutated; callers own the returned nodes.
pub fn concat23Trees(allocator: Allocator, items: []const *AstNode) !?*AstNode {
    return concat23TreesIn(allocator, allocator, items, null);
}

pub fn concat23TreesIn(allocator: Allocator, scratch: Allocator, items: []const *AstNode, region: ?*ast.NodeRegion) !?*AstNode {
    if (items.len == 0) return null;
    if (items.len == 1) return items[0];

    var i: usize = 0;

    var first = (try readNode(allocator, scratch, items, &i, region)).?;
    var second = try readNode(allocator, scratch, items, &i, region);
    if (second == null) return first;

    while (try readNode(allocator, scratch, items, &i, region)) |item| {
        if (heightDiff(first, second.?) <= heightDiff(second.?, item)) {
            first = try concat(allocator, scratch, first, second.?, region);
            second = item;
        } else {
            second = try concat(allocator, scratch, second.?, item, region);
        }
    }

    return try concat(allocator, scratch, first, second.?, region);
}

fn readNode(allocator: Allocator, scratch: Allocator, items: []const *AstNode, i: *usize, region: ?*ast.NodeRegion) !?*AstNode {
    if (i.* >= items.len) return null;
    const start = i.*;
    const height = items[start].list_height;
    i.* += 1;
    while (i.* < items.len and items[i.*].list_height == height) i.* += 1;

    if (i.* - start >= 2) {
        const group = if (start == 0 and i.* == items.len) items else items[start..i.*];
        return try concat23TreesOfSameHeightIn(allocator, scratch, group, region);
    }
    return items[start];
}

pub fn concat23TreesOfSameHeight(allocator: Allocator, items: []const *AstNode) !?*AstNode {
    return concat23TreesOfSameHeightIn(allocator, allocator, items, null);
}

pub fn concat23TreesOfSameHeightIn(allocator: Allocator, scratch: Allocator, items: []const *AstNode, region: ?*ast.NodeRegion) !?*AstNode {
    if (items.len == 0) return null;
    if (items.len == 1) return items[0];

    var current = try scratch.dupe(*AstNode, items);
    defer scratch.free(current);

    var length = current.len;
    while (length > 3) {
        const new_length = length >> 1;
        var i: usize = 0;
        while (i < new_length) : (i += 1) {
            const j = i << 1;
            current[i] = try ast.create23In(
                allocator,
                current[j],
                current[j + 1],
                if (j + 3 == length) current[j + 2] else null,
                region,
            );
        }
        length = new_length;
    }
    return try ast.create23In(allocator, current[0], current[1], if (length >= 3) current[2] else null, region);
}

fn heightDiff(node1: *AstNode, node2: *AstNode) u32 {
    return if (node1.list_height > node2.list_height)
        node1.list_height - node2.list_height
    else
        node2.list_height - node1.list_height;
}

fn concat(allocator: Allocator, scratch: Allocator, node1: *AstNode, node2: *AstNode, region: ?*ast.NodeRegion) !*AstNode {
    if (node1.list_height == node2.list_height) {
        return try ast.create23In(allocator, node1, node2, null, region);
    }
    if (node1.list_height > node2.list_height) return try append(allocator, scratch, node1, node2, region);
    return try prepend(allocator, scratch, node2, node1, region);
}

fn append(allocator: Allocator, scratch: Allocator, old_list: *AstNode, node_to_append: *AstNode, region: ?*ast.NodeRegion) !*AstNode {
    const list = try old_list.toMutable(allocator, region);
    var current = list;
    var parents = ArrayList(*AstNode).init(scratch);
    defer parents.deinit();
    var pending: ?*AstNode = null;

    while (true) {
        if (node_to_append.list_height == current.list_height) {
            pending = node_to_append;
            break;
        }
        if (current.data != .list) return error.Unexpected;
        try parents.append(current);
        current = (try current.makeLastElementMutable(allocator, region)) orelse return error.Unexpected;
    }

    var i = parents.items.len;
    while (i > 0) {
        i -= 1;
        const parent = parents.items[i];
        if (pending) |node| {
            if (parent.childrenLength() >= 3) {
                const removed = parent.unappendChild() orelse return error.Unexpected;
                pending = try ast.create23In(allocator, removed, node, null, region);
            } else {
                parent.appendChildOfSameHeight(node);
                pending = null;
            }
        } else {
            parent.handleChildrenChanged();
        }
    }

    if (pending) |node| return try ast.create23In(allocator, list, node, null, region);
    return list;
}

fn prepend(allocator: Allocator, scratch: Allocator, old_list: *AstNode, node_to_prepend: *AstNode, region: ?*ast.NodeRegion) !*AstNode {
    const list = try old_list.toMutable(allocator, region);
    var current = list;
    var parents = ArrayList(*AstNode).init(scratch);
    defer parents.deinit();
    var pending: ?*AstNode = node_to_prepend;

    while (node_to_prepend.list_height != current.list_height) {
        if (current.data != .list) return error.Unexpected;
        try parents.append(current);
        current = (try current.makeFirstElementMutable(allocator, region)) orelse return error.Unexpected;
    }

    var i = parents.items.len;
    while (i > 0) {
        i -= 1;
        const parent = parents.items[i];
        if (pending) |node| {
            if (parent.childrenLength() >= 3) {
                const removed = parent.unprependChild() orelse return error.Unexpected;
                pending = try ast.create23In(allocator, node, removed, null, region);
            } else {
                parent.prependChildOfSameHeight(node);
                pending = null;
            }
        } else {
            parent.handleChildrenChanged();
        }
    }

    if (pending) |node| return try ast.create23In(allocator, node, list, null, region);
    return list;
}

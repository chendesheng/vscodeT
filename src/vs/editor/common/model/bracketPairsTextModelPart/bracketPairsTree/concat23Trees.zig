// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsTree/concat23Trees.ts`.
//
// The port's list nodes are always mutable `ArrayList` children, so
// `toMutable` is the identity; everything else follows the upstream (2,3)
// tree algorithm.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ast = @import("./ast.zig");
const AstNode = ast.AstNode;

/// Concatenates a list of (2,3) AstNodes into a single (2,3) AstNode. The
/// input slice is not mutated; callers own the returned nodes.
pub fn concat23Trees(allocator: Allocator, items: []const *AstNode) !?*AstNode {
    if (items.len == 0) return null;
    if (items.len == 1) return items[0];

    var i: usize = 0;

    var first = (try readNode(allocator, items, &i)).?;
    var second = try readNode(allocator, items, &i);
    if (second == null) return first;

    while (try readNode(allocator, items, &i)) |item| {
        if (heightDiff(first, second.?) <= heightDiff(second.?, item)) {
            first = try concat(allocator, first, second.?);
            second = item;
        } else {
            second = try concat(allocator, second.?, item);
        }
    }

    return try concat(allocator, first, second.?);
}

fn readNode(allocator: Allocator, items: []const *AstNode, i: *usize) !?*AstNode {
    if (i.* >= items.len) return null;
    const start = i.*;
    const height = items[start].list_height;
    i.* += 1;
    while (i.* < items.len and items[i.*].list_height == height) i.* += 1;

    if (i.* - start >= 2) {
        const group = if (start == 0 and i.* == items.len) items else items[start..i.*];
        return try concat23TreesOfSameHeight(allocator, group);
    }
    return items[start];
}

pub fn concat23TreesOfSameHeight(allocator: Allocator, items: []const *AstNode) !?*AstNode {
    if (items.len == 0) return null;
    if (items.len == 1) return items[0];

    var current = try allocator.dupe(*AstNode, items);
    defer allocator.free(current);

    var length = current.len;
    while (length > 3) {
        const new_length = length >> 1;
        var i: usize = 0;
        while (i < new_length) : (i += 1) {
            const j = i << 1;
            current[i] = try ast.create23(
                allocator,
                current[j],
                current[j + 1],
                if (j + 3 == length) current[j + 2] else null,
            );
        }
        length = new_length;
    }
    return try ast.create23(allocator, current[0], current[1], if (length >= 3) current[2] else null);
}

fn heightDiff(node1: *AstNode, node2: *AstNode) u32 {
    return if (node1.list_height > node2.list_height)
        node1.list_height - node2.list_height
    else
        node2.list_height - node1.list_height;
}

fn concat(allocator: Allocator, node1: *AstNode, node2: *AstNode) !*AstNode {
    if (node1.list_height == node2.list_height) {
        return try ast.create23(allocator, node1, node2, null);
    }
    if (node1.list_height > node2.list_height) return try append(allocator, node1, node2);
    return try prepend(allocator, node2, node1);
}

fn append(allocator: Allocator, list: *AstNode, node_to_append: *AstNode) !*AstNode {
    var current = list;
    var parents = ArrayList(*AstNode).init(allocator);
    defer parents.deinit();
    var pending: ?*AstNode = null;

    while (true) {
        if (node_to_append.list_height == current.list_height) {
            pending = node_to_append;
            break;
        }
        if (current.data != .list) return error.Unexpected;
        try parents.append(current);
        current = current.makeLastElementMutable() orelse return error.Unexpected;
    }

    var i = parents.items.len;
    while (i > 0) {
        i -= 1;
        const parent = parents.items[i];
        if (pending) |node| {
            if (parent.childrenLength() >= 3) {
                const removed = parent.unappendChild() orelse return error.Unexpected;
                pending = try ast.create23(allocator, removed, node, null);
            } else {
                parent.appendChildOfSameHeight(node);
                pending = null;
            }
        } else {
            parent.handleChildrenChanged();
        }
    }

    if (pending) |node| return try ast.create23(allocator, list, node, null);
    return list;
}

fn prepend(allocator: Allocator, list: *AstNode, node_to_prepend: *AstNode) !*AstNode {
    var current = list;
    var parents = ArrayList(*AstNode).init(allocator);
    defer parents.deinit();
    var pending: ?*AstNode = node_to_prepend;

    while (node_to_prepend.list_height != current.list_height) {
        if (current.data != .list) return error.Unexpected;
        try parents.append(current);
        current = current.makeFirstElementMutable() orelse return error.Unexpected;
    }

    var i = parents.items.len;
    while (i > 0) {
        i -= 1;
        const parent = parents.items[i];
        if (pending) |node| {
            if (parent.childrenLength() >= 3) {
                const removed = parent.unprependChild() orelse return error.Unexpected;
                pending = try ast.create23(allocator, node, removed, null);
            } else {
                parent.prependChildOfSameHeight(node);
                pending = null;
            }
        } else {
            parent.handleChildrenChanged();
        }
    }

    if (pending) |node| return try ast.create23(allocator, node, list, null);
    return list;
}

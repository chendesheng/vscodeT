// Port of
// `src/vs/editor/test/common/model/bracketPairColorizer/concat23Trees.test.ts`.

const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const bpt = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig");
const AstNode = bpt.AstNode;
const concat23Trees = bpt.concat23Trees;
const toLength = bpt.toLength;

fn equals(node1: *const AstNode, node2: *const AstNode) bool {
    if (node1.length != node2.length) return false;
    if (node1.childrenLength() != node2.childrenLength()) return false;
    for (0..node1.childrenLength()) |i| {
        if (!equals(node1.child(i).?, node2.child(i).?)) return false;
    }
    if (!node1.missing.eql(node2.missing)) return false;
    if (node1.kind == .pair and node2.kind == .pair) return true;
    return node1.kind == node2.kind;
}

fn textNode(allocator: Allocator) !*AstNode {
    return try bpt.makeText(allocator, toLength(1, 1));
}

fn listOf(allocator: Allocator, items: []const *AstNode) !*AstNode {
    return try bpt.makeList(allocator, items, items[0].list_height + 1);
}

fn testMerge(allocator: Allocator, lists: []const *AstNode) !void {
    var clones = ArrayList(*AstNode).init(allocator);
    defer clones.deinit();
    for (lists) |list| try clones.append(try list.clone(allocator));

    const merged_unflattened = (try concat23Trees(allocator, clones.items)) orelse try bpt.makeEmptyList(allocator);
    const merged = try merged_unflattened.flattenLists(allocator);

    const reference_unflattened = try bpt.makeList(allocator, lists, if (lists.len > 0) lists[0].list_height + 1 else 0);
    const reference = try reference_unflattened.flattenLists(allocator);
    try std.testing.expect(equals(merged, reference));
}

test "concat23Trees: clone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try listOf(allocator, &.{ try textNode(allocator), try textNode(allocator) });
    const clone = try tree.clone(allocator);
    try std.testing.expect(equals(tree, clone));
}

test "concat23Trees: empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try testMerge(arena.allocator(), &.{});
}

test "concat23Trees: same height lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try textNode(a);
    const tree = try listOf(a, &.{ try text.clone(a), try text.clone(a) });
    try testMerge(a, &.{
        try tree.clone(a), try tree.clone(a), try tree.clone(a), try tree.clone(a), try tree.clone(a),
    });
}

test "concat23Trees: different height lists 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try textNode(a);
    const tree1 = try listOf(a, &.{ try text.clone(a), try text.clone(a) });
    const tree2 = try listOf(a, &.{ try tree1.clone(a), try tree1.clone(a) });
    try testMerge(a, &.{ tree1, tree2 });
}

test "concat23Trees: different height lists 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try textNode(a);
    const tree1 = try listOf(a, &.{ try text.clone(a), try text.clone(a) });
    const tree2 = try listOf(a, &.{ try tree1.clone(a), try tree1.clone(a) });
    try testMerge(a, &.{ tree2, tree1 });
}

test "concat23Trees: different height lists 3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try textNode(a);
    const tree1 = try listOf(a, &.{ try text.clone(a), try text.clone(a) });
    const tree2 = try listOf(a, &.{ try tree1.clone(a), try tree1.clone(a) });
    try testMerge(a, &.{ tree2, tree1, tree1, tree2, tree2 });
}

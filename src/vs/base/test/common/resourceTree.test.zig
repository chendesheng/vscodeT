// Port of `src/vs/base/test/common/resourceTree.test.ts`.
//
// The upstream tests use `URI` and `assert.strictEqual`; this terminal port uses
// path strings and `std.testing`. The transferred cases keep their names and
// assertions.

const std = @import("std");
const testing = std.testing;
const ResourceTree = @import("../../common/resourceTree.zig").ResourceTree;

test "ResourceTree: ctor" {
    const allocator = testing.allocator;
    var tree = try ResourceTree(u32, void).init(allocator, {}, "/");
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.root.childrenCount());
    try testing.expectEqualStrings("", tree.root.relative_path);
    try testing.expectEqualStrings("", tree.root.name);
    try testing.expect(tree.root.parent == null);
}

test "ResourceTree: simple" {
    const allocator = testing.allocator;
    var tree = try ResourceTree([]const u8, void).init(allocator, {}, "/");
    defer tree.deinit();

    _ = try tree.add("/foo/bar.txt", "bar contents");
    try testing.expectEqual(@as(usize, 1), tree.root.childrenCount());

    const foo = tree.root.get("foo").?;
    try testing.expectEqual(@as(usize, 1), foo.childrenCount());
    try testing.expectEqualStrings("foo", foo.name);
    try testing.expectEqualStrings("foo", foo.relative_path);
    try testing.expect(foo.parent == tree.root);

    const bar = foo.get("bar.txt").?;
    try testing.expectEqualStrings("bar contents", bar.element.?);
    try testing.expectEqualStrings("foo/bar.txt", bar.relative_path);
    try testing.expectEqualStrings("/foo/bar.txt", bar.path);

    _ = try tree.add("/hello.txt", "hello contents");
    try testing.expectEqual(@as(usize, 2), tree.root.childrenCount());
    try testing.expectEqualStrings("hello contents", tree.root.get("hello.txt").?.element.?);

    try testing.expectEqualStrings("bar contents", (try tree.delete("/foo/bar.txt")).?);
    try testing.expectEqual(@as(usize, 1), tree.root.childrenCount());
    try testing.expectEqualStrings("hello contents", tree.root.get("hello.txt").?.element.?);
}

test "ResourceTree: folders with data" {
    const allocator = testing.allocator;
    var tree = try ResourceTree([]const u8, void).init(allocator, {}, "/");
    defer tree.deinit();

    _ = try tree.add("/foo", "foo");
    try testing.expectEqual(@as(usize, 1), tree.root.childrenCount());
    try testing.expectEqualStrings("foo", tree.root.get("foo").?.element.?);

    _ = try tree.add("/bar", "bar");
    try testing.expectEqual(@as(usize, 2), tree.root.childrenCount());
    try testing.expectEqualStrings("bar", tree.root.get("bar").?.element.?);

    _ = try tree.add("/foo/file.txt", "file");
    try testing.expectEqual(@as(usize, 2), tree.root.childrenCount());
    try testing.expectEqualStrings("foo", tree.root.get("foo").?.element.?);
    try testing.expectEqualStrings("bar", tree.root.get("bar").?.element.?);
    try testing.expectEqualStrings("file", tree.root.get("foo").?.get("file.txt").?.element.?);

    try testing.expectEqualStrings("foo", (try tree.delete("/foo")).?);
    try testing.expectEqual(@as(usize, 1), tree.root.childrenCount());
    try testing.expect(tree.root.get("foo") == null);
    try testing.expectEqualStrings("bar", tree.root.get("bar").?.element.?);

    try testing.expectEqualStrings("bar", (try tree.delete("/bar")).?);
    try testing.expectEqual(@as(usize, 0), tree.root.childrenCount());
    try testing.expect(tree.root.get("foo") == null);
    try testing.expect(tree.root.get("bar") == null);
}

test "ResourceTree: insertion order, root-relative paths and collect" {
    const allocator = testing.allocator;
    var context: u32 = 7;
    var tree = try ResourceTree(u32, *u32).init(allocator, &context, "/repo");
    defer tree.deinit();

    _ = try tree.add("/repo/b/second.zig", 2);
    _ = try tree.add("/repo/a.zig", 1);
    _ = try tree.add("src/first.zig", 0);
    _ = try tree.add("/repo/b/first.zig", 3);

    const root = tree.root;
    try testing.expectEqual(@as(usize, 3), root.childrenCount());
    try testing.expectEqualStrings("b", root.childNodes()[0].name);
    try testing.expectEqualStrings("a.zig", root.childNodes()[1].name);
    try testing.expectEqualStrings("src", root.childNodes()[2].name);
    try testing.expectEqual(@as(u32, 7), root.childNodes()[0].context.*);

    const collected = try tree.collect(root);
    defer allocator.free(collected);
    try testing.expectEqualSlices(u32, &.{ 2, 3, 1, 0 }, collected);

    const node = tree.getNode("/repo/b/first.zig").?;
    try testing.expectEqual(@as(u32, 3), node.element.?);
    try testing.expectEqualStrings("first.zig", node.name);
    try testing.expect(ResourceTree(u32, *u32).getRoot(node) == root);
}

test "ResourceTree: trailing separators do not create leaf elements early" {
    const allocator = testing.allocator;
    var tree = try ResourceTree([]const u8, void).init(allocator, {}, "/");
    defer tree.deinit();

    const folder = try tree.add("/foo/", "folder");
    try testing.expectEqualStrings("folder", folder.element.?);
    try testing.expectEqualStrings("foo", folder.relative_path);
    try testing.expect(folder.get("") == null);
}

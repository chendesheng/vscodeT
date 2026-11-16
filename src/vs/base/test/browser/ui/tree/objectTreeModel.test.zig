// Port of the core setChildren/collapse/lookup cases of
// `src/vs/base/test/browser/ui/tree/objectTreeModel.test.ts`.

const std = @import("std");
const testing = std.testing;
const object_tree = @import("../../../../browser/ui/tree/objectTreeModel.zig");
const ObjectTreeModel = object_tree.ObjectTreeModel(i32);
const Element = object_tree.ObjectTreeElement(i32);

fn collect(model: *ObjectTreeModel, allocator: std.mem.Allocator) ![]*ObjectTreeModel.Node {
    var list = std.array_list.Managed(*ObjectTreeModel.Node).init(allocator);
    errdefer list.deinit();
    try model.collectRendered(&list);
    return list.toOwnedSlice();
}

test "ObjectTreeModel: setChildren and lookups" {
    const allocator = testing.allocator;
    var model = try ObjectTreeModel.init(allocator, "test", false);
    defer model.deinit();

    try model.setChildren(null, &.{
        .{ .element = 0 },
        .{ .element = 1 },
        .{ .element = 2 },
    });
    try testing.expectEqual(@as(usize, 3), model.size());
    try testing.expect(model.has(1));
    try testing.expectEqual(@as(?usize, 1), try model.getListIndex(1));

    const node = try model.getNode(1);
    try testing.expectEqual(@as(?i32, 1), node.element.?);
    try testing.expectEqual(@as(usize, 1), node.depth);

    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 3), rendered.len);
    try testing.expectEqual(@as(i32, 2), rendered[2].element.?);
}

test "ObjectTreeModel: nested children and replace" {
    const allocator = testing.allocator;
    var model = try ObjectTreeModel.init(allocator, "test", false);
    defer model.deinit();

    const nested = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
    };
    try model.setChildren(null, &.{
        .{ .element = 0, .children = &nested },
        .{ .element = 1 },
    });
    try testing.expectEqual(@as(usize, 4), model.size());

    var rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 4), rendered.len);
    try testing.expectEqual(@as(i32, 10), rendered[1].element.?);

    try model.setChildren(1, &.{.{ .element = 20 }});
    try testing.expectEqual(@as(usize, 5), model.size());
    allocator.free(rendered);
    rendered = try collect(&model, allocator);
    try testing.expectEqual(@as(usize, 5), rendered.len);
    try testing.expectEqual(@as(i32, 20), rendered[4].element.?);
}

test "ObjectTreeModel: collapse and preserve state across setChildren" {
    const allocator = testing.allocator;
    var model = try ObjectTreeModel.init(allocator, "test", false);
    defer model.deinit();

    const nested = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
    };
    const children = [_]Element{
        .{ .element = 0, .children = &nested },
        .{ .element = 1 },
    };
    try model.setChildren(null, &children);
    try testing.expect(try model.setCollapsed(0, true, false));
    try testing.expect(model.isCollapsed(0));

    // Replacing the children of the root preserves the existing collapse state.
    try model.setChildren(null, &children);
    try testing.expect(model.isCollapsed(0));
    const collapsed_rows = try collect(&model, allocator);
    defer allocator.free(collapsed_rows);
    try testing.expectEqual(@as(usize, 2), collapsed_rows.len);

    _ = try model.setCollapsed(0, false, false);
    const expanded_rows = try collect(&model, allocator);
    defer allocator.free(expanded_rows);
    try testing.expectEqual(@as(usize, 4), expanded_rows.len);
}

test "ObjectTreeModel: collapsible and expandTo" {
    const allocator = testing.allocator;
    var model = try ObjectTreeModel.init(allocator, "test", false);
    defer model.deinit();

    try model.setChildren(null, &.{.{ .element = 0 }});
    try testing.expect(!model.isCollapsible(0));
    try testing.expect(try model.setCollapsible(0, true));
    try testing.expect(model.isCollapsible(0));
    try model.expandTo(0);
    try testing.expect(!model.isCollapsed(0));
}

test "ObjectTreeModel: collapseByDefault" {
    const allocator = testing.allocator;
    var model = try ObjectTreeModel.init(allocator, "test", true);
    defer model.deinit();

    const nested = [_]Element{.{ .element = 2 }};
    try model.setChildren(null, &.{.{ .element = 1, .children = &nested }});
    try testing.expect(model.isCollapsed(1));
    const rendered = try collect(&model, allocator);
    defer allocator.free(rendered);
    try testing.expectEqual(@as(usize, 1), rendered.len);
}

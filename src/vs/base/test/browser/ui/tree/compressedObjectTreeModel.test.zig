// Port of the compress/decompress cases of
// `src/vs/base/test/browser/ui/tree/compressedObjectTreeModel.test.ts`.

const std = @import("std");
const testing = std.testing;
const compressed = @import("../../../../browser/ui/tree/compressedObjectTreeModel.zig");
const Element = compressed.CompressedTreeElement(i32);
const CompressedNode = compressed.CompressedTreeNode(i32);
const CompressedElement = compressed.CompressedTreeElement(CompressedNode);

fn expectElements(expected: []const i32, actual: []const i32) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqual(want, got);
}

test "CompressedObjectTreeModel: compress small" {
    const allocator = testing.allocator;
    const input = Element{ .element = 1 };
    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    try expectElements(&.{1}, output.element.elements);
    try testing.expectEqual(@as(usize, 0), output.children.len);
}

test "CompressedObjectTreeModel: compress single hierarchy" {
    const allocator = testing.allocator;
    const leaf = Element{ .element = 1111 };
    const c3 = [_]Element{leaf};
    const c2 = [_]Element{.{ .element = 111, .children = &c3 }};
    const c1 = [_]Element{.{ .element = 11, .children = &c2 }};
    const input = Element{ .element = 1, .children = &c1 };

    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    try expectElements(&.{ 1, 11, 111, 1111 }, output.element.elements);
    try testing.expectEqual(@as(usize, 0), output.children.len);
}

test "CompressedObjectTreeModel: no compression" {
    const allocator = testing.allocator;
    const children = [_]Element{
        .{ .element = 11 },
        .{ .element = 12 },
        .{ .element = 13 },
    };
    const input = Element{ .element = 1, .children = &children };
    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    try expectElements(&.{1}, output.element.elements);
    try testing.expectEqual(@as(usize, 3), output.children.len);
    try expectElements(&.{11}, output.children[0].element.elements);
    try expectElements(&.{13}, output.children[2].element.elements);
}

test "CompressedObjectTreeModel: compress/decompress roundtrip" {
    const allocator = testing.allocator;
    const leaf = Element{ .element = 1111 };
    const c3 = [_]Element{leaf};
    const c2 = [_]Element{.{ .element = 111, .children = &c3 }};
    const c1 = [_]Element{.{ .element = 11, .children = &c2 }};
    const input = Element{ .element = 1, .children = &c1 };

    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    const restored = try compressed.decompress(i32, allocator, output);
    defer compressed.freeDecompressed(i32, allocator, restored);

    try testing.expectEqual(@as(i32, 1), restored.element);
    try testing.expectEqual(@as(usize, 1), restored.children.len);
    try testing.expectEqual(@as(i32, 11), restored.children[0].element);
    try testing.expectEqual(@as(usize, 1), restored.children[0].children.len);
    try testing.expectEqual(@as(i32, 111), restored.children[0].children[0].element);
    try testing.expectEqual(@as(i32, 1111), restored.children[0].children[0].children[0].element);
}

test "CompressedObjectTreeModel: decompress a compressed branch" {
    const allocator = testing.allocator;
    const elements = [_]i32{ 1, 11 };
    const input = CompressedElement{
        .element = .{ .elements = &elements },
    };
    const restored = try compressed.decompress(i32, allocator, input);
    defer compressed.freeDecompressed(i32, allocator, restored);
    try testing.expectEqual(@as(i32, 1), restored.element);
    try testing.expectEqual(@as(usize, 1), restored.children.len);
    try testing.expectEqual(@as(i32, 11), restored.children[0].element);
}

test "CompressedObjectTreeModel: incompressible leaf" {
    const allocator = testing.allocator;
    const leaf = [_]Element{.{ .element = 1111, .incompressible = true }};
    const c111 = [_]Element{.{ .element = 111, .children = &leaf }};
    const c11 = [_]Element{.{ .element = 11, .children = &c111 }};
    const input = Element{ .element = 1, .children = &c11 };

    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    try expectElements(&.{ 1, 11, 111 }, output.element.elements);
    try testing.expect(!output.element.incompressible);
    try testing.expectEqual(@as(usize, 1), output.children.len);
    try expectElements(&.{1111}, output.children[0].element.elements);
    try testing.expect(output.children[0].element.incompressible);

    const restored = try compressed.decompress(i32, allocator, output);
    defer compressed.freeDecompressed(i32, allocator, restored);
    try testing.expectEqual(@as(i32, 1), restored.element);
    try testing.expectEqual(@as(i32, 11), restored.children[0].element);
    try testing.expectEqual(@as(i32, 111), restored.children[0].children[0].element);
    try testing.expect(restored.children[0].children[0].children[0].incompressible);
}

test "CompressedObjectTreeModel: incompressible branch" {
    const allocator = testing.allocator;
    const leaf = [_]Element{.{ .element = 1111 }};
    const c111 = [_]Element{.{ .element = 111, .incompressible = true, .children = &leaf }};
    const c11 = [_]Element{.{ .element = 11, .children = &c111 }};
    const input = Element{ .element = 1, .children = &c11 };

    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    try expectElements(&.{ 1, 11 }, output.element.elements);
    try testing.expectEqual(@as(usize, 1), output.children.len);
    try expectElements(&.{ 111, 1111 }, output.children[0].element.elements);
    try testing.expect(output.children[0].element.incompressible);
}

test "CompressedObjectTreeModel: incompressible chain" {
    const allocator = testing.allocator;
    const leaf = [_]Element{.{ .element = 1111, .incompressible = true }};
    const c111 = [_]Element{.{ .element = 111, .incompressible = true, .children = &leaf }};
    const c11 = [_]Element{.{ .element = 11, .children = &c111 }};
    const input = Element{ .element = 1, .children = &c11 };

    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    try expectElements(&.{ 1, 11 }, output.element.elements);
    try testing.expectEqual(@as(usize, 1), output.children.len);
    try expectElements(&.{111}, output.children[0].element.elements);
    try testing.expect(output.children[0].element.incompressible);
    try testing.expectEqual(@as(usize, 1), output.children[0].children.len);
    try expectElements(&.{1111}, output.children[0].children[0].element.elements);
    try testing.expect(output.children[0].children[0].element.incompressible);
}

test "CompressedObjectTreeModel: incompressible tree" {
    const allocator = testing.allocator;
    const leaf = [_]Element{.{ .element = 1111, .incompressible = true }};
    const c111 = [_]Element{.{ .element = 111, .incompressible = true, .children = &leaf }};
    const c11 = [_]Element{.{ .element = 11, .incompressible = true, .children = &c111 }};
    const input = Element{ .element = 1, .children = &c11 };

    const output = try compressed.compress(i32, allocator, input);
    defer compressed.freeCompressed(i32, allocator, output);
    try expectElements(&.{1}, output.element.elements);
    try testing.expectEqual(@as(usize, 1), output.children.len);
    try expectElements(&.{11}, output.children[0].element.elements);
    try testing.expect(output.children[0].element.incompressible);
    try expectElements(&.{111}, output.children[0].children[0].element.elements);
    try expectElements(&.{1111}, output.children[0].children[0].children[0].element.elements);
}

const Model = compressed.CompressedObjectTreeModel(i32);

fn collect(model: *Model, allocator: std.mem.Allocator) ![]*Model.ModelNode {
    var list = std.array_list.Managed(*Model.ModelNode).init(allocator);
    errdefer list.deinit();
    try model.collectRendered(&list);
    return list.toOwnedSlice();
}

fn expectRows(expected: []const []const i32, rows: []*Model.ModelNode) !void {
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, row| {
        const elements = row.element.?.elements;
        try testing.expectEqual(want.len, elements.len);
        for (want, elements) |want_element, element| try testing.expectEqual(want_element, element);
    }
}

test "CompressedObjectTreeModel: flat setChildren" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", true);
    defer model.deinit();

    try model.setChildren(null, &.{
        .{ .element = 0 },
        .{ .element = 1 },
        .{ .element = 2 },
    });
    try testing.expectEqual(@as(usize, 3), model.size());
    const rows = try collect(&model, allocator);
    defer allocator.free(rows);
    try expectRows(&.{ &.{0}, &.{1}, &.{2} }, rows);

    try model.setChildren(null, &.{
        .{ .element = 3 },
        .{ .element = 4 },
    });
    try testing.expectEqual(@as(usize, 2), model.size());
    const rows2 = try collect(&model, allocator);
    defer allocator.free(rows2);
    try expectRows(&.{ &.{3}, &.{4} }, rows2);
}

test "CompressedObjectTreeModel: nested setChildren" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", true);
    defer model.deinit();

    const nested = [_]Element{
        .{ .element = 10 },
        .{ .element = 11 },
        .{ .element = 12 },
    };
    try model.setChildren(null, &.{
        .{ .element = 0, .children = &nested },
        .{ .element = 1 },
        .{ .element = 2 },
    });
    try testing.expectEqual(@as(usize, 6), model.size());
    const rows = try collect(&model, allocator);
    defer allocator.free(rows);
    try expectRows(&.{ &.{0}, &.{10}, &.{11}, &.{12}, &.{1}, &.{2} }, rows);

    try model.setChildren(12, &.{
        .{ .element = 120 },
        .{ .element = 121 },
    });
    try testing.expectEqual(@as(usize, 8), model.size());
    const rows2 = try collect(&model, allocator);
    defer allocator.free(rows2);
    try expectRows(&.{ &.{0}, &.{10}, &.{11}, &.{12}, &.{120}, &.{121}, &.{1}, &.{2} }, rows2);

    try model.setChildren(0, &.{});
    const rows3 = try collect(&model, allocator);
    defer allocator.free(rows3);
    try expectRows(&.{ &.{0}, &.{1}, &.{2} }, rows3);
    try testing.expectEqual(@as(usize, 3), model.size());
}

test "CompressedObjectTreeModel: compressed regrouping" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", true);
    defer model.deinit();

    const leaves = [_]Element{
        .{ .element = 1111 },
        .{ .element = 1112 },
        .{ .element = 1113 },
    };
    const c111 = [_]Element{.{ .element = 111, .children = &leaves }};
    const c11 = [_]Element{.{ .element = 11, .children = &c111 }};
    try model.setChildren(null, &.{.{ .element = 1, .children = &c11 }});
    try testing.expectEqual(@as(usize, 6), model.size());

    const rows = try collect(&model, allocator);
    defer allocator.free(rows);
    try expectRows(&.{ &.{ 1, 11, 111 }, &.{1111}, &.{1112}, &.{1113} }, rows);

    try model.setChildren(11, &.{
        .{ .element = 111 },
        .{ .element = 112 },
        .{ .element = 113 },
    });
    try testing.expectEqual(@as(usize, 5), model.size());
    const rows2 = try collect(&model, allocator);
    defer allocator.free(rows2);
    try expectRows(&.{ &.{ 1, 11 }, &.{111}, &.{112}, &.{113} }, rows2);

    try model.setChildren(113, &.{.{ .element = 1131 }});
    const rows3 = try collect(&model, allocator);
    defer allocator.free(rows3);
    try expectRows(&.{ &.{ 1, 11 }, &.{111}, &.{112}, &.{ 113, 1131 } }, rows3);
    try testing.expectEqual(@as(usize, 6), model.size());

    try model.setChildren(1131, &.{
        .{ .element = 1132 },
        .{ .element = 1133 },
    });
    const rows4 = try collect(&model, allocator);
    defer allocator.free(rows4);
    try expectRows(&.{ &.{ 1, 11 }, &.{111}, &.{112}, &.{ 113, 1131 }, &.{1132}, &.{1133} }, rows4);
    try testing.expectEqual(@as(usize, 8), model.size());
}

test "CompressedObjectTreeModel: model keeps incompressible groups" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", true);
    defer model.deinit();

    const leaf = [_]Element{.{ .element = 1111, .incompressible = true }};
    const c111 = [_]Element{.{ .element = 111, .children = &leaf }};
    const c11 = [_]Element{.{ .element = 11, .children = &c111 }};
    try model.setChildren(null, &.{.{ .element = 1, .children = &c11 }});

    const rows = try collect(&model, allocator);
    defer allocator.free(rows);
    try expectRows(&.{ &.{ 1, 11, 111 }, &.{1111} }, rows);
    try testing.expect(!rows[0].element.?.incompressible);
    try testing.expect(rows[1].element.?.incompressible);
}

test "CompressedObjectTreeModel: collapse state survives child updates" {
    const allocator = testing.allocator;
    var model = try Model.init(allocator, "test", true);
    defer model.deinit();

    const leaf = [_]Element{.{ .element = 1111, .incompressible = true }};
    const c111 = [_]Element{.{ .element = 111, .children = &leaf }};
    const c11 = [_]Element{.{ .element = 11, .children = &c111 }};
    try model.setChildren(null, &.{.{ .element = 1, .children = &c11 }});
    try testing.expect(!model.isCollapsed(1));

    _ = try model.setCollapsed(1, true, false);
    try testing.expect(model.isCollapsed(1));

    try model.setChildren(111, &.{.{ .element = 1112, .incompressible = true }});
    try testing.expect(model.isCollapsed(1));
    const rows = try collect(&model, allocator);
    defer allocator.free(rows);
    try expectRows(&.{&.{ 1, 11, 111 }}, rows);

    _ = try model.setCollapsed(1, false, false);
    try testing.expect(!model.isCollapsed(1));
    try model.setChildren(111, &.{
        .{ .element = 1112, .incompressible = true },
        .{ .element = 1113, .incompressible = true },
    });
    try testing.expect(!model.isCollapsed(1));
    const expanded_rows = try collect(&model, allocator);
    defer allocator.free(expanded_rows);
    try expectRows(&.{ &.{ 1, 11, 111 }, &.{1112}, &.{1113} }, expanded_rows);

    try model.setCompressionEnabled(false);
    const flat = try collect(&model, allocator);
    defer allocator.free(flat);
    try expectRows(&.{ &.{1}, &.{11}, &.{111}, &.{1112}, &.{1113} }, flat);

    try model.setCompressionEnabled(true);
    const recompressed = try collect(&model, allocator);
    defer allocator.free(recompressed);
    try expectRows(&.{ &.{ 1, 11, 111 }, &.{1112}, &.{1113} }, recompressed);
}

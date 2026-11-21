// Port of the core ObjectTree view cases of
// `src/vs/base/test/browser/ui/tree/objectTree.test.ts`.

const std = @import("std");
const testing = std.testing;
const ui = @import("ui");
const list = @import("../../../../browser/ui/list/list.zig");
const object_tree = @import("../../../../browser/ui/tree/objectTree.zig");

const Tree = object_tree.ObjectTree(i32);
const Element = object_tree.ObjectTreeElement(i32);

fn renderRow(_: *anyopaque, row: *const list.Row, node: *const Tree.Model.Node) void {
    const element = node.element orelse return;
    const glyph: u21 = @intCast('0' + @as(u8, @intCast(element)));
    row.grid.putCodepoint(row.x, row.y, glyph, 1, .{});
}

test "ObjectTree: setChildren renders through AbstractTree" {
    const allocator = testing.allocator;
    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, "test", .{
        .context = @ptrCast(&context),
        .render = renderRow,
    }, false);
    defer tree.deinit();

    const nested = [_]Element{.{ .element = 2 }};
    try tree.setChildren(null, &.{
        .{ .element = 0 },
        .{ .element = 1, .children = &nested },
    });
    try testing.expectEqual(@as(usize, 3), tree.count());
    try testing.expect(tree.hasElement(1));

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    try testing.expectEqual(@as(u32, '0'), grid.cluster[grid.index(0, 0)]);
    try testing.expectEqual(@as(u32, '1'), grid.cluster[grid.index(0, 1)]);
    try testing.expectEqual(@as(u32, '2'), grid.cluster[grid.index(0, 2)]);

    try testing.expect(try tree.setCollapsed(1, true, false));
    try testing.expectEqual(@as(usize, 2), tree.count());
}

// Port of the `CompressibleObjectTree` cases of
// `src/vs/base/test/browser/ui/tree/objectTree.test.ts`.
//
// Terminal adaptation: rows are asserted from the CellGrid instead of DOM text,
// and upstream `updateOptions({ compressionEnabled })` is `setCompressionEnabled`.

const compressible_tree = @import("../../../../browser/ui/tree/compressibleObjectTree.zig");

const CompressibleTree = compressible_tree.CompressibleObjectTree(i32);
const CompressedElement = CompressibleTree.Element;

fn renderCompressedRow(_: *anyopaque, row: *const list.Row, node: *const CompressibleTree.Node) void {
    const compressed = node.element orelse return;
    var col = row.x;
    for (compressed.elements, 0..) |element, index| {
        if (index > 0) {
            row.grid.putCodepoint(col, row.y, '/', 1, .{});
            col += 1;
        }
        var buffer: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{element}) catch return;
        for (text) |ch| {
            row.grid.putCodepoint(col, row.y, @intCast(ch), 1, .{});
            col += 1;
        }
    }
}

fn initCompressibleTree(allocator: std.mem.Allocator, enabled: bool) !*CompressibleTree {
    var context: u8 = 0;
    _ = &context;
    return CompressibleTree.init(allocator, "test", enabled, .{
        .context = @ptrCast(&context),
        .render = renderCompressedRow,
    }, .{});
}

fn expectCompressedRows(
    allocator: std.mem.Allocator,
    tree: *CompressibleTree,
    expected: []const []const u8,
) !void {
    try testing.expectEqual(expected.len, tree.count());
    if (expected.len == 0) return;

    var grid = try ui.CellGrid.init(allocator, 24, expected.len);
    defer grid.deinit();
    tree.render(&grid, .{
        .x = 0,
        .y = 0,
        .w = 24,
        .h = @floatFromInt(expected.len),
    });
    for (expected, 0..) |want, y| {
        const text = try grid.rowText(allocator, y);
        defer allocator.free(text);
        try testing.expectEqualStrings(want, std.mem.trimEnd(u8, text, " "));
    }
}

test "CompressibleObjectTree: empty" {
    const allocator = testing.allocator;
    const tree = try initCompressibleTree(allocator, true);
    defer tree.deinit();

    try expectCompressedRows(allocator, tree, &.{});
}

test "CompressibleObjectTree: simple" {
    const allocator = testing.allocator;
    const tree = try initCompressibleTree(allocator, true);
    defer tree.deinit();

    const nested = [_]CompressedElement{
        .{ .element = 10 },
        .{ .element = 11 },
        .{ .element = 12 },
    };
    try tree.setChildren(null, &.{
        .{ .element = 0, .children = &nested },
        .{ .element = 1 },
        .{ .element = 2 },
    });

    try expectCompressedRows(allocator, tree, &.{ "0", "10", "11", "12", "1", "2" });
}

test "CompressibleObjectTree: compressed" {
    const allocator = testing.allocator;
    const tree = try initCompressibleTree(allocator, true);
    defer tree.deinit();

    const leaves = [_]CompressedElement{
        .{ .element = 1111 },
        .{ .element = 1112 },
        .{ .element = 1113 },
    };
    const c111 = [_]CompressedElement{.{ .element = 111, .children = &leaves }};
    const c11 = [_]CompressedElement{.{ .element = 11, .children = &c111 }};
    try tree.setChildren(null, &.{.{ .element = 1, .children = &c11 }});

    try expectCompressedRows(allocator, tree, &.{ "1/11/111", "1111", "1112", "1113" });

    // Selection resolves to the last element of the compressed group.
    tree.setSelectionElement(11);
    try testing.expectEqual(@as(i32, 111), tree.selectionElement().?);

    try tree.setChildren(11, &.{
        .{ .element = 111 },
        .{ .element = 112 },
        .{ .element = 113 },
    });
    try expectCompressedRows(allocator, tree, &.{ "1/11", "111", "112", "113" });

    try tree.setChildren(113, &.{.{ .element = 1131 }});
    try expectCompressedRows(allocator, tree, &.{ "1/11", "111", "112", "113/1131" });

    try tree.setChildren(1131, &.{.{ .element = 1132 }});
    try expectCompressedRows(allocator, tree, &.{ "1/11", "111", "112", "113/1131/1132" });

    try tree.setChildren(1131, &.{
        .{ .element = 1132 },
        .{ .element = 1133 },
    });
    try expectCompressedRows(allocator, tree, &.{ "1/11", "111", "112", "113/1131", "1132", "1133" });
}

test "CompressibleObjectTree: enableCompression" {
    const allocator = testing.allocator;
    const tree = try initCompressibleTree(allocator, true);
    defer tree.deinit();

    const leaves = [_]CompressedElement{
        .{ .element = 1111 },
        .{ .element = 1112 },
        .{ .element = 1113 },
    };
    const c111 = [_]CompressedElement{.{ .element = 111, .children = &leaves }};
    const c11 = [_]CompressedElement{.{ .element = 11, .children = &c111 }};
    try tree.setChildren(null, &.{.{ .element = 1, .children = &c11 }});

    try expectCompressedRows(allocator, tree, &.{ "1/11/111", "1111", "1112", "1113" });

    try tree.setCompressionEnabled(false);
    try expectCompressedRows(allocator, tree, &.{ "1", "11", "111", "1111", "1112", "1113" });

    try tree.setCompressionEnabled(true);
    try expectCompressedRows(allocator, tree, &.{ "1/11/111", "1111", "1112", "1113" });
}

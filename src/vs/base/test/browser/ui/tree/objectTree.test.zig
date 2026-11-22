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
    }, false, .{});
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

// Ports of the sticky-scroll cases of
// `src/vs/base/test/browser/ui/tree/objectTree.test.ts`.
//
// Terminal adaptation: row heights are whole cells, so a sticky node is one
// row and the widget is asserted from the `CellGrid` rather than from DOM
// elements. The sticky renderer marks its rows with `S` in column 2.

const abstract_tree = @import("../../../../browser/ui/tree/abstractTree.zig");

fn renderStickyAwareRow(_: *anyopaque, row: *const list.Row, node: *const Tree.Model.Node) void {
    const element = node.element orelse return;
    const glyph: u21 = @intCast('0' + @as(u8, @intCast(element)));
    row.grid.putCodepoint(row.x, row.y, glyph, 1, .{});
    if (row.sticky) row.grid.putCodepoint(row.x + 2, row.y, 'S', 1, .{});
}

fn initStickyTree(
    allocator: std.mem.Allocator,
    options: abstract_tree.Options,
) !*Tree {
    var context: u8 = 0;
    _ = &context;
    return Tree.init(allocator, "test", .{
        .context = @ptrCast(&context),
        .render = renderStickyAwareRow,
    }, false, options);
}

fn renderTreeRows(tree: *Tree, grid: *ui.CellGrid, height: usize) void {
    tree.render(grid, .{ .x = 0, .y = 0, .w = 10, .h = @floatFromInt(height) });
}

fn expectRowStartsWith(grid: *const ui.CellGrid, allocator: std.mem.Allocator, y: usize, want: []const u8) !void {
    const text = try grid.rowText(allocator, y);
    defer allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, want));
}

test "ObjectTree: shows the default sticky node after its source row starts scrolling out" {
    const allocator = testing.allocator;
    const tree = try initStickyTree(allocator, .{
        .enable_sticky_scroll = true,
        .sticky_scroll_max_item_count = 1,
    });
    defer tree.deinit();

    const children = [_]Element{
        .{ .element = 1 },
        .{ .element = 2 },
        .{ .element = 3 },
        .{ .element = 4 },
        .{ .element = 5 },
        .{ .element = 6 },
    };
    try tree.setChildren(null, &.{.{ .element = 0, .children = &children }});

    var grid = try ui.CellGrid.init(allocator, 10, 5);
    defer grid.deinit();

    renderTreeRows(tree, &grid, 5);
    try testing.expectEqual(@as(usize, 0), tree.view.stickyScrollNodes().len);
    try expectRowStartsWith(&grid, allocator, 0, "0");

    tree.view.widget.view.setScrollTop(1);
    renderTreeRows(tree, &grid, 5);
    try testing.expectEqual(@as(usize, 1), tree.view.stickyScrollNodes().len);
    const sticky = tree.view.stickyScrollNodes()[0];
    try testing.expectEqual(@as(f64, 0), sticky.position);
    try testing.expectEqual(@as(f64, 1), sticky.height);
    // Row 0 is the sticky copy of element 0; the list row it covers (element
    // 1) is hidden underneath it.
    try expectRowStartsWith(&grid, allocator, 0, "0");
    try testing.expectEqual(@as(u32, 'S'), grid.cluster[grid.index(2, 0)]);
    try expectRowStartsWith(&grid, allocator, 1, "2");
    try testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(2, 1)]);
}

test "ObjectTree: evaluates a custom sticky source range once per scroll update" {
    const Calls = struct {
        count: usize = 0,
        last_element: i32 = -1,
        last_default_start: f64 = -1,
        last_default_end: f64 = -1,

        fn get(context: *anyopaque, element: *const anyopaque, default_range: abstract_tree.StickyScrollNodeSourceRange) ?abstract_tree.StickyScrollNodeSourceRange {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.last_element = @as(*const i32, @ptrCast(@alignCast(element))).*;
            self.last_default_start = default_range.start;
            self.last_default_end = default_range.end;
            return .{ .start = 1, .end = 2 };
        }
    };

    const allocator = testing.allocator;
    var calls = Calls{};
    var context: u8 = 0;
    _ = &context;
    const tree = try Tree.init(allocator, "test", .{
        .context = @ptrCast(&context),
        .render = renderStickyAwareRow,
    }, false, .{
        .enable_sticky_scroll = true,
        .sticky_scroll_max_item_count = 1,
        .sticky_scroll_node_source_range_provider = .{
            .context = @ptrCast(&calls),
            .get = Calls.get,
        },
    });
    defer tree.deinit();

    const children = [_]Element{
        .{ .element = 1 },
        .{ .element = 2 },
        .{ .element = 3 },
        .{ .element = 4 },
        .{ .element = 5 },
        .{ .element = 6 },
    };
    try tree.setChildren(null, &.{.{ .element = 0, .children = &children }});

    var grid = try ui.CellGrid.init(allocator, 10, 5);
    defer grid.deinit();

    tree.view.widget.view.setScrollTop(1);
    renderTreeRows(tree, &grid, 5);
    try testing.expectEqual(@as(usize, 0), tree.view.stickyScrollNodes().len);

    tree.view.widget.view.setScrollTop(2);
    renderTreeRows(tree, &grid, 5);
    try testing.expectEqual(@as(usize, 1), tree.view.stickyScrollNodes().len);
    try testing.expectEqual(@as(usize, 2), calls.count);
    try testing.expectEqual(@as(i32, 0), calls.last_element);
    try testing.expectEqual(@as(f64, 0), calls.last_default_start);
    try testing.expectEqual(@as(f64, 1), calls.last_default_end);
    try expectRowStartsWith(&grid, allocator, 0, "0");
}

test "ObjectTree: sticky selection reveal reserves the sticky widget rows" {
    const allocator = testing.allocator;
    const tree = try initStickyTree(allocator, .{
        .enable_sticky_scroll = true,
    });
    defer tree.deinit();

    const children = [_]Element{
        .{ .element = 1 },
        .{ .element = 2 },
        .{ .element = 3 },
        .{ .element = 4 },
        .{ .element = 5 },
        .{ .element = 6 },
    };
    try tree.setChildren(null, &.{.{ .element = 0, .children = &children }});

    var grid = try ui.CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    tree.view.widget.view.setScrollTop(4);
    renderTreeRows(tree, &grid, 3);
    try testing.expectEqual(@as(usize, 1), tree.view.stickyScrollNodes().len);

    // Selecting element 2 scrolls it under the row-0 sticky widget when the
    // padding is ignored; with the widget height reserved it lands on row 1.
    tree.view.setSelectionNode(try tree.model.getNode(2));
    try testing.expectEqual(@as(f64, 1), tree.view.widget.view.scroll_top);
    renderTreeRows(tree, &grid, 3);
    try expectRowStartsWith(&grid, allocator, 0, "0");
    try expectRowStartsWith(&grid, allocator, 1, "2");
    try testing.expectEqual(@as(u32, 'S'), grid.cluster[grid.index(2, 0)]);
    try testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(2, 1)]);
}

test "ObjectTree: sticky widget keyboard focus follows upstream actions" {
    const allocator = testing.allocator;
    const tree = try initStickyTree(allocator, .{
        .enable_sticky_scroll = true,
        .sticky_scroll_max_item_count = 1,
    });
    defer tree.deinit();
    tree.setFocus(true);

    const children = [_]Element{
        .{ .element = 1 },
        .{ .element = 2 },
        .{ .element = 3 },
        .{ .element = 4 },
        .{ .element = 5 },
        .{ .element = 6 },
    };
    try tree.setChildren(null, &.{.{ .element = 0, .children = &children }});

    var grid = try ui.CellGrid.init(allocator, 10, 5);
    defer grid.deinit();
    tree.view.widget.view.setScrollTop(2);
    renderTreeRows(tree, &grid, 5);
    try testing.expectEqual(@as(usize, 1), tree.view.stickyScrollNodes().len);

    // Clicking a sticky row reveals/selects the node in the tree
    // (`handleStickyScrollMouseEvent`), rather than focusing the widget.
    const down = ui.MouseEvent{ .kind = .down, .x = 3, .y = 0, .button = .left };
    try testing.expect(tree.handleMouse(&down));
    try testing.expect(!tree.view.stickyScrollFocused());
    try testing.expectEqual(@as(i32, 0), tree.view.selectedElement().?);
    try testing.expectEqual(@as(f64, 0), tree.view.widget.view.scroll_top);

    // Down from the keyboard-focused widget moves into the first child of the
    // last sticky node.
    tree.view.widget.view.setScrollTop(2);
    renderTreeRows(tree, &grid, 5);
    _ = tree.view.focusStickyScroll();
    var down_key = ui.KeyEvent{ .key = .down };
    try testing.expect(tree.handleKey(&down_key));
    try testing.expect(!tree.view.stickyScrollFocused());
    try testing.expectEqual(@as(i32, 1), tree.view.selectedElement().?);

    // Enter on the sticky folder selects (reveals) it in the tree and returns
    // focus to the list, matching `list.stickyScrollselect`. Moving the focus
    // into the tree scrolled the list back to the top, so re-scroll first.
    tree.view.widget.view.setScrollTop(2);
    renderTreeRows(tree, &grid, 5);
    _ = tree.view.focusStickyScroll();
    var enter = ui.KeyEvent{ .key = .enter };
    try testing.expect(tree.handleKey(&enter));
    try testing.expect(!tree.view.stickyScrollFocused());
    try testing.expectEqual(@as(i32, 0), tree.view.selectedElement().?);

    // Left is `list.stickyScroll.collapse`: reveal then collapse.
    tree.view.widget.view.setScrollTop(2);
    renderTreeRows(tree, &grid, 5);
    _ = tree.view.focusStickyScroll();
    var left = ui.KeyEvent{ .key = .left };
    try testing.expect(tree.handleKey(&left));
    try testing.expect(tree.isCollapsed(0));
    try testing.expectEqual(@as(usize, 0), tree.view.stickyScrollNodes().len);
}

test "CompressibleObjectTree: sticky compression merges overflowing ancestors" {
    const allocator = testing.allocator;
    var context: u8 = 0;
    _ = &context;
    const tree = try CompressibleTree.init(allocator, "test", true, .{
        .context = @ptrCast(&context),
        .render = renderCompressedStickyRow,
    }, .{
        .enable_sticky_scroll = true,
    });
    defer tree.deinit();

    try tree.setChildren(null, &.{
        .{ .element = 1, .children = &.{
            .{ .element = 2, .children = &.{
                .{ .element = 3, .children = &.{
                    .{ .element = 4, .children = &.{
                        .{ .element = 5 },
                        .{ .element = 6 },
                    } },
                } },
                .{ .element = 7 },
            } },
        } },
        .{ .element = 8 },
        .{ .element = 9 },
    });
    var grid = try ui.CellGrid.init(allocator, 24, 5);
    defer grid.deinit();
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 5 });
    try expectRowStartsWith(&grid, allocator, 0, "1/2");
    try expectRowStartsWith(&grid, allocator, 1, "3/4");
    try expectRowStartsWith(&grid, allocator, 2, "5");

    tree.view.widget.view.setScrollTop(2);
    tree.render(&grid, .{ .x = 0, .y = 0, .w = 24, .h = 5 });
    try testing.expectEqual(@as(usize, 2), tree.view.stickyScrollNodes().len);
    try expectRowStartsWith(&grid, allocator, 0, "1/2");
    try expectRowStartsWith(&grid, allocator, 1, "3/4");
    try expectRowStartsWith(&grid, allocator, 2, "7");
    try expectRowStartsWith(&grid, allocator, 3, "8");
    try expectRowStartsWith(&grid, allocator, 4, "9");

    // With a one-row sticky limit, the two ancestor rows compress into one
    // `1/2/3/4` row, like `CompressibleStickyScrollDelegate`.
    const compressed = try CompressibleTree.init(allocator, "test", true, .{
        .context = @ptrCast(&context),
        .render = renderCompressedStickyRow,
    }, .{
        .enable_sticky_scroll = true,
        .sticky_scroll_max_item_count = 1,
    });
    defer compressed.deinit();
    try compressed.setChildren(null, &.{
        .{ .element = 1, .children = &.{
            .{ .element = 2, .children = &.{
                .{ .element = 3, .children = &.{
                    .{ .element = 4, .children = &.{
                        .{ .element = 5 },
                        .{ .element = 6 },
                    } },
                } },
                .{ .element = 7 },
            } },
        } },
        .{ .element = 8 },
        .{ .element = 9 },
    });
    var compressed_grid = try ui.CellGrid.init(allocator, 24, 5);
    defer compressed_grid.deinit();
    compressed.render(&compressed_grid, .{ .x = 0, .y = 0, .w = 24, .h = 5 });
    compressed.view.widget.view.setScrollTop(2);
    compressed.render(&compressed_grid, .{ .x = 0, .y = 0, .w = 24, .h = 5 });
    try testing.expectEqual(@as(usize, 1), compressed.view.stickyScrollNodes().len);
    try expectRowStartsWith(&compressed_grid, allocator, 0, "1/2/3/4");
    try expectRowStartsWith(&compressed_grid, allocator, 1, "6");
    try expectRowStartsWith(&compressed_grid, allocator, 2, "7");
    try expectRowStartsWith(&compressed_grid, allocator, 3, "8");
    try expectRowStartsWith(&compressed_grid, allocator, 4, "9");

    // Selecting element 2 (the compressed `1/2` row) descends into the
    // compressed group; its ancestor row count is used as reveal padding.
    const node = try tree.model.getNode(2);
    try testing.expectEqual(@as(f64, 0), tree.view.nodePositionTopBelowWidget(node));
}

fn renderCompressedStickyRow(_: *anyopaque, row: *const list.Row, node: *const CompressibleTree.Node) void {
    renderCompressedRow(undefined, row, node);
    if (row.sticky) row.grid.putCodepoint(row.x + 12, row.y, 'S', 1, .{});
}

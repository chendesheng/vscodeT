const std = @import("std");
const ui = @import("ui");
const box = ui.box;
const cell = ui.cell;
const cell_border = ui.cell_border;
const dom = ui.dom;
const layout = ui.layout;
const style_mod = ui.style;
const CellGrid = cell.CellGrid;
const Rect = style_mod.Rect;
const paintDocument = ui.paint.paintDocument;
const paintTree = ui.paint.paintTree;
const drawText = ui.paint.drawText;

fn measureCodepoint(cp: u21) u2 {
    return if (cp == 0x4e2d) 2 else 1;
}

test "paint: text and backgrounds" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 8, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = .{ .r = 1, .g = 2, .b = 3 },
    });
    doc.setRoot(root);

    const text = try doc.createText("hi");
    text.setStyle(.{ .color = .{ .r = 10, .g = 20, .b = 30 }, .bold = true });
    _ = try root.appendChild(text);

    var grid = try CellGrid.init(allocator, 8, 2);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    const row = try grid.rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("hi      ", row);
    try std.testing.expectEqual(@as(u32, 'h'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 'i'), grid.cluster[1]);
    try std.testing.expectEqual(cell.packColor(.{ .r = 10, .g = 20, .b = 30 }), grid.fg[0]);
    try std.testing.expectEqual(cell.packColor(.{ .r = 1, .g = 2, .b = 3 }), grid.bg[0]);
    try std.testing.expect((grid.attrs[0] & cell.Attr.bold) != 0);
    try std.testing.expectEqual(cell.packColor(.{ .r = 1, .g = 2, .b = 3 }), grid.bg[7]);
}

test "paint: clipping by a widths box" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 8, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    });
    _ = try root.appendChild(line);

    const text = try doc.createText("abcdef");
    _ = try line.appendChild(text);

    var grid = try CellGrid.init(allocator, 8, 2);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    const row = try grid.rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("abc", row);
    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, 'c'), grid.cluster[3]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[4]);
}

test "paint: wide glyph writes a continuation cell" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{
        .cols = 6,
        .rows = 1,
        .measure_width = measureCodepoint,
    });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const text = try doc.createText("中x");
    _ = try root.appendChild(text);

    var grid = try CellGrid.init(allocator, 6, 1);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    try std.testing.expectEqual(@as(u32, 0x4e2d), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, 'x'), grid.cluster[2]);

    const row = try grid.rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("中x", row);
}

test "paint: drawText clips ASCII runs at negative x and the clip edges" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{
        .cols = 8,
        .rows = 2,
        .measure_width = measureCodepoint,
    });
    defer doc.deinit();
    var grid = try CellGrid.init(allocator, 8, 2);
    defer grid.deinit();

    const red = cell.packColor(.{ .r = 200, .g = 10, .b = 10 });
    const blue = cell.packColor(.{ .r = 10, .g = 10, .b = 200 });
    const full = Rect{ .x = 0, .y = 0, .w = 8, .h = 1 };

    // Negative x keeps the measured width: the first two glyphs are clipped,
    // not collapsed into column zero.
    drawText(&doc, &grid, "abcdef", -2, 0, .{ .fg = red }, false, full);
    try std.testing.expectEqual(@as(u32, 'c'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 'f'), grid.cluster[3]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[4]);
    try std.testing.expectEqual(red, grid.fg[3]);

    // The run is clipped once at both edges of a narrower clip rectangle.
    grid.clear();
    drawText(&doc, &grid, "abcdef", 0, 0, .{}, false, .{ .x = 2, .y = 0, .w = 3, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 'c'), grid.cluster[2]);
    try std.testing.expectEqual(@as(u32, 'd'), grid.cluster[3]);
    try std.testing.expectEqual(@as(u32, 'e'), grid.cluster[4]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[5]);

    // Negative x combined with a clip that starts mid-run.
    grid.clear();
    drawText(&doc, &grid, "abcdef", -3, 0, .{}, false, .{ .x = 1, .y = 0, .w = 3, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 'e'), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, 'f'), grid.cluster[2]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[3]);

    // A wide glyph writes its empty continuation cell; a clip that cuts the
    // pair drops the whole glyph, like the old per-codepoint path.
    grid.clear();
    drawText(&doc, &grid, "中x", 0, 0, .{}, false, full);
    try std.testing.expectEqual(@as(u32, 0x4e2d), grid.cluster[0]);
    try std.testing.expectEqual(@as(usize, 2), grid.widthAt(0, 0));
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[1]);
    try std.testing.expectEqual(@as(usize, 0), grid.widthAt(1, 0));
    try std.testing.expectEqual(@as(u32, 'x'), grid.cluster[2]);
    grid.clear();
    drawText(&doc, &grid, "中x", 0, 0, .{}, false, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[2]);

    // Tabs expand to the next stop and are written as one background-preserving
    // span; a tab that starts before the clip only writes its visible part.
    grid.clear();
    drawText(&doc, &grid, "a\tb", 0, 0, .{}, false, full);
    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[3]);
    try std.testing.expectEqual(@as(u32, 'b'), grid.cluster[4]);
    grid.clear();
    drawText(&doc, &grid, "x\ty", -2, 0, .{}, false, full);
    try std.testing.expectEqual(@as(u32, 'y'), grid.cluster[0]);

    // keep_background reads the destination background before writing, for a
    // whole ASCII run as well.
    grid.clear();
    grid.bg[grid.index(0, 1)] = blue;
    grid.bg[grid.index(1, 1)] = blue;
    const row1_clip = Rect{ .x = 0, .y = 1, .w = 8, .h = 1 };
    drawText(&doc, &grid, "ab", 0, 1, .{ .fg = red, .bg = red }, true, row1_clip);
    try std.testing.expectEqual(blue, grid.bg[grid.index(0, 1)]);
    try std.testing.expectEqual(blue, grid.bg[grid.index(1, 1)]);
    try std.testing.expectEqual(red, grid.fg[grid.index(0, 1)]);
    drawText(&doc, &grid, "cd", 2, 1, .{ .fg = red, .bg = red }, false, row1_clip);
    try std.testing.expectEqual(red, grid.bg[grid.index(2, 1)]);
}

test "paint: border box and box-drawing glyphs" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 9, .rows = 6 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
        .border_color = .{ .r = 200, .g = 200, .b = 200 },
    });
    doc.setRoot(root);

    var grid = try CellGrid.init(allocator, 9, 6);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    // Border box: 3 + 2 padding + 2 border = 7 columns, 1 + 2 + 2 = 5 rows.
    try std.testing.expectEqual(@as(u32, '┌'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, '─'), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, '┐'), grid.cluster[6]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[1 * 9]);
    try std.testing.expectEqual(@as(u32, '└'), grid.cluster[4 * 9]);
    try std.testing.expectEqual(@as(u32, '┘'), grid.cluster[4 * 9 + 6]);
    try std.testing.expectEqual(cell.packColor(.{ .r = 200, .g = 200, .b = 200 }), grid.fg[0]);
}

test "paint: box-drawing borders clip at the snapped boundary" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 3 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 5 },
        .height = .{ .cells = 3 },
        .overflow = .hidden,
    });
    doc.setRoot(root);

    const child = try doc.createElement(.div);
    const child_style: style_mod.Style = .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 7 },
        .height = .{ .cells = 1 },
        .border = style_mod.EdgeDecl.all(1),
        .border_color = .{ .r = 200, .g = 200, .b = 200 },
    };
    child.setStyle(child_style);
    _ = try root.appendChild(child);

    var grid = try CellGrid.init(allocator, 10, 3);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    // The top-left corner is inside the clip; the dashes are cut at x = 7,
    // the exclusive right edge.
    try std.testing.expectEqual(@as(u32, '┌'), grid.cluster[grid.index(2, 0)]);
    try std.testing.expectEqual(@as(u32, '─'), grid.cluster[grid.index(3, 0)]);
    try std.testing.expectEqual(@as(u32, '─'), grid.cluster[grid.index(6, 0)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(7, 0)]);
    try std.testing.expectEqual(@as(u32, '│'), grid.cluster[grid.index(2, 1)]);
    try std.testing.expectEqual(@as(u32, '└'), grid.cluster[grid.index(2, 2)]);
    try std.testing.expectEqual(@as(u32, '─'), grid.cluster[grid.index(6, 2)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(7, 2)]);
    // The right edge at x = 10 is outside the grid and the clip.
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(9, 1)]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(9, 2)]);

    // A box whose left corner sits left of the clip starts with a dash at the
    // clip's inclusive left edge; its corner glyph is dropped.
    child.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = -2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 7 },
        .height = .{ .cells = 1 },
        .border = style_mod.EdgeDecl.all(1),
        .border_color = .{ .r = 200, .g = 200, .b = 200 },
    });
    var clipped = try CellGrid.init(allocator, 10, 3);
    defer clipped.deinit();
    try paintDocument(&doc, &clipped);
    try std.testing.expectEqual(@as(u32, '─'), clipped.cluster[clipped.index(2, 0)]);
    try std.testing.expectEqual(@as(u32, '─'), clipped.cluster[clipped.index(6, 0)]);
    try std.testing.expectEqual(@as(u32, 0), clipped.cluster[clipped.index(7, 0)]);
    try std.testing.expectEqual(@as(u32, 0), clipped.cluster[clipped.index(0, 1)]);
    try std.testing.expectEqual(@as(u32, 0), clipped.cluster[clipped.index(1, 1)]);
    try std.testing.expectEqual(@as(u32, 0), clipped.cluster[clipped.index(2, 1)]);
}

test "paint: cell borders are attributes on the box edge, not glyphs" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 6, .rows = 3 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .border = style_mod.EdgeDecl.all(1),
        .border_color = .{ .r = 200, .g = 100, .b = 50 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("abc"));

    var tree = try box.BoxTree.init(allocator);
    defer tree.deinit();
    tree.cell_borders = true;
    try tree.rebuild(&doc);
    try layout.layoutTree(&tree, &doc);

    var grid = try CellGrid.init(allocator, 6, 3);
    defer grid.deinit();
    paintTree(&tree, &doc, &grid);

    // The border consumes no cells: the 3x1 content box is the whole border box.
    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 'b'), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, 'c'), grid.cluster[2]);

    const corner = grid.borderSetAt(0, 0);
    var mask: u12 = 0;
    for (corner.groups[0..corner.count]) |group| mask |= group.mask;
    try std.testing.expectEqual(cell_border.Segment.top | cell_border.Segment.bottom | cell_border.Segment.left, mask);
    for (corner.groups[0..corner.count]) |group| {
        try std.testing.expect(group.stroke.color.eql(.{ .rgb = .{ .r = 200, .g = 100, .b = 50 } }));
        try std.testing.expectEqual(cell_border.Placement.centered, group.stroke.placement);
    }
}

test "paint: transparent text keeps the background underneath it" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 8, .rows = 2 });
    defer doc.deinit();

    const dark = style_mod.Color{ .r = 1, .g = 2, .b = 3 };
    const panel_fill = style_mod.Color{ .r = 10, .g = 20, .b = 30 };
    const explicit = style_mod.Color{ .r = 40, .g = 50, .b = 60 };

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = dark,
    });
    doc.setRoot(root);

    // The panel is painted first; the labels are later siblings and overlap it
    // without a background of their own, like the layout example.
    _ = try commonBox(&doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 8 },
        .height = .{ .cells = 2 },
        .background = panel_fill,
    });

    const first = try commonBox(&doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
    });
    const plain = try doc.createText("hi");
    plain.setStyle(.{ .color = .{ .r = 255, .g = 255, .b = 255 } });
    _ = try first.appendChild(plain);

    const second = try commonBox(&doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
    });
    const filled = try doc.createText("xx");
    filled.setStyle(.{ .background = explicit });
    _ = try second.appendChild(filled);

    var grid = try CellGrid.init(allocator, 8, 2);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    try std.testing.expectEqual(cell.packColor(panel_fill), grid.bg[0]);
    try std.testing.expectEqual(@as(u32, 'h'), grid.cluster[0]);
    try std.testing.expectEqual(cell.packColor(explicit), grid.bg[grid.index(0, 1)]);
    try std.testing.expectEqual(@as(u32, 'x'), grid.cluster[grid.index(0, 1)]);
}

test "paint: visibility hidden keeps the box but skips its own paint" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 6, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 2 },
        .background = .{ .r = 10, .g = 20, .b = 30 },
    });
    doc.setRoot(root);

    const hidden = try commonBox(&doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .background = .{ .r = 200, .g = 0, .b = 0 },
        .visibility = .hidden,
    });
    _ = try hidden.appendChild(try doc.createText("xx"));

    // A descendant may opt back in, as the CSS property allows.
    const shown = try commonBox(&doc, hidden, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 1 },
        .height = .{ .cells = 1 },
        .visibility = .visible,
    });
    _ = try shown.appendChild(try doc.createText("o"));

    var grid = try CellGrid.init(allocator, 6, 2);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    // The hidden box paints no background and no text of its own. The root's
    // background fills the covered cells with spaces.
    try std.testing.expectEqual(cell.packColor(.{ .r = 10, .g = 20, .b = 30 }), grid.bg[0]);
    try std.testing.expect(grid.cluster[1] != 'x');
    // The explicitly visible child still paints.
    try std.testing.expectEqual(@as(u32, 'o'), grid.cluster[0]);
}

test "paint: ancestor hover visibility reveals a hidden descendant" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 6, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 2 },
    });
    doc.setRoot(root);

    const row = try commonBox(&doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
    });
    row.setHoverStyle(.{ .visibility = .visible });
    const icon = try commonBox(&doc, row, .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 1 },
        .height = .{ .cells = 1 },
        .visibility = .hidden,
    });
    _ = try icon.appendChild(try doc.createText("\u{25BE}"));

    var grid = try CellGrid.init(allocator, 6, 2);
    defer grid.deinit();
    try paintDocument(&doc, &grid);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[0]);

    // The hover declaration wins over the child's own hidden declaration.
    try std.testing.expect(doc.setHoverTarget(row));
    grid.clear();
    try paintDocument(&doc, &grid);
    try std.testing.expectEqual(@as(u32, 0x25BE), grid.cluster[0]);

    try std.testing.expect(doc.clearHover());
    grid.clear();
    try paintDocument(&doc, &grid);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[0]);
}

fn commonBox(doc: *dom.Document, parent: *dom.Node, style: style_mod.Style) !*dom.Node {
    const node = try doc.createElement(.div);
    node.setStyle(style);
    _ = try parent.appendChild(node);
    return node;
}

test "paint: overflow hidden clips text and absolute children to the padding box" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 14, .rows = 5 });
    defer doc.deinit();

    const child_fill = style_mod.Color{ .r = 60, .g = 86, .b = 130 };

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const container = try doc.createElement(.div);
    container.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
        .overflow = .hidden,
    });
    _ = try root.appendChild(container);
    _ = try container.appendChild(try doc.createText("overflowing"));

    const child = try doc.createElement(.div);
    child.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 4 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
        .background = child_fill,
    });
    _ = try container.appendChild(child);
    _ = try child.appendChild(try doc.createText("childtext"));

    var grid = try CellGrid.init(allocator, 14, 5);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    // The text starts in the container's content box at (3, 2), but is cut at
    // the padding edge x=10; the right border at x=10 still paints.
    try std.testing.expectEqual(@as(u32, 'o'), grid.cluster[grid.index(3, 2)]);
    try std.testing.expectEqual(@as(u32, 'o'), grid.cluster[grid.index(9, 2)]);
    try std.testing.expect(grid.cluster[grid.index(11, 2)] == 0);
    // The absolute child starts at (6, 1) and is clipped at the same edge.
    try std.testing.expectEqual(@as(u32, 'c'), grid.cluster[grid.index(6, 1)]);
    try std.testing.expect(grid.cluster[grid.index(10, 1)] != 't');
    try std.testing.expect(grid.cluster[grid.index(11, 1)] == 0);
    // Its background is clipped with it: neither the border cell nor the
    // gutter past the padding edge keeps the child's fill.
    try std.testing.expectEqual(cell.packColor(child_fill), grid.bg[grid.index(6, 1)]);
    try std.testing.expectEqual(cell.packColor(child_fill), grid.bg[grid.index(9, 1)]);
    try std.testing.expectEqual(@as(u32, 0), grid.bg[grid.index(10, 1)]);
    try std.testing.expectEqual(@as(u32, 0), grid.bg[grid.index(11, 1)]);

    // `clip` cuts the same padding box as `hidden`.
    container.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
        .overflow = .clip,
    });
    var clipped = try CellGrid.init(allocator, 14, 5);
    defer clipped.deinit();
    try paintDocument(&doc, &clipped);
    try std.testing.expectEqual(cell.packColor(child_fill), clipped.bg[clipped.index(9, 1)]);
    try std.testing.expectEqual(@as(u32, 0), clipped.bg[clipped.index(10, 1)]);
    try std.testing.expectEqual(@as(u32, 0), clipped.bg[clipped.index(11, 1)]);

    // With overflow visible the child paints past the border and padding.
    container.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
        .overflow = .visible,
    });
    var visible = try CellGrid.init(allocator, 14, 5);
    defer visible.deinit();
    try paintDocument(&doc, &visible);
    try std.testing.expectEqual(@as(u32, 't'), visible.cluster[visible.index(11, 1)]);
    try std.testing.expectEqual(cell.packColor(child_fill), visible.bg[visible.index(11, 1)]);
}

test "paint: flex row items and gaps" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 8, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 8 },
        .height = .{ .cells = 2 },
        .display = .flex,
        .gap = .{ .column = 1 },
    });
    doc.setRoot(root);

    const first = try commonBox(&doc, root, .{
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .background = .{ .r = 10, .g = 20, .b = 30 },
    });
    _ = try first.appendChild(try doc.createText("a"));

    const second = try commonBox(&doc, root, .{
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .background = .{ .r = 40, .g = 50, .b = 60 },
    });
    _ = try second.appendChild(try doc.createText("b"));

    var grid = try CellGrid.init(allocator, 8, 2);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 'b'), grid.cluster[grid.index(4, 0)]);
    try std.testing.expectEqual(cell.packColor(.{ .r = 10, .g = 20, .b = 30 }), grid.bg[0]);
    try std.testing.expectEqual(cell.packColor(.{ .r = 40, .g = 50, .b = 60 }), grid.bg[grid.index(4, 0)]);
    // The one-column gap keeps the root background.
    try std.testing.expectEqual(@as(u32, 0), grid.bg[grid.index(3, 0)]);
}

test "paint: multiple text nodes keep their own positions" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 6, .rows = 1 });
    defer doc.deinit();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
        .white_space = .pre,
    });
    doc.setRoot(root);
    const a = try doc.createText("hi");
    _ = try root.appendChild(a);
    const b = try doc.createText(" ");
    b.setStyle(.{ .reverse = true });
    _ = try root.appendChild(b);
    var grid = try CellGrid.init(allocator, 6, 1);
    defer grid.deinit();
    try paintDocument(&doc, &grid);
    const row = try grid.rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("hi ", row);
}

test "paint: wrapped text paints every line" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 8, .rows = 3 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 8 },
        .height = .{ .cells = 3 },
    });
    doc.setRoot(root);
    const line = try doc.createElement(.div);
    line.setStyle(.{ .width = .{ .cells = 5 } });
    _ = try root.appendChild(line);
    _ = try line.appendChild(try doc.createText("one two three"));

    var grid = try CellGrid.init(allocator, 8, 3);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    const first = try grid.rowText(allocator, 0);
    defer allocator.free(first);
    const second = try grid.rowText(allocator, 1);
    defer allocator.free(second);
    const third = try grid.rowText(allocator, 2);
    defer allocator.free(third);
    try std.testing.expectEqualStrings("one", first);
    try std.testing.expectEqualStrings("two", second);
    try std.testing.expectEqualStrings("three", third);
}

test "paint: inline element background follows each fragment" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("foo "));

    const span = try doc.createElement(.span);
    span.setStyle(.{
        .display = .inline_,
        .background = .{ .r = 40, .g = 50, .b = 60 },
    });
    _ = try root.appendChild(span);
    _ = try span.appendChild(try doc.createText("bar baz"));
    _ = try root.appendChild(try doc.createText(" qux"));

    var grid = try CellGrid.init(allocator, 10, 4);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    const fill = cell.packColor(.{ .r = 40, .g = 50, .b = 60 });
    try std.testing.expectEqual(fill, grid.bg[grid.index(0, 1)]);
    try std.testing.expectEqual(fill, grid.bg[grid.index(0, 2)]);
    try std.testing.expectEqual(@as(u32, 'b'), grid.cluster[grid.index(0, 1)]);
    try std.testing.expectEqual(@as(u32, 'b'), grid.cluster[grid.index(0, 2)]);
}

test "paint: overflow hidden clips wrapped continuation lines" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 6, .rows = 3 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 6 },
        .height = .{ .cells = 3 },
    });
    doc.setRoot(root);
    const line = try doc.createElement(.div);
    line.setStyle(.{
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    });
    _ = try root.appendChild(line);
    _ = try line.appendChild(try doc.createText("one two three"));

    var grid = try CellGrid.init(allocator, 6, 3);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    const first = try grid.rowText(allocator, 0);
    defer allocator.free(first);
    const second = try grid.rowText(allocator, 1);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("one", first);
    try std.testing.expectEqualStrings("", second);
}

test "paint: underline styles reach the cell attributes" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 6, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{ .position = .absolute, .width = .{ .percent = 100 } });
    doc.setRoot(root);
    const text = try doc.createText("abc");
    text.setStyle(.{ .underline = true, .underline_style = .dotted });
    _ = try root.appendChild(text);

    var grid = try CellGrid.init(allocator, 6, 1);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    var col: usize = 0;
    while (col < 3) : (col += 1) {
        const attrs = grid.attrs[grid.index(col, 0)];
        try std.testing.expect((attrs & cell.Attr.underline) != 0);
        try std.testing.expectEqual(ui.style.UnderlineStyle.dotted, cell.underlineStyleOf(attrs));
    }
}

test "paint: class cascade inherits color and an explicit false clears bold" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const Class = enum(u16) { panel, selected };
    _ = try doc.registerSheet(.{ .styles = &.{
        .{ .color = .{ .r = 200, .g = 20, .b = 20 }, .bold = true },
        .{ .background = .{ .r = 0, .g = 0, .b = 100 }, .bold = false },
    } });

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
    });
    try root.setClasses(&.{ Class.panel, Class.selected });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("hi"));

    var grid = try CellGrid.init(allocator, 10, 2);
    defer grid.deinit();
    try paintDocument(&doc, &grid);

    try std.testing.expectEqual(cell.packColor(.{ .r = 200, .g = 20, .b = 20 }), grid.fg[grid.index(0, 0)]);
    try std.testing.expectEqual(cell.packColor(.{ .r = 0, .g = 0, .b = 100 }), grid.bg[grid.index(0, 0)]);
    try std.testing.expect((grid.attrs[grid.index(0, 0)] & cell.Attr.bold) == 0);
}

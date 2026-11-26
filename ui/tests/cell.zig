const std = @import("std");
const ui = @import("ui");
const cell_border = ui.cell_border;
const style = ui.style;
const Attr = ui.cell.Attr;
const PaintStyle = ui.cell.PaintStyle;
const packColor = ui.cell.packColor;
const unpackColor = ui.cell.unpackColor;
const CellGrid = ui.cell.CellGrid;

test "CellGrid drag overlays preserve wide text and clip the image" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 6, 2);
    defer grid.deinit();
    const defaults: PaintStyle = .{
        .fg = packColor(.{ .r = 200, .g = 200, .b = 200 }),
        .bg = packColor(.{ .r = 20, .g = 20, .b = 20 }),
    };
    grid.putCodepoint(1, 0, '界', 2, defaults);
    grid.tintRect(.{ .x = 2, .y = 0, .w = 2, .h = 1 }, .{ .r = 100, .g = 100, .b = 100 }, 0.5, defaults);
    try std.testing.expectEqual(@as(u32, '界'), grid.cluster[grid.index(1, 0)]);
    try std.testing.expectEqual(@as(usize, 2), grid.widthAt(1, 0));
    try std.testing.expectEqual(@as(usize, 0), grid.widthAt(2, 0));
    try std.testing.expectEqual(@as(u8, 60), unpackColor(grid.bg[grid.index(1, 0)]).r);
    try std.testing.expectEqual(grid.bg[grid.index(1, 0)], grid.bg[grid.index(2, 0)]);
    try std.testing.expectEqual(@as(u32, 0), grid.bg[grid.index(0, 0)]);

    var captured = try grid.captureRow(allocator, 1, 0, 2);
    defer captured.deinit();
    try grid.paintImage(&captured, 5, 1);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[grid.index(5, 1)]);
    try std.testing.expectEqual(@as(usize, 1), grid.widthAt(5, 1));
}

test "CellGrid stores wide glyphs and continuation cells" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 4, 1);
    defer grid.deinit();

    grid.putCodepoint(0, 0, 'a', 1, .{});
    grid.putCodepoint(1, 0, '中', 2, .{ .fg = packColor(.{ .r = 1, .g = 2, .b = 3 }) });
    grid.putCodepoint(3, 0, 'b', 1, .{});

    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, '中'), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[2]);
    try std.testing.expectEqual(@as(usize, 2), grid.widthAt(1, 0));
    try std.testing.expectEqual(@as(usize, 0), grid.widthAt(2, 0));

    const text = try grid.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("a中b", text);
}

test "CellGrid clears a vanished cell" {
    const allocator = std.testing.allocator;
    var a = try CellGrid.init(allocator, 3, 1);
    defer a.deinit();
    var b = try CellGrid.init(allocator, 3, 1);
    defer b.deinit();

    a.putCodepoint(0, 0, 'x', 1, .{});
    b.clear();
    try std.testing.expect(!CellGrid.sameCell(&a, 0, &b, 0));
    try std.testing.expectEqual(@as(u32, 0), b.cluster[0]);
}

test "CellGrid keeps cell borders across text and background paints" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 1, 1);
    defer grid.deinit();

    const stroke = cell_border.Stroke{ .color = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } } };
    grid.addBorder(0, 0, cell_border.Segment.left, stroke);
    const id = grid.borderIdAt(0, 0);
    try std.testing.expect(id != 0);

    grid.putCodepoint(0, 0, 'x', 1, .{});
    grid.fillRect(0, 0, 1, 1, .{});
    try std.testing.expectEqual(id, grid.borderIdAt(0, 0));
    try std.testing.expect(grid.borderSetAt(0, 0).eql(grid.borders.get(id).*));

    grid.clear();
    try std.testing.expectEqual(@as(u16, 0), grid.borderIdAt(0, 0));
}

test "CellGrid fillRect resets cells but keeps the border plane" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 6, 2);
    defer grid.deinit();

    // A wide glyph and an untouched neighbour so the fill's full cell contract
    // (glyph, grapheme id, width bits, colors) is observable.
    grid.putCodepoint(1, 0, '中', 2, .{ .bg = packColor(.{ .r = 5, .g = 6, .b = 7 }) });
    try grid.putGrapheme(4, 0, "e\u{301}", 1, .{});
    grid.addBorder(2, 0, cell_border.Segment.top, .{ .width = 16 });
    const border_id = grid.borderIdAt(2, 0);
    try std.testing.expect(border_id != 0);

    const fill: PaintStyle = .{
        .fg = packColor(.{ .r = 10, .g = 20, .b = 30 }),
        .bg = packColor(.{ .r = 40, .g = 50, .b = 60 }),
        .attrs = Attr.bold | Attr.underline,
    };
    grid.fillRect(0, 0, 3, 1, fill);

    for (0..3) |col| {
        const i = grid.index(col, 0);
        try std.testing.expectEqual(@as(u32, ' '), grid.cluster[i]);
        try std.testing.expectEqual(@as(u32, 0), grid.grapheme[i]);
        try std.testing.expectEqual(@as(usize, 1), grid.widthAt(col, 0));
        try std.testing.expectEqual(fill.fg, grid.fg[i]);
        try std.testing.expectEqual(fill.bg, grid.bg[i]);
        try std.testing.expectEqual(Attr.bold | Attr.underline, grid.attrs[i] & Attr.style_mask);
    }
    // The border under the fill and cells past `right` are untouched.
    try std.testing.expectEqual(border_id, grid.borderIdAt(2, 0));
    try std.testing.expectEqual(@as(u32, 'e'), grid.cluster[grid.index(4, 0)]);
    try std.testing.expectEqualStrings("e\u{301}", grid.graphemeAt(4, 0));
    // The second row was outside the fill.
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[grid.index(0, 1)]);
}

test "CellGrid fillRect clips negative x, out-of-range x and preserves snap rounding" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 6, 1);
    defer grid.deinit();

    // Negative origin: snap floors it to 0 and the right edge rounds the sum.
    grid.fillRect(-4, 0, 6.4, 1, .{});
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[2]);

    grid.clear();
    // `left` is not clamped: a rect entirely past the grid must be a no-op
    // instead of an out-of-bounds slice.
    grid.fillRect(10, 0, 2, 1, .{});
    for (0..6) |col| try std.testing.expectEqual(@as(u32, 0), grid.cluster[col]);

    // x = 1.4 snaps to 1, x + w = 3.8 snaps to 4, matching the per-cell loop.
    grid.fillRect(1.4, 0, 2.4, 1, .{});
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[1]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[2]);
    try std.testing.expectEqual(@as(u32, ' '), grid.cluster[3]);
    try std.testing.expectEqual(@as(u32, 0), grid.cluster[4]);
}

test "CellGrid blit remaps border sets into the destination table" {
    const allocator = std.testing.allocator;
    var source = try CellGrid.init(allocator, 1, 1);
    defer source.deinit();
    var dest = try CellGrid.init(allocator, 2, 1);
    defer dest.deinit();

    const stroke = cell_border.Stroke{ .width = 16, .color = .default_fg };
    source.addBorder(0, 0, cell_border.Segment.bottom, stroke);
    try dest.blit(&source, 1, 0, 1, 1);

    try std.testing.expect(dest.borderIdAt(0, 0) == 0);
    const copied = dest.borderSetAt(1, 0);
    try std.testing.expectEqual(@as(u3, 1), copied.count);
    try std.testing.expectEqual(cell_border.Segment.bottom, copied.groups[0].mask);
    try std.testing.expect(dest.borders.get(dest.borderIdAt(1, 0)).eql(source.borders.get(source.borderIdAt(0, 0)).*));
}

test "CellGrid sameCell sees border changes" {
    const allocator = std.testing.allocator;
    var a = try CellGrid.init(allocator, 1, 1);
    defer a.deinit();
    var b = try CellGrid.init(allocator, 1, 1);
    defer b.deinit();

    a.putCodepoint(0, 0, 'x', 1, .{});
    b.putCodepoint(0, 0, 'x', 1, .{});
    try std.testing.expect(CellGrid.sameCell(&a, 0, &b, 0));

    b.addBorder(0, 0, cell_border.Segment.top, .{});
    try std.testing.expect(!CellGrid.sameCell(&a, 0, &b, 0));
}

test "CellGrid clearBordersRect leaves the glyphs alone" {
    const allocator = std.testing.allocator;
    var grid = try CellGrid.init(allocator, 3, 1);
    defer grid.deinit();

    grid.putCodepoint(1, 0, 'x', 1, .{});
    grid.addBorder(0, 0, cell_border.Segment.top, .{});
    grid.addBorder(1, 0, cell_border.Segment.top, .{});
    grid.addBorder(2, 0, cell_border.Segment.top, .{});

    grid.clearBordersRect(0, 0, 2, 1);
    try std.testing.expectEqual(@as(u16, 0), grid.borderIdAt(0, 0));
    try std.testing.expectEqual(@as(u16, 0), grid.borderIdAt(1, 0));
    try std.testing.expect(grid.borderIdAt(2, 0) != 0);
    try std.testing.expectEqual(@as(u32, 'x'), grid.cluster[1]);
}

test "packColor distinguishes black from default" {
    const black = packColor(.{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expect(black != 0);
    try std.testing.expectEqual(@as(u32, 0), 0);
    try std.testing.expect(style.Color.eql(.{ .r = 0, .g = 0, .b = 0 }, unpackColor(black)));
}

test "CellGrid stores and copies multi-codepoint graphemes" {
    const allocator = std.testing.allocator;
    var source = try CellGrid.init(allocator, 4, 1);
    defer source.deinit();
    var dest = try CellGrid.init(allocator, 4, 1);
    defer dest.deinit();

    try source.putGrapheme(0, 0, "e\u{301}", 1, .{});
    try source.putGrapheme(1, 0, "\u{1F469}\u{200D}\u{1F4BB}", 2, .{});
    try std.testing.expectEqualStrings("e\u{301}", source.graphemeAt(0, 0));
    try std.testing.expectEqualStrings("\u{1F469}\u{200D}\u{1F4BB}", source.graphemeAt(1, 0));
    try std.testing.expectEqual(@as(usize, 2), source.widthAt(1, 0));

    try dest.blit(&source, 0, 0, 4, 1);
    try std.testing.expectEqualStrings("e\u{301}", dest.graphemeAt(0, 0));
    try std.testing.expectEqualStrings("\u{1F469}\u{200D}\u{1F4BB}", dest.graphemeAt(1, 0));
    try std.testing.expect(CellGrid.sameCell(&source, 0, &dest, 0));

    const text = try dest.rowText(allocator, 0);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("e\u{301}\u{1F469}\u{200D}\u{1F4BB}", text);
}

test "CellGrid grapheme equality compares the bytes" {
    const allocator = std.testing.allocator;
    var a = try CellGrid.init(allocator, 2, 1);
    defer a.deinit();
    var b = try CellGrid.init(allocator, 2, 1);
    defer b.deinit();

    try a.putGrapheme(0, 0, "e\u{301}", 1, .{});
    try b.putGrapheme(0, 0, "e\u{302}", 1, .{});
    try std.testing.expect(!CellGrid.sameCell(&a, 0, &b, 0));
}

test "CellGrid blitRows clips vertically without changing source coordinates or attributes" {
    const allocator = std.testing.allocator;
    var source = try CellGrid.init(allocator, 3, 4);
    defer source.deinit();
    var dest = try CellGrid.init(allocator, 5, 3);
    defer dest.deinit();
    source.putCodepoint(0, 0, 'a', 1, .{});
    source.putCodepoint(0, 1, 'b', 1, .{});
    try source.putGrapheme(1, 1, "e\u{301}", 1, .{});
    source.addBorder(2, 1, cell_border.Segment.bottom, .{ .width = 16, .color = .default_fg });
    source.putCodepoint(0, 2, 'c', 1, .{});
    source.putCodepoint(0, 3, 'd', 1, .{});
    try dest.blitRows(&source, 1, 1, 1, 3, 3);
    try std.testing.expect(CellGrid.sameCell(&source, source.index(0, 1), &dest, dest.index(1, 1)));
    try std.testing.expect(CellGrid.sameCell(&source, source.index(1, 1), &dest, dest.index(2, 1)));
    try std.testing.expect(CellGrid.sameCell(&source, source.index(2, 1), &dest, dest.index(3, 1)));
    try std.testing.expect(CellGrid.sameCell(&source, source.index(0, 2), &dest, dest.index(1, 2)));
    try std.testing.expectEqual(@as(u32, 0), dest.cluster[dest.index(1, 0)]);
}

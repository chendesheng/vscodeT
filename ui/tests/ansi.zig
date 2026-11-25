const std = @import("std");
const ui = @import("ui");
const cell = ui.cell;
const cell_border = ui.cell_border;
const CellGrid = cell.CellGrid;
const encode = ui.ansi.encode;

test "ansi: first frame, unchanged frame, changed row" {
    const allocator = std.testing.allocator;
    var prev = try CellGrid.init(allocator, 4, 2);
    defer prev.deinit();
    var next = try CellGrid.init(allocator, 4, 2);
    defer next.deinit();

    next.putCodepoint(0, 0, 'a', 1, .{});
    const first = try encode(allocator, null, &next, .{ .synchronized = false });
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[1;1H") != null);

    std.mem.swap(CellGrid, &prev, &next);
    next.clear();
    next.putCodepoint(0, 0, 'a', 1, .{});
    const same = try encode(allocator, &prev, &next, .{ .synchronized = false });
    defer allocator.free(same);
    try std.testing.expectEqual(@as(usize, 0), same.len);

    next.putCodepoint(0, 1, 'b', 1, .{});
    const changed = try encode(allocator, &prev, &next, .{ .synchronized = false });
    defer allocator.free(changed);
    try std.testing.expect(std.mem.indexOf(u8, changed, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, changed, "\x1b[1;1H") == null);
}

test "ansi: a vanished cell erases its row" {
    const allocator = std.testing.allocator;
    var prev = try CellGrid.init(allocator, 4, 1);
    defer prev.deinit();
    var next = try CellGrid.init(allocator, 4, 1);
    defer next.deinit();

    prev.putCodepoint(0, 0, 'x', 1, .{});
    const out = try encode(allocator, &prev, &next, .{ .synchronized = false });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x") == null);
}

test "ansi: cell borders ride the pen on changed cells" {
    const allocator = std.testing.allocator;
    var next = try CellGrid.init(allocator, 3, 1);
    defer next.deinit();

    const blue = cell_border.Stroke{ .width = 64, .color = .{ .rgb = .{ .r = 0x7a, .g = 0xa2, .b = 0xf7 } } };
    next.addBorder(0, 0, cell_border.Segment.top, blue);
    next.putCodepoint(1, 0, 'x', 1, .{ .fg = cell.packColor(.{ .r = 255, .g = 255, .b = 255 }) });
    next.addBorder(2, 0, cell_border.Segment.left, blue);

    const out = try encode(allocator, null, &next, .{ .synchronized = false });
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\x1bP1+bcell-border;pen;3;64;7aa2f7;1;0\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") != null);
    // The border-only cells are written as spaces carrying the pen.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b\\ ") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[0m"));
}

test "ansi: a border change repaints an otherwise identical row" {
    const allocator = std.testing.allocator;
    var prev = try CellGrid.init(allocator, 2, 1);
    defer prev.deinit();
    var next = try CellGrid.init(allocator, 2, 1);
    defer next.deinit();

    prev.putCodepoint(0, 0, 'x', 1, .{});
    next.putCodepoint(0, 0, 'x', 1, .{});
    prev.addBorder(0, 0, cell_border.Segment.top, .{ .color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } } });
    next.addBorder(0, 0, cell_border.Segment.top, .{ .color = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } });

    const out = try encode(allocator, &prev, &next, .{ .synchronized = false });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "040506") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x") != null);
}

test "ansi: unchanged and synchronized empty frames encode zero bytes" {
    const allocator = std.testing.allocator;
    var prev = try CellGrid.init(allocator, 3, 2);
    defer prev.deinit();
    var next = try CellGrid.init(allocator, 3, 2);
    defer next.deinit();

    // Two blank grids: nothing to emit and no synchronized start/end markers.
    const blank = try encode(allocator, &prev, &next, .{ .synchronized = true });
    defer allocator.free(blank);
    try std.testing.expectEqual(@as(usize, 0), blank.len);

    // Same content in both buffers is also zero bytes, even when rows have
    // content: the merged scan reports them unchanged.
    prev.putCodepoint(0, 0, 'a', 1, .{});
    next.putCodepoint(0, 0, 'a', 1, .{});
    prev.putCodepoint(2, 1, 'b', 1, .{});
    next.putCodepoint(2, 1, 'b', 1, .{});
    const unchanged = try encode(allocator, &prev, &next, .{ .synchronized = true });
    defer allocator.free(unchanged);
    try std.testing.expectEqual(@as(usize, 0), unchanged.len);
}

test "ansi: one trailing reset per frame in synchronized output" {
    const allocator = std.testing.allocator;
    var next = try CellGrid.init(allocator, 2, 2);
    defer next.deinit();
    next.putCodepoint(0, 0, 'a', 1, .{});
    next.putCodepoint(0, 1, 'b', 1, .{});

    const out = try encode(allocator, null, &next, .{ .synchronized = true });
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[0m\x1b[?2026l"));
    // Two row prefixes each carry a reset; the frame adds exactly one more and
    // not one per row.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\x1b[0m"));
    try std.testing.expect(std.mem.indexOf(u8, out, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b") != null);
}

test "ansi: synchronized output wraps only non-empty frames" {
    const allocator = std.testing.allocator;
    var next = try CellGrid.init(allocator, 2, 1);
    defer next.deinit();
    next.putCodepoint(0, 0, 'x', 1, .{});
    const out = try encode(allocator, null, &next, .{ .synchronized = true });
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[?2026l"));
}

test "ansi: emits interned grapheme bytes" {
    const allocator = std.testing.allocator;
    var next = try CellGrid.init(allocator, 3, 1);
    defer next.deinit();
    try next.putGrapheme(0, 0, "e\u{301}", 1, .{});
    try next.putGrapheme(1, 0, "\u{1F469}\u{200D}\u{1F4BB}", 2, .{});

    const encoded = try encode(allocator, null, &next, .{ .synchronized = false });
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "e\u{301}") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\u{1F469}\u{200D}\u{1F4BB}") != null);
}

test "ansi: underline styles emit SGR 4 subparameters after a plain fallback" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        style: ui.style.UnderlineStyle,
        sequence: []const u8,
    }{
        .{ .style = .single, .sequence = "\x1b[4m" },
        .{ .style = .double, .sequence = "\x1b[4m\x1b[4:2m" },
        .{ .style = .curly, .sequence = "\x1b[4m\x1b[4:3m" },
        .{ .style = .dotted, .sequence = "\x1b[4m\x1b[4:4m" },
        .{ .style = .dashed, .sequence = "\x1b[4m\x1b[4:5m" },
    };
    for (cases) |case| {
        var grid = try CellGrid.init(allocator, 1, 1);
        defer grid.deinit();
        grid.putCodepoint(0, 0, 'x', 1, .{ .attrs = cell.underlineAttr(case.style) });
        const encoded = try encode(allocator, null, &grid, .{ .synchronized = false });
        defer allocator.free(encoded);
        try std.testing.expect(std.mem.indexOf(u8, encoded, case.sequence) != null);
        if (case.style == .single) {
            try std.testing.expect(std.mem.indexOf(u8, encoded, "\x1b[4:") == null);
        }
    }

    // A style change resets the pen and re-emits the new subparameter.
    var grid = try CellGrid.init(allocator, 2, 1);
    defer grid.deinit();
    grid.putCodepoint(0, 0, 'a', 1, .{ .attrs = cell.underlineAttr(.curly) });
    grid.putCodepoint(1, 0, 'b', 1, .{ .attrs = cell.underlineAttr(.dotted) });
    const encoded = try encode(allocator, null, &grid, .{ .synchronized = false });
    defer allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\x1b[4m\x1b[4:3ma") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\x1b[4m\x1b[4:4mb") != null);
}

test "ansi: rounded cell-border joints apply after glyphs and clear on repaint" {
    const allocator = std.testing.allocator;
    var rounded = try CellGrid.init(allocator, 3, 1);
    defer rounded.deinit();
    const border = cell_border.Segment;
    const joint = cell_border.Joint;
    // The right corner is a continuation cell of the wide glyph; the
    // rectangle command still addresses that physical cell after painting.
    rounded.putCodepoint(1, 0, '界', 2, .{});
    rounded.addBorder(1, 0, border.top, .{});
    rounded.addBorder(2, 0, border.top | border.right, .{});
    rounded.roundBorder(2, 0, joint.top_right, .{
        .radius = 128,
        .outside = .{ .rgb = .{ .r = 0x28, .g = 0x30, .b = 0x38 } },
    });

    const bytes = try encode(allocator, null, &rounded, .{ .synchronized = false });
    defer allocator.free(bytes);
    const glyph_at = std.mem.indexOf(u8, bytes, "界") orelse return error.MissingGlyph;
    const arc_at = std.mem.indexOf(
        u8,
        bytes,
        "\x1b[1;3H\x1bP1+bcell-border;set;15;64;fg;1;0;1;1\x1b\\" ++
            "\x1bP1+bcell-border;round;2;1;1;radius=128;outside=283038\x1b\\",
    ) orelse return error.MissingRoundedJoint;
    try std.testing.expect(arc_at > glyph_at);

    var square = try CellGrid.init(allocator, 3, 1);
    defer square.deinit();
    square.putCodepoint(1, 0, '界', 2, .{});
    square.addBorder(1, 0, border.top, .{});
    square.addBorder(2, 0, border.top | border.right, .{});
    const delta = try encode(allocator, &rounded, &square, .{ .synchronized = false });
    defer allocator.free(delta);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[K") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "cell-border;round;") == null);
}

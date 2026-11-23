//! Frame-diff ANSI encoder.
//!
//! The process follows TermDOM's `generateANSI`: walk the diff row-major, move
//! the cursor only forward, erase a changed row before repainting it, and emit
//! only the cells that are not empty. A row that did not change is skipped
//! entirely, so an idle frame writes nothing. A cell-border set on a cell is
//! emitted as the terminal's border pen around that cell's glyph.
//!
//! Underlined cells emit SGR `4` and then the ECMA-48 style subparameter
//! (`4:2` double, `4:3` curly, `4:4` dotted, `4:5` dashed) when the cell
//! carries a non-single style. The plain `4` is the fallback for terminals
//! that do not implement underline subparameters.

const std = @import("std");
const cell = @import("cell.zig");
const cell_border = @import("cell_border.zig");

const CellGrid = cell.CellGrid;
const ColorDepth = cell.ColorDepth;
const PaintStyle = cell.PaintStyle;

pub const Options = struct {
    color_depth: ColorDepth = .rgb,
    synchronized: bool = true,
};

pub fn encode(
    allocator: std.mem.Allocator,
    prev: ?*const CellGrid,
    next: *const CellGrid,
    options: Options,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    var row: usize = 0;
    while (row < next.rows) : (row += 1) {
        if (!rowChanged(prev, next, row)) continue;

        // Reset first: erase-to-end uses the terminal's current background
        // with background-color erase. A stale marker background from a
        // previous row/frame must not paint the cells beyond the grid.
        try appendPrint(&body, allocator, "\x1b[0m\x1b[{d};1H\x1b[K", .{row + 1});

        if (!next.rowHasContent(row)) continue;
        try encodeRow(allocator, next, row, &body, options.color_depth);
        try encodeRoundedJoints(allocator, next, row, &body);
        try body.appendSlice(allocator, "\x1b[0m");
    }

    if (body.items.len == 0) {
        body.deinit(allocator);
        return allocator.alloc(u8, 0);
    }

    if (!options.synchronized) {
        return body.toOwnedSlice(allocator);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, "\x1b[?2026h");
    try result.appendSlice(allocator, body.items);
    try result.appendSlice(allocator, "\x1b[?2026l");
    body.deinit(allocator);
    return result.toOwnedSlice(allocator);
}

fn encodeRoundedJoints(allocator: std.mem.Allocator, grid: *const CellGrid, row: usize, out: *std.ArrayList(u8)) !void {
    const start = row * grid.cols;
    for (grid.border[start .. start + grid.cols], 0..) |id, col| {
        if (id == 0) continue;
        const set = grid.borders.get(id).*;
        if (set.joints == 0) continue;
        const continuation = col > 0 and grid.widthAt(col - 1, row) == 2;
        try appendPrint(out, allocator, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
        try cell_border.appendRoundCell(out, allocator, set, continuation);
    }
}

fn rowChanged(prev: ?*const CellGrid, next: *const CellGrid, row: usize) bool {
    const before = prev orelse return next.rowHasContent(row);
    const start = row * next.cols;
    const end = start + next.cols;
    var i = start;
    while (i < end) : (i += 1) {
        if (!CellGrid.sameCell(before, i, next, i)) return true;
    }
    return false;
}

fn encodeRow(
    allocator: std.mem.Allocator,
    grid: *const CellGrid,
    row: usize,
    out: *std.ArrayList(u8),
    depth: ColorDepth,
) !void {
    const start = row * grid.cols;
    var last: usize = 0;
    var has_last = false;
    var col = grid.cols;
    while (col > 0) {
        col -= 1;
        if (grid.cluster[start + col] != 0 or grid.grapheme[start + col] != 0 or grid.border[start + col] != 0) {
            last = col;
            has_last = true;
            break;
        }
    }
    if (!has_last) return;

    var current = PaintStyle{};
    var any_style = false;
    var current_pen: u16 = 0;
    col = 0;
    while (col <= last) : (col += 1) {
        const index = start + col;
        const cluster = grid.cluster[index];
        const grapheme_id = grid.grapheme[index];
        const width = grid.widthAt(col, row);

        if (cluster == 0 and grapheme_id == 0) {
            // Continuation of the wide glyph on the previous column: the glyph
            // already advanced the cursor over this cell. A border that differs
            // on the continuation cell cannot be applied without reprinting the
            // glyph, so it is dropped here.
            if (width == 0 and col > 0 and grid.widthAt(col - 1, row) == 2) continue;
            // An empty gap inside the painted run, or a border-only cell. The
            // space carries the border pen onto the cell.
            try emitStyle(allocator, out, &current, &any_style, grid, index, depth, &current_pen);
            try emitBorderPen(allocator, out, grid, index, &current_pen);
            try out.append(allocator, ' ');
            continue;
        }

        try emitStyle(allocator, out, &current, &any_style, grid, index, depth, &current_pen);
        try emitBorderPen(allocator, out, grid, index, &current_pen);
        if (grapheme_id != 0) {
            try out.appendSlice(allocator, grid.graphemes.get(grapheme_id));
        } else if (cluster >= 0x20 and cluster <= 0x7e) {
            try out.append(allocator, @intCast(cluster));
        } else {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cluster), &buf) catch {
                try out.append(allocator, '?');
                continue;
            };
            try out.appendSlice(allocator, buf[0..len]);
        }
    }

    if (any_style or current_pen != 0) try out.appendSlice(allocator, "\x1b[0m");
}

/// Emits the border pen for a cell when it differs from the current pen. A pen
/// is a rendition state like SGR: every cell written while it is set takes it,
/// and SGR 0 clears it. Only segments whose stroke changes or disappears are
/// touched, per the protocol's application guidance.
fn emitBorderPen(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    grid: *const CellGrid,
    index: usize,
    current_pen: *u16,
) !void {
    const wanted = grid.border[index];
    if (wanted == current_pen.*) return;
    const before = if (current_pen.* == 0) cell_border.Set.empty() else grid.borders.get(current_pen.*).*;
    const after = if (wanted == 0) cell_border.Set.empty() else grid.borders.get(wanted).*;
    try cell_border.appendPenDiff(out, allocator, before, after);
    current_pen.* = wanted;
}

fn emitStyle(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    current: *PaintStyle,
    any_style: *bool,
    grid: *const CellGrid,
    index: usize,
    depth: ColorDepth,
    current_pen: *u16,
) !void {
    const wanted = PaintStyle{
        .fg = grid.fg[index],
        .bg = grid.bg[index],
        .attrs = grid.attrs[index] & cell.Attr.style_mask,
    };
    if (current.eql(wanted) and (any_style.* or PaintStyle.eql(wanted, .{}))) return;

    try out.appendSlice(allocator, "\x1b[0m");
    current_pen.* = 0;
    if (wanted.fg != 0) try writeColor(allocator, out, wanted.fg, true, depth);
    if (wanted.bg != 0) try writeColor(allocator, out, wanted.bg, false, depth);

    if ((wanted.attrs & cell.Attr.bold) != 0) try out.appendSlice(allocator, "\x1b[1m");
    if ((wanted.attrs & cell.Attr.dim) != 0) try out.appendSlice(allocator, "\x1b[2m");
    if ((wanted.attrs & cell.Attr.italic) != 0) try out.appendSlice(allocator, "\x1b[3m");
    if ((wanted.attrs & (cell.Attr.underline | cell.Attr.underline_style_mask)) != 0) {
        // Emit a plain underline first: terminals without ECMA-48 4:x
        // subparameters keep it and ignore or mis-parse only the extra SGR.
        try out.appendSlice(allocator, "\x1b[4m");
        switch (cell.underlineStyleOf(wanted.attrs)) {
            .single => {},
            .double => try out.appendSlice(allocator, "\x1b[4:2m"),
            .curly => try out.appendSlice(allocator, "\x1b[4:3m"),
            .dotted => try out.appendSlice(allocator, "\x1b[4:4m"),
            .dashed => try out.appendSlice(allocator, "\x1b[4:5m"),
        }
    }
    if ((wanted.attrs & cell.Attr.blink) != 0) try out.appendSlice(allocator, "\x1b[5m");
    if ((wanted.attrs & cell.Attr.inverse) != 0) try out.appendSlice(allocator, "\x1b[7m");
    if ((wanted.attrs & cell.Attr.strikethrough) != 0) try out.appendSlice(allocator, "\x1b[9m");
    if ((wanted.attrs & cell.Attr.overline) != 0) try out.appendSlice(allocator, "\x1b[53m");

    current.* = wanted;
    any_style.* = true;
}

fn appendPrint(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try out.appendSlice(allocator, text);
}

fn writeColor(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: u32,
    foreground: bool,
    depth: ColorDepth,
) !void {
    const rgb = cell.unpackColor(value);
    switch (depth) {
        .rgb => {
            try appendPrint(
                out,
                allocator,
                "\x1b[{d};2;{d};{d};{d}m",
                .{ if (foreground) @as(u8, 38) else 48, rgb.r, rgb.g, rgb.b },
            );
        },
        .ansi256 => {
            try appendPrint(
                out,
                allocator,
                "\x1b[{d};5;{d}m",
                .{ if (foreground) @as(u8, 38) else 48, rgbTo256(rgb) },
            );
        },
        .ansi => {
            const index = rgbToAnsi(rgb);
            const code: u8 = if (foreground)
                (if (index < 8) 30 + @as(u8, @intCast(index)) else 90 + @as(u8, @intCast(index)) - 8)
            else
                (if (index < 8) 40 + @as(u8, @intCast(index)) else 100 + @as(u8, @intCast(index)) - 8);
            try appendPrint(out, allocator, "\x1b[{d}m", .{code});
        },
    }
}

const ansi_palette = [_][3]u8{
    .{ 0x00, 0x00, 0x00 }, .{ 0xcd, 0x00, 0x00 }, .{ 0x00, 0xcd, 0x00 }, .{ 0xcd, 0xcd, 0x00 },
    .{ 0x00, 0x00, 0xee }, .{ 0xcd, 0x00, 0xcd }, .{ 0x00, 0xcd, 0xcd }, .{ 0xe5, 0xe5, 0xe5 },
    .{ 0x7f, 0x7f, 0x7f }, .{ 0xff, 0x00, 0x00 }, .{ 0x00, 0xff, 0x00 }, .{ 0xff, 0xff, 0x00 },
    .{ 0x5c, 0x5c, 0xff }, .{ 0xff, 0x00, 0xff }, .{ 0x00, 0xff, 0xff }, .{ 0xff, 0xff, 0xff },
};

fn rgbTo256(rgb: @import("style.zig").Color) u8 {
    if (rgb.r == rgb.g and rgb.g == rgb.b) {
        if (rgb.r < 8) return 0;
        if (rgb.r > 248) return 15;
        return @intCast(@as(u32, @intFromFloat(@round((@as(f64, @floatFromInt(rgb.r - 8)) / 247.0) * 23.0))) + 232);
    }
    const r6: u8 = @intFromFloat(@round(@as(f64, @floatFromInt(rgb.r)) / 255.0 * 5.0));
    const g6: u8 = @intFromFloat(@round(@as(f64, @floatFromInt(rgb.g)) / 255.0 * 5.0));
    const b6: u8 = @intFromFloat(@round(@as(f64, @floatFromInt(rgb.b)) / 255.0 * 5.0));
    return 16 + 36 * r6 + 6 * g6 + b6;
}

fn rgbToAnsi(rgb: @import("style.zig").Color) u8 {
    var best: u8 = 0;
    var best_distance: f64 = std.math.inf(f64);
    for (ansi_palette, 0..) |entry, index| {
        const dr = @as(f64, @floatFromInt(rgb.r)) - @as(f64, @floatFromInt(entry[0]));
        const dg = @as(f64, @floatFromInt(rgb.g)) - @as(f64, @floatFromInt(entry[1]));
        const db = @as(f64, @floatFromInt(rgb.b)) - @as(f64, @floatFromInt(entry[2]));
        const distance = dr * dr + dg * dg + db * db;
        if (distance < best_distance) {
            best_distance = distance;
            best = @intCast(index);
        }
    }
    return best;
}

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
        style: @import("style.zig").UnderlineStyle,
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

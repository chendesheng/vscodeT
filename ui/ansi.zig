//! Frame-diff ANSI encoder.
//!
//! The process follows TermDOM's `generateANSI`: walk the diff row-major, move
//! the cursor only forward, erase a changed row before repainting it, and emit
//! only the cells that are not empty. A row that did not change is skipped
//! entirely, so an idle frame writes nothing.

const std = @import("std");
const cell = @import("cell.zig");

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
        if (grid.cluster[start + col] != 0) {
            last = col;
            has_last = true;
            break;
        }
    }
    if (!has_last) return;

    var current = PaintStyle{};
    var any_style = false;
    col = 0;
    while (col <= last) : (col += 1) {
        const index = start + col;
        const cluster = grid.cluster[index];
        const width = grid.widthAt(col, row);

        if (cluster == 0) {
            // Continuation of the wide glyph on the previous column: the glyph
            // already advanced the cursor over this cell.
            if (width == 0 and col > 0 and grid.widthAt(col - 1, row) == 2) continue;
            // An empty gap inside the painted run: keep the cursor aligned.
            try emitStyle(allocator, out, &current, &any_style, grid, index, depth);
            try out.append(allocator, ' ');
            continue;
        }

        try emitStyle(allocator, out, &current, &any_style, grid, index, depth);
        if (cluster >= 0x20 and cluster <= 0x7e) {
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

    if (any_style) try out.appendSlice(allocator, "\x1b[0m");
}

fn emitStyle(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    current: *PaintStyle,
    any_style: *bool,
    grid: *const CellGrid,
    index: usize,
    depth: ColorDepth,
) !void {
    const wanted = PaintStyle{
        .fg = grid.fg[index],
        .bg = grid.bg[index],
        .attrs = grid.attrs[index] & cell.Attr.style_mask,
    };
    if (current.eql(wanted) and (any_style.* or PaintStyle.eql(wanted, .{}))) return;

    try out.appendSlice(allocator, "\x1b[0m");
    if (wanted.fg != 0) try writeColor(allocator, out, wanted.fg, true, depth);
    if (wanted.bg != 0) try writeColor(allocator, out, wanted.bg, false, depth);

    if ((wanted.attrs & cell.Attr.bold) != 0) try out.appendSlice(allocator, "\x1b[1m");
    if ((wanted.attrs & cell.Attr.dim) != 0) try out.appendSlice(allocator, "\x1b[2m");
    if ((wanted.attrs & cell.Attr.italic) != 0) try out.appendSlice(allocator, "\x1b[3m");
    if ((wanted.attrs & cell.Attr.underline) != 0) try out.appendSlice(allocator, "\x1b[4m");
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

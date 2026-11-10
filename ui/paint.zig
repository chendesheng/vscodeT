//! Paints the derived box tree into a cell grid.
//!
//! There is no cascade and no CSS: each box carries the `Style` it was built
//! with, and anonymous boxes carry the inherited style of their container.
//! Text boxes own the text runs; element boxes own backgrounds and clipping.

const std = @import("std");
const box = @import("box.zig");
const cell = @import("cell.zig");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const style_mod = @import("style.zig");

const CellGrid = cell.CellGrid;
const LayoutBox = box.LayoutBox;
const PaintStyle = cell.PaintStyle;
const Rect = style_mod.Rect;
const Style = style_mod.Style;

/// One-shot convenience for tests: build the box tree, lay it out and paint.
pub fn paintDocument(doc: *dom.Document, grid: *CellGrid) !void {
    var tree = try box.BoxTree.init(doc.allocator);
    defer tree.deinit();
    try tree.rebuild(doc);
    layout.layoutTree(&tree, doc);
    paintTree(&tree, doc, grid);
}

pub fn paintTree(tree: *const box.BoxTree, doc: *const dom.Document, grid: *CellGrid) void {
    const viewport = Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(doc.cols),
        .h = @floatFromInt(doc.rows),
    };
    paintBox(doc, tree.root, grid, .{}, viewport);
}

fn paintBox(
    doc: *const dom.Document,
    current: *const LayoutBox,
    grid: *CellGrid,
    inherited: PaintStyle,
    clip: Rect,
) void {
    if (clip.isEmpty()) return;

    switch (current.kind) {
        .text => {
            const own = mergeStyle(inherited, current.style);
            drawText(doc, grid, current.text orelse "", current.rect.x, current.rect.y, own, clip);
        },
        .initial_containing_block, .element, .anonymous_inline, .anonymous_flex_item => {
            const style = current.style;
            if (style.display == .none or style.display == .contents) return;

            const rect = current.rect;
            if (rect.isEmpty()) return;

            const own = mergeStyle(inherited, style);
            if (style.background != null or style.reverse) {
                grid.fillRect(rect.x, rect.y, rect.w, rect.h, own);
            }

            const border = style_mod.borderWidths(style);
            drawBorder(grid, rect, border, style.border_color, own, clip);

            const child_clip = switch (style.overflow) {
                .visible => clip,
                .hidden, .clip => Rect.intersect(clip, current.padding_rect),
            };

            for (current.children.items) |child| {
                paintBox(doc, child, grid, own, child_clip);
            }
        },
    }
}

fn mergeStyle(base: PaintStyle, style: Style) PaintStyle {
    var result = base;
    if (style.color) |color| result.fg = cell.packColor(color);
    if (style.background) |color| result.bg = cell.packColor(color);
    if (style.bold) result.attrs |= cell.Attr.bold;
    if (style.italic) result.attrs |= cell.Attr.italic;
    if (style.underline) result.attrs |= cell.Attr.underline;
    if (style.strikethrough) result.attrs |= cell.Attr.strikethrough;
    if (style.dim) result.attrs |= cell.Attr.dim;
    if (style.reverse) result.attrs |= cell.Attr.inverse;
    return result;
}

fn drawBorder(
    grid: *CellGrid,
    rect: Rect,
    border: style_mod.Edges,
    border_color: ?style_mod.Color,
    inherited: PaintStyle,
    clip: Rect,
) void {
    if (border.left <= 0 and border.right <= 0 and border.top <= 0 and border.bottom <= 0) return;

    const x0 = cell.snap(rect.x);
    const y0 = cell.snap(rect.y);
    const x1 = cell.snap(rect.right());
    const y1 = cell.snap(rect.bottom());
    if (x1 <= x0 or y1 <= y0) return;

    const left = @min(cell.snap(border.left), x1 - x0);
    const right = @min(cell.snap(border.right), x1 - x0 - left);
    const top = @min(cell.snap(border.top), y1 - y0);
    const bottom = @min(cell.snap(border.bottom), y1 - y0 - top);

    var paint = PaintStyle{ .fg = inherited.fg, .bg = inherited.bg, .attrs = 0 };
    if (border_color) |color| paint.fg = cell.packColor(color);

    var row = y0;
    while (row < y0 + top) : (row += 1) {
        var col = x0;
        while (col < x1) : (col += 1) {
            const glyph: u21 = if (left > 0 and col < x0 + left)
                '┌'
            else if (right > 0 and col >= x1 - right)
                '┐'
            else
                '─';
            putBorderGlyph(grid, col, row, glyph, paint, clip);
        }
    }

    row = y1 - bottom;
    while (row < y1) : (row += 1) {
        var col = x0;
        while (col < x1) : (col += 1) {
            const glyph: u21 = if (left > 0 and col < x0 + left)
                '└'
            else if (right > 0 and col >= x1 - right)
                '┘'
            else
                '─';
            putBorderGlyph(grid, col, row, glyph, paint, clip);
        }
    }

    const column_start = x0;
    const column_end = x1;
    row = y0 + top;
    while (row < y1 - bottom) : (row += 1) {
        var col = column_start;
        while (col < column_start + left) : (col += 1) {
            putBorderGlyph(grid, col, row, '│', paint, clip);
        }
        col = column_end - right;
        while (col < column_end) : (col += 1) {
            putBorderGlyph(grid, col, row, '│', paint, clip);
        }
    }
}

fn putBorderGlyph(
    grid: *CellGrid,
    col: usize,
    row: usize,
    cp: u21,
    paint: PaintStyle,
    clip: Rect,
) void {
    if (col < cell.snap(clip.x) or row < cell.snap(clip.y)) return;
    if (col >= cell.snap(clip.right()) or row >= cell.snap(clip.bottom())) return;
    grid.putCodepoint(col, row, cp, 1, paint);
}

pub fn drawText(
    doc: *const dom.Document,
    grid: *CellGrid,
    text: []const u8,
    x: f64,
    y: f64,
    paint: PaintStyle,
    clip: Rect,
) void {
    const row = cell.snap(y);
    if (row >= grid.rows) return;
    const clip_top = cell.snap(clip.y);
    const clip_bottom = @min(grid.rows, cell.snap(clip.bottom()));
    if (row < clip_top or row >= clip_bottom) return;

    const clip_left = cell.snap(clip.x);
    const clip_right = @min(grid.cols, cell.snap(clip.right()));
    if (clip_left >= clip_right) return;

    var column = cell.snap(x);
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        offset += decoded.len;

        if (decoded.cp == '\t') {
            const next = dom.nextTabStop(column, doc.tab_size);
            while (column < next and column < clip_right) : (column += 1) {
                if (column >= clip_left) grid.putSpace(column, row, paint);
            }
            continue;
        }
        if (decoded.cp < 0x20 or decoded.cp == 0x7f) continue;

        const width = doc.measure_width(decoded.cp);
        if (width == 0) continue;
        if (column >= clip_right) break;
        if (column + width > clip_right) break;
        if (column >= clip_left) {
            grid.putCodepoint(column, row, decoded.cp, width, paint);
        }
        column += width;
    }
}

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
        .padding = .all(1),
        .border = .all(1),
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

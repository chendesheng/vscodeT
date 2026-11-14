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
    try layout.layoutTree(&tree, doc);
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
            // Backgrounds are not inherited in CSS. A text run with no
            // background of its own sits on whatever the cell already shows;
            // this is what lets a transparent label over a filled panel keep
            // the panel color instead of punching a hole with the root's.
            if (!current.has_text_layout) {
                drawText(doc, grid, current.text orelse "", current.rect.x, current.rect.y, own, current.style.background == null, clip);
            } else {
                for (current.text_fragments) |fragment| {
                    drawText(doc, grid, fragment.text, fragment.x, fragment.y, own, current.style.background == null, clip);
                }
            }
        },
        .initial_containing_block, .element, .anonymous_inline, .anonymous_flex_item => {
            const style = current.style;
            if (style.display == .none or style.display == .contents) return;

            const rect = current.rect;
            if (rect.isEmpty()) return;

            const own = mergeStyle(inherited, style);
            const border = style_mod.borderWidths(style);
            if (current.inline_fragments.len > 0) {
                for (current.inline_fragments) |fragment| {
                    const fragment_rect = Rect{
                        .x = fragment.x,
                        .y = fragment.y,
                        .w = fragment.w,
                        .h = fragment.h,
                    };
                    if (style.background != null or style.reverse) {
                        const fill = Rect.intersect(fragment_rect, clip);
                        grid.fillRect(fill.x, fill.y, fill.w, fill.h, own);
                    }
                    drawBorder(grid, fragment_rect, border, style.border_color, own, clip);
                }
            } else {
                if (style.background != null or style.reverse) {
                    // An ancestor's overflow clip cuts everything this box paints, so
                    // a child background must not paint into the gutter outside the
                    // padding edge the way its text already is cut.
                    const fill = Rect.intersect(rect, clip);
                    grid.fillRect(fill.x, fill.y, fill.w, fill.h, own);
                }
                drawBorder(grid, rect, border, style.border_color, own, clip);
            }

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
    grid.putCodepoint(col, row, cp, 1, keepBackground(grid, col, row, paint));
}

/// A border belongs to its box, not to the root: if the box has no background
/// fill, the border sits on the cell underneath it. The box's own fill, when
/// present, has already written the cells, so preserving is correct either way.
fn keepBackground(grid: *const CellGrid, col: usize, row: usize, paint: PaintStyle) PaintStyle {
    if (col >= grid.cols or row >= grid.rows) return paint;
    var result = paint;
    result.bg = grid.bg[grid.index(col, row)];
    return result;
}

pub fn drawText(
    doc: *const dom.Document,
    grid: *CellGrid,
    text: []const u8,
    x: f64,
    y: f64,
    paint: PaintStyle,
    keep_background: bool,
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
                if (column >= clip_left) {
                    const cell_paint = if (keep_background) keepBackground(grid, column, row, paint) else paint;
                    grid.putSpace(column, row, cell_paint);
                }
            }
            continue;
        }
        if (decoded.cp < 0x20 or decoded.cp == 0x7f) continue;

        const width = doc.measure_width(decoded.cp);
        if (width == 0) continue;
        if (column >= clip_right) break;
        if (column + width > clip_right) break;
        if (column >= clip_left) {
            const cell_paint = if (keep_background) keepBackground(grid, column, row, paint) else paint;
            grid.putCodepoint(column, row, decoded.cp, width, cell_paint);
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

fn commonBox(doc: *dom.Document, parent: *dom.Node, style: Style) !*dom.Node {
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
        .padding = style_mod.Edges.all(1),
        .border = style_mod.Edges.all(1),
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
        .padding = style_mod.Edges.all(1),
        .border = style_mod.Edges.all(1),
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
        .padding = style_mod.Edges.all(1),
        .border = style_mod.Edges.all(1),
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

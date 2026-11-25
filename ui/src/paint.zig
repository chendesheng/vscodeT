//! Paints the derived box tree into a cell grid.
//!
//! Each box carries its resolved `ComputedStyle`; classes are resolved from the
//! document stylesheet during box derivation. Paint properties remain
//! declarations and are inherited here, down the live box chain, so hover
//! overlays compose without re-running layout. Style-only `display: contents`
//! ancestors contribute a paint delta carried by the box.
//!
//! Borders paint as single-line box-drawing glyphs, or as cell-border protocol
//! attributes on the box edge when the terminal supports them.

const std = @import("std");
const box = @import("box.zig");
const cell = @import("cell.zig");
const cell_border = @import("cell_border.zig");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const style_mod = @import("style.zig");

const CellGrid = cell.CellGrid;
const LayoutBox = box.LayoutBox;
const PaintStyle = cell.PaintStyle;
const Rect = style_mod.Rect;
const Style = style_mod.ComputedStyle;

/// One-shot convenience for tests: build the box tree, lay it out and paint.
pub fn paintDocument(doc: *dom.Document, grid: *CellGrid) !void {
    var tree = try box.BoxTree.init(doc.allocator);
    defer tree.deinit();
    try tree.rebuild(doc);
    try layout.layoutTree(&tree, doc);
    paintTree(&tree, doc, grid);
}

pub fn paintTree(tree: *const box.BoxTree, doc: *const dom.Document, grid: *CellGrid) void {
    paintTreeWithBorderCapabilities(tree, doc, grid, .{});
}

pub fn paintTreeWithBorderCapabilities(tree: *const box.BoxTree, doc: *const dom.Document, grid: *CellGrid, capabilities: cell_border.Capabilities) void {
    const viewport = Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(doc.cols),
        .h = @floatFromInt(doc.rows),
    };
    paintBox(doc, tree.root, grid, .{}, .visible, null, viewport, .{ .cell_borders = tree.cell_borders, .capabilities = capabilities });
}

const BorderOptions = struct {
    cell_borders: bool,
    capabilities: cell_border.Capabilities,
};

fn paintBox(
    doc: *const dom.Document,
    current: *const LayoutBox,
    grid: *CellGrid,
    inherited: PaintStyle,
    /// Visibility inherited by text and anonymous runs. Element boxes resolve
    /// their own computed value; text boxes have none of their own.
    inherited_visibility: style_mod.Visibility,
    /// A hover visibility declaration from an ancestor in the hover chain.
    /// It wins over every base visibility below it (see `HoverStyle.visibility`).
    hover_visibility: ?style_mod.Visibility,
    clip: Rect,
    borders: BorderOptions,
) void {
    if (clip.isEmpty()) return;

    switch (current.kind) {
        .text => {
            if ((hover_visibility orelse inherited_visibility) == .hidden) return;
            const paint = current.paint_ref orelse &current.paint;
            var own = mergeTextStyle(inherited, current.paint_delta);
            own = mergeTextStyle(own, paint.*);
            // Backgrounds are not inherited in CSS. A text run with no
            // background of its own sits on whatever the cell already shows;
            // this is what lets a transparent label over a filled panel keep
            // the panel color instead of punching a hole with the root's.
            const keep_background = paint.background == null;
            if (!current.has_text_layout) {
                drawText(doc, grid, current.text orelse "", current.rect.x, current.rect.y, own, keep_background, clip);
            } else {
                for (current.text_fragments) |fragment| {
                    drawText(doc, grid, fragment.text, fragment.x, fragment.y, own, keep_background, clip);
                }
            }
        },
        .initial_containing_block, .element, .anonymous_inline, .anonymous_flex_item => {
            const style = current.style;
            if (style.display == .none or style.display == .contents) return;

            const rect = current.rect;
            if (rect.isEmpty()) return;

            // Anonymous boxes copy their container's style, and `inherited`
            // already carries that merged paint. Re-merging the copy would
            // re-apply the container's base color/attributes over an
            // ancestor's hover override (bare text runs live in anonymous
            // boxes, so this would mask hover colors and bold-off changes).
            const anonymous = current.kind == .anonymous_inline or
                current.kind == .anonymous_flex_item;
            var base = mergeTextStyle(inherited, current.paint_delta);
            if (!anonymous) base = mergeStyle(base, style);
            const hover = if (current.kind == .element) hoverStyleOf(current.owner) else null;
            const own = if (hover) |value| mergeHoverStyle(base, value) else base;
            const child_hover_visibility = if (hover) |value| value.visibility orelse hover_visibility else hover_visibility;
            const visibility = child_hover_visibility orelse style.visibility;
            const visible = visibility == .visible;
            // A hidden box keeps its layout and hit box but paints only its
            // descendants that override visibility back to visible.
            if (visible) {
                const paints_background = style.background != null or (style.reverse orelse false) or
                    (hover != null and (hover.?.background != null or (hover.?.reverse orelse false)));
                const border = style_mod.borderWidths(style);
                const border_color = if (hover) |value|
                    value.border_color orelse style.border_color
                else
                    style.border_color;
                if (current.inline_fragments.len > 0) {
                    for (current.inline_fragments) |fragment| {
                        const fragment_rect = Rect{
                            .x = fragment.x,
                            .y = fragment.y,
                            .w = fragment.w,
                            .h = fragment.h,
                        };
                        if (paints_background) {
                            const fill = Rect.intersect(fragment_rect, clip);
                            grid.fillRect(fill.x, fill.y, fill.w, fill.h, own);
                        }
                        if (borders.cell_borders) {
                            drawCellBorder(grid, fragment_rect, current.cell_border, style.border_style, border_color, own, clip);
                        } else {
                            drawBorder(grid, fragment_rect, border, border_color, own, clip, style.border_style == .rounded);
                        }
                    }
                } else {
                    const round = style.border_style == .rounded;
                    const fill = Rect.intersect(rect, clip);
                    const rounded_frame = if (round and borders.capabilities.has(.round) and
                        border.left > 0 and border.right > 0 and border.top > 0 and border.bottom > 0 and
                        std.meta.eql(fill, rect))
                        cell.RoundedCellFrame.capture(grid, rect)
                    else
                        null;
                    if (paints_background) {
                        // An ancestor's overflow clip cuts everything this box paints, so
                        // a child background must not paint into the gutter outside the
                        // padding edge the way its text already is cut.
                        grid.fillRect(fill.x, fill.y, fill.w, fill.h, own);
                    }
                    if (rounded_frame) |frame| {
                        if (paints_background) grid.clearBordersRect(rect.x, rect.y, rect.w, rect.h);
                        const stroke = cellBorderStroke(border.top, border_color, own);
                        frame.paint(grid, borders.capabilities, stroke.color);
                    } else if (borders.cell_borders) {
                        drawCellBorder(grid, rect, current.cell_border, style.border_style, border_color, own, clip);
                    } else {
                        drawBorder(grid, rect, border, border_color, own, clip, round);
                    }
                }
            }

            const child_clip = switch (style.overflow) {
                .visible => clip,
                .hidden, .clip => Rect.intersect(clip, current.padding_rect),
            };

            for (current.children.items) |child| {
                paintBox(doc, child, grid, own, visibility, child_hover_visibility, child_clip, borders);
            }
        },
    }
}

fn mergeTextStyle(base: PaintStyle, paint: style_mod.PaintStyle) PaintStyle {
    var result = base;
    if (paint.color) |color| result.fg = cell.packColor(color);
    if (paint.background) |color| result.bg = cell.packColor(color);
    if (paint.bold) |on| result.attrs = setAttr(result.attrs, cell.Attr.bold, on);
    if (paint.italic) |on| result.attrs = setAttr(result.attrs, cell.Attr.italic, on);
    if (paint.underline) |on| {
        if (on) {
            applyUnderline(&result, paint.underline_style);
        } else {
            result.attrs &= ~(cell.Attr.underline | cell.Attr.underline_style_mask);
        }
    }
    if (paint.strikethrough) |on| result.attrs = setAttr(result.attrs, cell.Attr.strikethrough, on);
    if (paint.dim) |on| result.attrs = setAttr(result.attrs, cell.Attr.dim, on);
    if (paint.reverse) |on| result.attrs = setAttr(result.attrs, cell.Attr.inverse, on);
    return result;
}

fn mergeStyle(base: PaintStyle, style: Style) PaintStyle {
    var result = base;
    if (style.color) |color| result.fg = cell.packColor(color);
    if (style.background) |color| result.bg = cell.packColor(color);
    if (style.bold) |on| result.attrs = setAttr(result.attrs, cell.Attr.bold, on);
    if (style.italic) |on| result.attrs = setAttr(result.attrs, cell.Attr.italic, on);
    if (style.underline) |on| {
        if (on) {
            applyUnderline(&result, style.underline_style orelse .single);
        } else {
            result.attrs &= ~(cell.Attr.underline | cell.Attr.underline_style_mask);
        }
    } else if (style.underline_style) |underline_style| {
        if ((result.attrs & cell.Attr.underline) != 0) applyUnderline(&result, underline_style);
    }
    if (style.strikethrough) |on| result.attrs = setAttr(result.attrs, cell.Attr.strikethrough, on);
    if (style.dim) |on| result.attrs = setAttr(result.attrs, cell.Attr.dim, on);
    if (style.reverse) |on| result.attrs = setAttr(result.attrs, cell.Attr.inverse, on);
    return result;
}

/// The hover declaration that applies to `owner`, or null when the element
/// does not opt in or is outside the current hover chain.
fn hoverStyleOf(owner: ?*dom.Node) ?style_mod.HoverStyle {
    const node = owner orelse return null;
    if (!node.isElement()) return null;
    const hover = node.asElement().hover_style orelse return null;
    if (!node.isHovered()) return null;
    return hover;
}

/// Overlays a hover declaration on the element's merged paint. Colors replace;
/// boolean attributes are set or cleared according to the optional field, so a
/// hover rule can remove a base attribute.
fn mergeHoverStyle(base: PaintStyle, hover: style_mod.HoverStyle) PaintStyle {
    var result = base;
    if (hover.color) |color| result.fg = cell.packColor(color);
    if (hover.background) |color| result.bg = cell.packColor(color);
    if (hover.bold) |on| result.attrs = setAttr(result.attrs, cell.Attr.bold, on);
    if (hover.italic) |on| result.attrs = setAttr(result.attrs, cell.Attr.italic, on);
    if (hover.underline) |on| {
        if (on) {
            applyUnderline(&result, hover.underline_style);
        } else {
            result.attrs &= ~(cell.Attr.underline | cell.Attr.underline_style_mask);
        }
    }
    if (hover.strikethrough) |on| result.attrs = setAttr(result.attrs, cell.Attr.strikethrough, on);
    if (hover.dim) |on| result.attrs = setAttr(result.attrs, cell.Attr.dim, on);
    if (hover.reverse) |on| result.attrs = setAttr(result.attrs, cell.Attr.inverse, on);
    return result;
}

fn setAttr(attrs: u16, bit: u16, on: bool) u16 {
    return if (on) attrs | bit else attrs & ~bit;
}

fn applyUnderline(result: *PaintStyle, underline_style: style_mod.UnderlineStyle) void {
    result.attrs &= ~cell.Attr.underline_style_mask;
    result.attrs |= cell.underlineAttr(underline_style);
}

/// The clip rectangle snapped and clamped once per border pass, so per-cell
/// border writers do not re-run `snap` for every cell.
const ClipBounds = struct {
    left: usize,
    top: usize,
    right: usize,
    bottom: usize,

    fn init(grid: *const CellGrid, clip: Rect) ClipBounds {
        return .{
            .left = cell.snap(clip.x),
            .top = cell.snap(clip.y),
            // Out-of-grid cells are dropped by the cell writers either way, so
            // clamping here is behavior preserving and keeps every span index
            // inside its planes.
            .right = @min(grid.cols, cell.snap(clip.right())),
            .bottom = @min(grid.rows, cell.snap(clip.bottom())),
        };
    }

    fn contains(self: ClipBounds, col: usize, row: usize) bool {
        return col >= self.left and col < self.right and
            row >= self.top and row < self.bottom;
    }
};

fn drawBorder(
    grid: *CellGrid,
    rect: Rect,
    border: style_mod.Edges,
    border_color: ?style_mod.Color,
    inherited: PaintStyle,
    clip: Rect,
    round: bool,
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

    const bounds = ClipBounds.init(grid, clip);

    var row = y0;
    while (row < y0 + top) : (row += 1) {
        borderRow(grid, bounds, row, x0, x1, left, right, if (round) '╭' else '┌', if (round) '╮' else '┐', paint);
    }

    row = y1 - bottom;
    while (row < y1) : (row += 1) {
        borderRow(grid, bounds, row, x0, x1, left, right, if (round) '╰' else '└', if (round) '╯' else '┘', paint);
    }

    row = y0 + top;
    while (row < y1 - bottom) : (row += 1) {
        fillBorderRun(grid, bounds, row, x0, x0 + left, '│', paint);
        fillBorderRun(grid, bounds, row, x1 - right, x1, '│', paint);
    }
}

/// One horizontal border row: the two corner runs and the dash run. Each run is
/// clipped and written as one span instead of one bounds-checked glyph per cell.
fn borderRow(
    grid: *CellGrid,
    bounds: ClipBounds,
    row: usize,
    x0: usize,
    x1: usize,
    left: usize,
    right: usize,
    left_glyph: u21,
    right_glyph: u21,
    paint: PaintStyle,
) void {
    fillBorderRun(grid, bounds, row, x0, x0 + left, left_glyph, paint);
    fillBorderRun(grid, bounds, row, x0 + left, x1 - right, '─', paint);
    fillBorderRun(grid, bounds, row, x1 - right, x1, right_glyph, paint);
}

/// Fills the horizontal span `[start, end)` on `row`, clipped to the snapped
/// bounds. The background underneath the border is preserved per cell.
fn fillBorderRun(
    grid: *CellGrid,
    bounds: ClipBounds,
    row: usize,
    start: usize,
    end: usize,
    glyph: u21,
    paint: PaintStyle,
) void {
    if (row < bounds.top or row >= bounds.bottom) return;
    const left = @max(start, bounds.left);
    const right = @min(end, bounds.right);
    if (left >= right) return;
    grid.fillGlyphSpan(row * grid.cols + left, right - left, glyph, 1, paint, true);
}

/// Cell-border mode: paint the border as terminal cell attributes on the box's
/// outer edges instead of box-drawing glyphs. Nothing is written to the glyph
/// plane, so the border shares its cells with text and costs no layout space.
/// The placement is centred, which lets two adjacent boxes merge a shared edge
/// in the terminal.
fn drawCellBorder(
    grid: *CellGrid,
    rect: Rect,
    border: style_mod.Edges,
    border_style: style_mod.BorderStyle,
    border_color: ?style_mod.Color,
    inherited: PaintStyle,
    clip: Rect,
) void {
    if (border_style == .none) return;
    if (border.left <= 0 and border.right <= 0 and border.top <= 0 and border.bottom <= 0) return;

    const x0 = cell.snap(rect.x);
    const y0 = cell.snap(rect.y);
    const x1 = cell.snap(rect.right());
    const y1 = cell.snap(rect.bottom());
    if (x1 <= x0 or y1 <= y0) return;

    const bounds = ClipBounds.init(grid, clip);
    const first_col = @max(x0, bounds.left);
    const last_col = @min(x1, bounds.right);
    const first_row = @max(y0, bounds.top);
    const last_row = @min(y1, bounds.bottom);

    if (border.top > 0) {
        const stroke = cellBorderStroke(border.top, border_color, inherited);
        var col = first_col;
        while (col < last_col) : (col += 1) addCellBorder(grid, col, y0, cell_border.Segment.top, stroke, bounds);
    }
    if (border.bottom > 0) {
        const stroke = cellBorderStroke(border.bottom, border_color, inherited);
        var col = first_col;
        while (col < last_col) : (col += 1) addCellBorder(grid, col, y1 - 1, cell_border.Segment.bottom, stroke, bounds);
    }
    if (border.left > 0) {
        const stroke = cellBorderStroke(border.left, border_color, inherited);
        var row = first_row;
        while (row < last_row) : (row += 1) addCellBorder(grid, x0, row, cell_border.Segment.left, stroke, bounds);
    }
    if (border.right > 0) {
        const stroke = cellBorderStroke(border.right, border_color, inherited);
        var row = first_row;
        while (row < last_row) : (row += 1) addCellBorder(grid, x1 - 1, row, cell_border.Segment.right, stroke, bounds);
    }
}

fn cellBorderStroke(
    width_cells: f64,
    border_color: ?style_mod.Color,
    inherited: PaintStyle,
) cell_border.Stroke {
    // One cell of CSS border maps to the protocol demo's 16/256-cell stroke;
    // a 4-cell border reaches the protocol's 1/4-cell width cap.
    const units = @round(width_cells * 16);
    const width: u8 = @intFromFloat(std.math.clamp(units, 1, 64));
    const color: cell_border.ColorValue = if (border_color) |value|
        .{ .rgb = value }
    else if (inherited.fg != 0)
        .{ .rgb = cell.unpackColor(inherited.fg) }
    else
        .default_fg;
    return .{
        .width = width,
        .color = color,
        .placement = .centered,
        .layer = .below_text,
    };
}

fn addCellBorder(
    grid: *CellGrid,
    col: usize,
    row: usize,
    mask: u12,
    stroke: cell_border.Stroke,
    bounds: ClipBounds,
) void {
    if (!bounds.contains(col, row)) return;
    grid.addBorder(col, row, mask, stroke);
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

    // Scrolled content can sit at negative x (the scroll viewport clips it).
    // Keep column signed until the clip test so the skipped glyphs keep their
    // measured width instead of collapsing to column zero.
    const row_base = row * grid.cols;
    var column: i64 = @intFromFloat(@round(x));
    var offset: usize = 0;
    while (offset < text.len) {
        // Fast path for printable ASCII, which is the overwhelming case for
        // terminal editor text. Group the whole run, clip it once and write it
        // through a precomputed row base instead of decoding, measuring and
        // bounds-checking every byte.
        const byte = text[offset];
        if (byte >= 0x20 and byte < 0x7f) {
            const run_start = offset;
            while (offset < text.len and text[offset] >= 0x20 and text[offset] < 0x7f) offset += 1;
            if (column >= @as(i64, @intCast(clip_right))) break;
            const run_end = column + @as(i64, @intCast(offset - run_start));
            const write_start = @max(column, @as(i64, @intCast(clip_left)));
            const write_end = @min(run_end, @as(i64, @intCast(clip_right)));
            if (write_start < write_end) {
                const skip: usize = @intCast(write_start - column);
                const length: usize = @intCast(write_end - write_start);
                grid.putAsciiSpan(
                    row_base + @as(usize, @intCast(write_start)),
                    text[run_start + skip .. run_start + skip + length],
                    paint,
                    keep_background,
                );
            }
            column = run_end;
            continue;
        }
        const decoded = dom.decodeAt(text, offset);
        if (decoded.len == 0) break;
        offset += decoded.len;

        if (decoded.cp == '\t') {
            const tab_size: i64 = @intCast(@max(doc.tab_size, 1));
            const next: i64 = if (column < 0)
                @divFloor(column, tab_size) * tab_size + tab_size
            else
                @intCast(dom.nextTabStop(@intCast(column), doc.tab_size));
            const write_start = @max(column, @as(i64, @intCast(clip_left)));
            const write_end = @min(next, @as(i64, @intCast(clip_right)));
            if (write_start < write_end) {
                grid.fillGlyphSpan(
                    row_base + @as(usize, @intCast(write_start)),
                    @intCast(write_end - write_start),
                    ' ',
                    1,
                    paint,
                    keep_background,
                );
            }
            column = next;
            continue;
        }
        if (decoded.cp < 0x20 or decoded.cp == 0x7f) continue;

        const width: i64 = doc.measure_width(decoded.cp);
        if (width == 0) continue;
        if (column >= @as(i64, @intCast(clip_right))) break;
        if (column + width > @as(i64, @intCast(clip_right))) break;
        if (column >= @as(i64, @intCast(clip_left))) {
            const cell_paint = if (keep_background) keepBackground(grid, @intCast(column), row, paint) else paint;
            const index = row_base + @as(usize, @intCast(column));
            grid.putCellAt(index, decoded.cp, @intCast(width), cell_paint);
            // The continuation cell is empty and advances no cursor of its own.
            if (width == 2) grid.putCellAt(index + 1, 0, 0, cell_paint);
        }
        column += width;
    }
}

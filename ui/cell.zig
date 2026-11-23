//! Terminal cell storage and the frame grid.
//!
//! A grid is a set of parallel planes, not an array of structs. A cell's
//! glyph is a Unicode scalar value for now; multi-codepoint graphemes will use
//! an interned reference once the renderer learns grapheme segmentation.
//!
//! `fg`/`bg` are packed as `1 << 24 | 0xRRGGBB`; `0` means "terminal default"
//! (so black is distinguishable from default). A cluster of `0` is an empty
//! cell; a wide glyph's continuation cells store `cluster = 0`, width 0.

const std = @import("std");
const cell_border = @import("cell_border.zig");
const grapheme = @import("grapheme.zig");
const style = @import("style.zig");

pub const Attr = struct {
    pub const bold: u16 = 1 << 0;
    pub const italic: u16 = 1 << 1;
    pub const underline: u16 = 1 << 2;
    pub const strikethrough: u16 = 1 << 3;
    pub const inverse: u16 = 1 << 4;
    pub const dim: u16 = 1 << 5;
    pub const blink: u16 = 1 << 6;
    pub const overline: u16 = 1 << 7;

    /// The underline shape lives in the three bits after `overline`; the
    /// presence bit stays `underline` so code that only wants a plain
    /// underline keeps setting a single flag.
    pub const underline_style_shift: u4 = 8;
    pub const underline_style_mask: u16 = 0b111 << underline_style_shift;

    pub const width_shift: u4 = 11;
    pub const width_mask: u16 = 0b11 << width_shift;
    pub const style_mask: u16 = 0x7ff;
};

pub const PaintStyle = struct {
    fg: u32 = 0,
    bg: u32 = 0,
    attrs: u16 = 0,

    pub fn eql(a: PaintStyle, b: PaintStyle) bool {
        return a.fg == b.fg and a.bg == b.bg and a.attrs == b.attrs;
    }
};

/// Cell attribute bits for an underlined text run.
pub fn underlineAttr(value: style.UnderlineStyle) u16 {
    return Attr.underline | (@as(u16, @backingInt(value)) << Attr.underline_style_shift);
}

/// The underline shape stored in `attrs`; `.single` when only the presence bit
/// is set (the default for all existing callers).
pub fn underlineStyleOf(attrs: u16) style.UnderlineStyle {
    return switch ((attrs & Attr.underline_style_mask) >> Attr.underline_style_shift) {
        1 => .double,
        2 => .curly,
        3 => .dotted,
        4 => .dashed,
        else => .single,
    };
}

pub fn packColor(color: style.Color) u32 {
    return (1 << 24) | (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b;
}

pub fn unpackColor(value: u32) style.Color {
    return .{
        .r = @intCast((value >> 16) & 0xff),
        .g = @intCast((value >> 8) & 0xff),
        .b = @intCast(value & 0xff),
    };
}

pub const ColorDepth = enum { ansi, ansi256, rgb };

const no_border: cell_border.Set = .{ .groups = undefined, .count = 0 };

pub const CellGrid = struct {
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
    /// Glyph scalar value. 0 = empty; continuation cells of a wide glyph are 0.
    /// For multi-codepoint clusters this is the first codepoint; the full text
    /// lives in the interned `grapheme` plane.
    cluster: []u32,
    /// Interned UTF-8 grapheme id per cell; 0 means the single `cluster`
    /// codepoint is the complete glyph.
    grapheme: []u32,
    fg: []u32,
    bg: []u32,
    attrs: []u16,
    /// Interned cell-border set id per cell; 0 is no border. The ANSI writer
    /// turns a change of this plane into a border pen around the glyph.
    border: []u16,
    borders: *cell_border.Table,
    owns_borders: bool,
    graphemes: *grapheme.Table,
    owns_graphemes: bool,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !CellGrid {
        const table = try allocator.create(cell_border.Table);
        table.* = .{};
        errdefer allocator.destroy(table);
        const graphemes = try allocator.create(grapheme.Table);
        errdefer allocator.destroy(graphemes);
        graphemes.* = try grapheme.Table.init(allocator);
        errdefer graphemes.deinit();
        var grid = try initInternal(allocator, cols, rows, table, graphemes);
        grid.owns_borders = true;
        grid.owns_graphemes = true;
        return grid;
    }

    /// Initialises a grid on a border table owned by the caller. Double-buffered
    /// frames share one table so border ids are comparable across buffers. The
    /// grapheme table is private to this grid; use `initWithTables` when both
    /// intern tables are shared.
    pub fn initWithTable(
        allocator: std.mem.Allocator,
        cols: usize,
        rows: usize,
        table: *cell_border.Table,
    ) !CellGrid {
        const graphemes = try allocator.create(grapheme.Table);
        errdefer allocator.destroy(graphemes);
        graphemes.* = try grapheme.Table.init(allocator);
        errdefer graphemes.deinit();
        var grid = try initInternal(allocator, cols, rows, table, graphemes);
        grid.owns_graphemes = true;
        return grid;
    }

    /// Initialises a grid on tables owned by the caller. Both intern tables are
    /// shared by the two buffers of a frame.
    pub fn initWithTables(
        allocator: std.mem.Allocator,
        cols: usize,
        rows: usize,
        borders: *cell_border.Table,
        graphemes: *grapheme.Table,
    ) !CellGrid {
        return initInternal(allocator, cols, rows, borders, graphemes);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        cols: usize,
        rows: usize,
        table: *cell_border.Table,
        graphemes: *grapheme.Table,
    ) !CellGrid {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        const size = c * r;
        const cluster = try allocator.alloc(u32, size);
        errdefer allocator.free(cluster);
        const grapheme_ids = try allocator.alloc(u32, size);
        errdefer allocator.free(grapheme_ids);
        const fg = try allocator.alloc(u32, size);
        errdefer allocator.free(fg);
        const bg = try allocator.alloc(u32, size);
        errdefer allocator.free(bg);
        const attrs = try allocator.alloc(u16, size);
        errdefer allocator.free(attrs);
        const border = try allocator.alloc(u16, size);
        errdefer allocator.free(border);

        var grid = CellGrid{
            .allocator = allocator,
            .cols = c,
            .rows = r,
            .cluster = cluster,
            .grapheme = grapheme_ids,
            .fg = fg,
            .bg = bg,
            .attrs = attrs,
            .border = border,
            .borders = table,
            .owns_borders = false,
            .graphemes = graphemes,
            .owns_graphemes = false,
        };
        grid.clear();
        return grid;
    }

    pub fn deinit(self: *CellGrid) void {
        self.allocator.free(self.cluster);
        self.allocator.free(self.grapheme);
        self.allocator.free(self.fg);
        self.allocator.free(self.bg);
        self.allocator.free(self.attrs);
        self.allocator.free(self.border);
        if (self.owns_borders) self.allocator.destroy(self.borders);
        if (self.owns_graphemes) {
            self.graphemes.deinit();
            self.allocator.destroy(self.graphemes);
        }
    }

    pub fn clear(self: *CellGrid) void {
        @memset(self.cluster, 0);
        @memset(self.grapheme, 0);
        @memset(self.fg, 0);
        @memset(self.bg, 0);
        @memset(self.attrs, 0);
        @memset(self.border, 0);
    }

    pub fn index(self: *const CellGrid, col: usize, row: usize) usize {
        return row * self.cols + col;
    }

    pub fn widthAt(self: *const CellGrid, col: usize, row: usize) usize {
        return (self.attrs[self.index(col, row)] & Attr.width_mask) >> Attr.width_shift;
    }

    pub fn borderIdAt(self: *const CellGrid, col: usize, row: usize) u16 {
        if (col >= self.cols or row >= self.rows) return 0;
        return self.border[self.index(col, row)];
    }

    pub fn borderSetAt(self: *const CellGrid, col: usize, row: usize) *const cell_border.Set {
        const id = self.borderIdAt(col, row);
        if (id == 0) return &no_border;
        return self.borders.get(id);
    }

    /// Sets the border id of one cell. Painting goes through `addBorder`; this
    /// is the primitive used by compositing and tests.
    pub fn setBorderId(self: *CellGrid, col: usize, row: usize, id: u16) void {
        if (col >= self.cols or row >= self.rows) return;
        self.border[self.index(col, row)] = id;
    }

    /// Assigns `mask` to `stroke`, keeping any segments this cell already has
    /// from other boxes. The table returns 0 when it is full, which drops the
    /// border rather than failing the paint pass.
    pub fn addBorder(
        self: *CellGrid,
        col: usize,
        row: usize,
        mask: u12,
        stroke: cell_border.Stroke,
    ) void {
        if (col >= self.cols or row >= self.rows) return;
        const i = self.index(col, row);
        const current = if (self.border[i] == 0) cell_border.Set.empty() else self.borders.get(self.border[i]).*;
        self.border[i] = self.borders.intern(current.with(mask, stroke));
    }

    fn put(
        self: *CellGrid,
        col: usize,
        row: usize,
        cluster: u32,
        width: usize,
        paint: PaintStyle,
    ) void {
        if (col >= self.cols or row >= self.rows) return;
        const i = self.index(col, row);
        self.cluster[i] = cluster;
        self.grapheme[i] = 0;
        self.fg[i] = paint.fg;
        self.bg[i] = paint.bg;
        self.attrs[i] = (paint.attrs & Attr.style_mask) |
            (@as(u16, @intCast(wordWidth(width))) << Attr.width_shift);
    }

    fn wordWidth(width: usize) usize {
        return @min(width, 2);
    }

    /// Writes one code point. `width` is 0, 1 or 2 terminal cells.
    pub fn putCodepoint(
        self: *CellGrid,
        col: usize,
        row: usize,
        cp: u21,
        width: usize,
        paint: PaintStyle,
    ) void {
        if (col >= self.cols or row >= self.rows) return;
        if (width == 0) return;
        if (cp < 0x20 or cp == 0x7f) {
            self.put(col, row, ' ', 1, paint);
            return;
        }
        if (width == 2 and col + 1 >= self.cols) {
            self.put(col, row, ' ', 1, paint);
            return;
        }
        self.put(col, row, cp, width, paint);
        if (width == 2) {
            // The continuation cell is empty and advances no cursor of its own.
            self.put(col + 1, row, 0, 0, paint);
        }
    }

    /// Writes one multi-codepoint grapheme cluster. `width` is 1 or 2 cells;
    /// the bytes are interned for the frame diff and the ANSI writer. The first
    /// codepoint is kept in the `cluster` plane for the existing single-glyph
    /// helpers.
    pub fn putGrapheme(
        self: *CellGrid,
        col: usize,
        row: usize,
        text: []const u8,
        width: usize,
        paint: PaintStyle,
    ) !void {
        if (col >= self.cols or row >= self.rows) return;
        if (width == 0) return;
        if (text.len == 0) {
            self.putSpace(col, row, paint);
            return;
        }
        if (width >= 2 and col + 1 >= self.cols) {
            self.putSpace(col, row, paint);
            return;
        }
        const cells = @min(width, 2);
        const first_len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        const first = if (first_len <= text.len)
            std.unicode.utf8Decode(text[0..first_len]) catch '?'
        else
            '?';
        const id = try self.graphemes.intern(text);
        self.put(col, row, first, cells, paint);
        self.grapheme[self.index(col, row)] = id;
        if (cells == 2) self.put(col + 1, row, 0, 0, paint);
    }

    /// Returns the interned grapheme bytes at a cell, or an empty slice for a
    /// single-codepoint cell.
    pub fn graphemeAt(self: *const CellGrid, col: usize, row: usize) []const u8 {
        if (col >= self.cols or row >= self.rows) return "";
        return self.graphemes.get(self.grapheme[self.index(col, row)]);
    }

    pub fn putSpace(self: *CellGrid, col: usize, row: usize, paint: PaintStyle) void {
        if (col >= self.cols or row >= self.rows) return;
        self.put(col, row, ' ', 1, paint);
    }

    pub fn fillRect(
        self: *CellGrid,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        paint: PaintStyle,
    ) void {
        if (w <= 0 or h <= 0) return;
        const left = snap(x);
        const top = snap(y);
        const right = @min(self.cols, snap(x + w));
        const bottom = @min(self.rows, snap(y + h));
        var row = top;
        while (row < bottom) : (row += 1) {
            var col = left;
            while (col < right) : (col += 1) {
                self.putSpace(col, row, paint);
            }
        }
    }

    /// Paints a color over the cells already on screen. Foreground and
    /// background blend independently, leaving glyphs and attributes intact.
    pub fn tintRect(self: *CellGrid, rect: style.Rect, color: style.Color, alpha: f32, defaults: PaintStyle) void {
        if (alpha <= 0 or rect.w <= 0 or rect.h <= 0) return;
        const left = @min(self.cols, snap(rect.x));
        const right = @min(self.cols, snap(rect.right()));
        var row = @min(self.rows, snap(rect.y));
        const bottom = @min(self.rows, snap(rect.bottom()));
        if (left >= right) return;
        while (row < bottom) : (row += 1) {
            // A terminal writes both cells of a wide glyph together.
            const start = if (left > 0 and self.widthAt(left - 1, row) == 2) left - 1 else left;
            const end = if (right < self.cols and self.widthAt(right - 1, row) == 2) right + 1 else right;
            for (start..end) |col| {
                const i = self.index(col, row);
                self.fg[i] = blendColor(color, alpha, if (self.fg[i] == 0) defaults.fg else self.fg[i]);
                self.bg[i] = blendColor(color, alpha, if (self.bg[i] == 0) defaults.bg else self.bg[i]);
            }
        }
    }

    fn blendColor(color: style.Color, alpha: f32, base: u32) u32 {
        if (alpha >= 1) return packColor(color);
        const background = unpackColor(base);
        return packColor(.{
            .r = blendChannel(color.r, alpha, background.r),
            .g = blendChannel(color.g, alpha, background.g),
            .b = blendChannel(color.b, alpha, background.b),
        });
    }

    fn blendChannel(top: u8, alpha: f32, bottom: u8) u8 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(top)) * alpha + @as(f32, @floatFromInt(bottom)) * (1 - alpha)));
    }

    /// Captures the already-painted cells of a tab or another one-line view.
    pub fn captureRow(self: *const CellGrid, allocator: std.mem.Allocator, left: usize, row: usize, width: usize) !CellGrid {
        std.debug.assert(row < self.rows and left < self.cols and width > 0 and width <= self.cols - left);
        var image = try CellGrid.init(allocator, width, 1);
        errdefer image.deinit();
        for (0..width) |col| {
            const x = left + col;
            const i = self.index(x, row);
            const paint: PaintStyle = .{ .fg = self.fg[i], .bg = self.bg[i], .attrs = self.attrs[i] };
            const cells = self.widthAt(x, row);
            if (cells != 0 and !(cells == 2 and col + 1 == width)) {
                const glyph = self.graphemeAt(x, row);
                if (glyph.len > 0) {
                    try image.putGrapheme(col, 0, glyph, cells, paint);
                } else {
                    image.putCodepoint(col, 0, @intCast(self.cluster[i]), cells, paint);
                }
            } else if (col == 0 or self.widthAt(x - 1, row) != 2) {
                image.putSpace(col, 0, paint);
            }
            image.border[col] = image.borders.remap(self.borders, self.border[i]);
        }
        return image;
    }

    /// Composites a drag image without changing layout or hit testing.
    pub fn paintImage(self: *CellGrid, image: *const CellGrid, x: usize, y: usize) !void {
        if (x >= self.cols or y >= self.rows) return;
        const width = @min(image.cols, self.cols - x);
        const height = @min(image.rows, self.rows - y);
        for (0..height) |row| {
            if (x > 0 and self.widthAt(x - 1, y + row) == 2) self.blankGlyph(x - 1, y + row);
            if (x + width < self.cols and self.widthAt(x + width - 1, y + row) == 2) self.blankGlyph(x + width, y + row);
        }
        try self.blit(image, x, y, width, height);
        if (width < image.cols) {
            for (0..height) |row| {
                if (image.widthAt(width - 1, row) == 2) self.blankGlyph(x + width - 1, y + row);
            }
        }
    }

    fn blankGlyph(self: *CellGrid, x: usize, y: usize) void {
        const i = self.index(x, y);
        self.putSpace(x, y, .{ .fg = self.fg[i], .bg = self.bg[i], .attrs = self.attrs[i] });
    }

    /// Removes cell borders from a rectangle without touching glyphs or
    /// colors. Overlays such as a quick pick must call this where they paint,
    /// because the normal text/background primitives preserve a parent's
    /// border attribute (the terminal draws a pen-set border under/over text).
    pub fn clearBordersRect(self: *CellGrid, x: f64, y: f64, w: f64, h: f64) void {
        if (w <= 0 or h <= 0) return;
        const left = @min(self.cols, snap(x));
        const top = @min(self.rows, snap(y));
        const right = @min(self.cols, snap(x + w));
        const bottom = @min(self.rows, snap(y + h));
        var row = top;
        while (row < bottom) : (row += 1) {
            @memset(self.border[row * self.cols + left .. row * self.cols + right], 0);
        }
    }

    /// Copies a rectangle from `source` into this grid. Used by the TUI
    /// workbench to composite an editor pane below the tab strip.
    pub fn blit(
        self: *CellGrid,
        source: *const CellGrid,
        dest_col: usize,
        dest_row: usize,
        width: usize,
        height: usize,
    ) !void {
        if (dest_col >= self.cols or dest_row >= self.rows) return;
        const copy_width = @min(width, @min(source.cols, self.cols - dest_col));
        const copy_height = @min(height, @min(source.rows, self.rows - dest_row));
        var row: usize = 0;
        while (row < copy_height) : (row += 1) {
            const source_start = row * source.cols;
            const dest_start = (dest_row + row) * self.cols + dest_col;
            @memcpy(self.cluster[dest_start .. dest_start + copy_width], source.cluster[source_start .. source_start + copy_width]);
            @memcpy(self.fg[dest_start .. dest_start + copy_width], source.fg[source_start .. source_start + copy_width]);
            @memcpy(self.bg[dest_start .. dest_start + copy_width], source.bg[source_start .. source_start + copy_width]);
            @memcpy(self.attrs[dest_start .. dest_start + copy_width], source.attrs[source_start .. source_start + copy_width]);
            if (self.borders == source.borders) {
                @memcpy(self.border[dest_start .. dest_start + copy_width], source.border[source_start .. source_start + copy_width]);
            } else {
                var col: usize = 0;
                while (col < copy_width) : (col += 1) {
                    self.border[dest_start + col] = self.borders.remap(source.borders, source.border[source_start + col]);
                }
            }
            if (self.graphemes == source.graphemes) {
                @memcpy(self.grapheme[dest_start .. dest_start + copy_width], source.grapheme[source_start .. source_start + copy_width]);
            } else {
                var col: usize = 0;
                while (col < copy_width) : (col += 1) {
                    self.grapheme[dest_start + col] = try self.graphemes.remap(source.graphemes, source.grapheme[source_start + col]);
                }
            }
        }
    }

    pub fn rowHasContent(self: *const CellGrid, row: usize) bool {
        if (row >= self.rows) return false;
        const start = row * self.cols;
        for (
            self.cluster[start .. start + self.cols],
            self.grapheme[start .. start + self.cols],
            self.border[start .. start + self.cols],
        ) |c, grapheme_id, border| {
            if (c != 0 or grapheme_id != 0 or border != 0) return true;
        }
        return false;
    }

    pub fn sameCell(a: *const CellGrid, a_index: usize, b: *const CellGrid, b_index: usize) bool {
        return a.cluster[a_index] == b.cluster[b_index] and
            a.fg[a_index] == b.fg[b_index] and
            a.bg[a_index] == b.bg[b_index] and
            a.attrs[a_index] == b.attrs[b_index] and
            grapheme.Table.eql(a.graphemes, b.graphemes, a.grapheme[a_index], b.grapheme[b_index]) and
            sameBorder(a, a_index, b, b_index);
    }

    fn sameBorder(a: *const CellGrid, a_index: usize, b: *const CellGrid, b_index: usize) bool {
        const a_id = a.border[a_index];
        const b_id = b.border[b_index];
        if (a_id == b_id and a.borders == b.borders) return true;
        if (a_id == 0 or b_id == 0) return a_id == b_id;
        return a.borders.get(a_id).eql(b.borders.get(b_id).*);
    }

    /// Extracts a row as UTF-8, for tests and debugging.
    pub fn rowText(self: *const CellGrid, allocator: std.mem.Allocator, row: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (row < self.rows) {
            const start = row * self.cols;
            for (self.cluster[start .. start + self.cols], 0..) |c, col| {
                if (c == 0) continue;
                if (self.widthAt(col, row) == 0 and col > 0 and self.cluster[start + col - 1] != 0) {
                    // Should not happen; wide continuations are empty.
                    continue;
                }
                if (self.grapheme[start + col] != 0) {
                    try out.appendSlice(allocator, self.graphemes.get(self.grapheme[start + col]));
                    continue;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(c), &buf) catch {
                    try out.append(allocator, '?');
                    continue;
                };
                try out.appendSlice(allocator, buf[0..len]);
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn snap(value: f64) usize {
    if (!(value > 0)) return 0;
    return @intFromFloat(@round(value));
}

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

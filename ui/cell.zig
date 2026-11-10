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

    pub const width_shift: u4 = 8;
    pub const width_mask: u16 = 0b11 << width_shift;
    pub const style_mask: u16 = 0xff;
};

pub const PaintStyle = struct {
    fg: u32 = 0,
    bg: u32 = 0,
    attrs: u16 = 0,

    pub fn eql(a: PaintStyle, b: PaintStyle) bool {
        return a.fg == b.fg and a.bg == b.bg and a.attrs == b.attrs;
    }
};

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

pub const CellGrid = struct {
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
    /// Glyph scalar value. 0 = empty; continuation cells of a wide glyph are 0.
    cluster: []u32,
    fg: []u32,
    bg: []u32,
    attrs: []u16,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !CellGrid {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        const size = c * r;
        const cluster = try allocator.alloc(u32, size);
        errdefer allocator.free(cluster);
        const fg = try allocator.alloc(u32, size);
        errdefer allocator.free(fg);
        const bg = try allocator.alloc(u32, size);
        errdefer allocator.free(bg);
        const attrs = try allocator.alloc(u16, size);
        errdefer allocator.free(attrs);

        var grid = CellGrid{
            .allocator = allocator,
            .cols = c,
            .rows = r,
            .cluster = cluster,
            .fg = fg,
            .bg = bg,
            .attrs = attrs,
        };
        grid.clear();
        return grid;
    }

    pub fn deinit(self: *CellGrid) void {
        self.allocator.free(self.cluster);
        self.allocator.free(self.fg);
        self.allocator.free(self.bg);
        self.allocator.free(self.attrs);
    }

    pub fn clear(self: *CellGrid) void {
        @memset(self.cluster, 0);
        @memset(self.fg, 0);
        @memset(self.bg, 0);
        @memset(self.attrs, 0);
    }

    pub fn index(self: *const CellGrid, col: usize, row: usize) usize {
        return row * self.cols + col;
    }

    pub fn widthAt(self: *const CellGrid, col: usize, row: usize) usize {
        return (self.attrs[self.index(col, row)] & Attr.width_mask) >> Attr.width_shift;
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

    pub fn rowHasContent(self: *const CellGrid, row: usize) bool {
        if (row >= self.rows) return false;
        const start = row * self.cols;
        for (self.cluster[start .. start + self.cols]) |c| {
            if (c != 0) return true;
        }
        return false;
    }

    pub fn sameCell(a: *const CellGrid, a_index: usize, b: *const CellGrid, b_index: usize) bool {
        return a.cluster[a_index] == b.cluster[b_index] and
            a.fg[a_index] == b.fg[b_index] and
            a.bg[a_index] == b.bg[b_index] and
            a.attrs[a_index] == b.attrs[b_index];
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

test "packColor distinguishes black from default" {
    const black = packColor(.{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expect(black != 0);
    try std.testing.expectEqual(@as(u32, 0), 0);
    try std.testing.expect(style.Color.eql(.{ .r = 0, .g = 0, .b = 0 }, unpackColor(black)));
}

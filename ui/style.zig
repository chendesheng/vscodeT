//! Directly assigned styles for the terminal UI tree.
//!
//! There is no stylesheet and no class-based styling: the code that builds a
//! node writes these fields. One unit is one terminal cell.

const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// A length in layout units (terminal cells).
pub const Dimension = union(enum) {
    auto,
    cells: f64,
    percent: f64,
};

pub const Position = enum { static, relative, absolute, fixed };
pub const Display = enum { block, inline_, inline_block, none };
pub const Overflow = enum { visible, hidden, clip };
pub const TextAlign = enum { left, center, right };
pub const Visibility = enum { visible, hidden };

pub const Style = struct {
    position: Position = .static,
    top: Dimension = .auto,
    right: Dimension = .auto,
    bottom: Dimension = .auto,
    left: Dimension = .auto,

    width: Dimension = .auto,
    height: Dimension = .auto,

    display: Display = .block,
    overflow: Overflow = .visible,
    text_align: TextAlign = .left,
    visibility: Visibility = .visible,

    color: ?Color = null,
    background: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    reverse: bool = false,

    z_index: i32 = 0,
    translate_x: f64 = 0,
    translate_y: f64 = 0,
};

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn right(self: Rect) f64 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) f64 {
        return self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        return .{
            .x = x0,
            .y = y0,
            .w = @max(0, x1 - x0),
            .h = @max(0, y1 - y0),
        };
    }
};

test "Rect intersects and clamps" {
    const r = Rect.intersect(
        .{ .x = 0, .y = 0, .w = 10, .h = 5 },
        .{ .x = 5, .y = 3, .w = 10, .h = 5 },
    );
    try std.testing.expectEqual(@as(f64, 5), r.x);
    try std.testing.expectEqual(@as(f64, 3), r.y);
    try std.testing.expectEqual(@as(f64, 5), r.w);
    try std.testing.expectEqual(@as(f64, 2), r.h);
}

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

pub const Edges = struct {
    top: f64 = 0,
    right: f64 = 0,
    bottom: f64 = 0,
    left: f64 = 0,

    pub fn all(value: f64) Edges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn horizontal(self: Edges) f64 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) f64 {
        return self.top + self.bottom;
    }

    pub fn nonNegative(self: Edges) Edges {
        return .{
            .top = @max(0, self.top),
            .right = @max(0, self.right),
            .bottom = @max(0, self.bottom),
            .left = @max(0, self.left),
        };
    }
};

pub const BorderStyle = enum { none, single };

pub const Position = enum { static, relative, absolute, fixed };
pub const Display = enum { block, inline_, inline_block, flex, inline_flex, contents, none };
pub const Overflow = enum { visible, hidden, clip };
pub const TextAlign = enum { left, center, right };
pub const Visibility = enum { visible, hidden };

/// CSS `white-space` values, a subset supported by the terminal text engine.
/// `normal` is the initial value and wraps; the preserving values keep their
/// own spaces, the collapsing values fold ASCII whitespace runs to one space.
pub const WhiteSpace = enum { normal, nowrap, pre, pre_wrap, pre_line, break_spaces };

/// CSS `word-break`. `keep_all` suppresses soft wrapping for the text it
/// styles; `break_all` and `break_word` allow breaking inside a word.
pub const WordBreak = enum { normal, break_all, keep_all, break_word };

/// CSS `overflow-wrap`: whether an otherwise unbreakable word may be broken to
/// avoid overflowing its line.
pub const OverflowWrap = enum { normal, break_word, anywhere };

/// The inherited text properties resolved for a box. `Style` keeps the
/// optional overrides; a layout box stores the result so text and nested
/// inline boxes inherit the nearest declaration.
pub const TextStyle = struct {
    white_space: WhiteSpace = .normal,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,

    pub fn resolve(parent: TextStyle, own: Style) TextStyle {
        return .{
            .white_space = own.white_space orelse parent.white_space,
            .word_break = own.word_break orelse parent.word_break,
            .overflow_wrap = own.overflow_wrap orelse parent.overflow_wrap,
        };
    }

    pub fn resolveFlow(parent: TextStyle, flow: TextFlow) TextStyle {
        return .{
            .white_space = flow.white_space orelse parent.white_space,
            .word_break = flow.word_break orelse parent.word_break,
            .overflow_wrap = flow.overflow_wrap orelse parent.overflow_wrap,
        };
    }

    pub fn preservesSpaces(self: TextStyle) bool {
        return switch (self.white_space) {
            .pre, .pre_wrap, .break_spaces => true,
            else => false,
        };
    }

    pub fn preservesNewlines(self: TextStyle) bool {
        return switch (self.white_space) {
            .pre, .pre_wrap, .pre_line, .break_spaces => true,
            else => false,
        };
    }

    pub fn suppressesWrap(self: TextStyle) bool {
        return self.white_space == .nowrap or
            self.white_space == .pre or
            self.word_break == .keep_all;
    }
};

/// A margin edge is either a fixed cell length or `auto`; auto margins absorb
/// free space in a flex line (css-flexbox-1 §8.1) and center a definite-width
/// block horizontally.
pub const MarginEdge = union(enum) {
    cells: f64,
    auto,

    /// The numeric value, with `auto` resolved to zero. Callers that care
    /// about auto margins check `isAuto` first.
    pub fn resolve(self: MarginEdge) f64 {
        return switch (self) {
            .cells => |value| value,
            .auto => 0,
        };
    }

    pub fn isAuto(self: MarginEdge) bool {
        return self == .auto;
    }
};

/// Space outside the border box. Unlike `Edges`, each side can be `auto`.
pub const Margin = struct {
    top: MarginEdge = .{ .cells = 0 },
    right: MarginEdge = .{ .cells = 0 },
    bottom: MarginEdge = .{ .cells = 0 },
    left: MarginEdge = .{ .cells = 0 },

    pub fn all(value: f64) Margin {
        return .{
            .top = .{ .cells = value },
            .right = .{ .cells = value },
            .bottom = .{ .cells = value },
            .left = .{ .cells = value },
        };
    }

    /// Numeric horizontal margins, with auto counted as zero.
    pub fn horizontal(self: Margin) f64 {
        return self.left.resolve() + self.right.resolve();
    }

    /// Numeric vertical margins, with auto counted as zero.
    pub fn vertical(self: Margin) f64 {
        return self.top.resolve() + self.bottom.resolve();
    }

    pub fn hasAuto(self: Margin) bool {
        return self.top.isAuto() or self.right.isAuto() or
            self.bottom.isAuto() or self.left.isAuto();
    }
};

/// Row and column gaps between flex lines and flex items, in cells.
pub const Gap = struct {
    row: f64 = 0,
    column: f64 = 0,

    pub fn all(value: f64) Gap {
        return .{ .row = value, .column = value };
    }
};

pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
pub const JustifyContent = enum {
    flex_start,
    center,
    flex_end,
    space_between,
    space_around,
    space_evenly,
};
pub const AlignItems = enum { stretch, flex_start, center, flex_end, baseline };
pub const AlignSelf = enum { auto, stretch, flex_start, center, flex_end, baseline };
pub const AlignContent = enum {
    stretch,
    flex_start,
    center,
    flex_end,
    space_between,
    space_around,
    space_evenly,
};

pub const Style = struct {
    position: Position = .static,
    top: Dimension = .auto,
    right: Dimension = .auto,
    bottom: Dimension = .auto,
    left: Dimension = .auto,

    width: Dimension = .auto,
    height: Dimension = .auto,
    /// Content-box width bounds. `auto` places no bound on that side. When both
    /// resolve, the minimum wins. Percentages resolve against the containing
    /// block's content width; intrinsic measurement ignores percentage bounds.
    min_width: Dimension = .auto,
    max_width: Dimension = .auto,

    /// Space outside the border box. Negative margins are allowed; `auto`
    /// margins absorb free space in a flex line or center a block.
    margin: Margin = .{},
    /// Space between the border and the content box.
    padding: Edges = .{},
    /// Border widths. Zero by default; with `border_style == .single` they are
    /// drawn with box-drawing characters.
    border: Edges = .{},
    border_style: BorderStyle = .single,
    border_color: ?Color = null,

    display: Display = .block,
    overflow: Overflow = .visible,
    text_align: TextAlign = .left,
    visibility: Visibility = .visible,

    /// Inherited text-flow properties. `null` inherits the resolved value of
    /// the parent box; the viewport root resolves them to the initial values.
    white_space: ?WhiteSpace = null,
    word_break: ?WordBreak = null,
    overflow_wrap: ?OverflowWrap = null,

    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .stretch,
    align_self: AlignSelf = .auto,
    align_content: AlignContent = .stretch,
    flex_grow: f64 = 0,
    flex_shrink: f64 = 1,
    /// The initial main size. `auto` falls back to the item's main-axis
    /// `width`/`height`, then to its content size.
    flex_basis: Dimension = .auto,
    /// Order-modified document order for flex items. Lower values lay out and
    /// paint first; equal values keep document order.
    order: i32 = 0,
    gap: Gap = .{},

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

/// The paint-only subset of `Style`: what a text run/span contributes to the
/// cell style (the browser's CSS class properties). Layout properties stay on
/// `Element.style`/`LayoutBox.style`; text nodes carry this small value or a
/// shared reference to one.
pub const PaintStyle = struct {
    color: ?Color = null,
    background: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    reverse: bool = false,

    pub fn eql(a: PaintStyle, b: PaintStyle) bool {
        return std.meta.eql(a, b);
    }
};

/// Text-flow overrides carried by a text node (extracted from `Style`). They
/// resolve against the parent box's `TextStyle`.
pub const TextFlow = struct {
    white_space: ?WhiteSpace = null,
    word_break: ?WordBreak = null,
    overflow_wrap: ?OverflowWrap = null,
};

pub fn paintStyleOf(style: Style) PaintStyle {
    return .{
        .color = style.color,
        .background = style.background,
        .bold = style.bold,
        .italic = style.italic,
        .underline = style.underline,
        .strikethrough = style.strikethrough,
        .dim = style.dim,
        .reverse = style.reverse,
    };
}

pub fn textFlowOf(style: Style) TextFlow {
    return .{
        .white_space = style.white_space,
        .word_break = style.word_break,
        .overflow_wrap = style.overflow_wrap,
    };
}

pub fn borderWidths(style: Style) Edges {
    if (style.border_style == .none) return .{};
    return style.border.nonNegative();
}

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

    pub fn inset(self: Rect, edges: Edges) Rect {
        return .{
            .x = self.x + edges.left,
            .y = self.y + edges.top,
            .w = @max(0, self.w - edges.left - edges.right),
            .h = @max(0, self.h - edges.top - edges.bottom),
        };
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

test "Margin and Gap helpers" {
    const margin = Margin.all(2);
    try std.testing.expectEqual(@as(f64, 4), margin.horizontal());
    try std.testing.expectEqual(@as(f64, 4), margin.vertical());
    try std.testing.expect(!margin.hasAuto());

    const auto_margin = Margin{ .left = .auto, .right = .auto };
    try std.testing.expect(auto_margin.hasAuto());
    try std.testing.expectEqual(@as(f64, 0), auto_margin.left.resolve());

    const gap = Gap.all(1);
    try std.testing.expectEqual(@as(f64, 1), gap.row);
    try std.testing.expectEqual(@as(f64, 1), gap.column);
}

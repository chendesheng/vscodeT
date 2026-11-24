//! Style declarations and computed styles for the terminal UI tree.
//!
//! `Style` is an authored declaration: every field is optional, and an unset
//! field means "not specified". `ComputedStyle` is the resolved value a box
//! uses: non-inherited properties fall back to their initial value, inherited
//! properties come from the parent's computed value.
//!
//! Paint properties intentionally stay declarations in `ComputedStyle`; the
//! painter inherits them down the live box chain so hover overlays compose.
//! Class styles live in the document's array-backed stylesheet (`css.zig`).

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

/// Per-side declaration for padding and border widths. Sides left unset keep
/// the value contributed by an earlier class (or the initial zero).
pub const EdgeDecl = struct {
    top: ?f64 = null,
    right: ?f64 = null,
    bottom: ?f64 = null,
    left: ?f64 = null,

    pub fn all(value: f64) EdgeDecl {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};

/// Rounded is the terminal representation of a single stroke with rounded corners.
pub const BorderStyle = enum { none, single, rounded };

/// The mouse pointer shape requested by an element, matching the CSS `cursor`
/// names that kitty's OSC 22 protocol standardizes. `Style.pointer` is
/// inherited: `null` keeps the parent's computed shape, `.default` overrides
/// an inherited shape back to the terminal default. The terminal protocol and
/// encoding live in `pointer.zig`.
pub const Pointer = enum {
    default,
    alias,
    cell,
    copy,
    crosshair,
    e_resize,
    ew_resize,
    grab,
    grabbing,
    help,
    move,
    n_resize,
    ne_resize,
    nesw_resize,
    no_drop,
    not_allowed,
    ns_resize,
    nw_resize,
    nwse_resize,
    pointer,
    progress,
    s_resize,
    se_resize,
    sw_resize,
    text,
    vertical_text,
    w_resize,
    wait,
    zoom_in,
    zoom_out,
};

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

/// The inherited text properties resolved for a box. `ComputedStyle` keeps the
/// optional overrides; a layout box stores the result so text and nested
/// inline boxes inherit the nearest declaration.
pub const TextStyle = struct {
    white_space: WhiteSpace = .normal,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,
    text_align: TextAlign = .left,

    pub fn fromComputed(computed: ComputedStyle) TextStyle {
        return .{
            .white_space = computed.white_space,
            .word_break = computed.word_break,
            .overflow_wrap = computed.overflow_wrap,
            .text_align = computed.text_align,
        };
    }

    pub fn resolveFlow(parent: TextStyle, flow: TextFlow) TextStyle {
        return .{
            .white_space = flow.white_space orelse parent.white_space,
            .word_break = flow.word_break orelse parent.word_break,
            .overflow_wrap = flow.overflow_wrap orelse parent.overflow_wrap,
            .text_align = parent.text_align,
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

/// Per-side margin declaration for class merging.
pub const MarginDecl = struct {
    top: ?MarginEdge = null,
    right: ?MarginEdge = null,
    bottom: ?MarginEdge = null,
    left: ?MarginEdge = null,

    pub fn all(value: f64) MarginDecl {
        return .{
            .top = .{ .cells = value },
            .right = .{ .cells = value },
            .bottom = .{ .cells = value },
            .left = .{ .cells = value },
        };
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

/// Per-axis gap declaration for class merging.
pub const GapDecl = struct {
    row: ?f64 = null,
    column: ?f64 = null,

    pub fn all(value: f64) GapDecl {
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

/// Terminal text-decoration underline shapes (ECMA-48 SGR 4 subparameters).
/// `single` is the fallback every terminal understands; `curly` approximates
/// the browser's wavy squiggle. The value is stored in the cell attribute
/// field, so keep the numeric order stable.
pub const UnderlineStyle = enum(u3) {
    single = 0,
    double = 1,
    curly = 2,
    dotted = 3,
    dashed = 4,
};

/// An authored style declaration. Unset fields are not specified; class
/// declarations merge in order, then the inline `Element.style` wins.
pub const Style = struct {
    position: ?Position = null,
    top: ?Dimension = null,
    right: ?Dimension = null,
    bottom: ?Dimension = null,
    left: ?Dimension = null,

    width: ?Dimension = null,
    height: ?Dimension = null,
    min_width: ?Dimension = null,
    max_width: ?Dimension = null,

    margin: ?MarginDecl = null,
    padding: ?EdgeDecl = null,
    border: ?EdgeDecl = null,
    border_style: ?BorderStyle = null,
    border_color: ?Color = null,

    display: ?Display = null,
    overflow: ?Overflow = null,
    text_align: ?TextAlign = null,
    visibility: ?Visibility = null,

    white_space: ?WhiteSpace = null,
    word_break: ?WordBreak = null,
    overflow_wrap: ?OverflowWrap = null,

    flex_direction: ?FlexDirection = null,
    flex_wrap: ?FlexWrap = null,
    justify_content: ?JustifyContent = null,
    align_items: ?AlignItems = null,
    align_self: ?AlignSelf = null,
    align_content: ?AlignContent = null,
    flex_grow: ?f64 = null,
    flex_shrink: ?f64 = null,
    flex_basis: ?Dimension = null,
    order: ?i32 = null,
    gap: ?GapDecl = null,

    color: ?Color = null,
    background: ?Color = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    underline_style: ?UnderlineStyle = null,
    strikethrough: ?bool = null,
    dim: ?bool = null,
    reverse: ?bool = null,

    pointer: ?Pointer = null,

    z_index: ?i32 = null,
    translate_x: ?f64 = null,
    translate_y: ?f64 = null,

    /// Merge `over` on top of `base`: later non-null declarations win, and
    /// per-side box declarations merge side by side.
    pub fn merge(base: Style, over: Style) Style {
        var result = base;
        const info = @typeInfo(Style).@"struct";
        inline for (info.field_names, info.field_types) |name, FieldType| {
            if (comptime isPartialStruct(FieldType)) {
                @field(result, name) = mergePartialStruct(
                    @field(base, name),
                    @field(over, name),
                );
            } else if (@field(over, name)) |value| {
                @field(result, name) = value;
            }
        }
        return result;
    }

    pub fn mergeAll(styles: []const Style) Style {
        var result = Style{};
        for (styles) |style| result = merge(result, style);
        return result;
    }

    /// Resolve this declaration against the parent computed style. Inherited
    /// fields fall back to the parent, everything else to the initial value.
    pub fn resolve(self: Style, parent: ComputedStyle, default_display: Display) ComputedStyle {
        const initial = ComputedStyle.initial(default_display);
        var result = initial;

        result.margin = resolveMargin(self.margin, initial.margin);
        result.padding = resolveEdges(self.padding, initial.padding);
        result.border = resolveEdges(self.border, initial.border);
        result.gap = resolveGap(self.gap, initial.gap);

        const info = @typeInfo(ComputedStyle).@"struct";
        inline for (info.field_names, info.field_types) |name, ComputedType| {
            if (comptime isBoxField(name)) continue;
            const DeclType = @FieldType(Style, name);
            if (comptime DeclType == ComputedType) {
                // Paint/optional declarations stay declarations in the
                // computed style; the painter inherits them down the tree.
                @field(result, name) = @field(self, name);
            } else if (@field(self, name)) |value| {
                @field(result, name) = value;
            } else if (comptime isInherited(name)) {
                @field(result, name) = @field(parent, name);
            }
        }
        return result;
    }
};

/// The resolved style carried by a layout box. Layout, text-flow, pointer and
/// visibility properties are computed; paint properties stay declarations and
/// are resolved by the paint pass (so hover overlays keep working).
pub const ComputedStyle = struct {
    position: Position = .static,
    top: Dimension = .auto,
    right: Dimension = .auto,
    bottom: Dimension = .auto,
    left: Dimension = .auto,

    width: Dimension = .auto,
    height: Dimension = .auto,
    min_width: Dimension = .auto,
    max_width: Dimension = .auto,

    margin: Margin = .{},
    padding: Edges = .{},
    border: Edges = .{},
    border_style: BorderStyle = .single,
    border_color: ?Color = null,

    display: Display = .block,
    overflow: Overflow = .visible,
    text_align: TextAlign = .left,
    visibility: Visibility = .visible,

    white_space: WhiteSpace = .normal,
    word_break: WordBreak = .normal,
    overflow_wrap: OverflowWrap = .normal,

    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .stretch,
    align_self: AlignSelf = .auto,
    align_content: AlignContent = .stretch,
    flex_grow: f64 = 0,
    flex_shrink: f64 = 1,
    flex_basis: Dimension = .auto,
    order: i32 = 0,
    gap: Gap = .{},

    color: ?Color = null,
    background: ?Color = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    underline_style: ?UnderlineStyle = null,
    strikethrough: ?bool = null,
    dim: ?bool = null,
    reverse: ?bool = null,

    pointer: Pointer = .default,

    z_index: i32 = 0,
    translate_x: f64 = 0,
    translate_y: f64 = 0,

    pub fn initial(display: Display) ComputedStyle {
        var result = ComputedStyle{};
        result.display = display;
        return result;
    }
};

fn isBoxField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "margin") or
        std.mem.eql(u8, name, "padding") or
        std.mem.eql(u8, name, "border") or
        std.mem.eql(u8, name, "gap");
}

fn isInherited(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "text_align") or
        std.mem.eql(u8, name, "visibility") or
        std.mem.eql(u8, name, "white_space") or
        std.mem.eql(u8, name, "word_break") or
        std.mem.eql(u8, name, "overflow_wrap") or
        std.mem.eql(u8, name, "pointer");
}

fn resolveEdges(declaration: ?EdgeDecl, fallback: Edges) Edges {
    const decl = declaration orelse return fallback;
    return .{
        .top = decl.top orelse fallback.top,
        .right = decl.right orelse fallback.right,
        .bottom = decl.bottom orelse fallback.bottom,
        .left = decl.left orelse fallback.left,
    };
}

fn resolveMargin(declaration: ?MarginDecl, fallback: Margin) Margin {
    const decl = declaration orelse return fallback;
    return .{
        .top = decl.top orelse fallback.top,
        .right = decl.right orelse fallback.right,
        .bottom = decl.bottom orelse fallback.bottom,
        .left = decl.left orelse fallback.left,
    };
}

fn resolveGap(declaration: ?GapDecl, fallback: Gap) Gap {
    const decl = declaration orelse return fallback;
    return .{
        .row = decl.row orelse fallback.row,
        .column = decl.column orelse fallback.column,
    };
}

fn isPartialStruct(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .optional => |opt| {
            switch (@typeInfo(opt.child)) {
                .@"struct" => |inner| {
                    for (inner.field_types) |FieldType| {
                        if (@typeInfo(FieldType) != .optional) return false;
                    }
                    return true;
                },
                else => return false,
            }
        },
        else => return false,
    }
}

fn mergePartialStruct(base: anytype, over: @TypeOf(base)) @TypeOf(base) {
    if (over == null) return base;
    if (base == null) return over;
    const Inner = @typeInfo(@TypeOf(base)).optional.child;
    var result = base.?;
    const info = @typeInfo(Inner).@"struct";
    inline for (info.field_names, info.field_types) |name, FieldType| {
        _ = FieldType;
        if (@field(over.?, name)) |value| {
            @field(result, name) = value;
        }
    }
    return result;
}

/// The paint-only subset of `Style`: what a text run/span contributes to the
/// cell style. `null` booleans are unspecified and inherit from the parent.
pub const PaintStyle = struct {
    color: ?Color = null,
    background: ?Color = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    underline_style: UnderlineStyle = .single,
    strikethrough: ?bool = null,
    dim: ?bool = null,
    reverse: ?bool = null,

    pub fn eql(a: PaintStyle, b: PaintStyle) bool {
        return std.meta.eql(a, b);
    }
};

/// Paint-only overrides applied while an element is in the hover chain
/// (`Element.hover_style`). Every field is optional so a declaration is a
/// delta: `null` keeps the element's own value, while `false` clears a
/// boolean attribute. No property here affects layout: hover is applied by the
/// painter and never dirties or re-runs layout.
pub const HoverStyle = struct {
    color: ?Color = null,
    background: ?Color = null,
    border_color: ?Color = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    underline_style: UnderlineStyle = .single,
    strikethrough: ?bool = null,
    dim: ?bool = null,
    reverse: ?bool = null,
    /// Paint visibility for this element and its descendants while it is
    /// hovered. Unlike the other paint deltas this deliberately beats a
    /// descendant's own `visibility` declaration, so it can express upstream
    /// rules such as `.parent:hover .child { opacity: 1 }`: the child keeps
    /// its layout and hit box but only paints during hover. `null` keeps the
    /// computed value. This is still paint-only; layout and hit testing never
    /// depend on it.
    visibility: ?Visibility = null,
};

/// Text-flow overrides carried by a text node. They resolve against the parent
/// box's `TextStyle`.
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
        .underline_style = style.underline_style orelse .single,
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

/// Accumulate the inherited paint declarations of a style-only ancestor
/// (`display: contents`) into the paint delta of its box descendants.
pub fn paintInherit(base: PaintStyle, computed: ComputedStyle) PaintStyle {
    var result = base;
    if (computed.color) |color| result.color = color;
    if (computed.bold) |value| result.bold = value;
    if (computed.italic) |value| result.italic = value;
    if (computed.underline) |value| result.underline = value;
    if (computed.underline_style) |value| result.underline_style = value;
    if (computed.strikethrough) |value| result.strikethrough = value;
    if (computed.dim) |value| result.dim = value;
    if (computed.reverse) |value| result.reverse = value;
    return result;
}

pub fn borderWidths(style: ComputedStyle) Edges {
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

test "Style.merge: later class wins and unset fields keep the base" {
    const base = Style{
        .color = .{ .r = 1, .g = 2, .b = 3 },
        .margin = .{ .left = .{ .cells = 2 } },
        .bold = true,
    };
    const over = Style{
        .color = .{ .r = 4, .g = 5, .b = 6 },
        .margin = .{ .top = .{ .cells = 1 } },
    };
    const merged = Style.merge(base, over);
    try std.testing.expect(merged.color.?.eql(.{ .r = 4, .g = 5, .b = 6 }));
    try std.testing.expectEqual(@as(f64, 2), merged.margin.?.left.?.resolve());
    try std.testing.expectEqual(@as(f64, 1), merged.margin.?.top.?.resolve());
    try std.testing.expectEqual(@as(?bool, true), merged.bold);
}

test "Style.resolve: inherited and initial values" {
    const parent = (Style{
        .text_align = .center,
        .visibility = .hidden,
        .white_space = .pre,
        .pointer = .pointer,
        .width = .{ .cells = 20 },
        .color = .{ .r = 9, .g = 8, .b = 7 },
    }).resolve(ComputedStyle.initial(.block), .block);

    const child = (Style{}).resolve(parent, .inline_);
    try std.testing.expectEqual(TextAlign.center, child.text_align);
    try std.testing.expectEqual(Visibility.hidden, child.visibility);
    try std.testing.expectEqual(WhiteSpace.pre, child.white_space);
    try std.testing.expectEqual(Pointer.pointer, child.pointer);
    // Non-inherited properties use their initial value.
    try std.testing.expectEqual(Dimension.auto, child.width);
    try std.testing.expectEqual(Display.inline_, child.display);
    // Paint stays a declaration for the painter.
    try std.testing.expectEqual(@as(?Color, null), child.color);

    const overridden = (Style{ .text_align = .left, .pointer = .default }).resolve(parent, .block);
    try std.testing.expectEqual(TextAlign.left, overridden.text_align);
    try std.testing.expectEqual(Pointer.default, overridden.pointer);
}

test "Style.resolve: per-side box declarations" {
    const child = (Style{
        .margin = .{ .left = .{ .cells = 2 } },
        .padding = .{ .top = 1 },
        .border = .{ .bottom = 3 },
        .gap = .{ .column = 4 },
    }).resolve(ComputedStyle.initial(.block), .block);
    try std.testing.expectEqual(@as(f64, 2), child.margin.left.resolve());
    try std.testing.expectEqual(@as(f64, 0), child.margin.top.resolve());
    try std.testing.expectEqual(@as(f64, 1), child.padding.top);
    try std.testing.expectEqual(@as(f64, 0), child.padding.left);
    try std.testing.expectEqual(@as(f64, 3), child.border.bottom);
    try std.testing.expectEqual(@as(f64, 4), child.gap.column);
    try std.testing.expectEqual(@as(f64, 0), child.gap.row);
}

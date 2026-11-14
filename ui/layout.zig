//! Whole-cell layout over the derived box tree.
//!
//! The solver never touches the DOM. It computes `LayoutBox` geometry and
//! copies the border box back to the DOM nodes only for the measurement
//! boundary.
//!
//! Supported box model: content box (`width`/`height`), padding, border and
//! margin, with absolute `left`/`top` anchoring the margin box, block flow,
//! inline text flow, and flex formatting contexts. The flex pass follows
//! css-flexbox-1 §9 and TermDOM's `layoutsolver` shape (direction, wrap,
//! grow/shrink/basis, justify/align, gap, order and auto margins); it is a
//! reimplementation in Zig over this library's box tree.
//!
//! Inline text flow lives in `text_layout.zig`: UAX #14 line breaking, the
//! `white-space` family, `word-break`/`overflow-wrap`, line alignment and
//! fragments. This file only collects leaves and places atomic inline boxes.
//!
//! There is no min/max sizing, grid, table boxes or incremental box reuse yet.
//! Flex items shrink to a zero content size rather than to an automatic
//! min-content floor. `position: fixed` still resolves like `absolute`, as it
//! did before flex was added.

const std = @import("std");
const box = @import("box.zig");
const dom = @import("dom.zig");
const linebreak = @import("linebreak.zig");
const style_mod = @import("style.zig");
const text_layout = @import("text_layout.zig");

pub const Rect = style_mod.Rect;
pub const Style = style_mod.Style;
pub const Dimension = style_mod.Dimension;
pub const Edges = style_mod.Edges;
pub const LayoutBox = box.LayoutBox;
pub const BoxTree = box.BoxTree;

/// The solver only allocates temporary flex lists.
const LayoutError = error{OutOfMemory};

/// Convenience for tests and one-shot callers: build a box tree, solve it and
/// copy the geometry back to the DOM nodes.
pub fn layoutDocument(doc: *dom.Document) !void {
    var tree = try BoxTree.init(doc.allocator);
    defer tree.deinit();
    try tree.rebuild(doc);
    try layoutTree(&tree, doc);
}

pub fn layoutTree(tree: *BoxTree, doc: *dom.Document) LayoutError!void {
    _ = tree.scratch.reset(.retain_capacity);
    var ctx = LayoutContext{
        .doc = doc,
        .allocator = tree.scratch.allocator(),
        .tables = try linebreak.LineBreakTables.init(tree.scratch.allocator()),
    };
    defer ctx.tables.deinit();

    const viewport = Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(doc.cols),
        .h = @floatFromInt(doc.rows),
    };
    tree.root.rect = viewport;
    tree.root.padding_rect = viewport;
    tree.root.content_rect = viewport;
    _ = try layoutBlockChildren(&ctx, tree.root, viewport, null);
    try layoutOutOfFlow(&ctx, tree.root, viewport);
    copyRects(tree.root);
    tree.clearNeedsLayout();
}

const Sizing = enum { definite, shrink_to_fit, indefinite };

const Constraints = struct {
    /// Space available to the margin box.
    width: f64 = 0,
    width_sizing: Sizing = .indefinite,
    height: f64 = 0,
    height_sizing: Sizing = .indefinite,
    /// Containing block content sizes, for percentage resolution.
    owner_width: f64 = 0,
    owner_height: ?f64 = null,
};

/// Content-box sizes imposed by a flex container or an explicit caller.
const Forced = struct {
    width: ?f64 = null,
    height: ?f64 = null,
};

const Size = struct {
    width: f64 = 0,
    height: f64 = 0,
};

const LayoutContext = struct {
    doc: *dom.Document,
    allocator: std.mem.Allocator,
    tables: linebreak.LineBreakTables,
};

const ResolvedMargins = struct {
    top: f64,
    right: f64,
    bottom: f64,
    left: f64,
    top_auto: bool,
    right_auto: bool,
    bottom_auto: bool,
    left_auto: bool,

    fn horizontal(self: ResolvedMargins) f64 {
        return self.left + self.right;
    }

    fn vertical(self: ResolvedMargins) f64 {
        return self.top + self.bottom;
    }

    fn main(self: ResolvedMargins, row: bool) f64 {
        return if (row) self.horizontal() else self.vertical();
    }

    fn cross(self: ResolvedMargins, row: bool) f64 {
        return if (row) self.vertical() else self.horizontal();
    }

    fn mainLead(self: ResolvedMargins, row: bool) f64 {
        return if (row) self.left else self.top;
    }

    fn mainTrail(self: ResolvedMargins, row: bool) f64 {
        return if (row) self.right else self.bottom;
    }

    fn crossLead(self: ResolvedMargins, row: bool) f64 {
        return if (row) self.top else self.left;
    }

    fn crossTrail(self: ResolvedMargins, row: bool) f64 {
        return if (row) self.bottom else self.right;
    }

    fn mainLeadAuto(self: ResolvedMargins, row: bool) bool {
        return if (row) self.left_auto else self.top_auto;
    }

    fn mainTrailAuto(self: ResolvedMargins, row: bool) bool {
        return if (row) self.right_auto else self.bottom_auto;
    }

    fn crossLeadAuto(self: ResolvedMargins, row: bool) bool {
        return if (row) self.top_auto else self.left_auto;
    }

    fn crossTrailAuto(self: ResolvedMargins, row: bool) bool {
        return if (row) self.bottom_auto else self.right_auto;
    }
};

fn resolveDimension(dimension: Dimension, base: ?f64) ?f64 {
    return switch (dimension) {
        .auto => null,
        .cells => |value| value,
        .percent => |percent| if (base) |value| value * percent / 100.0 else null,
    };
}

pub fn resolve(dimension: Dimension, base: f64) ?f64 {
    return resolveDimension(dimension, base);
}

fn resolveMargins(margin: style_mod.Margin) ResolvedMargins {
    return .{
        .top = margin.top.resolve(),
        .right = margin.right.resolve(),
        .bottom = margin.bottom.resolve(),
        .left = margin.left.resolve(),
        .top_auto = margin.top.isAuto(),
        .right_auto = margin.right.isAuto(),
        .bottom_auto = margin.bottom.isAuto(),
        .left_auto = margin.left.isAuto(),
    };
}

fn isOutOfFlow(style: Style) bool {
    return style.position == .absolute or style.position == .fixed;
}

fn isFlexContainer(style: Style) bool {
    return style.display == .flex or style.display == .inline_flex;
}

fn axisIsRow(style: Style) bool {
    return style.flex_direction == .row or style.flex_direction == .row_reverse;
}

fn axisIsReverse(style: Style) bool {
    return style.flex_direction == .row_reverse or
        style.flex_direction == .column_reverse;
}

fn mainGap(style: Style) f64 {
    return @max(0, if (axisIsRow(style)) style.gap.column else style.gap.row);
}

fn crossGap(style: Style) f64 {
    return @max(0, if (axisIsRow(style)) style.gap.row else style.gap.column);
}

fn alignOffset(alignment: style_mod.TextAlign, container_width: f64, content_width: f64) f64 {
    return switch (alignment) {
        .left => 0,
        .center => @max(0, (container_width - content_width) / 2),
        .right => @max(0, container_width - content_width),
    };
}

fn zeroBox(current: *LayoutBox) void {
    current.rect = .{};
    current.padding_rect = .{};
    current.content_rect = .{};
}

const LeafList = std.ArrayList(text_layout.Leaf);

fn appendTextLeaf(ctx: *LayoutContext, current: *LayoutBox, leaves: *LeafList) !void {
    // A flex/table probe may have run this box before. The authoritative
    // fragments are the ones the placing pass writes.
    current.text_fragments = &.{};
    current.has_text_layout = true;
    current.rect = .{};
    current.padding_rect = .{};
    current.content_rect = .{};
    try leaves.append(ctx.allocator, .{ .text = .{
        .box = current,
        .data = current.text orelse "",
        .text_style = current.text_style,
    } });
}

fn measureAtomic(
    ctx: *LayoutContext,
    child: *LayoutBox,
    available_width: f64,
    owner_height: ?f64,
) LayoutError!text_layout.AtomicLeaf {
    const margin = resolveMargins(child.style.margin);
    const padding = child.style.padding.nonNegative();
    const border = style_mod.borderWidths(child.style);
    const extra_width = padding.horizontal() + border.horizontal();
    const inner = @max(0, available_width - margin.horizontal() - extra_width);
    const content = resolveDimension(child.style.width, available_width) orelse
        @max(0, @min(contentMaxWidth(ctx, child), inner));
    const size = try layoutElement(
        ctx,
        child,
        0,
        0,
        .{
            .width = inner,
            .width_sizing = .shrink_to_fit,
            .height_sizing = .indefinite,
            .owner_width = available_width,
            .owner_height = owner_height,
        },
        .{ .width = content },
    );
    return .{
        .box = child,
        .width = size.width + margin.horizontal(),
        .height = size.height,
        .baseline = firstBaseline(child),
        .margin_left = margin.left,
        .margin_right = margin.right,
    };
}

fn edgeWidth(style: style_mod.Style, side: text_layout.EdgeSide) f64 {
    const margin = resolveMargins(style.margin);
    const padding = style.padding.nonNegative();
    const border = style_mod.borderWidths(style);
    return switch (side) {
        .start => @max(0, margin.left + padding.left + border.left),
        .end => @max(0, margin.right + padding.right + border.right),
    };
}

/// Collects the leaves of an inline run. Text stays text; a non-atomic
/// `display: inline_` box contributes start/end edges and flattens its
/// children so its text breaks across lines. Inline blocks/flex boxes are
/// atomic inline items.
fn collectInlineLeaves(
    ctx: *LayoutContext,
    parent: *LayoutBox,
    available_width: f64,
    owner_height: ?f64,
    leaves: *LeafList,
) LayoutError!void {
    for (parent.children.items) |child| {
        if (child.style.display == .none or child.style.display == .contents) {
            zeroBox(child);
            continue;
        }
        if (isOutOfFlow(child.style)) continue;
        switch (child.kind) {
            .text => try appendTextLeaf(ctx, child, leaves),
            .element, .anonymous_flex_item, .anonymous_inline => {
                const inline_box = child.displayInline();
                if (inline_box) {
                    child.rect = .{};
                    child.padding_rect = .{};
                    child.content_rect = .{};
                    child.text_fragments = &.{};
                    child.has_text_layout = false;
                    child.inline_fragments = &.{};
                    const start_width = if (child.style.display == .inline_)
                        edgeWidth(child.style, .start)
                    else
                        0;
                    if (start_width > 0) {
                        try leaves.append(ctx.allocator, .{ .edge = .{
                            .box = child,
                            .margin = resolveMargins(child.style.margin).left,
                            .border = style_mod.borderWidths(child.style).left,
                            .padding = child.style.padding.nonNegative().left,
                            .side = .start,
                        } });
                    }
                    try collectInlineLeaves(ctx, child, available_width, owner_height, leaves);
                    const end_width = if (child.style.display == .inline_)
                        edgeWidth(child.style, .end)
                    else
                        0;
                    if (end_width > 0) {
                        try leaves.append(ctx.allocator, .{ .edge = .{
                            .box = child,
                            .margin = resolveMargins(child.style.margin).right,
                            .border = style_mod.borderWidths(child.style).right,
                            .padding = child.style.padding.nonNegative().right,
                            .side = .end,
                        } });
                    }
                } else {
                    const atomic = try measureAtomic(ctx, child, available_width, owner_height);
                    try leaves.append(ctx.allocator, .{ .atomic = atomic });
                }
            },
            .initial_containing_block => {},
        }
    }
}

fn addTextFragment(ctx: *LayoutContext, node_box: *LayoutBox, fragment: box.TextFragment) !void {
    const old = node_box.text_fragments;
    const next = try ctx.allocator.alloc(box.TextFragment, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = fragment;
    node_box.text_fragments = next;
}

fn addInlineFragment(ctx: *LayoutContext, node_box: *LayoutBox, fragment: box.InlineFragment) !void {
    const old = node_box.inline_fragments;
    const next = try ctx.allocator.alloc(box.InlineFragment, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = fragment;
    node_box.inline_fragments = next;
}

const InlineExtent = struct {
    box: *LayoutBox,
    min_x: f64,
    max_x: f64,
};

fn placeInlineFragments(ctx: *LayoutContext, run: *LayoutBox, wrapped: text_layout.Wrapped) !void {
    for (wrapped.lines) |line| {
        var extents: std.ArrayList(InlineExtent) = .empty;
        defer extents.deinit(ctx.allocator);
        for (line.segments) |segment| {
            if (segment.kind == .edge) continue;
            const left = segment.x;
            const right = segment.x + segment.width;
            var ancestor = segment.box.parent;
            while (ancestor) |current| : (ancestor = current.parent) {
                if (current == run) break;
                // Fragmented wrappers (including anonymous runs inside an
                // inline element) still need a non-empty box so the painter
                // descends into their fragments.
                current.rect = unionRect(current.rect, .{
                    .x = segment.x,
                    .y = segment.y,
                    .w = segment.width,
                    .h = 1,
                });
                if (current.kind != .element or current.style.display != .inline_) continue;
                var found = false;
                for (extents.items) |*extent| {
                    if (extent.box != current) continue;
                    extent.min_x = @min(extent.min_x, left);
                    extent.max_x = @max(extent.max_x, right);
                    found = true;
                    break;
                }
                if (!found) {
                    try extents.append(ctx.allocator, .{
                        .box = current,
                        .min_x = left,
                        .max_x = right,
                    });
                }
            }
        }
        for (extents.items) |extent| {
            const padding = extent.box.style.padding.nonNegative();
            const border = style_mod.borderWidths(extent.box.style);
            const rect = style_mod.Rect{
                .x = extent.min_x - padding.left - border.left,
                .y = line.y - padding.top - border.top,
                .w = @max(0, extent.max_x - extent.min_x) + padding.horizontal() + border.horizontal(),
                .h = line.height + padding.vertical() + border.vertical(),
            };
            try addInlineFragment(ctx, extent.box, .{
                .x = rect.x,
                .y = rect.y,
                .w = rect.w,
                .h = rect.h,
            });
            extent.box.rect = unionRect(extent.box.rect, rect);
            extent.box.padding_rect = extent.box.rect.inset(border);
            extent.box.content_rect = extent.box.padding_rect.inset(padding);
        }
    }
}

fn applyWrapped(
    ctx: *LayoutContext,
    run: *LayoutBox,
    wrapped: text_layout.Wrapped,
    x: f64,
    y: f64,
    available_width: f64,
) LayoutError!f64 {
    for (wrapped.lines) |line| {
        for (line.segments) |segment| {
            switch (segment.kind) {
                .text => {
                    try addTextFragment(ctx, segment.box, .{
                        .text = segment.text,
                        .x = segment.x,
                        .y = segment.y,
                        .width = segment.width,
                    });
                    const current = segment.box;
                    current.rect = unionRect(current.rect, .{
                        .x = segment.x,
                        .y = segment.y,
                        .w = segment.width,
                        .h = 1,
                    });
                    current.padding_rect = current.rect;
                    current.content_rect = current.rect;
                },
                .atomic => {
                    const child = segment.box;
                    const padding = child.style.padding.nonNegative();
                    const border = style_mod.borderWidths(child.style);
                    const content_width = @max(0, segment.width -
                        padding.horizontal() - border.horizontal());
                    _ = try layoutElement(
                        ctx,
                        child,
                        segment.x,
                        segment.y,
                        .{
                            .width = available_width,
                            .width_sizing = .indefinite,
                            .height_sizing = .indefinite,
                            .owner_width = available_width,
                            .owner_height = null,
                        },
                        .{ .width = content_width },
                    );
                },
                .edge => {},
            }
        }
    }

    try placeInlineFragments(ctx, run, wrapped);

    if (run.kind != .text) {
        run.rect = .{
            .x = x,
            .y = y,
            .w = if (wrapped.wrapped) available_width else wrapped.max_line_width,
            .h = wrapped.height,
        };
        run.padding_rect = run.rect;
        run.content_rect = run.rect;
    }
    return wrapped.height;
}

fn layoutInlineRun(
    ctx: *LayoutContext,
    run: *LayoutBox,
    x: f64,
    y: f64,
    available_width: f64,
    owner_height: ?f64,
) LayoutError!f64 {
    var leaves: LeafList = .empty;
    defer leaves.deinit(ctx.allocator);
    try collectInlineLeaves(ctx, run, available_width, owner_height, &leaves);
    if (leaves.items.len == 0) {
        zeroBox(run);
        return 0;
    }
    const wrapped = try text_layout.layoutRun(.{
        .allocator = ctx.allocator,
        .doc = ctx.doc,
        .tables = &ctx.tables,
        .text_style = run.text_style,
        .text_align = run.style.text_align,
        .max_width = available_width,
        .tab_size = ctx.doc.tab_size,
        .origin_x = x,
        .origin_y = y,
    }, leaves.items);
    return applyWrapped(ctx, run, wrapped, x, y, available_width);
}

fn layoutTextContent(
    ctx: *LayoutContext,
    current: *LayoutBox,
    x: f64,
    y: f64,
    available_width: f64,
    owner_height: ?f64,
    text_align: style_mod.TextAlign,
) LayoutError!f64 {
    var leaves: LeafList = .empty;
    defer leaves.deinit(ctx.allocator);
    _ = owner_height;
    try appendTextLeaf(ctx, current, &leaves);
    const wrapped = try text_layout.layoutRun(.{
        .allocator = ctx.allocator,
        .doc = ctx.doc,
        .tables = &ctx.tables,
        .text_style = current.text_style,
        .text_align = text_align,
        .max_width = available_width,
        .tab_size = ctx.doc.tab_size,
        .origin_x = x,
        .origin_y = y,
    }, leaves.items);
    return applyWrapped(ctx, current, wrapped, x, y, available_width);
}

fn unionRect(a: style_mod.Rect, b: style_mod.Rect) style_mod.Rect {
    if (a.w <= 0 or a.h <= 0) return b;
    if (b.w <= 0 or b.h <= 0) return a;
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(a.right(), b.right());
    const bottom = @max(a.bottom(), b.bottom());
    return .{ .x = left, .y = top, .w = right - left, .h = bottom - top };
}

/// Max-content width of the box's content (excluding padding, border and
/// margins). Percentages are treated as auto during intrinsic measurement.
/// Out-of-flow children do not contribute.
fn contentMaxWidth(ctx: *const LayoutContext, current: *const LayoutBox) f64 {
    switch (current.kind) {
        .initial_containing_block => return 0,
        .text => return text_layout.maxContentWidth(
            ctx.doc,
            current.text orelse "",
            current.text_style,
            ctx.doc.tab_size,
        ),
        .anonymous_inline => {
            var total: f64 = 0;
            for (current.children.items) |child| {
                if (!contributesToFlow(child)) continue;
                total += outerMaxWidth(ctx, child);
            }
            return total;
        },
        .element, .anonymous_flex_item => {
            if (current.style.width == .cells) {
                return current.style.width.cells;
            }
            const style = current.style;
            if (isFlexContainer(style)) {
                if (axisIsRow(style)) {
                    var total: f64 = 0;
                    var count: usize = 0;
                    for (current.children.items) |child| {
                        if (!contributesToFlow(child)) continue;
                        if (count > 0) total += mainGap(style);
                        total += flexItemOuterWidth(ctx, child);
                        count += 1;
                    }
                    return total;
                }
                var widest: f64 = 0;
                for (current.children.items) |child| {
                    if (!contributesToFlow(child)) continue;
                    widest = @max(widest, outerMaxWidth(ctx, child));
                }
                return widest;
            }
            var widest: f64 = 0;
            for (current.children.items) |child| {
                if (!contributesToFlow(child)) continue;
                widest = @max(widest, outerMaxWidth(ctx, child));
            }
            return widest;
        },
    }
}

fn contributesToFlow(current: *const LayoutBox) bool {
    return current.style.display != .none and
        current.style.display != .contents and
        !isOutOfFlow(current.style);
}

/// Border-box plus margin width, used for intrinsic flex and block sizing.
fn outerMaxWidth(ctx: *const LayoutContext, current: *const LayoutBox) f64 {
    switch (current.kind) {
        .initial_containing_block => return 0,
        .text => return text_layout.maxContentWidth(
            ctx.doc,
            current.text orelse "",
            current.text_style,
            ctx.doc.tab_size,
        ),
        .anonymous_inline => return contentMaxWidth(ctx, current),
        .element, .anonymous_flex_item => {
            const padding = current.style.padding.nonNegative();
            const border = style_mod.borderWidths(current.style);
            const margin = resolveMargins(current.style.margin);
            return contentMaxWidth(ctx, current) +
                padding.horizontal() + border.horizontal() + margin.horizontal();
        },
    }
}

/// Max-content outer width of a flex item, honouring a cell-valued
/// `flex_basis` the same way the flex pass does.
fn flexItemOuterWidth(ctx: *const LayoutContext, current: *const LayoutBox) f64 {
    const padding = current.style.padding.nonNegative();
    const border = style_mod.borderWidths(current.style);
    const margin = resolveMargins(current.style.margin);
    const content = switch (current.style.flex_basis) {
        .cells => |value| @max(0, value),
        else => contentMaxWidth(ctx, current),
    };
    return content + padding.horizontal() + border.horizontal() + margin.horizontal();
}

fn layoutBlockChildren(
    ctx: *LayoutContext,
    parent: *LayoutBox,
    content: Rect,
    owner_height: ?f64,
) LayoutError!f64 {
    var block_y = content.y;
    for (parent.children.items) |child| {
        if (child.style.display == .none or child.style.display == .contents) {
            zeroBox(child);
            continue;
        }
        if (isOutOfFlow(child.style)) continue;

        switch (child.kind) {
            .anonymous_inline => {
                block_y += try layoutInlineRun(
                    ctx,
                    child,
                    content.x,
                    block_y,
                    content.w,
                    owner_height,
                );
            },
            .text => {
                block_y += try layoutTextContent(
                    ctx,
                    child,
                    content.x,
                    block_y,
                    content.w,
                    owner_height,
                    parent.style.text_align,
                );
            },
            .element, .anonymous_flex_item => {
                const margin = resolveMargins(child.style.margin);
                const padding = child.style.padding.nonNegative();
                const border = style_mod.borderWidths(child.style);

                var auto_offset: f64 = 0;
                if (margin.left_auto or margin.right_auto) {
                    if (resolveDimension(child.style.width, content.w)) |width| {
                        const outer = width + padding.horizontal() +
                            border.horizontal() + margin.horizontal();
                        const free = content.w - outer;
                        if (free > 0) {
                            if (margin.left_auto and margin.right_auto) {
                                auto_offset = free / 2;
                            } else if (margin.left_auto) {
                                auto_offset = free;
                            }
                        }
                    }
                }

                const relative_x = if (child.style.position == .relative)
                    resolveDimension(child.style.left, content.w) orelse 0
                else
                    0;
                const relative_y = if (child.style.position == .relative)
                    resolveDimension(
                        child.style.top,
                        owner_height orelse content.h,
                    ) orelse 0
                else
                    0;
                const origin_y = block_y + margin.top;
                const size = try layoutElement(
                    ctx,
                    child,
                    content.x + margin.left + auto_offset + relative_x + child.style.translate_x,
                    origin_y + relative_y + child.style.translate_y,
                    .{
                        .width = content.w,
                        .width_sizing = .definite,
                        .height_sizing = .indefinite,
                        .owner_width = content.w,
                        .owner_height = owner_height,
                    },
                    .{},
                );
                block_y = origin_y + size.height + margin.bottom;
            },
            .initial_containing_block => {},
        }
    }
    return block_y - content.y;
}

fn layoutElement(
    ctx: *LayoutContext,
    current: *LayoutBox,
    x: f64,
    y: f64,
    constraints: Constraints,
    forced: Forced,
) LayoutError!Size {
    const style = current.style;
    if (style.display == .none or style.display == .contents) {
        zeroBox(current);
        return .{};
    }

    const margin = resolveMargins(style.margin);
    const padding = style.padding.nonNegative();
    const border = style_mod.borderWidths(style);
    const extra_width = padding.horizontal() + border.horizontal();
    const extra_height = padding.vertical() + border.vertical();

    var content_width: f64 = 0;
    if (forced.width) |width| {
        content_width = @max(0, width);
    } else if (resolveDimension(style.width, constraints.owner_width)) |width| {
        content_width = @max(0, width);
    } else switch (constraints.width_sizing) {
        .definite => {
            content_width = @max(0, constraints.width -
                margin.horizontal() - extra_width);
        },
        .shrink_to_fit => {
            const inner = @max(0, constraints.width -
                margin.horizontal() - extra_width);
            content_width = @max(0, @min(contentMaxWidth(ctx, current), inner));
        },
        .indefinite => content_width = @max(0, contentMaxWidth(ctx, current)),
    }

    var content_height: f64 = 0;
    var height_auto = false;
    if (forced.height) |height| {
        content_height = @max(0, height);
    } else if (resolveDimension(style.height, constraints.owner_height)) |height| {
        content_height = @max(0, height);
    } else switch (constraints.height_sizing) {
        .definite => {
            content_height = @max(0, constraints.height -
                margin.vertical() - extra_height);
        },
        .shrink_to_fit, .indefinite => height_auto = true,
    }

    current.rect = .{
        .x = x,
        .y = y,
        .w = content_width + extra_width,
        .h = content_height + extra_height,
    };
    current.padding_rect = current.rect.inset(border);
    current.content_rect = current.padding_rect.inset(padding);

    if (isFlexContainer(style)) {
        const used_height = try layoutFlex(
            ctx,
            current,
            current.content_rect,
            if (!height_auto) content_height else null,
        );
        if (height_auto) content_height = used_height;
    } else {
        const used_height = try layoutBlockChildren(
            ctx,
            current,
            current.content_rect,
            if (!height_auto) content_height else null,
        );
        if (height_auto) content_height = used_height;
    }

    if (height_auto) {
        current.rect.h = content_height + extra_height;
        current.padding_rect = current.rect.inset(border);
        current.content_rect = current.padding_rect.inset(padding);
    }

    return .{ .width = current.rect.w, .height = current.rect.h };
}

const FlexItem = struct {
    box: *LayoutBox,
    margin: ResolvedMargins,
    extra_width: f64,
    extra_height: f64,
    item_align: style_mod.AlignItems,

    /// Flex base and resolved target, both border-box main sizes.
    base_main: f64,
    target_main: f64,
    frozen: bool = false,
    clamp_dir: i8 = 0,

    /// Content-box cross size before stretching.
    content_cross: f64 = 0,
    /// Border-box cross size after stretching.
    final_cross: f64 = 0,

    baseline: f64 = 0,
    main_pos: f64 = 0,
    cross_rel: f64 = 0,

    fn extraMain(self: *const FlexItem, row: bool) f64 {
        return if (row) self.extra_width else self.extra_height;
    }

    fn extraCross(self: *const FlexItem, row: bool) f64 {
        return if (row) self.extra_height else self.extra_width;
    }

    fn baseFactor(self: *const FlexItem, growing: bool) f64 {
        if (growing) return @max(0, self.box.style.flex_grow);
        return @max(0, self.box.style.flex_shrink) * self.base_main;
    }
};

const FlexLine = struct {
    start: usize,
    count: usize,
    main: f64 = 0,
    cross: f64 = 0,
    extra: f64 = 0,
    cross_start: f64 = 0,
};

fn resolvedAlign(container: Style, item: Style) style_mod.AlignItems {
    return switch (item.align_self) {
        .auto => container.align_items,
        .stretch => .stretch,
        .flex_start => .flex_start,
        .center => .center,
        .flex_end => .flex_end,
        .baseline => .baseline,
    };
}

fn firstBaseline(current: *const LayoutBox) f64 {
    switch (current.kind) {
        .text => return 0,
        .anonymous_inline => {
            for (current.children.items) |child| {
                if (child.style.display == .none or
                    child.style.display == .contents or
                    isOutOfFlow(child.style)) continue;
                return child.rect.y - current.rect.y + firstBaseline(child);
            }
            return 0;
        },
        .element, .anonymous_flex_item, .initial_containing_block => {
            const border = style_mod.borderWidths(current.style);
            const padding = current.style.padding.nonNegative();
            for (current.children.items) |child| {
                if (child.style.display == .none or
                    child.style.display == .contents or
                    isOutOfFlow(child.style)) continue;
                return child.rect.y - current.rect.y + firstBaseline(child);
            }
            return border.top + padding.top;
        },
    }
}

fn itemCrossDefined(style: Style, row: bool, cross_owner: ?f64) bool {
    const dimension = if (row) style.height else style.width;
    return resolveDimension(dimension, cross_owner) != null;
}

fn resolveFlexibleLengths(
    items: []FlexItem,
    inner_main: ?f64,
    main_gap_value: f64,
    row: bool,
) void {
    const gap_total = if (items.len > 0)
        main_gap_value * @as(f64, @floatFromInt(items.len - 1))
    else
        0;

    var hypothetical_total: f64 = 0;
    for (items) |item| {
        hypothetical_total += item.base_main + item.margin.main(row);
    }
    const inner = if (inner_main) |value| value - gap_total else null;
    const growing = if (inner) |value|
        value - hypothetical_total > 0
    else
        false;

    for (items) |*item| {
        item.target_main = item.base_main;
        item.clamp_dir = 0;
        const factor = item.baseFactor(growing);
        item.frozen = inner == null or factor <= 0;
    }
    if (inner == null) return;

    var guard: usize = 0;
    while (guard <= items.len) : (guard += 1) {
        var unfrozen: usize = 0;
        var used: f64 = 0;
        for (items) |*item| {
            if (item.frozen) {
                used += item.target_main + item.margin.main(row);
            } else {
                used += item.base_main + item.margin.main(row);
                unfrozen += 1;
            }
        }
        if (unfrozen == 0) break;

        var remaining = inner.? - used;
        var total_factor: f64 = 0;
        for (items) |*item| {
            if (!item.frozen) total_factor += item.baseFactor(growing);
        }
        if (total_factor <= 0) break;

        // css-flexbox-1 §9.7.1: a grow factor sum below one distributes only
        // that fraction of the free space; the rest stays unused.
        if (growing and total_factor < 1) remaining *= total_factor;

        var violation: f64 = 0;
        for (items) |*item| {
            if (item.frozen) continue;
            const factor = item.baseFactor(growing);
            const unclamped = item.base_main + remaining * factor / total_factor;
            const floor = item.extraMain(row);
            const bounded = @max(floor, unclamped);
            item.target_main = bounded;
            item.clamp_dir = if (bounded > unclamped)
                1
            else if (bounded < unclamped)
                -1
            else
                0;
            violation += bounded - unclamped;
        }

        const freeze_dir: i8 = if (violation > 0)
            1
        else if (violation < 0)
            -1
        else
            0;
        if (freeze_dir == 0) break;

        var froze = false;
        for (items) |*item| {
            if (!item.frozen and item.clamp_dir == freeze_dir) {
                item.frozen = true;
                froze = true;
            }
        }
        if (!froze) break;
    }
}

fn layoutFlex(
    ctx: *LayoutContext,
    container: *LayoutBox,
    content: Rect,
    height_defined: ?f64,
) LayoutError!f64 {
    const style = container.style;
    const row = axisIsRow(style);
    const main_reverse = axisIsReverse(style);
    const cross_reverse = style.flex_wrap == .wrap_reverse;
    const wrap = style.flex_wrap != .nowrap;
    const allocator = ctx.allocator;
    const main_gap_value = mainGap(style);
    const cross_gap_value = crossGap(style);
    const inner_main_defined: ?f64 = if (row) content.w else height_defined;

    var items: std.ArrayList(FlexItem) = .empty;
    for (container.children.items) |child| {
        if (child.style.display == .none or child.style.display == .contents) {
            zeroBox(child);
            continue;
        }
        if (isOutOfFlow(child.style)) continue;

        const margin = resolveMargins(child.style.margin);
        const padding = child.style.padding.nonNegative();
        const border = style_mod.borderWidths(child.style);
        const extra_width = padding.horizontal() + border.horizontal();
        const extra_height = padding.vertical() + border.vertical();
        const item_align = resolvedAlign(style, child.style);
        const main_owner = inner_main_defined;

        var item = FlexItem{
            .box = child,
            .margin = margin,
            .extra_width = extra_width,
            .extra_height = extra_height,
            .item_align = item_align,
            .base_main = 0,
            .target_main = 0,
        };

        const extra_main = if (row) extra_width else extra_height;
        const basis_dimension = resolveDimension(child.style.flex_basis, main_owner);
        const main_dimension = resolveDimension(
            if (row) child.style.width else child.style.height,
            main_owner,
        );

        if (basis_dimension) |basis| {
            item.base_main = @max(extra_main, basis + extra_main);
        } else if (main_dimension) |size| {
            item.base_main = @max(extra_main, size + extra_main);
        } else if (row) {
            item.base_main = @max(
                extra_main,
                contentMaxWidth(ctx, child) + extra_width,
            );
        } else {
            const cross_content = if (resolveDimension(child.style.width, content.w)) |width|
                @max(0, width)
            else blk: {
                const inner = @max(0, content.w -
                    margin.horizontal() - extra_width);
                break :blk @max(0, @min(contentMaxWidth(ctx, child), inner));
            };
            const size = try layoutElement(
                ctx,
                child,
                0,
                0,
                .{
                    .width_sizing = .indefinite,
                    .height_sizing = .indefinite,
                    .owner_width = content.w,
                    .owner_height = height_defined,
                },
                .{ .width = cross_content },
            );
            item.base_main = @max(extra_height, size.height);
        }

        try items.append(allocator, item);
    }

    if (items.items.len == 0) {
        return if (row) 0 else height_defined orelse 0;
    }

    var lines: std.ArrayList(FlexLine) = .empty;
    var index: usize = 0;
    while (index < items.items.len) {
        var line = FlexLine{ .start = index, .count = 0 };
        var consumed: f64 = 0;
        while (index < items.items.len) {
            const item = &items.items[index];
            const outer = item.base_main + item.margin.main(row);
            const preceding_gap = if (line.count > 0) main_gap_value else 0;
            if (wrap and inner_main_defined != null and line.count > 0 and
                consumed + preceding_gap + outer > inner_main_defined.?)
            {
                break;
            }
            consumed += preceding_gap + outer;
            line.count += 1;
            index += 1;
        }
        try lines.append(allocator, line);
    }

    for (lines.items) |*line| {
        const slice = items.items[line.start .. line.start + line.count];
        resolveFlexibleLengths(slice, inner_main_defined, main_gap_value, row);
        var total: f64 = 0;
        for (slice, 0..) |item, i| {
            if (i > 0) total += main_gap_value;
            total += item.target_main + item.margin.main(row);
        }
        line.main = total;
    }

    // Measure every item at its resolved main size; its cross size comes from
    // the style, the content, or the line after wrapping.
    for (lines.items) |*line| {
        var widest: f64 = 0;
        for (items.items[line.start .. line.start + line.count]) |*item| {
            const content_main = if (row)
                @max(0, item.target_main - item.extra_width)
            else
                @max(0, item.target_main - item.extra_height);
            const size = try layoutElement(
                ctx,
                item.box,
                0,
                0,
                .{
                    .width = content.w,
                    .width_sizing = .shrink_to_fit,
                    .height_sizing = .indefinite,
                    .owner_width = content.w,
                    .owner_height = height_defined,
                },
                .{
                    .width = if (row) content_main else null,
                    .height = if (row) null else content_main,
                },
            );
            item.content_cross = if (row)
                @max(0, size.height - item.extra_height)
            else
                @max(0, size.width - item.extra_width);
            item.baseline = firstBaseline(item.box);
            const outer_cross = if (row)
                size.height + item.margin.vertical()
            else
                size.width + item.margin.horizontal();
            widest = @max(widest, outer_cross);
        }
        const single_line_cross = !wrap and (if (row) height_defined != null else true);
        line.cross = if (single_line_cross)
            (if (row) height_defined.? else content.w)
        else
            widest;
    }

    var total_cross: f64 = 0;
    for (lines.items, 0..) |line, i| {
        if (i > 0) total_cross += cross_gap_value;
        total_cross += line.cross;
    }
    const used_height: f64 = height_defined orelse if (row)
        total_cross
    else
        lines.items[0].main;
    const resolved_cross: f64 = if (row) used_height else content.w;
    const resolved_main: f64 = if (row) content.w else used_height;

    const free_cross = resolved_cross - total_cross;
    var line_leading: f64 = 0;
    var line_between: f64 = 0;
    var line_stretch: f64 = 0;
    if (lines.items.len > 1) {
        switch (style.align_content) {
            .flex_end => line_leading = free_cross,
            .center => line_leading = free_cross / 2,
            .space_between => {
                if (lines.items.len > 1) {
                    line_between = @max(0, free_cross) /
                        @as(f64, @floatFromInt(lines.items.len - 1));
                }
            },
            .space_around => {
                line_between = @max(0, free_cross) /
                    @as(f64, @floatFromInt(lines.items.len));
                line_leading = line_between / 2;
            },
            .space_evenly => {
                line_between = @max(0, free_cross) /
                    @as(f64, @floatFromInt(lines.items.len + 1));
                line_leading = line_between;
            },
            .stretch => {
                if (free_cross > 0) {
                    line_stretch = free_cross / @as(f64, @floatFromInt(lines.items.len));
                }
            },
            .flex_start => {},
        }
    }

    // Cross sizes after align-content's stretch is known.
    for (lines.items) |*line| {
        line.extra = line_stretch;
        const line_cross_total = line.cross + line.extra;
        for (items.items[line.start .. line.start + line.count]) |*item| {
            const cross_owner: ?f64 = if (row) height_defined else content.w;
            const cross_defined = itemCrossDefined(item.box.style, row, cross_owner);
            const stretch = item.item_align == .stretch and !cross_defined and
                !item.margin.crossLeadAuto(row) and !item.margin.crossTrailAuto(row);
            const content_cross = if (stretch)
                @max(0, line_cross_total - item.margin.cross(row) - item.extraCross(row))
            else
                item.content_cross;
            item.final_cross = content_cross + item.extraCross(row);
        }
    }

    // Main-axis positions within each line. Reverse directions place from the
    // opposite edge in logical coordinates, so auto margins still refer to
    // their physical side.
    const main_start = if (row) content.x else content.y;
    const main_end = main_start + resolved_main;
    const cross_start = if (row) content.y else content.x;
    const cross_end = cross_start + resolved_cross;

    for (lines.items) |*line| {
        var content_main: f64 = 0;
        for (items.items[line.start .. line.start + line.count]) |item| {
            content_main += item.target_main + item.margin.main(row);
        }
        if (line.count > 1) {
            content_main += main_gap_value * @as(f64, @floatFromInt(line.count - 1));
        }
        const free = resolved_main - content_main;

        var auto_count: usize = 0;
        for (items.items[line.start .. line.start + line.count]) |item| {
            if (item.margin.mainLeadAuto(row)) auto_count += 1;
            if (item.margin.mainTrailAuto(row)) auto_count += 1;
        }

        var leading: f64 = 0;
        var between: f64 = 0;
        if (!(auto_count > 0 and free > 0)) {
            switch (style.justify_content) {
                .flex_start => {},
                .center => leading = free / 2,
                .flex_end => leading = free,
                .space_between => {
                    if (line.count > 1) {
                        between = @max(0, free) /
                            @as(f64, @floatFromInt(line.count - 1));
                    }
                },
                .space_around => {
                    between = @max(0, free) / @as(f64, @floatFromInt(line.count));
                    leading = between / 2;
                },
                .space_evenly => {
                    between = @max(0, free) /
                        @as(f64, @floatFromInt(line.count + 1));
                    leading = between;
                },
            }
        }
        const auto_share = if (auto_count > 0 and free > 0)
            free / @as(f64, @floatFromInt(auto_count))
        else
            0;

        var cursor = leading;
        for (items.items[line.start .. line.start + line.count], 0..) |*item, i| {
            const lead_auto = if (main_reverse)
                item.margin.mainTrailAuto(row)
            else
                item.margin.mainLeadAuto(row);
            const trail_auto = if (main_reverse)
                item.margin.mainLeadAuto(row)
            else
                item.margin.mainTrailAuto(row);
            const lead = if (main_reverse)
                item.margin.mainTrail(row)
            else
                item.margin.mainLead(row);
            const trail = if (main_reverse)
                item.margin.mainLead(row)
            else
                item.margin.mainTrail(row);

            if (lead_auto) cursor += auto_share;
            cursor += lead;
            item.main_pos = if (main_reverse)
                main_end - cursor - item.target_main
            else
                main_start + cursor;
            cursor += item.target_main + trail;
            if (trail_auto) cursor += auto_share;
            if (i + 1 < line.count) cursor += between + main_gap_value;
        }
    }

    // Cross-axis line starts and per-item cross offsets. wrap-reverse places
    // lines and items from the opposite cross edge in logical coordinates.
    var logical_cross = line_leading;
    for (lines.items) |*line| {
        const line_cross_total = line.cross + line.extra;
        line.cross_start = if (cross_reverse)
            cross_end - logical_cross - line_cross_total
        else
            cross_start + logical_cross;

        var max_baseline: f64 = 0;
        var has_baseline = false;
        if (row and !cross_reverse) {
            for (items.items[line.start .. line.start + line.count]) |item| {
                if (item.item_align != .baseline) continue;
                has_baseline = true;
                max_baseline = @max(
                    max_baseline,
                    item.margin.crossLead(row) + item.baseline,
                );
            }
        }

        for (items.items[line.start .. line.start + line.count]) |*item| {
            const outer_cross = item.final_cross + item.margin.cross(row);
            const free = line_cross_total - outer_cross;
            const lead_auto = if (cross_reverse)
                item.margin.crossTrailAuto(row)
            else
                item.margin.crossLeadAuto(row);
            const trail_auto = if (cross_reverse)
                item.margin.crossLeadAuto(row)
            else
                item.margin.crossTrailAuto(row);

            var offset: f64 = 0;
            if (lead_auto and trail_auto) {
                offset = @max(0, free) / 2;
            } else if (lead_auto) {
                offset = @max(0, free);
            } else if (!trail_auto) {
                switch (item.item_align) {
                    .center => offset = free / 2,
                    .flex_end => offset = free,
                    .baseline => {
                        if (has_baseline) {
                            offset = max_baseline -
                                (item.margin.crossLead(row) + item.baseline);
                        }
                    },
                    .stretch, .flex_start => {},
                }
            }

            // In a wrap-reverse line the logical leading margin is the
            // physical trailing one.
            const logical_lead = if (cross_reverse)
                item.margin.crossTrail(row)
            else
                item.margin.crossLead(row);
            const logical_dist = logical_lead + offset;
            item.cross_rel = if (cross_reverse)
                line_cross_total - logical_dist - item.final_cross
            else
                logical_dist;
        }

        logical_cross += line_cross_total + line_between + cross_gap_value;
    }

    // Final pass: lay each item out at its placed origin so descendants and
    // absolute children get final absolute coordinates.
    for (lines.items) |line| {
        for (items.items[line.start .. line.start + line.count]) |item| {
            const content_width = if (row)
                @max(0, item.target_main - item.extra_width)
            else
                @max(0, item.final_cross - item.extra_width);
            const content_height = if (row)
                @max(0, item.final_cross - item.extra_height)
            else
                @max(0, item.target_main - item.extra_height);

            const relative_x = resolveDimension(item.box.style.left, content.w) orelse 0;
            const relative_y = resolveDimension(item.box.style.top, used_height) orelse 0;

            const origin_x = (if (row) item.main_pos else line.cross_start + item.cross_rel) +
                relative_x + item.box.style.translate_x;
            const origin_y = (if (row) line.cross_start + item.cross_rel else item.main_pos) +
                relative_y + item.box.style.translate_y;

            _ = try layoutElement(
                ctx,
                item.box,
                origin_x,
                origin_y,
                .{
                    .width = content.w,
                    .width_sizing = .indefinite,
                    .height_sizing = .indefinite,
                    .owner_width = content.w,
                    .owner_height = height_defined,
                },
                .{ .width = content_width, .height = content_height },
            );
        }
    }

    return used_height;
}

fn layoutAbsolute(
    ctx: *LayoutContext,
    current: *LayoutBox,
    containing: Rect,
) LayoutError!void {
    const style = current.style;
    const margin = resolveMargins(style.margin);
    const left = resolveDimension(style.left, containing.w) orelse 0;
    const top = resolveDimension(style.top, containing.h) orelse 0;

    _ = try layoutElement(
        ctx,
        current,
        containing.x + margin.left + left + style.translate_x,
        containing.y + margin.top + top + style.translate_y,
        .{
            .width = containing.w,
            .width_sizing = .definite,
            .height = containing.h,
            .height_sizing = .indefinite,
            .owner_width = containing.w,
            .owner_height = containing.h,
        },
        .{},
    );
}

/// Second pass: place absolutely positioned boxes once every containing block
/// has its final geometry. An in-flow positioned box establishes the
/// containing block for its absolute descendants.
fn layoutOutOfFlow(ctx: *LayoutContext, parent: *LayoutBox, containing: Rect) LayoutError!void {
    for (parent.children.items) |child| {
        if (child.style.display == .none or child.style.display == .contents) continue;
        if (isOutOfFlow(child.style)) {
            try layoutAbsolute(ctx, child, containing);
            try layoutOutOfFlow(ctx, child, child.padding_rect);
        } else {
            const child_containing = if (child.style.position != .static)
                child.padding_rect
            else
                containing;
            try layoutOutOfFlow(ctx, child, child_containing);
        }
    }
}

fn copyRects(current: *LayoutBox) void {
    if (current.owner) |owner| {
        switch (owner.kind) {
            .element => |*element| element.rect = current.rect,
            .text => |*text| text.rect = current.rect,
        }
    }
    for (current.children.items) |child| copyRects(child);
}

test "layout: absolute boxes and percentages" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const child = try doc.createElement(.div);
    child.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
    });
    _ = try root.appendChild(child);

    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), root.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 10), root.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 2), child.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 1), child.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 4), child.asElement().rect.w);
}

test "layout: right-aligned inline text" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .top = .{ .cells = 0 },
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .text_align = .right,
    });
    doc.setRoot(line);

    const text = try doc.createText("abc");
    _ = try line.appendChild(text);
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 7), text.asText().rect.x);
}

test "layout: inline text runs advance by measured width" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
    });
    doc.setRoot(line);

    const a = try doc.createText("ab");
    const b = try doc.createText("c");
    _ = try line.appendChild(a);
    _ = try line.appendChild(b);
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), a.asText().rect.x);
    try std.testing.expectEqual(@as(f64, 2), b.asText().rect.x);
    try std.testing.expectEqual(@as(f64, 1), b.asText().rect.w);
}

test "layout: margin, border and padding produce content and border boxes" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 24, .rows = 16 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const child = try doc.createElement(.div);
    child.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 5 },
        .height = .{ .cells = 2 },
        .margin = .all(1),
        .padding = .all(1),
        .border = .all(1),
    });
    _ = try root.appendChild(child);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const layout_box = tree.find(child).?;
    // margin box origin = left/top; border box starts after the margin.
    try std.testing.expectEqual(@as(f64, 3), layout_box.rect.x);
    try std.testing.expectEqual(@as(f64, 2), layout_box.rect.y);
    try std.testing.expectEqual(@as(f64, 9), layout_box.rect.w);
    try std.testing.expectEqual(@as(f64, 6), layout_box.rect.h);

    try std.testing.expectEqual(@as(f64, 4), layout_box.padding_rect.x);
    try std.testing.expectEqual(@as(f64, 3), layout_box.padding_rect.y);
    try std.testing.expectEqual(@as(f64, 7), layout_box.padding_rect.w);
    try std.testing.expectEqual(@as(f64, 4), layout_box.padding_rect.h);

    try std.testing.expectEqual(@as(f64, 5), layout_box.content_rect.x);
    try std.testing.expectEqual(@as(f64, 4), layout_box.content_rect.y);
    try std.testing.expectEqual(@as(f64, 5), layout_box.content_rect.w);
    try std.testing.expectEqual(@as(f64, 2), layout_box.content_rect.h);
}

test "layout: percent width uses the parent content box" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 24, .rows = 10 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 10 },
        .height = .{ .cells = 4 },
        .padding = .all(1),
        .border = .all(1),
    });
    doc.setRoot(root);

    const child = try doc.createElement(.div);
    child.setStyle(.{
        .width = .{ .percent = 50 },
        .height = .{ .cells = 1 },
    });
    _ = try root.appendChild(child);

    try layoutDocument(&doc);

    const parent_box = root.asElement();
    try std.testing.expectEqual(@as(f64, 14), parent_box.rect.w);
    try std.testing.expectEqual(@as(f64, 2), child.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 5), child.asElement().rect.w);
}

test "layout: inline text starts at the content box" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 6 });
    defer doc.deinit();

    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
        .padding = .all(1),
        .border = .all(1),
    });
    doc.setRoot(line);

    const text = try doc.createText("xy");
    _ = try line.appendChild(text);
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 3), text.asText().rect.x);
    try std.testing.expectEqual(@as(f64, 3), text.asText().rect.y);
}

fn measureCodepoint(cp: u21) u2 {
    return if (cp == 0x4e2d) 2 else 1;
}

test "layout: wide text uses the width callback" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{
        .cols = 10,
        .rows = 2,
        .measure_width = measureCodepoint,
    });
    defer doc.deinit();

    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
    });
    doc.setRoot(line);

    const text = try doc.createText("中x");
    _ = try line.appendChild(text);
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 3), text.asText().rect.w);
}

test "layout: normal text wraps and grows auto height" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 8 },
    });
    doc.setRoot(root);

    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
    });
    _ = try root.appendChild(line);
    const text = try doc.createText("one two three");
    _ = try line.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const text_box = tree.find(text).?;
    try std.testing.expectEqual(@as(usize, 3), text_box.text_fragments.len);
    try std.testing.expectEqualStrings("one", text_box.text_fragments[0].text);
    try std.testing.expectEqualStrings("two", text_box.text_fragments[1].text);
    try std.testing.expectEqualStrings("three", text_box.text_fragments[2].text);
    try std.testing.expectEqual(@as(f64, 0), text_box.text_fragments[0].y);
    try std.testing.expectEqual(@as(f64, 1), text_box.text_fragments[1].y);
    try std.testing.expectEqual(@as(f64, 2), text_box.text_fragments[2].y);
    try std.testing.expectEqual(@as(f64, 5), line.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), line.asElement().rect.h);
}

fn testBox(doc: *dom.Document, parent: *dom.Node, style: Style) !*dom.Node {
    const node = try doc.createElement(.div);
    node.setStyle(style);
    _ = try parent.appendChild(node);
    return node;
}

fn testText(doc: *dom.Document, parent: *dom.Node, data: []const u8, style: Style) !*dom.Node {
    const node = try doc.createText(data);
    node.setStyle(style);
    _ = try parent.appendChild(node);
    return node;
}

test "layout: flex row justify-content and align-items" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 5 },
        .display = .flex,
        .justify_content = .center,
        .align_items = .center,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 4 }, .height = .{ .cells = 1 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 4 }, .height = .{ .cells = 1 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 6), a.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 2), a.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 10), b.asElement().rect.x);
}

test "layout: flex-grow distributes free space" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .flex_grow = 1,
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
        .flex_grow = 1,
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), a.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 4), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 4), b.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 6), b.asElement().rect.w);
}

test "layout: flex-shrink is weighted by the base size" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
        .flex_shrink = 1,
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
        .flex_shrink = 3,
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 6.5), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 6.5), b.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 3.5), b.asElement().rect.w);
}

test "layout: flex column stacks and stretches" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 10 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 10 },
        .display = .flex,
        .flex_direction = .column,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .height = .{ .cells = 2 } });
    const b = try testBox(&doc, root, .{ .height = .{ .cells = 3 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), a.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 10), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 2), b.asElement().rect.y);
}

test "layout: row-reverse mirrors margin boxes" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
        .flex_direction = .row_reverse,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 3 }, .height = .{ .cells = 1 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 5), b.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 8), a.asElement().rect.x);
}

test "layout: flex gap and space-between" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
        .justify_content = .space_between,
        .gap = .{ .column = 2 },
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    const c = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), a.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 4), b.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 8), c.asElement().rect.x);
}

test "layout: flex wrap and align-content" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 10 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 10 },
        .display = .flex,
        .flex_wrap = .wrap,
        .align_content = .center,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 6 }, .height = .{ .cells = 2 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 6 }, .height = .{ .cells = 2 } });
    const c = try testBox(&doc, root, .{ .width = .{ .cells = 4 }, .height = .{ .cells = 2 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 3), a.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 5), b.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 0), b.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 6), c.asElement().rect.x);
}

test "layout: align-self overrides align-items and stretches" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 5 },
        .display = .flex,
        .align_items = .center,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .align_self = .flex_end,
    });
    const c = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .align_self = .stretch,
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 2), a.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 4), b.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 5), c.asElement().rect.h);
}

test "layout: flex auto margins center an item" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 3 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 3 },
        .display = .flex,
        .align_items = .center,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .margin = .{ .left = .auto, .right = .auto },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 4), a.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 1), a.asElement().rect.y);
}

test "layout: flex order is stable for equal values" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .order = 2,
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .order = 0,
    });
    const c = try testBox(&doc, root, .{
        .width = .{ .cells = 1 },
        .height = .{ .cells = 1 },
        .order = 0,
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), b.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 3), c.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 4), a.asElement().rect.x);
}

test "layout: flex auto sizes come from content" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .display = .flex,
        .align_items = .flex_start,
    });
    doc.setRoot(root);

    const first = try testBox(&doc, root, .{});
    _ = try testText(&doc, first, "abc", .{});
    const second = try testBox(&doc, root, .{});
    _ = try testText(&doc, second, "de", .{});
    _ = try testText(&doc, second, "fg", .{});
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 1), root.asElement().rect.h);
    try std.testing.expectEqual(@as(f64, 3), first.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), second.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 4), second.asElement().rect.w);
}

test "layout: flex column auto height stacks content" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 10 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .display = .flex,
        .flex_direction = .column,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{});
    _ = try testText(&doc, a, "x", .{});
    _ = try testBox(&doc, root, .{ .height = .{ .cells = 2 }, .width = .{ .cells = 4 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 3), root.asElement().rect.h);
    try std.testing.expectEqual(@as(f64, 1), a.asElement().rect.h);
    try std.testing.expectEqual(@as(f64, 0), a.asElement().rect.y);
}

test "layout: nested flex items grow inside their parent" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 2 },
        .display = .flex,
    });
    doc.setRoot(root);

    const inner = try testBox(&doc, root, .{
        .display = .flex,
        .flex_grow = 1,
        .height = .{ .cells = 1 },
    });
    const a = try testBox(&doc, inner, .{ .height = .{ .cells = 1 }, .flex_grow = 1 });
    const b = try testBox(&doc, inner, .{ .height = .{ .cells = 1 }, .flex_grow = 1 });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 10), inner.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 5), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 5), b.asElement().rect.x);
}

test "layout: absolute child of a flex container is out of flow" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 5 },
        .display = .flex,
    });
    doc.setRoot(root);

    const item = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    const floating = try testBox(&doc, root, .{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 1 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), item.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 2), floating.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 1), floating.asElement().rect.y);
}

test "layout: inline-flex shrink-wraps on an inline line" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 3 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 3 },
    });
    doc.setRoot(root);

    const inline_box = try testBox(&doc, root, .{
        .display = .inline_flex,
    });
    const a = try testBox(&doc, inline_box, .{ .width = .{ .cells = 3 }, .height = .{ .cells = 1 } });
    const b = try testBox(&doc, inline_box, .{ .width = .{ .cells = 3 }, .height = .{ .cells = 1 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 6), inline_box.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 1), inline_box.asElement().rect.h);
    try std.testing.expectEqual(@as(f64, 0), a.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 3), b.asElement().rect.x);
}

test "layout: baseline aligns first text lines" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 4 },
        .display = .flex,
        .align_items = .baseline,
    });
    doc.setRoot(root);

    const padded = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .padding = .{ .top = 1 },
    });
    const padded_text = try testText(&doc, padded, "a", .{});
    const plain = try testBox(&doc, root, .{ .width = .{ .cells = 2 } });
    const plain_text = try testText(&doc, plain, "b", .{});
    try layoutDocument(&doc);
    try std.testing.expectEqual(@as(f64, 1), padded_text.asText().rect.y);
    try std.testing.expectEqual(@as(f64, 1), plain_text.asText().rect.y);
}

test "layout: flex percentages resolve against the content box" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 5 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .percent = 50 },
        .height = .{ .percent = 50 },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 10), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 2.5), a.asElement().rect.h);
}

test "layout: column-reverse mirrors the main axis" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 10 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 10 },
        .display = .flex,
        .flex_direction = .column_reverse,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .height = .{ .cells = 2 } });
    const b = try testBox(&doc, root, .{ .height = .{ .cells = 3 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 8), a.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 5), b.asElement().rect.y);
}

test "layout: wrap-reverse mirrors flex lines" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 6 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 6 },
        .display = .flex,
        .flex_wrap = .wrap_reverse,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 6 }, .height = .{ .cells = 2 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 6 }, .height = .{ .cells = 2 } });
    const c = try testBox(&doc, root, .{ .width = .{ .cells = 6 }, .height = .{ .cells = 2 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 4), a.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 2), b.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 0), c.asElement().rect.y);
}

test "layout: justify-content space-evenly" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
        .justify_content = .space_evenly,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    const c = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 1), a.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 4), b.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 7), c.asElement().rect.x);
}

test "layout: flex-basis overrides the main size" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 7 },
        .height = .{ .cells = 1 },
        .flex_basis = .{ .cells = 2 },
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 2), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 2), b.asElement().rect.x);
}

test "layout: cross auto margins center an item" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 5 },
        .display = .flex,
        .align_items = .flex_start,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .margin = .{ .top = .auto, .bottom = .auto },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 2), a.asElement().rect.y);
}

test "layout: block auto height and auto margins" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
    });
    doc.setRoot(root);

    const title = try testBox(&doc, root, .{});
    _ = try testText(&doc, title, "abc", .{});

    const centered = try testBox(&doc, root, .{
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
        .margin = .{ .left = .auto, .right = .auto },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 2), root.asElement().rect.h);
    try std.testing.expectEqual(@as(f64, 0), title.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 3), centered.asElement().rect.x);
}

test "layout: bare text in a flex container becomes an item" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 2 },
        .display = .flex,
    });
    doc.setRoot(root);

    const text = try testText(&doc, root, "ab", .{});
    const item_box = try testBox(&doc, root, .{ .width = .{ .cells = 2 }, .height = .{ .cells = 1 } });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), text.asText().rect.x);
    try std.testing.expectEqual(@as(f64, 2), item_box.asElement().rect.x);
}

test "layout: flex item padding and border join the flex base size" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 12, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 12 },
        .height = .{ .cells = 2 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .height = .{ .cells = 1 },
        .padding = .all(1),
        .border = .all(1),
        .flex_grow = 1,
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .flex_grow = 1,
    });
    try layoutDocument(&doc);

    // The first item's base includes 2 padding + 2 border cells, so the two
    // growing items split the remaining space from 4 + 2 = 6.
    try std.testing.expectEqual(@as(f64, 0), a.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 7), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 7), b.asElement().rect.x);
}

test "layout: row-reverse keeps physical auto margins" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .display = .flex,
        .flex_direction = .row_reverse,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .margin = .{ .left = .auto },
    });
    try layoutDocument(&doc);

    // A physical left auto margin is on the main-end side of a row-reverse
    // line, so it absorbs the free space and leaves the item flush right.
    try std.testing.expectEqual(@as(f64, 8), a.asElement().rect.x);
}

test "layout: wrap-reverse aligns items from the cross-start edge" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 5 },
        .display = .flex,
        .flex_wrap = .wrap_reverse,
        .align_items = .flex_start,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 6 }, .height = .{ .cells = 2 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 4 }, .height = .{ .cells = 1 } });
    try layoutDocument(&doc);

    // The single line sits at the bottom; flex-start packs b against the
    // bottom (cross-start) of that line.
    try std.testing.expectEqual(@as(f64, 3), a.asElement().rect.y);
    try std.testing.expectEqual(@as(f64, 4), b.asElement().rect.y);
}

// The following cases are ported from Taffy's flexbox test fixtures
// (test_fixtures/flex/*.html and tests/xml/flex/*.xml, MIT). Taffy rounds
// border-box geometry to whole units; these assertions keep the unrounded
// cell geometry and use expectClose where the fixture rounds.

fn expectClose(expected: f64, actual: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.001);
}

test "layout: flex item shrinks and wraps its text" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
        .display = .flex,
    });
    doc.setRoot(root);

    const item = try testBox(&doc, root, .{ .flex_shrink = 1 });
    const text = try doc.createText("one two three");
    _ = try item.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const text_box = tree.find(text).?;
    try std.testing.expectEqual(@as(f64, 5), item.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), item.asElement().rect.h);
    try std.testing.expectEqual(@as(usize, 3), text_box.text_fragments.len);
    try std.testing.expectEqual(@as(f64, 2), text_box.text_fragments[2].y);
}

test "layout: nowrap flex item keeps one line and overflows" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
        .display = .flex,
    });
    doc.setRoot(root);

    const item = try testBox(&doc, root, .{ .flex_shrink = 1, .white_space = .nowrap });
    const text = try doc.createText("one two three");
    _ = try item.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const text_box = tree.find(text).?;
    try std.testing.expectEqual(@as(usize, 1), text_box.text_fragments.len);
    try std.testing.expectEqual(@as(f64, 13), text_box.rect.w);
    try std.testing.expectEqual(@as(f64, 1), item.asElement().rect.h);
}

test "layout: an unbreakable word overflows instead of splitting" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
    });
    doc.setRoot(root);
    const text = try doc.createText("abcdefghij");
    _ = try root.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const text_box = tree.find(text).?;
    try std.testing.expectEqual(@as(usize, 1), text_box.text_fragments.len);
    try std.testing.expectEqual(@as(f64, 10), text_box.rect.w);
}

test "taffy flex: basis and grow, row" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .flex_basis = .{ .cells = 50 }, .flex_grow = 1 });
    const b = try testBox(&doc, root, .{ .flex_grow = 1 });
    try layoutDocument(&doc);

    try expectClose(75, a.asElement().rect.w);
    try expectClose(75, b.asElement().rect.x);
    try expectClose(25, b.asElement().rect.w);
}

test "taffy flex: basis and grow, column" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .flex_direction = .column,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .flex_basis = .{ .cells = 50 }, .flex_grow = 1 });
    const b = try testBox(&doc, root, .{ .flex_grow = 1 });
    try layoutDocument(&doc);

    try expectClose(75, a.asElement().rect.h);
    try expectClose(75, b.asElement().rect.y);
    try expectClose(25, b.asElement().rect.h);
}

test "taffy flex: basis shrink, row" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .flex_basis = .{ .cells = 100 } });
    const b = try testBox(&doc, root, .{ .flex_basis = .{ .cells = 50 } });
    try layoutDocument(&doc);

    // Taffy's border-box snapshot rounds these to 67 and 33.
    try expectClose(200.0 / 3.0, a.asElement().rect.w);
    try expectClose(200.0 / 3.0, b.asElement().rect.x);
    try expectClose(100.0 / 3.0, b.asElement().rect.w);
}

test "taffy flex: row-reverse and column-reverse" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const row = try doc.createElement(.div);
    row.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .flex_direction = .row_reverse,
    });
    doc.setRoot(row);
    const r0 = try testBox(&doc, row, .{ .width = .{ .cells = 10 } });
    const r1 = try testBox(&doc, row, .{ .width = .{ .cells = 10 } });
    const r2 = try testBox(&doc, row, .{ .width = .{ .cells = 10 } });
    try layoutDocument(&doc);

    try expectClose(90, r0.asElement().rect.x);
    try expectClose(80, r1.asElement().rect.x);
    try expectClose(70, r2.asElement().rect.x);

    doc.clear();
    const column = try doc.createElement(.div);
    column.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .flex_direction = .column_reverse,
    });
    doc.setRoot(column);
    const c0 = try testBox(&doc, column, .{ .height = .{ .cells = 10 } });
    const c1 = try testBox(&doc, column, .{ .height = .{ .cells = 10 } });
    const c2 = try testBox(&doc, column, .{ .height = .{ .cells = 10 } });
    try layoutDocument(&doc);

    try expectClose(90, c0.asElement().rect.y);
    try expectClose(80, c1.asElement().rect.y);
    try expectClose(70, c2.asElement().rect.y);
}

test "taffy flex: justify-content space-around" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .justify_content = .space_around,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 10 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 10 } });
    const c = try testBox(&doc, root, .{ .width = .{ .cells = 10 } });
    try layoutDocument(&doc);

    // Taffy rounds these border-box positions to 12 and 78.
    try expectClose(35.0 / 3.0, a.asElement().rect.x);
    try expectClose(45, b.asElement().rect.x);
    try expectClose(235.0 / 3.0, c.asElement().rect.x);
}

test "taffy flex: justify-content space-evenly with zero-width items" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .justify_content = .space_evenly,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .height = .{ .cells = 10 } });
    const b = try testBox(&doc, root, .{ .height = .{ .cells = 10 } });
    const c = try testBox(&doc, root, .{ .height = .{ .cells = 10 } });
    try layoutDocument(&doc);

    try expectClose(25, a.asElement().rect.x);
    try expectClose(50, b.asElement().rect.x);
    try expectClose(75, c.asElement().rect.x);
    try expectClose(0, a.asElement().rect.w);
}

test "taffy flex: align-items center with a child margin" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .align_items = .center,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 10 },
        .height = .{ .cells = 10 },
        .margin = .{ .top = .{ .cells = 10 } },
    });
    try layoutDocument(&doc);

    try expectClose(50, a.asElement().rect.y);
}

test "taffy flex: column gap inflexible" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 80, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 80 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .gap = .{ .column = 10 },
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 20 } });
    const b = try testBox(&doc, root, .{ .width = .{ .cells = 20 } });
    const c = try testBox(&doc, root, .{ .width = .{ .cells = 20 } });
    try layoutDocument(&doc);

    try expectClose(0, a.asElement().rect.x);
    try expectClose(30, b.asElement().rect.x);
    try expectClose(60, c.asElement().rect.x);
}

test "taffy flex: wrapped gap with align-content center" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .flex_wrap = .wrap,
        .align_content = .center,
        .gap = .{ .row = 20, .column = 10 },
    });
    doc.setRoot(root);

    const nodes: [6]*dom.Node = blk: {
        var list: [6]*dom.Node = undefined;
        for (&list) |*slot| {
            slot.* = try testBox(&doc, root, .{
                .width = .{ .cells = 20 },
                .height = .{ .cells = 20 },
            });
        }
        break :blk list;
    };
    try layoutDocument(&doc);

    for (nodes, 0..) |node, index| {
        const expected_y: f64 = if (index < 3) 20 else 60;
        try expectClose(expected_y, node.asElement().rect.y);
    }
}

test "taffy flex: align-content center spans three wrapped lines" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 120, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 120 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .flex_wrap = .wrap,
        .align_content = .center,
    });
    doc.setRoot(root);

    var nodes: [6]*dom.Node = undefined;
    for (&nodes) |*slot| {
        slot.* = try testBox(&doc, root, .{
            .width = .{ .cells = 50 },
            .height = .{ .cells = 10 },
        });
    }
    try layoutDocument(&doc);

    for (nodes, 0..) |node, index| {
        const expected_y: f64 = 35 + @as(f64, @floatFromInt(index / 2)) * 10;
        try expectClose(expected_y, node.asElement().rect.y);
    }
}

test "taffy flex: align-content stretch grows wrapped rows" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 150, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 150 },
        .height = .{ .cells = 100 },
        .display = .flex,
        .flex_wrap = .wrap,
        .align_content = .stretch,
    });
    doc.setRoot(root);

    var nodes: [5]*dom.Node = undefined;
    for (&nodes) |*slot| {
        slot.* = try testBox(&doc, root, .{ .width = .{ .cells = 50 } });
    }
    try layoutDocument(&doc);

    try expectClose(0, nodes[0].asElement().rect.y);
    try expectClose(50, nodes[0].asElement().rect.h);
    try expectClose(50, nodes[3].asElement().rect.y);
}

test "taffy flex: row gap aligns items at flex-end" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 200 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .height = .{ .cells = 200 },
        .display = .flex,
        .flex_wrap = .wrap,
        .align_items = .flex_end,
        .gap = .{ .row = 20, .column = 10 },
    });
    doc.setRoot(root);

    var nodes: [6]*dom.Node = undefined;
    for (&nodes) |*slot| {
        slot.* = try testBox(&doc, root, .{ .width = .{ .cells = 20 } });
    }
    try layoutDocument(&doc);

    for (nodes, 0..) |node, index| {
        const expected_y: f64 = if (index < 3) 90 else 200;
        try expectClose(expected_y, node.asElement().rect.y);
    }
}

test "taffy flex: auto bottom margin with align-items center" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 200, .rows = 200 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 200 },
        .height = .{ .cells = 200 },
        .display = .flex,
        .align_items = .center,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 50 },
        .height = .{ .cells = 50 },
        .margin = .{ .bottom = .auto },
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 50 },
        .height = .{ .cells = 50 },
    });
    try layoutDocument(&doc);

    try expectClose(0, a.asElement().rect.y);
    try expectClose(75, b.asElement().rect.y);
}

test "taffy flex: grow factors below one leave free space" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 500, .rows = 200 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 500 },
        .height = .{ .cells = 200 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .flex_basis = .{ .cells = 40 },
        .flex_grow = 0.2,
        .flex_shrink = 0,
    });
    const b = try testBox(&doc, root, .{
        .flex_grow = 0.2,
        .flex_shrink = 0,
    });
    const c = try testBox(&doc, root, .{
        .flex_grow = 0.4,
        .flex_shrink = 0,
    });
    try layoutDocument(&doc);

    try expectClose(132, a.asElement().rect.w);
    try expectClose(92, b.asElement().rect.w);
    try expectClose(184, c.asElement().rect.w);
    try expectClose(408, c.asElement().rect.x + c.asElement().rect.w);
}

test "taffy flex: border on the container insets content" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 80 },
        .height = .{ .cells = 80 },
        .border = .all(10),
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .width = .{ .cells = 10 }, .flex_grow = 1 });
    try layoutDocument(&doc);

    try expectClose(10, a.asElement().rect.x);
    try expectClose(10, a.asElement().rect.y);
    try expectClose(80, a.asElement().rect.w);
    try expectClose(80, a.asElement().rect.h);
}

test "taffy flex: column with auto height sizes to its content" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 100, .rows = 100 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 100 },
        .display = .flex,
        .flex_direction = .column,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{ .height = .{ .cells = 10 } });
    const b = try testBox(&doc, root, .{ .height = .{ .cells = 10 } });
    const c = try testBox(&doc, root, .{ .height = .{ .cells = 10 } });
    try layoutDocument(&doc);

    try expectClose(30, root.asElement().rect.h);
    try expectClose(0, a.asElement().rect.y);
    try expectClose(10, b.asElement().rect.y);
    try expectClose(20, c.asElement().rect.y);
}

test "layout: elementFromPoint hits later wrapped lines" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 4 },
    });
    doc.setRoot(root);

    const line = try doc.createElement(.div);
    line.setStyle(.{ .width = .{ .cells = 5 } });
    _ = try root.appendChild(line);
    _ = try line.appendChild(try doc.createText("one two three"));

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    try std.testing.expectEqual(line, tree.elementFromPoint(0, 0).?);
    try std.testing.expectEqual(line, tree.elementFromPoint(0, 1).?);
    try std.testing.expectEqual(line, tree.elementFromPoint(0, 2).?);
    try std.testing.expectEqual(root, tree.elementFromPoint(0, 3).?);
}

test "layout: non-atomic inline elements fragment across wrapped lines" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 12, .rows = 6 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("foo "));

    const span = try doc.createElement(.span);
    span.setStyle(.{ .display = .inline_ });
    _ = try root.appendChild(span);
    const inner = try doc.createText("bar baz");
    _ = try span.appendChild(inner);
    _ = try root.appendChild(try doc.createText(" qux"));

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const span_box = tree.find(span).?;
    const inner_box = tree.find(inner).?;
    try std.testing.expectEqual(@as(usize, 2), span_box.inline_fragments.len);
    try std.testing.expectEqual(@as(usize, 2), inner_box.text_fragments.len);
    try std.testing.expectEqualStrings("bar", inner_box.text_fragments[0].text);
    try std.testing.expectEqualStrings("baz", inner_box.text_fragments[1].text);
    try std.testing.expectEqual(@as(f64, 2), span_box.rect.h);
}

test "layout: bare text in a flex container wraps as its anonymous item" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
        .display = .flex,
    });
    doc.setRoot(root);
    const text = try doc.createText("one two three");
    _ = try root.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const text_box = tree.find(text).?;
    try std.testing.expectEqual(@as(usize, 3), text_box.text_fragments.len);
    try std.testing.expectEqual(@as(f64, 3), root.asElement().rect.h);
}

test "layout: text-align aligns each wrapped line independently" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 12, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 3 },
        .text_align = .center,
    });
    doc.setRoot(root);
    const text = try doc.createText("a bb");
    _ = try root.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const fragments = tree.find(text).?.text_fragments;
    try std.testing.expectEqual(@as(usize, 2), fragments.len);
    try std.testing.expectEqual(@as(f64, 1), fragments[0].x);
    try std.testing.expectEqual(@as(f64, 0.5), fragments[1].x);
}

test "layout: flex column item auto height follows wrapped text" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 8 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 5 },
        .display = .flex,
        .flex_direction = .column,
    });
    doc.setRoot(root);
    const item = try testBox(&doc, root, .{});
    const text = try doc.createText("one two three");
    _ = try item.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const text_box = tree.find(text).?;
    try std.testing.expectEqual(@as(usize, 3), text_box.text_fragments.len);
    try std.testing.expectEqual(@as(f64, 5), item.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), item.asElement().rect.h);
    try std.testing.expectEqual(@as(f64, 3), root.asElement().rect.h);
}

test "layout: inline element padding joins the line and fragment box" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 12, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 6 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("x "));

    const span = try doc.createElement(.span);
    span.setStyle(.{
        .display = .inline_,
        .padding = .{ .left = 1, .right = 1 },
    });
    _ = try root.appendChild(span);
    _ = try span.appendChild(try doc.createText("abcd"));

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const span_box = tree.find(span).?;
    try std.testing.expectEqual(@as(usize, 1), span_box.inline_fragments.len);
    try std.testing.expectEqual(@as(f64, 6), span_box.inline_fragments[0].w);
    try std.testing.expectEqual(@as(f64, 1), span_box.inline_fragments[0].y);
}

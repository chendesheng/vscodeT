//! Whole-cell layout over the derived box tree.
//!
//! The solver never touches the DOM. It computes `LayoutBox` geometry and
//! copies the border box back to the DOM nodes only for the measurement
//! boundary.
//!
//! Supported box model: content box (`width`/`height`, bounded by
//! `min_width`/`max_width`), padding, border and margin, with absolute
//! `left`/`top` anchoring the margin box, block flow, inline text flow, and
//! flex formatting contexts. The flex pass follows css-flexbox-1 §9 and
//! TermDOM's `layoutsolver` shape (direction, wrap, grow/shrink/basis,
//! justify/align, gap, order and auto margins); it is a reimplementation in Zig
//! over this library's box tree.
//!
//! Inline text flow lives in `text_layout.zig`: UAX #14 line breaking, the
//! `white-space` family, `word-break`/`overflow-wrap`, line alignment and
//! fragments. This file only collects leaves and places atomic inline boxes.
//!
//! There is no `min-height`/`max-height`, grid, table boxes or incremental box
//! reuse yet. Flex items shrink to a zero content size rather than to an
//! automatic min-content floor. `position: fixed` still resolves like
//! `absolute`, as it did before flex was added.

const std = @import("std");
const box = @import("box.zig");
const dom = @import("../dom/dom.zig");
const linebreak = @import("linebreak.zig");
const style_mod = @import("../style/style.zig");
const text_layout = @import("text_layout.zig");

pub const Rect = style_mod.Rect;
pub const Style = style_mod.ComputedStyle;
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
    tree.syncIntrinsicSettings(doc);
    var ctx = LayoutContext{
        .doc = doc,
        .allocator = tree.scratch.allocator(),
        .tables = try linebreak.LineBreakTables.init(tree.scratch.allocator()),
        .intrinsic_epoch = tree.intrinsic_epoch,
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

/// Solves one already-built out-of-flow box subtree (a retained editor line,
/// gutter row or part) without resetting the layout scratch, so fragments for
/// clean boxes stay valid. Used by the retained editor view.
pub fn layoutSubtree(tree: *BoxTree, doc: *dom.Document, target: *LayoutBox) LayoutError!void {
    tree.syncIntrinsicSettings(doc);
    var ctx = LayoutContext{
        .doc = doc,
        .allocator = tree.scratch.allocator(),
        .tables = linebreak.LineBreakTables.value(),
        .intrinsic_epoch = tree.intrinsic_epoch,
    };
    const containing = containingBlockRect(target) orelse Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(doc.cols),
        .h = @floatFromInt(doc.rows),
    };
    try layoutAbsolute(&ctx, target, containing);
    try layoutOutOfFlow(&ctx, target, target.padding_rect);
    copyRects(target);
    // `layoutSubtree` intentionally keeps scratch alive for clean boxes, so
    // growth is bounded here instead: crossing the budget schedules the full
    // rebuild that resets both arenas on the next ensureLayout.
    tree.checkLayoutScratchBudget();
}

fn containingBlockRect(target: *const LayoutBox) ?Rect {
    var current = target.parent;
    while (current) |parent| {
        if (parent.kind == .initial_containing_block) return parent.padding_rect;
        if (parent.style.position != .static) return parent.padding_rect;
        current = parent.parent;
    }
    return null;
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
    /// Must match `BoxTree.intrinsic_epoch`; a box cache entry from another
    /// epoch is recomputed on demand.
    intrinsic_epoch: u32,
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

/// Clamps a content-box width by the style's min/max bounds. The minimum wins
/// when both resolve. `base == null` means percentages are unresolved, which is
/// the case during intrinsic measurement.
fn constrainContentWidth(style: Style, value: f64, base: ?f64) f64 {
    var width = @max(0, value);
    if (resolveDimension(style.max_width, base)) |maximum| {
        width = @min(width, @max(0, maximum));
    }
    if (resolveDimension(style.min_width, base)) |minimum| {
        width = @max(width, @max(0, minimum));
    }
    return width;
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

fn edgeWidth(style: style_mod.ComputedStyle, side: text_layout.EdgeSide) f64 {
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
            // A bare text box is its own formatting context. Walking its
            // ancestors would union every containing block into the text
            // fragment and corrupt their rects (their padding/content rects
            // stay correct, so backgrounds and hit testing diverge).
            if (run.kind == .text) continue;
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
///
/// The value is independent of the containing block and is cached per box for
/// the current intrinsic epoch. Any style/text/structure mutation clears the
/// changed box and its ancestors; measurement-setting changes bump the epoch.
fn contentMaxWidth(ctx: *const LayoutContext, current: *LayoutBox) f64 {
    if (current.max_content_epoch == ctx.intrinsic_epoch) return current.max_content_width;
    const value = computeContentMaxWidth(ctx, current);
    current.max_content_width = value;
    current.max_content_epoch = ctx.intrinsic_epoch;
    return value;
}

fn computeContentMaxWidth(ctx: *const LayoutContext, current: *const LayoutBox) f64 {
    const content = switch (current.kind) {
        .initial_containing_block => return 0,
        .text => return text_layout.maxContentWidth(
            ctx.doc,
            current.text orelse "",
            current.text_style,
            ctx.doc.tab_size,
        ),
        .anonymous_inline => blk: {
            var total: f64 = 0;
            for (current.children.items) |child| {
                if (!contributesToFlow(child)) continue;
                total += outerMaxWidth(ctx, child);
            }
            break :blk total;
        },
        .element, .anonymous_flex_item => blk: {
            if (current.style.width == .cells) {
                break :blk current.style.width.cells;
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
                    break :blk total;
                }
                var widest: f64 = 0;
                for (current.children.items) |child| {
                    if (!contributesToFlow(child)) continue;
                    widest = @max(widest, outerMaxWidth(ctx, child));
                }
                break :blk widest;
            }
            var widest: f64 = 0;
            for (current.children.items) |child| {
                if (!contributesToFlow(child)) continue;
                widest = @max(widest, outerMaxWidth(ctx, child));
            }
            break :blk widest;
        },
    };
    return switch (current.kind) {
        .element, .anonymous_flex_item => constrainContentWidth(current.style, content, null),
        else => content,
    };
}

fn contributesToFlow(current: *const LayoutBox) bool {
    return current.style.display != .none and
        current.style.display != .contents and
        !isOutOfFlow(current.style);
}

/// Border-box plus margin width, used for intrinsic flex and block sizing.
fn outerMaxWidth(ctx: *const LayoutContext, current: *LayoutBox) f64 {
    switch (current.kind) {
        .initial_containing_block => return 0,
        .text => return contentMaxWidth(ctx, current),
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
fn flexItemOuterWidth(ctx: *const LayoutContext, current: *LayoutBox) f64 {
    const padding = current.style.padding.nonNegative();
    const border = style_mod.borderWidths(current.style);
    const margin = resolveMargins(current.style.margin);
    const content = switch (current.style.flex_basis) {
        .cells => |value| constrainContentWidth(current.style, value, null),
        else => contentMaxWidth(ctx, current),
    };
    return content + padding.horizontal() + border.horizontal() + margin.horizontal();
}

/// Content width that a block-level box would use for auto-margin centering.
/// Returns null when the box has no definite or max-clamped width (plain
/// `width:auto` fills the containing block, so auto margins resolve to zero).
fn blockMarginedContentWidth(
    style: Style,
    owner_width: f64,
    margin: ResolvedMargins,
    extra_width: f64,
) ?f64 {
    if (resolveDimension(style.width, owner_width)) |width| {
        return constrainContentWidth(style, width, owner_width);
    }
    if (resolveDimension(style.max_width, owner_width) != null) {
        const inner = @max(0, owner_width - margin.horizontal() - extra_width);
        return constrainContentWidth(style, inner, owner_width);
    }
    return null;
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
                    child.text_style.text_align,
                );
            },
            .element, .anonymous_flex_item => {
                const margin = resolveMargins(child.style.margin);
                const padding = child.style.padding.nonNegative();
                const border = style_mod.borderWidths(child.style);

                var auto_offset: f64 = 0;
                if (margin.left_auto or margin.right_auto) {
                    if (blockMarginedContentWidth(
                        child.style,
                        content.w,
                        margin,
                        padding.horizontal() + border.horizontal(),
                    )) |width| {
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
    content_width = constrainContentWidth(style, content_width, constraints.owner_width);

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
    /// Border-box main-axis bounds. They default to unconstrained so the
    /// column main axis (height) keeps its existing behaviour.
    main_min: f64 = 0,
    main_max: f64 = std.math.inf(f64),
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

    fn clampMainSize(self: *const FlexItem, row: bool, value: f64) f64 {
        const floor = @max(self.extraMain(row), self.main_min);
        const ceiling = @max(floor, self.main_max);
        return @max(floor, @min(value, ceiling));
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
            const bounded = item.clampMainSize(row, unclamped);
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

        if (row) {
            const minimum = resolveDimension(child.style.min_width, content.w) orelse 0;
            const maximum = resolveDimension(child.style.max_width, content.w) orelse
                std.math.inf(f64);
            item.main_min = extra_width + @max(0, minimum);
            item.main_max = extra_width + @max(0, maximum);
        }

        const extra_main = if (row) extra_width else extra_height;
        const basis_dimension = resolveDimension(child.style.flex_basis, main_owner);
        const main_dimension = resolveDimension(
            if (row) child.style.width else child.style.height,
            main_owner,
        );

        if (basis_dimension) |basis| {
            item.base_main = item.clampMainSize(row, basis + extra_main);
        } else if (main_dimension) |size| {
            item.base_main = item.clampMainSize(row, size + extra_main);
        } else if (row) {
            item.base_main = item.clampMainSize(
                row,
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
            item.base_main = item.clampMainSize(row, size.height);
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
            var content_cross = if (stretch)
                @max(0, line_cross_total - item.margin.cross(row) - item.extraCross(row))
            else
                item.content_cross;
            // Width is the cross axis in a column container, so its bounds
            // clamp both stretched and measured cross sizes.
            if (!row) {
                content_cross = constrainContentWidth(
                    item.box.style,
                    content_cross,
                    content.w,
                );
            }
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
    current.needs_layout = false;
    if (current.owner) |owner| {
        switch (owner.kind) {
            .element => |*element| element.rect = current.rect,
            .text => |*text| text.rect = current.rect,
        }
    }
    for (current.children.items) |child| copyRects(child);
}

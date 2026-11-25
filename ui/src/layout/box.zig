//! The derived layout box tree.
//!
//! Layout never walks the DOM. It walks this tree, which is built from the DOM
//! and its authored `Style` declarations. Class declarations come from the
//! document's array-backed stylesheet and are resolved against the parent's
//! computed style during derivation. The shape follows WebKit's
//! LayoutFormattingContext box tree (`Layout::InitialContainingBlock`,
//! `Layout::ElementBox`, `Layout::InlineTextBox`) and TermDOM's box derivation:
//!
//! - one viewport root with no DOM owner,
//! - one principal box per element that generates a box,
//! - anonymous inline boxes for contiguous inline content,
//! - anonymous flex-item boxes for bare text in a flex container,
//! - one text box per text node.
//!
//! `display: none` generates nothing; `display: contents` generates no box of
//! its own and its children join the parent's formatting context while still
//! inheriting its computed style and paint declarations.
//!
//! The tree owns layout invalidation. Because boxes copy the resolved style
//! and text data, structural, style and text changes set `needs_rebuild`;
//! `needs_layout` triggers a solve after the rebuild. Per-box `needs_layout`
//! is kept for the future incremental pass.

const std = @import("std");
const css = @import("../style/css.zig");
const dom = @import("../dom/dom.zig");
const style_mod = @import("../style/style.zig");

pub const Kind = enum {
    initial_containing_block,
    element,
    anonymous_inline,
    anonymous_flex_item,
    text,
};

/// One painted line of a text box. `text` points into the layout pass's
/// processed-text arena, which lives until the next solve.
pub const TextFragment = struct {
    text: []const u8 = "",
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
};

/// One laid-out fragment of a non-atomic inline element. A fragmented inline
/// element can span several lines, so its background and border paint per
/// fragment instead of from one union rect.
pub const InlineFragment = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 1,
};

pub const LayoutBox = struct {
    kind: Kind,
    /// The DOM element/text node this box was generated from. Null for the
    /// viewport and anonymous boxes.
    owner: ?*dom.Node = null,
    style: style_mod.ComputedStyle = .{},
    /// Inherited paint declarations from style-only `display: contents`
    /// ancestors. The painter applies this before the box's own declaration.
    paint_delta: style_mod.PaintStyle = .{},
    /// Inherited text properties, resolved from the computed styles on the way
    /// down the box tree.
    text_style: style_mod.TextStyle = .{},
    /// Inherited mouse pointer shape, resolved from the direct styles on the
    /// way down the box tree (CSS `cursor` inheritance). Text and anonymous
    /// boxes carry the container's computed value.
    pointer: style_mod.Pointer = .default,
    parent: ?*LayoutBox = null,
    children: std.ArrayList(*LayoutBox) = .empty,
    /// Border box.
    rect: style_mod.Rect = .{},
    /// Border box inset by the border widths.
    padding_rect: style_mod.Rect = .{},
    /// Border widths to paint when the terminal supports cell borders. In that
    /// mode `style.border` is zeroed during box derivation, so the border does
    /// not consume layout cells; this copy keeps the requested edges and
    /// widths for the painter.
    cell_border: style_mod.Edges = .{},
    /// Padding box inset by the padding: the content box.
    content_rect: style_mod.Rect = .{},
    /// Paint payload for a `.text` box (elements use `style`).
    paint: style_mod.PaintStyle = .{},
    /// Shared paint style from the editor's class cache.
    paint_ref: ?*const style_mod.PaintStyle = null,
    /// Text content for a `.text` box.
    text: ?[]const u8 = null,
    /// Painted line fragments for a `.text` box. Populated by the layout pass
    /// that places the box; empty means "paint the whole text at `rect`".
    text_fragments: []TextFragment = &.{},
    /// Whether the layout pass has computed `text_fragments` for this text box
    /// (an empty slice then means the text paints nothing).
    has_text_layout: bool = false,
    /// Per-line border boxes for a fragmented non-atomic inline element.
    inline_fragments: []InlineFragment = &.{},
    /// Set when this box or something it contains needs layout. The current
    /// pass solves the whole tree but clears the bits at the end, so the flag
    /// is ready for the incremental pass.
    needs_layout: bool = true,
    /// Cached max-content width of the box's flow content. `-1` means "not
    /// computed for the current intrinsic epoch". The value is independent of
    /// the containing block (percentages resolve as auto), so it survives
    /// solves and resizes and only changes when this box or an ancestor's
    /// style/text/structure changes.
    max_content_width: f64 = -1,
    max_content_epoch: u32 = 0,

    pub fn displayInline(self: *const LayoutBox) bool {
        return switch (self.kind) {
            .element => self.style.display == .inline_,
            .anonymous_inline => true,
            else => false,
        };
    }
};

pub const default_layout_scratch_limit: usize = 32 * 1024 * 1024;

pub const BoxTree = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Per-solve scratch: processed text, break lists, line boxes and text
    /// fragments. It is reset at the start of every layout pass and stays alive
    /// through paint and hit testing.
    scratch: std.heap.ArenaAllocator,
    root: *LayoutBox,
    node_boxes: std.AutoHashMapUnmanaged(*dom.Node, *LayoutBox) = .empty,
    /// A structure, style or text change needs the boxes rebuilt from the DOM.
    needs_rebuild: bool = true,
    /// The rebuilt boxes need the layout solved. Per-box `needs_layout` records
    /// which subtrees are dirty; the current pass still solves all.
    needs_layout: bool = true,
    /// Epoch for cached max-content widths. It only changes when the
    /// document's measurement callback or tab size changes, so ordinary solves
    /// and retained subtree solves reuse previous measurements.
    intrinsic_epoch: u32 = 1,
    intrinsic_measure_width: ?*const fn (u21) u2 = null,
    intrinsic_tab_size: ?usize = null,
    /// Budget for the per-solve scratch arena on the incremental
    /// `layoutSubtree` path. Crossing it marks the tree for a full rebuild,
    /// which resets scratch; `layoutTree` never marks itself, so a legitimate
    /// one-shot solve of a huge scene cannot loop.
    layout_scratch_limit: usize = default_layout_scratch_limit,
    /// The terminal implements the cell-border protocol. Borders paint as cell
    /// attributes on the box edge and do not reserve cells, so `width`,
    /// `height`, padding and content geometry ignore the border widths.
    cell_borders: bool = false,
    /// When false, DOM mutations do not invalidate the tree. The retained
    /// editor view owns a stable document and explicitly marks the line/row
    /// subtrees it changed, like WebKit's layout invalidation on a dirty
    /// subtree. Generic surfaces keep the automatic path.
    auto_invalidate: bool = true,

    pub fn init(allocator: std.mem.Allocator) !BoxTree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const root = try arena.allocator().create(LayoutBox);
        root.* = .{
            .kind = .initial_containing_block,
            .style = rootStyle(),
        };
        return .{
            .allocator = allocator,
            .arena = arena,
            .scratch = std.heap.ArenaAllocator.init(allocator),
            .root = root,
        };
    }

    pub fn create(allocator: std.mem.Allocator) !*BoxTree {
        const self = try allocator.create(BoxTree);
        errdefer allocator.destroy(self);
        self.* = try init(allocator);
        return self;
    }

    pub fn deinit(self: *BoxTree) void {
        self.scratch.deinit();
        self.arena.deinit();
    }

    pub fn destroy(self: *BoxTree) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn observer(self: *BoxTree) dom.MutationObserver {
        return .{ .context = self, .on_mutation = onMutation };
    }

    pub fn find(self: *const BoxTree, node: *dom.Node) ?*LayoutBox {
        return self.node_boxes.get(node);
    }

    /// The element under a viewport point (terminal cells), or null when no box
    /// contains it. The tree is walked in reverse paint order, so a later
    /// sibling wins, and clipping follows `overflow` as the painter does. A hit
    /// on a text box retargets to its parent element, like `elementFromPoint`.
    ///
    /// The tree must have been laid out; `Surface.elementFromPoint` does that
    /// before calling here.
    pub fn elementFromPoint(self: *const BoxTree, x: f64, y: f64) ?*dom.Node {
        const hit = hitTestBox(self.root, x, y, self.root.rect) orelse return null;
        return elementForNode(hit);
    }

    /// The computed mouse pointer shape under a viewport point, or null when no
    /// box contains it. Hit testing follows paint order and clipping exactly
    /// like `elementFromPoint`; text hits read the text box's inherited shape.
    ///
    /// The tree must have been laid out; `Surface.pointerAt` does that before
    /// calling here.
    pub fn pointerAt(self: *const BoxTree, x: f64, y: f64) ?style_mod.Pointer {
        const hit = hitTestBox(self.root, x, y, self.root.rect) orelse return null;
        var node: ?*dom.Node = hit;
        while (node) |current| : (node = current.parent) {
            if (self.node_boxes.get(current)) |box| return box.pointer;
        }
        return null;
    }

    /// Capacity of the per-solve scratch arena. Retained hosts use this to
    /// bound incremental text-fragment growth, which cannot be reclaimed by
    /// `layoutSubtree` because clean boxes still point into the arena.
    pub fn layoutScratchBytes(self: *const BoxTree) usize {
        return self.scratch.queryCapacity();
    }

    /// Sets the per-solve scratch budget used by `layoutSubtree`. Tests use a
    /// tiny value to exercise the fallback without allocating 32 MB.
    pub fn setLayoutScratchLimit(self: *BoxTree, bytes: usize) void {
        self.layout_scratch_limit = @max(bytes, 1);
    }

    /// Called after an incremental subtree solve. If scratch has grown past the
    /// budget, mark the tree for a full rebuild; the next `ensureLayout` uses
    /// `rebuild` + `layoutTree`, which replaces and resets scratch. This keeps
    /// the memory bound in the UI library and out of retained-view hosts.
    pub fn checkLayoutScratchBudget(self: *BoxTree) void {
        if (self.scratch.queryCapacity() <= self.layout_scratch_limit) return;
        self.needs_rebuild = true;
        self.needs_layout = true;
    }

    pub fn clearNeedsLayout(self: *BoxTree) void {
        // Per-box bits are cleared by the layout pass's `copyRects` walk. The
        // tree flag is the only one observed by `Surface.ensureLayout`.
        self.needs_layout = false;
    }

    /// Refreshes the measurement-settings epoch when the document's width
    /// callback or tab size changes. A change only bumps the epoch; boxes keep
    /// their stale values until the next ask and then recompute.
    pub fn syncIntrinsicSettings(self: *BoxTree, doc: *const dom.Document) void {
        if (self.intrinsic_measure_width == doc.measure_width and
            self.intrinsic_tab_size == doc.tab_size)
        {
            return;
        }
        self.intrinsic_measure_width = doc.measure_width;
        self.intrinsic_tab_size = doc.tab_size;
        self.intrinsic_epoch +%= 1;
        if (self.intrinsic_epoch == 0) self.intrinsic_epoch = 1;
    }

    fn invalidateIntrinsicAncestors(start: ?*LayoutBox) void {
        var current = start;
        while (current) |box| : (current = box.parent) box.max_content_epoch = 0;
    }

    /// Switches automatic mutation invalidation. The retained editor view
    /// turns it off after the initial full build and drives the tree through
    /// the explicit subtree calls below.
    pub fn setAutoInvalidate(self: *BoxTree, enabled: bool) void {
        self.auto_invalidate = enabled;
    }

    pub fn markFullRebuild(self: *BoxTree) void {
        self.needs_rebuild = true;
        self.needs_layout = true;
    }

    /// Creates boxes for a newly attached DOM node and appends them under its
    /// parent's box. Returns the new box, or null when the node has no parent
    /// box yet (the caller then falls back to a full rebuild).
    pub fn addSubtree(self: *BoxTree, node: *dom.Node) !?*LayoutBox {
        const parent_node = node.parent orelse return null;
        const parent_box = self.node_boxes.get(parent_node) orelse return null;
        const allocator = self.arena.allocator();
        const inherited = parent_box.style;
        const box = switch (node.kind) {
            .text => |*text| try createTextBox(self, parent_box, node, text, inherited, parent_box.paint_delta),
            .element => |*element| blk: {
                const computed = elementStyle(inherited, node, element);
                switch (computed.display) {
                    .none => return null,
                    .contents => return null,
                    else => {},
                }
                const created = try createElementBox(self, parent_box, node, element, computed, parent_box.paint_delta);
                var run: std.ArrayList(*LayoutBox) = .empty;
                try collectChildren(self, created, node, &run, computed, parent_box.paint_delta, true);
                break :blk created;
            },
        };
        try parent_box.children.append(allocator, box);
        if (box.kind == .element) {
            box.needs_layout = true;
        } else {
            parent_box.needs_layout = true;
        }
        invalidateIntrinsicAncestors(parent_box);
        return box;
    }

    /// Drops the box subtree for a detached DOM node. Absolute siblings are
    /// unaffected, so this does not need a layout pass.
    pub fn removeSubtree(self: *BoxTree, node: *dom.Node) void {
        const box = self.node_boxes.get(node) orelse return;
        if (box.parent) |parent| {
            for (parent.children.items, 0..) |child, index| {
                if (child == box) {
                    _ = parent.children.orderedRemove(index);
                    break;
                }
            }
            invalidateIntrinsicAncestors(parent);
        }
        removeBoxMappings(self, box);
    }

    /// Rebuilds the box children of `node` from the DOM and marks the box for
    /// a targeted layout. Used for a line whose text runs changed and for the
    /// gutter/scrollbar/status parts that update their own subtree.
    pub fn rebuildSubtree(self: *BoxTree, node: *dom.Node) !?*LayoutBox {
        const box = self.node_boxes.get(node) orelse return self.addSubtree(node);
        for (box.children.items) |child| removeBoxMappings(self, child);
        box.children.clearRetainingCapacity();
        if (node.kind == .element) {
            const inherited = if (box.parent) |parent| parent.style else style_mod.ComputedStyle{};
            const computed = elementStyle(inherited, node, node.asElement());
            if (computed.pointer != box.pointer) resolvePointers(box, computed.pointer);
            box.style = computed;
            box.text_style = style_mod.TextStyle.fromComputed(computed);
            box.pointer = computed.pointer;
            if (self.cell_borders) {
                box.cell_border = style_mod.borderWidths(computed);
                box.style.border = .{};
            }
            var run: std.ArrayList(*LayoutBox) = .empty;
            try collectChildren(self, box, node, &run, computed, box.paint_delta, true);
        }
        box.max_content_epoch = 0;
        invalidateIntrinsicAncestors(box.parent);
        box.needs_layout = true;
        return box;
    }

    /// Shifts an existing box subtree by a cell delta without re-running text
    /// layout. Used when a retained line only moves to another row.
    pub fn translateSubtree(self: *BoxTree, node: *dom.Node, dx: f64, dy: f64) bool {
        const box = self.node_boxes.get(node) orelse return false;
        if (node.kind == .element) {
            const inherited = if (box.parent) |parent| parent.style else style_mod.ComputedStyle{};
            const computed = elementStyle(inherited, node, node.asElement());
            if (!std.meta.eql(computed, box.style)) {
                // The cached intrinsic size runs through the changed style and
                // this subtree's inherited text properties.
                box.style = computed;
                box.text_style = style_mod.TextStyle.fromComputed(computed);
                if (self.cell_borders) {
                    box.cell_border = style_mod.borderWidths(computed);
                    box.style.border = .{};
                }
                invalidateIntrinsicSubtree(box);
                invalidateIntrinsicAncestors(box.parent);
            }
            if (computed.pointer != box.pointer) resolvePointers(box, computed.pointer);
        }
        if (dx == 0 and dy == 0) return true;
        shiftBox(box, dx, dy);
        return true;
    }

    /// Discards the derived tree and rebuilds it from the current DOM. The
    /// tree is arena-owned, so this is also the cleanup path between passes.
    pub fn rebuild(self: *BoxTree, doc: *dom.Document) !void {
        // Build into a fresh tree first. All allocations go through
        // `next.arena` so its state owns the whole result; on failure the old
        // tree stays valid, on success the old arena is released and the new
        // tree is installed.
        var next = BoxTree{
            .allocator = self.allocator,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .scratch = std.heap.ArenaAllocator.init(self.allocator),
            .root = undefined,
            .cell_borders = self.cell_borders,
        };
        errdefer {
            next.scratch.deinit();
            next.arena.deinit();
        }

        const allocator = next.arena.allocator();
        const root = try allocator.create(LayoutBox);
        root.* = .{
            .kind = .initial_containing_block,
            .style = rootStyle(),
        };
        next.root = root;

        if (doc.root) |dom_root| {
            const element = dom_root.asElement();
            const computed = elementStyle(root.style, dom_root, element);
            switch (computed.display) {
                .none => {},
                .contents => {
                    var run: std.ArrayList(*LayoutBox) = .empty;
                    const child_delta = style_mod.paintInherit(.{}, computed);
                    try collectChildren(&next, root, dom_root, &run, computed, child_delta, true);
                },
                else => {
                    const element_box = try createElementBox(&next, root, dom_root, element, computed, .{});
                    try root.children.append(allocator, element_box);
                    var run: std.ArrayList(*LayoutBox) = .empty;
                    try collectChildren(&next, element_box, dom_root, &run, computed, .{}, true);
                },
            }
        }

        self.scratch.deinit();
        self.scratch = next.scratch;
        self.arena.deinit();
        self.arena = next.arena;
        self.root = next.root;
        self.node_boxes = next.node_boxes;
        self.needs_rebuild = false;
        self.needs_layout = true;
    }
};

fn hitTestBox(current: *const LayoutBox, x: f64, y: f64, clip: style_mod.Rect) ?*dom.Node {
    switch (current.kind) {
        .text => {
            if (!rectContains(clip, x, y)) return null;
            if (current.has_text_layout) {
                for (current.text_fragments) |fragment| {
                    if (rectContains(clip, x, y) and rectContains(.{
                        .x = fragment.x,
                        .y = fragment.y,
                        .w = fragment.width,
                        .h = 1,
                    }, x, y)) return current.owner;
                }
                return null;
            }
            if (!rectContains(current.rect, x, y)) return null;
            return current.owner;
        },
        .initial_containing_block, .element, .anonymous_inline, .anonymous_flex_item => {
            if (current.kind == .element and current.style.display == .none) return null;
            // The inherited clip bounds everything this subtree paints.
            if (!rectContains(clip, x, y)) return null;

            const child_clip = switch (current.style.overflow) {
                .visible => clip,
                .hidden, .clip => style_mod.Rect.intersect(clip, current.padding_rect),
            };

            // Children are probed last-painted first. A child of a
            // non-clipping box may lie outside the parent's rect and still be
            // hit, so the parent's rect does not gate the descent.
            if (!child_clip.isEmpty() and rectContains(child_clip, x, y)) {
                var index = current.children.items.len;
                while (index > 0) {
                    index -= 1;
                    if (hitTestBox(current.children.items[index], x, y, child_clip)) |hit| {
                        return hit;
                    }
                }
            }

            if (current.owner) |owner| {
                if (current.kind == .element and current.owner.?.asElement().pointer_events) {
                    if (current.inline_fragments.len > 0) {
                        for (current.inline_fragments) |fragment| {
                            if (rectContains(.{
                                .x = fragment.x,
                                .y = fragment.y,
                                .w = fragment.w,
                                .h = fragment.h,
                            }, x, y)) return owner;
                        }
                    } else if (rectContains(current.rect, x, y)) {
                        return owner;
                    }
                }
            }
            return null;
        },
    }
}

fn rectContains(rect: style_mod.Rect, x: f64, y: f64) bool {
    return x >= rect.x and x < rect.right() and y >= rect.y and y < rect.bottom();
}

fn elementForNode(node: *dom.Node) ?*dom.Node {
    var current: ?*dom.Node = node;
    while (current) |candidate| : (current = candidate.parent) {
        if (candidate.isElement()) return candidate;
    }
    return null;
}

fn rootStyle() style_mod.ComputedStyle {
    return .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    };
}

/// Resolves one element's declaration against the inherited computed style.
fn elementStyle(
    inherited: style_mod.ComputedStyle,
    node: *dom.Node,
    element: *dom.Element,
) style_mod.ComputedStyle {
    return css.resolveElementStyle(
        inherited,
        &node.document.class_styles,
        element.classes.items,
        element.style,
        dom.defaultDisplay(element.tag),
    );
}

fn removeBoxMappings(tree: *BoxTree, box: *LayoutBox) void {
    // A DOM node is only mapped to its current box. Retained parts recycle DOM
    // nodes before the owning line rebuilds, so an about-to-be-dropped box can
    // name a node that already belongs to a different box; removing that entry
    // would strand the newer box in the tree without a mapping.
    if (box.owner) |owner| {
        if (tree.node_boxes.get(owner)) |mapped| {
            if (mapped == box) _ = tree.node_boxes.remove(owner);
        }
    }
    for (box.children.items) |child| removeBoxMappings(tree, child);
}

fn invalidateIntrinsicSubtree(box: *LayoutBox) void {
    box.max_content_epoch = 0;
    for (box.children.items) |child| invalidateIntrinsicSubtree(child);
}

fn shiftBox(box: *LayoutBox, dx: f64, dy: f64) void {
    box.rect.x += dx;
    box.rect.y += dy;
    box.padding_rect.x += dx;
    box.padding_rect.y += dy;
    box.content_rect.x += dx;
    box.content_rect.y += dy;
    for (box.text_fragments) |*fragment| {
        fragment.x += dx;
        fragment.y += dy;
    }
    for (box.inline_fragments) |*fragment| {
        fragment.x += dx;
        fragment.y += dy;
    }
    // Keep the measurement-boundary DOM rects in step in the same walk; a
    // separate copyBoxRects pass made every retained scroll touch the tree
    // twice.
    if (box.owner) |owner| {
        switch (owner.kind) {
            .element => |*element| element.rect = box.rect,
            .text => |*text| text.rect = box.rect,
        }
    }
    for (box.children.items) |child| shiftBox(child, dx, dy);
}

/// Re-resolves the inherited pointer after an in-place style update. Anonymous
/// and text boxes have no declaration of their own; only a principal element
/// box keeps its computed `style.pointer`.
fn resolvePointers(box: *LayoutBox, inherited: style_mod.Pointer) void {
    box.pointer = if (box.kind == .element) box.style.pointer else inherited;
    for (box.children.items) |child| resolvePointers(child, box.pointer);
}

fn createElementBox(
    tree: *BoxTree,
    parent: *LayoutBox,
    node: *dom.Node,
    element: *dom.Element,
    computed: style_mod.ComputedStyle,
    paint_delta: style_mod.PaintStyle,
) !*LayoutBox {
    _ = element;
    const allocator = tree.arena.allocator();
    const box = try allocator.create(LayoutBox);
    box.* = .{
        .kind = .element,
        .owner = node,
        .style = computed,
        .paint_delta = paint_delta,
        .text_style = style_mod.TextStyle.fromComputed(computed),
        .pointer = computed.pointer,
        .parent = parent,
    };
    if (tree.cell_borders) {
        // Keep the requested border for paint, but take it out of the box model
        // so the border line sits on the box edge without reserving a cell.
        box.cell_border = style_mod.borderWidths(computed);
        box.style.border = .{};
    }
    try tree.node_boxes.put(allocator, node, box);
    return box;
}

fn createTextBox(
    tree: *BoxTree,
    parent: *LayoutBox,
    node: *dom.Node,
    text: *dom.Text,
    inherited: style_mod.ComputedStyle,
    paint_delta: style_mod.PaintStyle,
) !*LayoutBox {
    const allocator = tree.arena.allocator();
    const box = try allocator.create(LayoutBox);
    box.* = .{
        .kind = .text,
        .owner = node,
        .paint = text.paint,
        .paint_ref = text.paint_ref,
        .paint_delta = paint_delta,
        .text_style = style_mod.TextStyle.resolveFlow(
            style_mod.TextStyle.fromComputed(inherited),
            text.flow,
        ),
        .pointer = inherited.pointer,
        .text = text.data,
        .parent = parent,
    };
    try tree.node_boxes.put(allocator, node, box);
    return box;
}

fn parentIsFlex(parent: *const LayoutBox) bool {
    return parent.style.display == .flex or parent.style.display == .inline_flex;
}

fn collectChildren(
    tree: *BoxTree,
    parent: *LayoutBox,
    dom_parent: *dom.Node,
    run: *std.ArrayList(*LayoutBox),
    inherited: style_mod.ComputedStyle,
    paint_delta: style_mod.PaintStyle,
    flush_at_end: bool,
) !void {
    const allocator = tree.arena.allocator();
    const flex = parentIsFlex(parent);

    var child = dom_parent.first_child;
    while (child) |node| : (child = node.next) {
        switch (node.kind) {
            .text => |*text| {
                const box = try createTextBox(tree, parent, node, text, inherited, paint_delta);
                try run.append(allocator, box);
            },
            .element => |*element| {
                const computed = elementStyle(inherited, node, element);
                switch (computed.display) {
                    .none => continue,
                    .contents => {
                        const child_delta = style_mod.paintInherit(paint_delta, computed);
                        try collectChildren(tree, parent, node, run, computed, child_delta, false);
                    },
                    .inline_, .inline_block, .inline_flex => {
                        if (flex) {
                            // Every in-flow element child of a flex container
                            // is its own flex item.
                            try flushRun(tree, parent, run, inherited);
                            const box = try createElementBox(tree, parent, node, element, computed, paint_delta);
                            try parent.children.append(allocator, box);
                            var sub_run: std.ArrayList(*LayoutBox) = .empty;
                            try collectChildren(tree, box, node, &sub_run, computed, paint_delta, true);
                        } else {
                            const box = try createElementBox(tree, parent, node, element, computed, paint_delta);
                            try run.append(allocator, box);
                            var sub_run: std.ArrayList(*LayoutBox) = .empty;
                            try collectChildren(tree, box, node, &sub_run, computed, paint_delta, true);
                        }
                    },
                    .block, .flex => {
                        try flushRun(tree, parent, run, inherited);
                        const box = try createElementBox(tree, parent, node, element, computed, paint_delta);
                        try parent.children.append(allocator, box);
                        var sub_run: std.ArrayList(*LayoutBox) = .empty;
                        try collectChildren(tree, box, node, &sub_run, computed, paint_delta, true);
                    },
                }
            },
        }
    }

    if (flush_at_end) try flushRun(tree, parent, run, inherited);

    // CSS `order` reorders flex items for layout, painting and hit testing.
    // The sort is stable, so equal orders keep document order.
    if (flex) std.mem.sort(*LayoutBox, parent.children.items, {}, flexOrderLessThan);
}

fn flexOrderLessThan(_: void, a: *LayoutBox, b: *LayoutBox) bool {
    return a.style.order < b.style.order;
}

fn flushRun(
    tree: *BoxTree,
    parent: *LayoutBox,
    run: *std.ArrayList(*LayoutBox),
    style_base: style_mod.ComputedStyle,
) !void {
    if (run.items.len == 0) return;
    const allocator = tree.arena.allocator();
    const flex = parentIsFlex(parent);

    var style = style_base;
    style.position = .static;
    style.top = .auto;
    style.right = .auto;
    style.bottom = .auto;
    style.left = .auto;
    style.width = .auto;
    style.height = .auto;
    style.min_width = .auto;
    style.max_width = .auto;
    style.background = null;
    style.overflow = .visible;
    style.z_index = 0;
    style.margin = .{};
    style.padding = .{};
    style.border = .{};
    style.border_style = .none;
    style.border_color = null;
    style.translate_x = 0;
    style.translate_y = 0;
    style.display = if (flex) .block else .inline_;
    // Flex properties are not inherited; an anonymous box is not a flex
    // container and an anonymous flex item has no order of its own.
    style.flex_direction = .row;
    style.flex_wrap = .nowrap;
    style.justify_content = .flex_start;
    style.align_items = .stretch;
    style.align_self = .auto;
    style.align_content = .stretch;
    style.flex_grow = 0;
    style.flex_shrink = 1;
    style.flex_basis = .auto;
    style.order = 0;
    style.gap = .{};

    const box = try allocator.create(LayoutBox);
    box.* = .{
        .kind = if (flex) .anonymous_flex_item else .anonymous_inline,
        .style = style,
        .text_style = parent.text_style,
        .pointer = parent.pointer,
        .parent = parent,
    };
    try box.children.appendSlice(allocator, run.items);
    for (box.children.items) |child| child.parent = box;
    try parent.children.append(allocator, box);
    run.clearRetainingCapacity();
}

fn onMutation(context: *anyopaque, _: *dom.Node, kind: dom.MutationKind) void {
    const tree: *BoxTree = @ptrCast(@alignCast(context));
    if (!tree.auto_invalidate) return;
    switch (kind) {
        .tree => {
            tree.needs_rebuild = true;
            tree.needs_layout = true;
        },
        // Boxes copy the direct style and the text data when they are built.
        // An in-place update would have to refresh principal, anonymous and
        // text boxes alike (and `display` changes the box shape), so the POC
        // rebuilds the derived tree and relayouts.
        .style, .text => {
            tree.needs_rebuild = true;
            tree.needs_layout = true;
        },
    }
}

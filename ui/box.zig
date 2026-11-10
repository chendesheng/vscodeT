//! The derived layout box tree.
//!
//! Layout never walks the DOM. It walks this tree, which is built from the DOM
//! and the direct `Style` values. The shape follows WebKit's
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
//! its own and its children join the parent's formatting context.
//!
//! The tree owns layout invalidation: `needs_rebuild` for DOM structure changes
//! and `needs_layout` for style/content changes, with per-box `needs_layout`
//! marking the affected subtrees and their ancestors.

const std = @import("std");
const dom = @import("dom.zig");
const style_mod = @import("style.zig");

pub const Kind = enum {
    initial_containing_block,
    element,
    anonymous_inline,
    anonymous_flex_item,
    text,
};

pub const LayoutBox = struct {
    kind: Kind,
    /// The DOM element/text node this box was generated from. Null for the
    /// viewport and anonymous boxes.
    owner: ?*dom.Node = null,
    style: style_mod.Style = .{},
    parent: ?*LayoutBox = null,
    children: std.ArrayList(*LayoutBox) = .empty,
    /// Border box.
    rect: style_mod.Rect = .{},
    /// Border box inset by the border widths.
    padding_rect: style_mod.Rect = .{},
    /// Padding box inset by the padding: the content box.
    content_rect: style_mod.Rect = .{},
    /// Text content for a `.text` box.
    text: ?[]const u8 = null,
    /// Set when this box or something it contains needs layout. The current
    /// pass solves the whole tree but clears the bits at the end, so the flag
    /// is ready for the incremental pass.
    needs_layout: bool = true,
};

pub const BoxTree = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    root: *LayoutBox,
    node_boxes: std.AutoHashMapUnmanaged(*dom.Node, *LayoutBox) = .empty,
    /// A tree/structure change needs the boxes rebuilt from the DOM.
    needs_rebuild: bool = true,
    /// A style/content change needs the layout solved. Per-box `needs_layout`
    /// records which subtrees are dirty; the current pass still solves all.
    needs_layout: bool = true,

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

    pub fn clearNeedsLayout(self: *BoxTree) void {
        clearBoxNeedsLayout(self.root);
        self.needs_layout = false;
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
            .root = undefined,
        };
        errdefer next.arena.deinit();

        const allocator = next.arena.allocator();
        const root = try allocator.create(LayoutBox);
        root.* = .{
            .kind = .initial_containing_block,
            .style = rootStyle(),
        };
        next.root = root;

        if (doc.root) |dom_root| {
            const element = dom_root.asElement();
            switch (element.style.display) {
                .none => {},
                .contents => {
                    var run: std.ArrayList(*LayoutBox) = .empty;
                    try collectChildren(&next, root, dom_root, &run);
                },
                else => {
                    const element_box = try createElementBox(&next, root, dom_root, element);
                    try root.children.append(allocator, element_box);
                    var run: std.ArrayList(*LayoutBox) = .empty;
                    try collectChildren(&next, element_box, dom_root, &run);
                },
            }
        }

        self.arena.deinit();
        self.arena = next.arena;
        self.root = next.root;
        self.node_boxes = next.node_boxes;
        self.needs_rebuild = false;
        self.needs_layout = true;
    }
};

fn rootStyle() style_mod.Style {
    return .{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    };
}

fn createElementBox(
    tree: *BoxTree,
    parent: *LayoutBox,
    node: *dom.Node,
    element: *dom.Element,
) !*LayoutBox {
    const allocator = tree.arena.allocator();
    const box = try allocator.create(LayoutBox);
    box.* = .{
        .kind = .element,
        .owner = node,
        .style = element.style,
        .parent = parent,
    };
    try tree.node_boxes.put(allocator, node, box);
    return box;
}

fn createTextBox(tree: *BoxTree, parent: *LayoutBox, node: *dom.Node, text: *dom.Text) !*LayoutBox {
    const allocator = tree.arena.allocator();
    const box = try allocator.create(LayoutBox);
    box.* = .{
        .kind = .text,
        .owner = node,
        .style = text.style,
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
) !void {
    const allocator = tree.arena.allocator();
    const flex = parentIsFlex(parent);

    var child = dom_parent.first_child;
    while (child) |node| : (child = node.next) {
        switch (node.kind) {
            .text => |*text| {
                const box = try createTextBox(tree, parent, node, text);
                try run.append(allocator, box);
            },
            .element => |*element| {
                switch (element.style.display) {
                    .none => continue,
                    .contents => {
                        try collectChildren(tree, parent, node, run);
                    },
                    .inline_, .inline_block, .inline_flex => {
                        if (flex) {
                            // Every in-flow element child of a flex container
                            // is its own flex item.
                            try flushRun(tree, parent, run);
                            const box = try createElementBox(tree, parent, node, element);
                            try parent.children.append(allocator, box);
                            var sub_run: std.ArrayList(*LayoutBox) = .empty;
                            try collectChildren(tree, box, node, &sub_run);
                        } else {
                            const box = try createElementBox(tree, parent, node, element);
                            try run.append(allocator, box);
                            var sub_run: std.ArrayList(*LayoutBox) = .empty;
                            try collectChildren(tree, box, node, &sub_run);
                        }
                    },
                    .block, .flex => {
                        try flushRun(tree, parent, run);
                        const box = try createElementBox(tree, parent, node, element);
                        try parent.children.append(allocator, box);
                        var sub_run: std.ArrayList(*LayoutBox) = .empty;
                        try collectChildren(tree, box, node, &sub_run);
                    },
                }
            },
        }
    }

    try flushRun(tree, parent, run);
}

fn flushRun(
    tree: *BoxTree,
    parent: *LayoutBox,
    run: *std.ArrayList(*LayoutBox),
) !void {
    if (run.items.len == 0) return;
    const allocator = tree.arena.allocator();
    const flex = parentIsFlex(parent);

    var style = parent.style;
    style.position = .static;
    style.top = .auto;
    style.right = .auto;
    style.bottom = .auto;
    style.left = .auto;
    style.width = .auto;
    style.height = .auto;
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

    const box = try allocator.create(LayoutBox);
    box.* = .{
        .kind = if (flex) .anonymous_flex_item else .anonymous_inline,
        .style = style,
        .parent = parent,
    };
    try box.children.appendSlice(allocator, run.items);
    try parent.children.append(allocator, box);
    run.clearRetainingCapacity();
}

fn clearBoxNeedsLayout(box: *LayoutBox) void {
    box.needs_layout = false;
    for (box.children.items) |child| clearBoxNeedsLayout(child);
}

fn markNeedsLayout(tree: *BoxTree, box: *LayoutBox) void {
    var current: ?*LayoutBox = box;
    while (current) |item| {
        item.needs_layout = true;
        if (item == tree.root) break;
        current = item.parent;
    }
    tree.needs_layout = true;
}

fn onMutation(context: *anyopaque, node: *dom.Node, kind: dom.MutationKind) void {
    const tree: *BoxTree = @ptrCast(@alignCast(context));
    switch (kind) {
        .tree => {
            tree.needs_rebuild = true;
            tree.needs_layout = true;
        },
        .style, .text => {
            if (tree.find(node)) |box| {
                markNeedsLayout(tree, box);
            } else {
                tree.needs_rebuild = true;
                tree.needs_layout = true;
            }
        },
    }
}

test "BoxTree: principal, text and anonymous boxes" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
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

    const text = try doc.createText("hello");
    _ = try root.appendChild(text);

    const block = try doc.createElement(.div);
    block.setStyle(.{ .position = .absolute, .width = .{ .cells = 4 }, .height = .{ .cells = 1 } });
    _ = try root.appendChild(block);

    const hidden = try doc.createElement(.div);
    hidden.setStyle(.{ .display = .none });
    _ = try root.appendChild(hidden);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    try std.testing.expectEqual(Kind.initial_containing_block, tree.root.kind);
    try std.testing.expect(tree.root.owner == null);

    const root_box = tree.find(root).?;
    try std.testing.expectEqual(Kind.element, root_box.kind);
    try std.testing.expectEqual(root, root_box.owner.?);

    try std.testing.expectEqual(@as(usize, 2), tree.root.children.items[0].children.items.len);
    const run = tree.root.children.items[0].children.items[0];
    try std.testing.expectEqual(Kind.anonymous_inline, run.kind);
    try std.testing.expect(run.owner == null);
    try std.testing.expectEqual(@as(usize, 1), run.children.items.len);
    try std.testing.expectEqual(Kind.text, run.children.items[0].kind);

    try std.testing.expect(tree.find(hidden) == null);
}

test "BoxTree: display:contents promotes children into the inline run" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("a"));

    const contents = try doc.createElement(.span);
    contents.setStyle(.{ .display = .contents });
    _ = try root.appendChild(contents);
    _ = try contents.appendChild(try doc.createText("b"));

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    const root_box = tree.find(root).?;
    try std.testing.expectEqual(@as(usize, 1), root_box.children.items.len);
    const run = root_box.children.items[0];
    try std.testing.expectEqual(Kind.anonymous_inline, run.kind);
    try std.testing.expectEqual(@as(usize, 2), run.children.items.len);
    try std.testing.expect(tree.find(contents) == null);
}

test "BoxTree: flex text runs become anonymous flex items" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{ .display = .flex });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("a"));

    const item = try doc.createElement(.div);
    _ = try root.appendChild(item);

    _ = try root.appendChild(try doc.createText("b"));

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    const root_box = tree.find(root).?;
    try std.testing.expectEqual(@as(usize, 3), root_box.children.items.len);
    try std.testing.expectEqual(Kind.anonymous_flex_item, root_box.children.items[0].kind);
    try std.testing.expectEqual(Kind.element, root_box.children.items[1].kind);
    try std.testing.expectEqual(Kind.anonymous_flex_item, root_box.children.items[2].kind);
}

test "BoxTree: mutations mark the affected boxes and the tree" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const text = try doc.createText("x");
    _ = try root.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    defer doc.setObserver(null);
    doc.setObserver(tree.observer());
    try tree.rebuild(&doc);
    tree.clearNeedsLayout();
    try std.testing.expect(!tree.needs_layout);
    try std.testing.expect(!tree.needs_rebuild);

    root.setStyle(.{ .color = .{ .r = 1, .g = 2, .b = 3 } });
    try std.testing.expect(tree.needs_layout);
    try std.testing.expect(tree.find(root).?.needs_layout);

    tree.clearNeedsLayout();
    try text.setTextContent("y");
    try std.testing.expect(tree.needs_layout);
    try std.testing.expect(tree.find(text).?.needs_layout);

    tree.clearNeedsLayout();
    _ = try root.appendChild(try doc.createText("z"));
    try std.testing.expect(tree.needs_rebuild);
}

const std = @import("std");
const ui = @import("ui");
const dom = ui.dom;
const style_mod = ui.style;
const Kind = ui.box.Kind;
const BoxTree = ui.box.BoxTree;

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

test "BoxTree: style, text and tree mutations rebuild" {
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
    try std.testing.expect(tree.needs_rebuild);
    try std.testing.expect(tree.needs_layout);
    try tree.rebuild(&doc);
    try std.testing.expectEqual(@as(?style_mod.Color, .{ .r = 1, .g = 2, .b = 3 }), tree.find(root).?.style.color);

    tree.clearNeedsLayout();
    try text.setTextContent("y");
    try std.testing.expect(tree.needs_rebuild);
    try tree.rebuild(&doc);
    try std.testing.expectEqualStrings("y", tree.find(text).?.text.?);

    tree.clearNeedsLayout();
    _ = try root.appendChild(try doc.createText("z"));
    try std.testing.expect(tree.needs_rebuild);
}

test "BoxTree: flex order sorts children stably" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{ .display = .flex });
    doc.setRoot(root);

    const first = try doc.createElement(.div);
    first.setStyle(.{ .order = 2 });
    _ = try root.appendChild(first);

    const second = try doc.createElement(.div);
    second.setStyle(.{ .order = 0 });
    _ = try root.appendChild(second);

    const third = try doc.createElement(.div);
    third.setStyle(.{ .order = 0 });
    _ = try root.appendChild(third);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    const children = tree.find(root).?.children.items;
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expectEqual(second, children[0].owner.?);
    try std.testing.expectEqual(third, children[1].owner.?);
    try std.testing.expectEqual(first, children[2].owner.?);
}

test "BoxTree: text styles inherit from ancestors and can be overridden" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{ .white_space = .nowrap, .word_break = .keep_all });
    doc.setRoot(root);
    const plain = try doc.createText("a");
    _ = try root.appendChild(plain);
    const override = try doc.createText("b");
    override.setStyle(.{ .white_space = .pre, .word_break = .break_all });
    _ = try root.appendChild(override);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    try std.testing.expectEqual(style_mod.WhiteSpace.nowrap, tree.find(plain).?.text_style.white_space);
    try std.testing.expectEqual(style_mod.WordBreak.keep_all, tree.find(plain).?.text_style.word_break);
    try std.testing.expectEqual(style_mod.WhiteSpace.pre, tree.find(override).?.text_style.white_space);
    try std.testing.expectEqual(style_mod.WordBreak.break_all, tree.find(override).?.text_style.word_break);
}

test "BoxTree: pointer inherits through elements and text boxes" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{ .pointer = .text });
    doc.setRoot(root);

    const plain = try doc.createText("a");
    _ = try root.appendChild(plain);

    const child = try doc.createElement(.div);
    child.setStyle(.{ .pointer = .pointer });
    _ = try root.appendChild(child);
    const linked = try doc.createText("b");
    _ = try child.appendChild(linked);

    const reset = try doc.createElement(.div);
    reset.setStyle(.{ .pointer = .default });
    _ = try root.appendChild(reset);
    const plain_again = try doc.createText("c");
    _ = try reset.appendChild(plain_again);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    try std.testing.expectEqual(style_mod.Pointer.default, tree.root.pointer);
    try std.testing.expectEqual(style_mod.Pointer.text, tree.find(root).?.pointer);
    try std.testing.expectEqual(style_mod.Pointer.text, tree.find(plain).?.pointer);
    try std.testing.expectEqual(style_mod.Pointer.pointer, tree.find(child).?.pointer);
    try std.testing.expectEqual(style_mod.Pointer.pointer, tree.find(linked).?.pointer);
    try std.testing.expectEqual(style_mod.Pointer.default, tree.find(reset).?.pointer);
    try std.testing.expectEqual(style_mod.Pointer.default, tree.find(plain_again).?.pointer);
}

test "BoxTree: translateSubtree refreshes descendant pointers" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const text = try doc.createText("a");
    _ = try root.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try std.testing.expectEqual(style_mod.Pointer.default, tree.find(text).?.pointer);

    root.setStyle(.{ .pointer = .text });
    try std.testing.expect(tree.translateSubtree(root, 0, 0));
    try std.testing.expectEqual(style_mod.Pointer.text, tree.find(text).?.pointer);
}

test "BoxTree: rebuilding a line keeps boxes of recycled DOM nodes" {
    // Retained view parts recycle DOM nodes before the owning line is rebuilt:
    // `ViewLine.paint` drops the line's children while their boxes are still in
    // the tree, and a part rendered later in the same frame may reuse those
    // nodes and give them new boxes. Rebuilding the line afterwards must only
    // drop the old boxes, not the mappings of the reused nodes.
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const line = try doc.createElement(.div);
    _ = try root.appendChild(line);
    const run = try doc.createElement(.span);
    _ = try line.appendChild(run);
    const run_text = try doc.createText("x");
    _ = try run.appendChild(run_text);
    const gutter = try doc.createElement(.div);
    _ = try root.appendChild(gutter);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    const line_box = tree.find(line).?;

    // The retained line drops its children. Their boxes stay in the tree until
    // `syncBoxes` rebuilds the line.
    line.clearChildren();

    // A part rendered before that rebuild reuses the recycled nodes (the free
    // list is LIFO: the element and then its text node).
    const row = try doc.createElement(.div);
    try std.testing.expectEqual(run, row);
    _ = try gutter.appendChild(row);
    const label = try doc.createTextBorrowed("y");
    try std.testing.expectEqual(run_text, label);
    _ = try row.appendChild(label);
    const row_box = (try tree.addSubtree(row)).?;
    try std.testing.expectEqual(row_box, tree.find(row).?);
    try std.testing.expect(tree.find(label) != null);

    // Rebuilding the line drops its stale boxes without unlinking the
    // recycled nodes' current mappings.
    _ = try tree.rebuildSubtree(line);
    try std.testing.expectEqual(@as(usize, 0), line_box.children.items.len);
    try std.testing.expectEqual(row_box, tree.find(row).?);
    try std.testing.expect(tree.find(label) != null);

    // The reused subtree is still removable: its parent box finds it by the
    // mapping that the line rebuild preserved.
    tree.removeSubtree(row);
    try std.testing.expect(tree.find(row) == null);
    try std.testing.expect(tree.find(label) == null);
}

test "BoxTree: class declarations cascade and inherit computed values" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();

    const Class = enum(u16) { panel, selected };
    _ = try doc.registerSheet(.{ .styles = &.{
        .{
            .text_align = .center,
            .width = .{ .cells = 10 },
            .padding = .{ .left = 1 },
            .color = .{ .r = 200, .g = 20, .b = 20 },
            .bold = true,
        },
        .{
            .background = .{ .r = 0, .g = 0, .b = 100 },
            .bold = false,
        },
    } });

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .height = .{ .cells = 2 },
    });
    try root.setClasses(&.{ Class.panel, Class.selected });
    doc.setRoot(root);

    const child = try doc.createElement(.div);
    _ = try child.appendChild(try doc.createText("x"));
    _ = try root.appendChild(child);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    const root_box = tree.find(root).?;
    try std.testing.expectEqual(style_mod.TextAlign.center, root_box.style.text_align);
    try std.testing.expectEqual(@as(f64, 10), root_box.style.width.cells);
    try std.testing.expectEqual(@as(f64, 1), root_box.style.padding.left);
    try std.testing.expectEqual(@as(u8, 0), root_box.style.background.?.r);
    try std.testing.expectEqual(@as(?bool, false), root_box.style.bold);
    try std.testing.expectEqual(@as(u8, 200), root_box.style.color.?.r);

    const child_box = tree.find(child).?;
    // Inherited: text alignment. Not inherited: width/background.
    try std.testing.expectEqual(style_mod.TextAlign.center, child_box.style.text_align);
    try std.testing.expectEqual(style_mod.Dimension.auto, child_box.style.width);
    try std.testing.expectEqual(@as(?style_mod.Color, null), child_box.style.background);
}

test "BoxTree: display none and contents resolve from class declarations" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 4 });
    defer doc.deinit();

    const Class = enum(u16) { hidden, contents, red };
    _ = try doc.registerSheet(.{ .styles = &.{
        .{ .display = .none },
        .{ .display = .contents, .white_space = .pre, .pointer = .pointer },
        .{ .color = .{ .r = 9, .g = 8, .b = 7 } },
    } });

    const root = try doc.createElement(.div);
    doc.setRoot(root);

    const hidden = try doc.createElement(.div);
    try hidden.setClasses(&.{Class.hidden});
    _ = try root.appendChild(hidden);
    _ = try hidden.appendChild(try doc.createText("hidden"));

    const contents = try doc.createElement(.div);
    try contents.setClasses(&.{ Class.contents, Class.red });
    _ = try contents.appendChild(try doc.createText("shown"));
    _ = try root.appendChild(contents);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);

    try std.testing.expect(tree.find(hidden) == null);
    try std.testing.expect(tree.find(contents) == null);
    // The contents element has no box, but its text child inherits its
    // computed alignment, color declaration and paint delta.
    const text_box = tree.find(contents.firstChild().?).?;
    try std.testing.expectEqual(style_mod.WhiteSpace.pre, text_box.text_style.white_space);
    try std.testing.expectEqual(style_mod.Pointer.pointer, text_box.pointer);
    try std.testing.expectEqual(@as(u8, 9), text_box.paint_delta.color.?.r);
}

const std = @import("std");
const ui = @import("ui");
const dom = ui.dom;
const style_mod = ui.style;
const BoxTree = ui.layout.BoxTree;
const layoutDocument = ui.layout.layoutDocument;
const layoutTree = ui.layout.layoutTree;
const layoutSubtree = ui.layout.layoutSubtree;

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
        .margin = style_mod.MarginDecl.all(1),
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
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
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
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

test "layout: min-width and max-width clamp block content boxes" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 24, .rows = 12 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 10 },
    });
    doc.setRoot(root);

    const maxed = try testBox(&doc, root, .{
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
        .max_width = .{ .cells = 3 },
    });
    const minned = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .min_width = .{ .cells = 5 },
    });
    const conflict = try testBox(&doc, root, .{
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
        .min_width = .{ .cells = 5 },
        .max_width = .{ .cells = 3 },
    });
    const padded = try testBox(&doc, root, .{
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
        .max_width = .{ .cells = 3 },
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
    });

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    try std.testing.expectEqual(@as(f64, 3), maxed.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 5), minned.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 5), conflict.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 7), padded.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), tree.find(padded).?.content_rect.w);
}

test "layout: max-width shrinks an auto block and auto margins center it" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 10 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 10 },
    });
    doc.setRoot(root);

    const centered = try testBox(&doc, root, .{
        .height = .{ .cells = 1 },
        .max_width = .{ .cells = 6 },
        .margin = .{ .left = .auto, .right = .auto },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 6), centered.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 7), centered.asElement().rect.x);
}

test "layout: min-width and max-width resolve percentages" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 24, .rows = 8 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 8 },
    });
    doc.setRoot(root);

    const maxed = try testBox(&doc, root, .{
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .max_width = .{ .percent = 25 },
    });
    const minned = try testBox(&doc, root, .{
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
        .min_width = .{ .percent = 50 },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 5), maxed.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 10), minned.asElement().rect.w);
}

test "layout: max-width wraps text and grows auto height" {
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

    const paragraph = try testBox(&doc, root, .{
        .max_width = .{ .cells = 5 },
    });
    const text = try doc.createText("one two three");
    _ = try paragraph.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    const text_box = tree.find(text).?;
    try std.testing.expectEqual(@as(usize, 3), text_box.text_fragments.len);
    try std.testing.expectEqual(@as(f64, 0), text_box.text_fragments[0].y);
    try std.testing.expectEqual(@as(f64, 1), text_box.text_fragments[1].y);
    try std.testing.expectEqual(@as(f64, 2), text_box.text_fragments[2].y);
    try std.testing.expectEqual(@as(f64, 5), paragraph.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), paragraph.asElement().rect.h);
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
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
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

fn testBox(doc: *dom.Document, parent: *dom.Node, style: style_mod.Style) !*dom.Node {
    const node = try doc.createElement(.div);
    node.setStyle(style);
    _ = try parent.appendChild(node);
    return node;
}

fn testText(doc: *dom.Document, parent: *dom.Node, data: []const u8, style: style_mod.Style) !*dom.Node {
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

test "layout: max-width caps flex-grow" {
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
        .max_width = .{ .cells = 4 },
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
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

test "layout: min-width prevents flex-shrink" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 8 },
        .height = .{ .cells = 1 },
        .display = .flex,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .width = .{ .cells = 10 },
        .height = .{ .cells = 1 },
        .flex_shrink = 1,
        .min_width = .{ .cells = 7 },
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
        .flex_shrink = 1,
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 7), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 1), b.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 7), b.asElement().rect.x);
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

test "layout: max-width clamps a stretched flex column item" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 10 },
        .height = .{ .cells = 5 },
        .display = .flex,
        .flex_direction = .column,
        .align_items = .stretch,
    });
    doc.setRoot(root);

    const a = try testBox(&doc, root, .{
        .height = .{ .cells = 1 },
        .max_width = .{ .cells = 6 },
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 6), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 4), b.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 1), b.asElement().rect.y);
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

test "layout: block text does not expand flex item ancestor rects" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 1 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 1 },
        .display = .flex,
    });
    doc.setRoot(root);

    const spacer = try testBox(&doc, root, .{
        .width = .{ .cells = 5 },
        .height = .{ .cells = 1 },
        .flex_shrink = 0,
    });
    const item = try testBox(&doc, root, .{
        .display = .inline_block,
        .height = .{ .cells = 1 },
    });
    const label = try testBox(&doc, item, .{
        .display = .flex,
        .height = .{ .percent = 100 },
        .padding = .{ .left = 1, .right = 1 },
    });
    const text = try testText(&doc, label, "B", .{});

    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), spacer.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 5), item.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 3), item.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 5), label.asElement().rect.x);
    try std.testing.expectEqual(@as(f64, 3), label.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 6), text.asText().rect.x);
}

test "layout: max-width shrink-wraps an inline-block" {
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
        .display = .inline_block,
        .max_width = .{ .cells = 4 },
    });
    const text = try testText(&doc, inline_box, "abcdefghij", .{});
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 4), inline_box.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 10), text.asText().rect.w);
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

test "layout: max-width clamps the flex base size" {
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
        .height = .{ .cells = 1 },
        .flex_basis = .{ .cells = 8 },
        .max_width = .{ .cells = 3 },
    });
    const b = try testBox(&doc, root, .{
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
    });
    try layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 3), a.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), b.asElement().rect.x);
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
        .padding = style_mod.EdgeDecl.all(1),
        .border = style_mod.EdgeDecl.all(1),
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
        .border = style_mod.EdgeDecl.all(10),
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

test "layout: text-align inherits into a nested block" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 10 },
        .text_align = .center,
    });
    doc.setRoot(root);

    const child = try doc.createElement(.div);
    child.setStyle(.{ .width = .{ .cells = 10 } });
    _ = try root.appendChild(child);
    const text = try doc.createText("abc");
    _ = try child.appendChild(text);

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);

    // 10-cell line, 3-cell text, centred by the inherited text-align.
    try std.testing.expectEqual(@as(f64, 3.5), text.asText().rect.x);
}

test "layout: intrinsic cache invalidates after a retained subtree rebuild" {
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
    const second_text = try testText(&doc, second, "de", .{});
    _ = try testText(&doc, second, "fg", .{});

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);
    try std.testing.expectEqual(@as(f64, 4), tree.find(second).?.rect.w);

    // A retained row rebuild keeps the DOM nodes but replaces the boxes'
    // children and style. The ancestor flex container's cached max-content
    // width must be dropped, then re-solved through layoutSubtree.
    try second_text.setTextContent("defghi");
    _ = try tree.rebuildSubtree(root);
    const root_box = tree.find(root).?;
    try layoutSubtree(&tree, &doc, root_box);
    try std.testing.expectEqual(@as(f64, 8), tree.find(second).?.rect.w);
}

test "layout: layoutSubtree marks a full rebuild when scratch crosses its budget" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 20, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .cells = 20 },
        .height = .{ .cells = 5 },
    });
    doc.setRoot(root);
    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .top = .{ .cells = 0 },
        .width = .{ .cells = 20 },
        .height = .{ .cells = 1 },
        .white_space = .pre,
    });
    _ = try root.appendChild(line);
    _ = try line.appendChild(try doc.createText("hello"));

    var tree = try BoxTree.init(allocator);
    defer tree.deinit();
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);
    try std.testing.expect(!tree.needs_rebuild);

    tree.setLayoutScratchLimit(1);
    try layoutSubtree(&tree, &doc, tree.find(line).?);
    try std.testing.expect(tree.needs_rebuild);
    try std.testing.expect(tree.needs_layout);

    // The full rebuild + solve clears the flag and replaces scratch.
    try tree.rebuild(&doc);
    try layoutTree(&tree, &doc);
    try std.testing.expect(!tree.needs_rebuild);
}

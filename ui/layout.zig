//! Whole-cell layout over the derived box tree.
//!
//! The solver never touches the DOM. It computes `LayoutBox` geometry and
//! copies the border box back to the DOM nodes only for the measurement
//! boundary.
//!
//! Supported box model: content box (`width`/`height`), padding, border and
//! margin, with absolute `left`/`top` anchoring the margin box. Block flow,
//! inline text and clipping follow. Flex formatting contexts and margin
//! collapsing are the next additions.

const std = @import("std");
const box = @import("box.zig");
const dom = @import("dom.zig");
const style_mod = @import("style.zig");

pub const Rect = style_mod.Rect;
pub const Style = style_mod.Style;
pub const Dimension = style_mod.Dimension;
pub const Edges = style_mod.Edges;
pub const LayoutBox = box.LayoutBox;
pub const BoxTree = box.BoxTree;

/// Convenience for tests and one-shot callers: build a box tree, solve it and
/// copy the geometry back to the DOM nodes.
pub fn layoutDocument(doc: *dom.Document) !void {
    var tree = try BoxTree.init(doc.allocator);
    defer tree.deinit();
    try tree.rebuild(doc);
    layoutTree(&tree, doc);
}

pub fn layoutTree(tree: *BoxTree, doc: *dom.Document) void {
    const viewport = Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(doc.cols),
        .h = @floatFromInt(doc.rows),
    };
    tree.root.rect = viewport;
    tree.root.padding_rect = viewport;
    tree.root.content_rect = viewport;
    layoutChildren(doc, tree.root, viewport, viewport);
    copyRects(tree.root);
    tree.clearNeedsLayout();
}

fn layoutBox(doc: *dom.Document, current: *LayoutBox, containing: Rect) void {
    switch (current.kind) {
        .initial_containing_block => {
            current.rect = containing;
            current.padding_rect = containing;
            current.content_rect = containing;
            layoutChildren(doc, current, containing, containing);
        },
        .element, .anonymous_flex_item => layoutElementBox(doc, current, containing),
        .anonymous_inline => {
            const width = inlineWidth(doc, current);
            layoutInlineBox(doc, current, containing.x, containing.y, width);
        },
        .text => {
            current.rect = .{
                .x = containing.x,
                .y = containing.y,
                .w = @floatFromInt(doc.measureText(current.text orelse "")),
                .h = 1,
            };
        },
    }
}

fn layoutElementBox(doc: *dom.Document, current: *LayoutBox, containing: Rect) void {
    const style = current.style;
    if (style.display == .none or style.display == .contents) {
        current.rect = .{};
        current.padding_rect = .{};
        current.content_rect = .{};
        return;
    }

    const margin = style.margin;
    const padding = style.padding.nonNegative();
    const border = style_mod.borderWidths(style);

    const positioned = style.position == .absolute or style.position == .fixed;
    const relative = style.position == .relative;
    const x_shift = resolve(style.left, containing.w) orelse 0;
    const y_shift = resolve(style.top, containing.h) orelse 0;

    const extra_width = margin.horizontal() + padding.horizontal() + border.horizontal();
    const content_width = resolve(style.width, containing.w) orelse
        @max(0, containing.w - extra_width);
    const content_height = resolve(style.height, containing.h) orelse 1;

    var x = containing.x + margin.left + style.translate_x;
    var y = containing.y + margin.top + style.translate_y;
    if (positioned or relative) {
        x += x_shift;
        y += y_shift;
    }

    const border_width = content_width + padding.horizontal() + border.horizontal();
    const border_height = content_height + padding.vertical() + border.vertical();

    current.rect = .{ .x = x, .y = y, .w = border_width, .h = border_height };
    current.padding_rect = current.rect.inset(border);
    current.content_rect = current.padding_rect.inset(padding);

    // Absolutely positioned descendants resolve against the padding box of a
    // positioned ancestor; otherwise the containing block stays above.
    const child_containing = if (positioned or relative) current.padding_rect else containing;
    layoutChildren(doc, current, current.content_rect, child_containing);
}

fn layoutChildren(
    doc: *dom.Document,
    parent: *const LayoutBox,
    content: Rect,
    absolute_containing: Rect,
) void {
    var block_y = content.y;
    for (parent.children.items) |child| {
        switch (child.kind) {
            .anonymous_inline => {
                const width = inlineWidth(doc, child);
                const offset = alignOffset(parent.style.text_align, content.w, width);
                layoutInlineBox(doc, child, content.x + offset, block_y, width);
                block_y += 1;
            },
            .text => {
                child.rect = .{
                    .x = content.x,
                    .y = block_y,
                    .w = @floatFromInt(doc.measureText(child.text orelse "")),
                    .h = 1,
                };
                block_y += 1;
            },
            .element, .anonymous_flex_item, .initial_containing_block => {
                if (child.style.position == .absolute or child.style.position == .fixed) {
                    layoutBox(doc, child, absolute_containing);
                } else {
                    layoutElementBox(doc, child, .{
                        .x = content.x,
                        .y = block_y,
                        .w = content.w,
                        .h = @max(1, content.bottom() - block_y),
                    });
                    block_y = child.rect.bottom() + child.style.margin.bottom;
                }
            },
        }
    }
}

fn inlineWidth(doc: *const dom.Document, current: *const LayoutBox) f64 {
    var width: f64 = 0;
    for (current.children.items) |child| {
        switch (child.kind) {
            .text => width += @floatFromInt(doc.measureText(child.text orelse "")),
            .element, .anonymous_inline, .anonymous_flex_item => {
                const style = child.style;
                const padding = style.padding.nonNegative();
                const border = style_mod.borderWidths(style);
                width += (resolve(style.width, 0) orelse 0) +
                    style.margin.horizontal() +
                    padding.horizontal() +
                    border.horizontal();
            },
            .initial_containing_block => {},
        }
    }
    return width;
}

fn layoutInlineBox(
    doc: *dom.Document,
    current: *LayoutBox,
    x: f64,
    y: f64,
    width: f64,
) void {
    current.rect = .{ .x = x, .y = y, .w = width, .h = 1 };
    current.padding_rect = current.rect;
    current.content_rect = current.rect;

    var cursor = x;
    for (current.children.items) |child| {
        switch (child.kind) {
            .text => {
                const text_width: f64 = @floatFromInt(doc.measureText(child.text orelse ""));
                child.rect = .{ .x = cursor, .y = y, .w = text_width, .h = 1 };
                cursor += text_width;
            },
            .element, .anonymous_inline, .anonymous_flex_item => {
                const style = child.style;
                const padding = style.padding.nonNegative();
                const border = style_mod.borderWidths(style);
                const child_width = (resolve(style.width, 0) orelse 0) +
                    style.margin.horizontal() +
                    padding.horizontal() +
                    border.horizontal();
                child.rect = .{ .x = cursor, .y = y, .w = child_width, .h = 1 };
                cursor += child_width;
            },
            .initial_containing_block => {},
        }
    }
}

fn alignOffset(alignment: style_mod.TextAlign, container_width: f64, content_width: f64) f64 {
    return switch (alignment) {
        .left => 0,
        .center => @max(0, (container_width - content_width) / 2),
        .right => @max(0, container_width - content_width),
    };
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

pub fn resolve(dimension: Dimension, base: f64) ?f64 {
    return switch (dimension) {
        .auto => null,
        .cells => |value| value,
        .percent => |percent| base * percent / 100.0,
    };
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
    layoutTree(&tree, &doc);

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

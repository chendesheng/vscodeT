//! Whole-cell layout for the terminal tree.
//!
//! The editor view positions its parts explicitly, so the POC layout pass is
//! deliberately small: absolute positioning against the nearest positioned
//! ancestor, one row of inline text per element, alignment and percentages.
//! Flexbox/grid/block wrapping belong to a later widget layer.

const std = @import("std");
const dom = @import("dom.zig");
const style_mod = @import("style.zig");

pub const Rect = style_mod.Rect;
pub const Style = style_mod.Style;
pub const Dimension = style_mod.Dimension;

pub fn layoutDocument(doc: *dom.Document) void {
    const root = doc.root orelse return;
    const viewport = Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(doc.cols),
        .h = @floatFromInt(doc.rows),
    };
    layoutNode(doc, root, viewport);
}

fn layoutNode(doc: *dom.Document, node: *dom.Node, containing: Rect) void {
    switch (node.kind) {
        .element => |*element| layoutElement(doc, node, element, containing),
        .text => |*text| {
            text.rect = .{
                .x = containing.x,
                .y = containing.y,
                .w = @floatFromInt(doc.measureText(text.data)),
                .h = 1,
            };
        },
    }
}

fn layoutElement(
    doc: *dom.Document,
    node: *dom.Node,
    element: *dom.Element,
    containing: Rect,
) void {
    const style = element.style;
    if (style.display == .none or style.visibility == .hidden) {
        element.rect = .{};
        return;
    }

    const positioned = style.position != .static;
    const x_shift = resolve(style.left, containing.w) orelse 0;
    const y_shift = resolve(style.top, containing.h) orelse 0;

    // Absolute boxes are placed against their containing block; static boxes
    // start at the containing block's origin. Relative boxes use left/top as
    // a shift only.
    var x = containing.x + style.translate_x;
    var y = containing.y + style.translate_y;
    if (positioned) {
        x += x_shift;
        y += y_shift;
    } else if (style.position == .relative) {
        x += x_shift;
        y += y_shift;
    }

    const width = resolve(style.width, containing.w) orelse containing.w;
    const height = resolve(style.height, containing.h) orelse 1;
    element.rect = .{ .x = x, .y = y, .w = width, .h = height };

    // Children of a positioned box are placed against it; otherwise the
    // containing block stays the one above.
    const child_containing = if (positioned) element.rect else containing;

    // Inline content: one row of text nodes, then text-align.
    var inline_width: f64 = 0;
    {
        var child = node.first_child;
        while (child) |current| : (child = current.next) {
            switch (current.kind) {
                .text => |*text| inline_width += @floatFromInt(doc.measureText(text.data)),
                .element => {},
            }
        }
    }
    const align_offset = switch (style.text_align) {
        .left => 0,
        .center => @max(0, (width - inline_width) / 2),
        .right => @max(0, width - inline_width),
    };

    var cursor_x = element.rect.x + align_offset;
    var block_y = element.rect.y;
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        switch (current.kind) {
            .text => |*text| {
                const text_width: f64 = @floatFromInt(doc.measureText(text.data));
                text.rect = .{
                    .x = cursor_x,
                    .y = element.rect.y,
                    .w = text_width,
                    .h = 1,
                };
                cursor_x += text_width;
            },
            .element => |*child_element| {
                if (child_element.style.display == .none) continue;
                if (child_element.style.position != .static) {
                    layoutElement(doc, current, child_element, child_containing);
                    continue;
                }
                if (child_element.style.display == .inline_ or
                    child_element.style.display == .inline_block)
                {
                    // POC: inline elements are not measured; the preview uses
                    // text nodes for inline runs.
                    layoutElement(doc, current, child_element, child_containing);
                    cursor_x += child_element.rect.w;
                } else {
                    layoutElement(doc, current, child_element, .{
                        .x = element.rect.x,
                        .y = block_y,
                        .w = element.rect.w,
                        .h = @max(1, element.rect.bottom() - block_y),
                    });
                    block_y += child_element.rect.h;
                }
            },
        }
    }

    // Shrink-to-fit width/height for explicit auto boxes is a later feature.
    // Keep the containing block's size for auto for now; the preview always
    // sets the sizes the editor view computes.
}

pub fn resolve(dimension: Dimension, base: f64) ?f64 {
    return switch (dimension) {
        .auto => null,
        .cells => |value| value,
        .percent => |percent| base * percent / 100.0,
    };
}

fn measure(doc: *const dom.Document, text: []const u8) f64 {
    return @floatFromInt(doc.measureText(text));
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

    layoutDocument(&doc);

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
    layoutDocument(&doc);

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
    layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 0), a.asText().rect.x);
    try std.testing.expectEqual(@as(f64, 2), b.asText().rect.x);
    try std.testing.expectEqual(@as(f64, 1), b.asText().rect.w);
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
    layoutDocument(&doc);

    try std.testing.expectEqual(@as(f64, 3), text.asText().rect.w);
}

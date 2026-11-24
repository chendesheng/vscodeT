//! Bounded stress tests for the UI library.
//!
//! These run as part of `zig build test`; the sizes are chosen to catch
//! algorithmic blowups (quadratic fragment growth, unbounded retained-tree or
//! scratch growth, deep recursion) without turning the normal suite into a
//! benchmark. The heavier variants live in `bench/scenarios` and are run with
//! `zig build bench --stress`.

const std = @import("std");
const ui = @import("ui.zig");

fn fullRoot(doc: *ui.Document) !*ui.Node {
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .overflow = .hidden,
    });
    doc.setRoot(root);
    return root;
}

fn row(
    doc: *ui.Document,
    parent: *ui.Node,
    top: usize,
    text: []const u8,
    background: ?ui.Color,
) !*ui.Node {
    const line = try doc.createElement(.div);
    line.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = @floatFromInt(top) },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .background = background,
        .white_space = .pre,
        .overflow = .hidden,
    });
    _ = try parent.appendChild(line);
    _ = try line.appendChild(try doc.createText(text));
    return line;
}

fn lineText(buffer: []u8, index: usize) []const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 +-*/()[]{}";
    const width = 40 + index % 61;
    var at: usize = 0;
    while (at < width and at < buffer.len) : (at += 1) {
        buffer[at] = alphabet[(index * 11 + at * 7) % alphabet.len];
    }
    return buffer[0..@min(at, buffer.len)];
}

test "stress: 1000-row document solves and paints" {
    const allocator = std.testing.allocator;
    var surface = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    const root = try fullRoot(doc);

    var lines: [1000]*ui.Node = undefined;
    var buffers: [1000][128]u8 = undefined;
    for (0..1000) |index| {
        lines[index] = try row(doc, root, index, lineText(&buffers[index], index), if (index % 2 == 0) .{ .r = 20, .g = 22, .b = 28 } else null);
    }

    try surface.paintFrame();
    try std.testing.expectEqual(@as(u32, 'a'), surface.grid().cluster[0]);
    try std.testing.expectEqual(@as(f64, 999), surface.box_tree.find(lines[999]).?.rect.y);

    // Edit a retained row in place and re-solve only that line.
    buffers[5][0] = 'Z';
    const text_node = lines[5].firstChild().?;
    text_node.setTextBorrowed(&buffers[5]);
    const box = (try surface.box_tree.rebuildSubtree(lines[5])).?;
    try ui.layout.layoutSubtree(surface.box_tree, doc, box);
    try surface.paintFrame();
    try std.testing.expectEqual(@as(u32, 'Z'), surface.grid().cluster[5 * 100]);
}

test "stress: retained 200-step scroll window stays bounded" {
    const allocator = std.testing.allocator;
    const visible = 40;
    var surface = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    const root = try fullRoot(doc);

    var lines: [visible]*ui.Node = undefined;
    var buffers: [visible][128]u8 = undefined;
    for (0..visible) |index| {
        lines[index] = try row(doc, root, index, lineText(&buffers[index], index), null);
    }
    try surface.paintFrame();
    surface.box_tree.setAutoInvalidate(false);
    const scratch_before = surface.box_tree.layoutScratchBytes();

    var head: usize = 0;
    var next_line: usize = visible;
    for (0..200) |_| {
        for (lines, 0..) |line, index| {
            if (index == head) continue;
            try std.testing.expect(surface.box_tree.translateSubtree(line, 0, -1));
        }
        const leaving = lines[head];
        surface.box_tree.removeSubtree(leaving);
        doc.destroy(leaving);
        const text = lineText(&buffers[head], next_line);
        lines[head] = try row(doc, root, visible - 1, text, null);
        const added = (try surface.box_tree.addSubtree(lines[head])).?;
        try ui.layout.layoutSubtree(surface.box_tree, doc, added);
        head = (head + 1) % visible;
        next_line += 1;

        if (head == 0) {
            try surface.paintFrame();
            try std.testing.expect(surface.grid().cluster[0] != 0);
            try std.testing.expectEqual(@as(usize, visible * 2 + 1), surface.box_tree.node_boxes.count());
        }
    }
    // The retained path must not grow the scratch arena without bound relative
    // to the initial solve.
    try std.testing.expect(surface.box_tree.layoutScratchBytes() <= scratch_before * 4 + (1 << 20));
}

test "stress: 64-level nested boxes solve, hit test and resize" {
    const allocator = std.testing.allocator;
    var surface = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    const root = try fullRoot(doc);

    var parent = root;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const child = try doc.createElement(.div);
        child.setStyle(.{
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
            .overflow = .hidden,
        });
        _ = try parent.appendChild(child);
        parent = child;
    }
    _ = try parent.appendChild(try doc.createText("deep"));

    try surface.paintFrame();
    try std.testing.expectEqual(@as(u32, 'd'), surface.grid().cluster[0]);
    try std.testing.expect((try surface.elementFromPoint(0, 0)) != null);

    try surface.resize(80, 30);
    try surface.paintFrame();
    try std.testing.expectEqual(@as(f64, 80), root.asElement().rect.w);
}

test "stress: 120-line wrapped paragraph produces linear fragments" {
    const allocator = std.testing.allocator;
    var surface = try ui.Surface.init(allocator, .{ .cols = 60, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    const root = try fullRoot(doc);

    const paragraph = try doc.createElement(.div);
    paragraph.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 50 },
        .white_space = .normal,
    });
    _ = try root.appendChild(paragraph);

    var text: [4096]u8 = undefined;
    @memset(text[0..], 0);
    const body = "word and CJK 中文 and emoji 🚀 wrap this paragraph. ";
    var at: usize = 0;
    while (at + body.len <= text.len) : (at += body.len) {
        @memcpy(text[at .. at + body.len], body);
    }
    _ = try paragraph.appendChild(try doc.createText(text[0..at]));

    try surface.paintFrame();
    const text_box = surface.box_tree.find(paragraph.firstChild().?).?;
    try std.testing.expect(text_box.text_fragments.len > 20);
    try std.testing.expectEqual(@as(usize, 1), surface.box_tree.find(paragraph).?.children.items.len);
    try std.testing.expect(text_box.rect.h >= 20);
}

test "stress: 500 bordered cells encode and diff" {
    const allocator = std.testing.allocator;
    var grid = try ui.CellGrid.init(allocator, 100, 40);
    defer grid.deinit();
    const stroke = ui.cell_border.Stroke{
        .color = .{ .rgb = .{ .r = 0x7a, .g = 0xa2, .b = 0xf7 } },
        .width = 64,
    };
    for (0..40) |row_index| {
        for (0..100) |col| {
            const paint = ui.cell.PaintStyle{ .fg = ui.cell.packColor(.{ .r = 200, .g = 200, .b = 200 }) };
            grid.putCodepoint(col, row_index, if (col % 10 == 0) '界' else 'x', 1, paint);
        }
        grid.addBorder(0, row_index, ui.cell_border.Segment.left, stroke);
        grid.addBorder(99, row_index, ui.cell_border.Segment.right, stroke);
    }
    for (0..100) |col| {
        grid.addBorder(col, 0, ui.cell_border.Segment.top, stroke);
        grid.addBorder(col, 39, ui.cell_border.Segment.bottom, stroke);
    }

    const first = try ui.ansi.encode(allocator, null, &grid, .{});
    defer allocator.free(first);
    try std.testing.expect(first.len > 1000);
    const unchanged = try ui.ansi.encode(allocator, &grid, &grid, .{});
    defer allocator.free(unchanged);
    try std.testing.expectEqual(@as(usize, 0), unchanged.len);
}

test "stress: 500-row focus and hit-test traversal" {
    const allocator = std.testing.allocator;
    var surface = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    const root = try fullRoot(doc);

    var lines: [500]*ui.Node = undefined;
    for (0..500) |index| {
        var buffer: [64]u8 = undefined;
        lines[index] = try row(doc, root, index, lineText(&buffer, index), null);
        lines[index].asElement().focusable = true;
    }
    try surface.paintFrame();

    for (0..500) |index| {
        try std.testing.expect(doc.moveFocus(.forward));
        const target = (try surface.elementFromPoint(index % 100, index % 40)) orelse return error.MissingHit;
        try std.testing.expect(target.isElement());
    }
    try std.testing.expect(doc.activeElement() != null);
}

test "stress: 200 class toggles with auto invalidation" {
    const allocator = std.testing.allocator;
    const Class = enum(u16) { a = 0, b = 1, active = 2 };
    var surface = try ui.Surface.init(allocator, .{ .cols = 100, .rows = 40 });
    defer surface.deinit();
    const doc = surface.document();
    _ = try doc.registerSheet(.{ .styles = &.{
        .{ .background = .{ .r = 20, .g = 22, .b = 28 } },
        .{ .background = .{ .r = 30, .g = 32, .b = 40 } },
        .{ .bold = true, .color = .{ .r = 240, .g = 240, .b = 240 } },
    } });
    const root = try fullRoot(doc);
    var lines: [200]*ui.Node = undefined;
    for (0..200) |index| {
        var buffer: [64]u8 = undefined;
        lines[index] = try row(doc, root, index, lineText(&buffer, index), null);
        try lines[index].setClasses(&.{if (index % 2 == 0) Class.a else Class.b});
    }

    try surface.paintFrame();
    for (0..200) |index| {
        try lines[index].setClasses(&.{ if (index % 2 == 0) Class.a else Class.b, Class.active });
        try surface.paintFrame();
        try std.testing.expect(surface.grid().cluster[0] != 0);
    }
}

const std = @import("std");
const ui = @import("ui");
const cell = ui.cell;
const dom = ui.dom;
const paint = ui.paint;
const style = ui.style;
const Pointer = ui.surface.Pointer;
const Surface = ui.surface.Surface;

test "Surface: resize replaces the frame and re-solves layout" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 4, .rows = 2 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("x"));

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try surface.render(&first.writer, .{});
    try std.testing.expectEqual(@as(usize, 4), surface.grid().cols);
    try std.testing.expectEqual(@as(usize, 2), surface.grid().rows);
    try std.testing.expectEqual(@as(f64, 4), root.asElement().rect.w);
    try std.testing.expect(!surface.first_frame);

    // Same size is a no-op.
    try surface.resize(4, 2);
    try std.testing.expectEqual(@as(usize, 4), doc.cols);

    try surface.resize(8, 3);
    try std.testing.expectEqual(@as(usize, 8), doc.cols);
    try std.testing.expectEqual(@as(usize, 3), doc.rows);
    try std.testing.expectEqual(@as(usize, 8), surface.grid().cols);
    try std.testing.expectEqual(@as(usize, 3), surface.grid().rows);
    try std.testing.expect(surface.first_frame);

    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try surface.render(&second.writer, .{});
    try std.testing.expect(std.mem.startsWith(u8, second.written(), "\x1b[2J\x1b[H"));
    try std.testing.expectEqual(@as(f64, 8), root.asElement().rect.w);
    try std.testing.expectEqual(@as(f64, 3), root.asElement().rect.h);

    const row = try surface.grid().rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("x", row);
}

test "Surface: text, diff and resize-free redraw" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("hello"));

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try surface.render(&first.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "hello") != null);

    const row = try surface.grid().rowText(allocator, 0);
    defer allocator.free(row);
    try std.testing.expectEqualStrings("hello", row);

    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try surface.render(&second.writer, .{});
    try std.testing.expectEqual(@as(usize, 0), second.written().len);
}

test "Surface: host overlay paints into the frame and clears on the next render" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("base"));

    const OverlayPaint = struct {
        fn paint(_: ?*anyopaque, grid: *cell.CellGrid) void {
            grid.putCodepoint(0, 1, 'o', 1, .{});
            grid.putCodepoint(1, 1, 'v', 1, .{});
        }
    };

    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try surface.renderWithOverlay(&first.writer, .{}, .{ .paint = OverlayPaint.paint });

    const with_overlay = try surface.grid().rowText(allocator, 1);
    defer allocator.free(with_overlay);
    try std.testing.expectEqualStrings("ov", with_overlay);

    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try surface.render(&second.writer, .{});

    const without_overlay = try surface.grid().rowText(allocator, 1);
    defer allocator.free(without_overlay);
    try std.testing.expectEqualStrings("", without_overlay);
}

test "Surface: text and style mutations repaint" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 8, .rows = 2 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const text = try doc.createText("a");
    const red = style.Color{ .r = 255, .g = 0, .b = 0 };
    const blue = style.Color{ .r = 0, .g = 0, .b = 255 };
    text.setStyle(.{ .color = red });
    _ = try root.appendChild(text);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{});

    const first_row = try surface.grid().rowText(allocator, 0);
    defer allocator.free(first_row);
    try std.testing.expectEqualStrings("a", first_row);
    try std.testing.expectEqual(cell.packColor(red), surface.grid().fg[surface.grid().index(0, 0)]);

    try text.setTextContent("b");
    try surface.render(&out.writer, .{});
    const second_row = try surface.grid().rowText(allocator, 0);
    defer allocator.free(second_row);
    try std.testing.expectEqualStrings("b", second_row);

    text.setStyle(.{ .color = blue });
    try surface.render(&out.writer, .{});
    try std.testing.expectEqual(cell.packColor(blue), surface.grid().fg[surface.grid().index(0, 0)]);
}

test "Surface: elementFromPoint hits the topmost box and retargets text" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 4 });
    defer surface.deinit();

    const doc = surface.document();
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

    const under = try doc.createElement(.div);
    under.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
    });
    _ = try under.appendChild(try doc.createText("under"));
    _ = try root.appendChild(under);

    const over = try doc.createElement(.div);
    over.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
    });
    _ = try over.appendChild(try doc.createText("over"));
    _ = try root.appendChild(over);

    // No render needed: hit testing solves the pending layout itself.
    try std.testing.expectEqual(over, (try surface.elementFromPoint(2, 0)).?);
    try std.testing.expectEqual(over, (try surface.elementFromPoint(0, 0)).?);
    // Outside both children the root covers the viewport.
    try std.testing.expectEqual(root, (try surface.elementFromPoint(8, 2)).?);
    try std.testing.expectEqual(@as(?*dom.Node, null), try surface.elementFromPoint(20, 20));
}

test "Surface: elementFromPoint clips and lets visible overflow through" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 12, .rows = 4 });
    defer surface.deinit();

    const doc = surface.document();
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

    const under = try doc.createElement(.div);
    under.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 3 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
    });
    _ = try root.appendChild(under);

    const clipping = try doc.createElement(.div);
    clipping.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
    });
    const spill = try doc.createElement(.div);
    spill.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 2 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 5 },
        .height = .{ .cells = 1 },
    });
    _ = try clipping.appendChild(spill);
    _ = try root.appendChild(clipping);

    // The spill reaches the row but is clipped by its parent, so the sibling
    // under that part of the row wins.
    try std.testing.expectEqual(under, (try surface.elementFromPoint(4, 0)).?);
    // The visible part of the spill still hits the spill itself.
    try std.testing.expectEqual(spill, (try surface.elementFromPoint(2, 0)).?);

    // A non-clipping parent lets the pointer reach a child outside its rect.
    clipping.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .overflow = .visible,
    });
    try std.testing.expectEqual(spill, (try surface.elementFromPoint(5, 0)).?);
}

test "Surface: cell borders paint edges and fall back to glyphs" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{
        .cols = 6,
        .rows = 3,
        .cell_borders = true,
    });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .border = style.EdgeDecl.all(1),
        .border_color = .{ .r = 9, .g = 8, .b = 7 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("abc"));

    try surface.paintFrame();
    const grid = surface.grid();
    // The border contributes no layout cells, so the text starts at the edge.
    try std.testing.expectEqual(@as(u32, 'a'), grid.cluster[0]);
    try std.testing.expectEqual(@as(u32, 'c'), grid.cluster[2]);
    const set = grid.borderSetAt(0, 0);
    try std.testing.expect(set.count > 0);
    try std.testing.expect(grid.borderIdAt(2, 0) != 0);

    // Disabling the protocol puts the glyph fallback back into the layout.
    surface.setCellBorders(false);
    try std.testing.expect(!surface.cellBorders());
    try surface.paintFrame();
    try std.testing.expectEqual(@as(u32, '┌'), surface.grid().cluster[0]);
    try std.testing.expectEqual(@as(u32, 0), surface.grid().borderIdAt(0, 0));
}

test "Surface: cell-border render uses the pen and drops box glyphs" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{
        .cols = 6,
        .rows = 3,
        .cell_borders = true,
    });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .border = style.EdgeDecl.all(1),
        .border_color = .{ .r = 0x7a, .g = 0xa2, .b = 0xf7 },
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("abc"));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try surface.render(&out.writer, .{ .synchronized = false });
    const rendered = out.written();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1bP1+bcell-border;pen;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "7aa2f7") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "┌") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "c") != null);

    // The fallback path still reserves cells and writes glyphs.
    var fallback = try Surface.init(allocator, .{ .cols = 6, .rows = 3 });
    defer fallback.deinit();
    const fallback_doc = fallback.document();
    const fallback_root = try fallback_doc.createElement(.div);
    fallback_root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .border = style.EdgeDecl.all(1),
    });
    fallback_doc.setRoot(fallback_root);
    _ = try fallback_root.appendChild(try fallback_doc.createText("abc"));

    var fallback_out: std.Io.Writer.Allocating = .init(allocator);
    defer fallback_out.deinit();
    try fallback.render(&fallback_out.writer, .{ .synchronized = false });
    try std.testing.expect(std.mem.indexOf(u8, fallback_out.written(), "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback_out.written(), "cell-border") == null);
}

test "Surface: pointerAt resolves inherited styles and hit clipping" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 3 });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .pointer = .text,
    });
    doc.setRoot(root);

    const link = try doc.createElement(.div);
    link.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .pointer = .pointer,
    });
    _ = try root.appendChild(link);
    _ = try link.appendChild(try doc.createText("abc"));

    // The link overrides the root's inherited text shape; text itself reports
    // the container's shape; empty root area falls back to the inherited one.
    try std.testing.expectEqual(Pointer.pointer, (try surface.pointerAt(2, 0)).?);
    try std.testing.expectEqual(Pointer.text, (try surface.pointerAt(6, 1)).?);

    // A clipping parent keeps the pointer out of the clipped area.
    link.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
        .overflow = .hidden,
        .pointer = .pointer,
    });
    const spill = try doc.createElement(.div);
    spill.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 3 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 5 },
        .height = .{ .cells = 1 },
    });
    _ = try link.appendChild(spill);
    try std.testing.expectEqual(Pointer.text, (try surface.pointerAt(6, 0)).?);
}

test "Surface: render emits OSC 22 only when the pointer shape changes" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{
        .cols = 8,
        .rows = 2,
        .pointer_shapes = true,
    });
    defer surface.deinit();

    const doc = surface.document();
    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .pointer = .text,
    });
    doc.setRoot(root);
    _ = try root.appendChild(try doc.createText("hello"));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Frames keep their exact cell output; the default pointer adds no bytes.
    try surface.render(&out.writer, .{ .synchronized = false });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);

    out.clearRetainingCapacity();
    try std.testing.expect(surface.setPointer(.text));
    try surface.render(&out.writer, .{ .synchronized = false });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;text\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "hello") == null);

    out.clearRetainingCapacity();
    try surface.render(&out.writer, .{ .synchronized = false });
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    out.clearRetainingCapacity();
    try std.testing.expect(surface.setPointer(.pointer));
    try surface.render(&out.writer, .{ .synchronized = false });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;pointer\x1b\\") != null);

    out.clearRetainingCapacity();
    surface.setPointerShapes(false);
    try std.testing.expect(surface.setPointer(.default));
    try surface.render(&out.writer, .{ .synchronized = false });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b]22;") == null);
}

test "Surface: hover paints the pointer element and reverts on leave" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 10, .rows = 2 });
    defer surface.deinit();
    const doc = surface.document();

    const base_bg = style.Color{ .r = 10, .g = 10, .b = 10 };
    const hover_bg = style.Color{ .r = 40, .g = 50, .b = 60 };
    const base_fg = style.Color{ .r = 200, .g = 200, .b = 200 };
    const hover_fg = style.Color{ .r = 255, .g = 255, .b = 255 };

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = base_bg,
        .color = base_fg,
    });
    doc.setRoot(root);

    const row = try doc.createElement(.div);
    row.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
        .color = base_fg,
    });
    row.setHoverStyle(.{ .background = hover_bg, .color = hover_fg, .bold = true });
    _ = try row.appendChild(try doc.createText("ab"));
    _ = try root.appendChild(row);

    const other = try doc.createElement(.div);
    other.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 5 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 2 },
        .height = .{ .cells = 1 },
        .color = base_fg,
    });
    other.setHoverStyle(.{ .background = hover_bg });
    _ = try other.appendChild(try doc.createText("cd"));
    _ = try root.appendChild(other);

    try surface.paintFrame();
    var grid = surface.grid();
    try std.testing.expectEqual(cell.packColor(base_bg), grid.bg[grid.index(0, 0)]);
    try std.testing.expectEqual(cell.packColor(base_fg), grid.fg[grid.index(0, 0)]);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 0)] & cell.Attr.bold);

    // A text cell retargets to its row element.
    try std.testing.expect(try surface.updateHoverAt(1, 0));
    try std.testing.expectEqual(row, doc.hoverTarget().?);
    try std.testing.expect(!try surface.updateHoverAt(1, 0));
    try surface.paintFrame();
    grid = surface.grid();
    try std.testing.expectEqual(cell.packColor(hover_bg), grid.bg[grid.index(0, 0)]);
    try std.testing.expectEqual(cell.packColor(hover_bg), grid.bg[grid.index(3, 0)]);
    try std.testing.expectEqual(cell.packColor(hover_fg), grid.fg[grid.index(0, 0)]);
    try std.testing.expect((grid.attrs[grid.index(0, 0)] & cell.Attr.bold) != 0);
    // The sibling keeps its base paint.
    try std.testing.expectEqual(cell.packColor(base_bg), grid.bg[grid.index(5, 0)]);
    try std.testing.expectEqual(cell.packColor(base_fg), grid.fg[grid.index(5, 0)]);

    // Moving to the sibling moves the highlight.
    try std.testing.expect(try surface.updateHoverAt(5, 0));
    try surface.paintFrame();
    grid = surface.grid();
    try std.testing.expectEqual(cell.packColor(base_bg), grid.bg[grid.index(0, 0)]);
    try std.testing.expectEqual(cell.packColor(base_fg), grid.fg[grid.index(0, 0)]);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(0, 0)] & cell.Attr.bold);
    try std.testing.expectEqual(cell.packColor(hover_bg), grid.bg[grid.index(5, 0)]);

    // Leaving the surface clears it.
    try std.testing.expect(surface.clearHover());
    try surface.paintFrame();
    grid = surface.grid();
    try std.testing.expectEqual(cell.packColor(base_bg), grid.bg[grid.index(5, 0)]);
    try std.testing.expect(doc.hoverTarget() == null);
    try std.testing.expect(!row.isHovered());
}

test "Surface: hover applies to the pointer's ancestor chain" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 12, .rows = 2 });
    defer surface.deinit();
    const doc = surface.document();

    const base_bg = style.Color{ .r = 5, .g = 5, .b = 5 };
    const hover_bg = style.Color{ .r = 30, .g = 40, .b = 50 };
    const base_fg = style.Color{ .r = 180, .g = 180, .b = 180 };
    const hover_fg = style.Color{ .r = 250, .g = 250, .b = 250 };

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
        .background = base_bg,
    });
    doc.setRoot(root);

    const parent = try doc.createElement(.div);
    parent.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 6 },
        .height = .{ .cells = 1 },
        .color = base_fg,
    });
    parent.setHoverStyle(.{ .background = hover_bg, .color = hover_fg });
    const child = try doc.createElement(.div);
    child.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 1 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 3 },
        .height = .{ .cells = 1 },
    });
    _ = try child.appendChild(try doc.createText("ab"));
    _ = try parent.appendChild(child);
    _ = try root.appendChild(parent);

    try std.testing.expect(try surface.updateHoverAt(2, 0));
    try std.testing.expectEqual(child, doc.hoverTarget().?);
    try std.testing.expect(child.isHovered());
    try std.testing.expect(parent.isHovered());
    try surface.paintFrame();

    const grid = surface.grid();
    // The parent's hover background fills behind the child, and its hover
    // color is inherited by the child's text.
    try std.testing.expectEqual(cell.packColor(hover_bg), grid.bg[grid.index(2, 0)]);
    try std.testing.expectEqual(cell.packColor(hover_fg), grid.fg[grid.index(2, 0)]);
    try std.testing.expectEqual(cell.packColor(base_bg), grid.bg[grid.index(8, 0)]);
}

test "Surface: hover can clear base attributes and repaint the border" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 8, .rows = 3 });
    defer surface.deinit();
    const doc = surface.document();

    const base_fg = style.Color{ .r = 180, .g = 180, .b = 180 };
    const hover_fg = style.Color{ .r = 255, .g = 255, .b = 255 };
    const base_border = style.Color{ .r = 60, .g = 60, .b = 60 };
    const hover_border = style.Color{ .r = 200, .g = 120, .b = 20 };

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    doc.setRoot(root);

    const bordered = try doc.createElement(.div);
    bordered.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 4 },
        .height = .{ .cells = 3 },
        .border = style.EdgeDecl.all(1),
        .border_color = base_border,
        .color = base_fg,
        .bold = true,
    });
    bordered.setHoverStyle(.{
        .border_color = hover_border,
        .color = hover_fg,
        .bold = false,
        .dim = true,
    });
    _ = try bordered.appendChild(try doc.createText("x"));
    _ = try root.appendChild(bordered);

    try surface.paintFrame();
    var grid = surface.grid();
    try std.testing.expectEqual(cell.packColor(base_border), grid.fg[grid.index(0, 0)]);
    try std.testing.expect((grid.attrs[grid.index(1, 1)] & cell.Attr.bold) != 0);

    try std.testing.expect(try surface.updateHoverAt(1, 1));
    try surface.paintFrame();
    grid = surface.grid();
    try std.testing.expectEqual(cell.packColor(hover_border), grid.fg[grid.index(0, 0)]);
    try std.testing.expectEqual(cell.packColor(hover_fg), grid.fg[grid.index(1, 1)]);
    try std.testing.expectEqual(@as(u16, 0), grid.attrs[grid.index(1, 1)] & cell.Attr.bold);
    try std.testing.expect((grid.attrs[grid.index(1, 1)] & cell.Attr.dim) != 0);
}

test "Surface: hover re-resolves from the stored pointer after a rebuild" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 6, .rows = 2 });
    defer surface.deinit();
    const doc = surface.document();

    const base_bg = style.Color{ .r = 10, .g = 10, .b = 10 };
    const hover_bg = style.Color{ .r = 70, .g = 80, .b = 90 };

    const build = struct {
        fn run(d: *dom.Document, background: style.Color, hover: style.Color) !*dom.Node {
            const root = try d.createElement(.div);
            root.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .percent = 100 },
                .height = .{ .percent = 100 },
                .background = background,
            });
            const row = try d.createElement(.div);
            row.setStyle(.{
                .position = .absolute,
                .left = .{ .cells = 0 },
                .top = .{ .cells = 0 },
                .width = .{ .cells = 4 },
                .height = .{ .cells = 1 },
            });
            row.setHoverStyle(.{ .background = hover });
            _ = try row.appendChild(try d.createText("ab"));
            _ = try root.appendChild(row);
            d.setRoot(root);
            return row;
        }
    }.run;

    const first_row = try build(doc, base_bg, hover_bg);
    try std.testing.expect(try surface.updateHoverAt(1, 0));
    try std.testing.expectEqual(first_row, doc.hoverTarget().?);
    try surface.paintFrame();
    try std.testing.expectEqual(cell.packColor(hover_bg), surface.grid().bg[surface.grid().index(0, 0)]);

    // Rebuilding the tree drops the old target; the next paint re-resolves the
    // stored pointer against the new nodes.
    doc.clear();
    const second_row = try build(doc, base_bg, hover_bg);
    try surface.paintFrame();
    try std.testing.expectEqual(second_row, doc.hoverTarget().?);
    try std.testing.expect(second_row.isHovered());
    try std.testing.expectEqual(cell.packColor(hover_bg), surface.grid().bg[surface.grid().index(0, 0)]);

    // Once the pointer leaves, a rebuild does not resurrect hover.
    try std.testing.expect(surface.clearHover());
    doc.clear();
    _ = try build(doc, base_bg, hover_bg);
    try surface.paintFrame();
    try std.testing.expect(doc.hoverTarget() == null);
    try std.testing.expectEqual(cell.packColor(base_bg), surface.grid().bg[surface.grid().index(0, 0)]);
}

test "Surface: hover updates are paint-only" {
    const allocator = std.testing.allocator;
    var surface = try Surface.init(allocator, .{ .cols = 6, .rows = 2 });
    defer surface.deinit();
    const doc = surface.document();

    const root = try doc.createElement(.div);
    root.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .percent = 100 },
        .height = .{ .percent = 100 },
    });
    const row = try doc.createElement(.div);
    row.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = 0 },
        .width = .{ .cells = 4 },
        .height = .{ .cells = 1 },
    });
    row.setHoverStyle(.{ .background = .{ .r = 1, .g = 2, .b = 3 } });
    _ = try row.appendChild(try doc.createText("ab"));
    _ = try root.appendChild(row);
    doc.setRoot(root);

    try surface.paintFrame();
    try std.testing.expect(!surface.box_tree.needs_rebuild);
    try std.testing.expect(!surface.box_tree.needs_layout);

    _ = try surface.updateHoverAt(1, 0);
    try std.testing.expect(!surface.box_tree.needs_rebuild);
    try std.testing.expect(!surface.box_tree.needs_layout);

    _ = surface.clearHover();
    try std.testing.expect(!surface.box_tree.needs_rebuild);
    try std.testing.expect(!surface.box_tree.needs_layout);
}

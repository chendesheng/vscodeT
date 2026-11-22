//! A document, a viewport, and the double-buffered cell renderer.

const std = @import("std");
const ansi = @import("ansi.zig");
const cell = @import("cell.zig");
const dom = @import("dom.zig");
const box = @import("box.zig");
const frame_mod = @import("frame.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const style = @import("style.zig");

pub const ColorDepth = cell.ColorDepth;

pub const Options = struct {
    cols: usize,
    rows: usize,
    tab_size: usize = 4,
    color_depth: ColorDepth = .rgb,
    measure_width: *const fn (u21) u2 = dom.defaultMeasureWidth,
    /// The terminal implements the cell-border protocol. Hosts set this after
    /// probing the terminal; when false, borders keep their box-drawing
    /// fallback and reserve layout cells.
    cell_borders: bool = false,
};

pub const RenderOptions = struct {
    synchronized: bool = true,
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    doc: dom.Document,
    box_tree: *box.BoxTree,
    frame: frame_mod.Frame,
    color_depth: ColorDepth,
    first_frame: bool = true,
    /// The last pointer cell reported through `updateHoverAt`. Kept so a
    /// cleared or rebuilt tree can re-resolve its hover target on the next
    /// paint without the host re-sending the pointer position.
    hover_cell: ?[2]usize = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Surface {
        var doc = try dom.Document.init(allocator, .{
            .cols = options.cols,
            .rows = options.rows,
            .tab_size = options.tab_size,
            .measure_width = options.measure_width,
        });
        errdefer doc.deinit();

        var frame = try frame_mod.Frame.init(allocator, doc.cols, doc.rows);
        errdefer frame.deinit();

        const box_tree = try box.BoxTree.create(allocator);
        errdefer box_tree.destroy();
        box_tree.cell_borders = options.cell_borders;
        doc.setObserver(box_tree.observer());
        errdefer doc.setObserver(null);

        return .{
            .allocator = allocator,
            .doc = doc,
            .box_tree = box_tree,
            .frame = frame,
            .color_depth = options.color_depth,
        };
    }

    pub fn deinit(self: *Surface) void {
        self.doc.setObserver(null);
        self.box_tree.destroy();
        self.frame.deinit();
        self.doc.deinit();
    }

    pub fn document(self: *Surface) *dom.Document {
        return &self.doc;
    }

    /// Switches between cell borders and the box-drawing fallback. The box tree
    /// is rebuilt because border widths take part in layout only in fallback
    /// mode; the first render after a change repaints affected rows.
    pub fn setCellBorders(self: *Surface, enabled: bool) void {
        if (self.box_tree.cell_borders == enabled) return;
        self.box_tree.cell_borders = enabled;
        self.box_tree.needs_rebuild = true;
        self.box_tree.needs_layout = true;
    }

    pub fn cellBorders(self: *const Surface) bool {
        return self.box_tree.cell_borders;
    }

    pub fn grid(self: *Surface) *const cell.CellGrid {
        return self.frame.present();
    }

    /// Writable view of the grid the last `paintFrame` produced. Terminal
    /// graphics overlays (image placeholders) write here before the caller
    /// composites the grid; the writes are part of the following frame diff.
    pub fn presentedGrid(self: *Surface) *cell.CellGrid {
        return self.frame.presentMut();
    }

    /// Reallocates the double buffers for a new terminal viewport and marks the
    /// box tree dirty. The caller owns the document and should rebuild (or
    /// adjust) its tree afterwards; the next layout pass resolves percentages
    /// and absolute geometry against the new size. The following frame clears
    /// the terminal because a resize may have reflowed the old contents.
    pub fn resize(self: *Surface, cols: usize, rows: usize) !void {
        const new_cols = @max(cols, 1);
        const new_rows = @max(rows, 1);
        if (new_cols == self.doc.cols and new_rows == self.doc.rows) return;

        var frame = try frame_mod.Frame.init(self.allocator, new_cols, new_rows);
        errdefer frame.deinit();
        self.frame.deinit();
        self.frame = frame;
        self.doc.cols = new_cols;
        self.doc.rows = new_rows;
        self.box_tree.needs_rebuild = true;
        self.box_tree.needs_layout = true;
        self.first_frame = true;
        if (self.hover_cell) |point| {
            if (point[0] >= new_cols or point[1] >= new_rows) {
                self.hover_cell = null;
                _ = self.doc.clearHover();
            }
        }
    }

    /// Lays out the current tree and paints it into the next frame without
    /// encoding ANSI. Hosts that composite several surfaces use this and read
    /// `grid()` afterwards; `render` is the one-surface convenience.
    pub fn paintFrame(self: *Surface) !void {
        try self.ensureLayout();
        self.resolveHover();
        self.frame.begin();
        paint.paintTree(self.box_tree, &self.doc, &self.frame.next);
        self.frame.swap();
    }

    /// Lays out the current tree, paints it, diffs it against the previous
    /// frame and writes the ANSI delta. An unchanged frame writes nothing.
    pub fn render(self: *Surface, writer: *std.Io.Writer, options: RenderOptions) !void {
        if (self.first_frame) {
            try writer.writeAll("\x1b[2J\x1b[H");
            self.first_frame = false;
        }

        try self.ensureLayout();
        self.resolveHover();
        self.frame.begin();
        paint.paintTree(self.box_tree, &self.doc, &self.frame.next);

        const encoded = try ansi.encode(
            self.allocator,
            if (self.frame.have_prev) &self.frame.prev else null,
            &self.frame.next,
            .{
                .color_depth = self.color_depth,
                .synchronized = options.synchronized,
            },
        );
        defer self.allocator.free(encoded);
        if (encoded.len != 0) try writer.writeAll(encoded);

        self.frame.swap();
    }

    /// The element under a viewport cell, or null when nothing was hit. The
    /// box tree is rebuilt and solved first when mutations are pending, so a
    /// pointer can be resolved before the next frame is painted. A cell's
    /// center is the point tested.
    pub fn elementFromPoint(self: *Surface, col: usize, row: usize) !?*dom.Node {
        try self.ensureLayout();
        const x = @as(f64, @floatFromInt(col)) + 0.5;
        const y = @as(f64, @floatFromInt(row)) + 0.5;
        return self.box_tree.elementFromPoint(x, y);
    }

    /// Moves the pointer to a viewport cell and remembers it, so the hover
    /// target can be re-resolved after the tree is rebuilt. Returns whether the
    /// hover target changed. Hover is paint state only and never dirties
    /// layout. A point outside the viewport clears the hover.
    pub fn updateHoverAt(self: *Surface, col: usize, row: usize) !bool {
        try self.ensureLayout();
        if (col >= self.doc.cols or row >= self.doc.rows) {
            self.hover_cell = null;
            return self.doc.clearHover();
        }
        self.hover_cell = .{ col, row };
        const x = @as(f64, @floatFromInt(col)) + 0.5;
        const y = @as(f64, @floatFromInt(row)) + 0.5;
        return self.doc.setHoverTarget(self.box_tree.elementFromPoint(x, y));
    }

    /// Clears the stored pointer and the hover target, for a pointer that left
    /// the surface. Returns whether the target changed.
    pub fn clearHover(self: *Surface) bool {
        self.hover_cell = null;
        return self.doc.clearHover();
    }

    /// Re-resolves the stored pointer cell after the document was cleared or
    /// rebuilt under a stationary pointer. No-op without a stored cell or when
    /// the current target is still valid.
    fn resolveHover(self: *Surface) void {
        const point = self.hover_cell orelse return;
        if (self.doc.hover_target != null) return;
        if (point[0] >= self.doc.cols or point[1] >= self.doc.rows) {
            _ = self.doc.clearHover();
            return;
        }
        const x = @as(f64, @floatFromInt(point[0])) + 0.5;
        const y = @as(f64, @floatFromInt(point[1])) + 0.5;
        _ = self.doc.setHoverTarget(self.box_tree.elementFromPoint(x, y));
    }

    fn ensureLayout(self: *Surface) !void {
        if (self.box_tree.needs_rebuild) {
            try self.box_tree.rebuild(&self.doc);
        }
        if (self.box_tree.needs_layout) {
            try layout.layoutTree(self.box_tree, &self.doc);
        }
    }
};

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
        .border = .all(1),
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
        .border = .all(1),
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
        .border = .all(1),
    });
    fallback_doc.setRoot(fallback_root);
    _ = try fallback_root.appendChild(try fallback_doc.createText("abc"));

    var fallback_out: std.Io.Writer.Allocating = .init(allocator);
    defer fallback_out.deinit();
    try fallback.render(&fallback_out.writer, .{ .synchronized = false });
    try std.testing.expect(std.mem.indexOf(u8, fallback_out.written(), "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback_out.written(), "cell-border") == null);
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
        .border = .all(1),
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

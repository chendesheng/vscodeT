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

    pub fn grid(self: *Surface) *const cell.CellGrid {
        return self.frame.present();
    }

    /// Lays out the current tree and paints it into the next frame without
    /// encoding ANSI. Hosts that composite several surfaces use this and read
    /// `grid()` afterwards; `render` is the one-surface convenience.
    pub fn paintFrame(self: *Surface) !void {
        try self.ensureLayout();
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

    fn ensureLayout(self: *Surface) !void {
        if (self.box_tree.needs_rebuild) {
            try self.box_tree.rebuild(&self.doc);
        }
        if (self.box_tree.needs_layout) {
            try layout.layoutTree(self.box_tree, &self.doc);
        }
    }
};

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

//! A document, a viewport, and the double-buffered cell renderer.

const std = @import("std");
const ansi = @import("ansi.zig");
const cell = @import("cell.zig");
const dom = @import("dom.zig");
const frame_mod = @import("frame.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");

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

        return .{
            .allocator = allocator,
            .doc = doc,
            .frame = frame,
            .color_depth = options.color_depth,
        };
    }

    pub fn deinit(self: *Surface) void {
        self.frame.deinit();
        self.doc.deinit();
    }

    pub fn document(self: *Surface) *dom.Document {
        return &self.doc;
    }

    pub fn grid(self: *Surface) *const cell.CellGrid {
        return self.frame.present();
    }

    /// Lays out the current tree, paints it, diffs it against the previous
    /// frame and writes the ANSI delta. An unchanged frame writes nothing.
    pub fn render(self: *Surface, writer: *std.Io.Writer, options: RenderOptions) !void {
        if (self.first_frame) {
            try writer.writeAll("\x1b[2J\x1b[H");
            self.first_frame = false;
        }

        layout.layoutDocument(&self.doc);
        self.frame.begin();
        paint.paintDocument(&self.doc, &self.frame.next);

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

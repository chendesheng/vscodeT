//! A document, a viewport, and the double-buffered cell renderer.

const std = @import("std");
const ansi = @import("ansi.zig");
const cell = @import("cell.zig");
const cell_border = @import("cell_border.zig");
const dom = @import("dom.zig");
const box = @import("box.zig");
const frame_mod = @import("frame.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const pointer_mod = @import("pointer.zig");
const style = @import("style.zig");

pub const ColorDepth = cell.ColorDepth;
pub const Pointer = style.Pointer;

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
    /// Emit the kitty OSC 22 pointer shape when `pointer` changes. Off by
    /// default because the pointer is terminal-global output, not part of the
    /// grid; hosts that already track the mouse (the TUI) opt in.
    pointer_shapes: bool = false,
};

pub const RenderOptions = struct {
    synchronized: bool = true,
};

/// A host overlay painted after the tree and before ANSI encoding. Native
/// overlays such as `ContextMenu` use this hook so their cells take part in
/// the normal frame diff and clipping.
pub const Overlay = struct {
    context: ?*anyopaque = null,
    paint: *const fn (context: ?*anyopaque, grid: *cell.CellGrid) void,
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    doc: dom.Document,
    box_tree: *box.BoxTree,
    frame: frame_mod.Frame,
    color_depth: ColorDepth,
    /// The negotiated paint extensions. The box tree separately controls
    /// whether ordinary borders take up layout cells.
    border_capabilities: cell_border.Capabilities = .{},
    pointer_shapes: bool = false,
    /// Desired pointer shape for the next rendered frame. The host updates it
    /// from mouse events; the renderer diffs it against `pointer_state`.
    pointer: Pointer = .default,
    pointer_state: pointer_mod.State = .{},
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
            .pointer_shapes = options.pointer_shapes,
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

    /// Enables or disables OSC 22 emission. Disabling does not emit a reset;
    /// the host owns that transition through `pointer_state`.
    pub fn setPointerShapes(self: *Surface, enabled: bool) void {
        self.pointer_shapes = enabled;
    }

    pub fn pointerShapes(self: *const Surface) bool {
        return self.pointer_shapes;
    }

    /// Records the pointer shape the next render should show. Returns true when
    /// the shape changed, so a host can schedule a redraw.
    pub fn setPointer(self: *Surface, shape: Pointer) bool {
        if (self.pointer == shape) return false;
        self.pointer = shape;
        return true;
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
        paint.paintTreeWithBorderCapabilities(self.box_tree, &self.doc, &self.frame.next, self.border_capabilities);
        self.frame.swap();
    }

    /// Paints this viewport into a host frame with the same dimensions.
    pub fn paintInto(self: *Surface, target: *cell.CellGrid) !void {
        std.debug.assert(target.cols == self.doc.cols and target.rows == self.doc.rows);
        try self.ensureLayout();
        self.resolveHover();
        paint.paintTreeWithBorderCapabilities(self.box_tree, &self.doc, target, self.border_capabilities);
    }

    /// Lays out the current tree, paints it, diffs it against the previous
    /// frame and writes the ANSI delta. An unchanged frame writes nothing.
    pub fn render(self: *Surface, writer: *std.Io.Writer, options: RenderOptions) !void {
        return self.renderWithOverlay(writer, options, null);
    }

    /// Like `render`, but lets a host paint a native overlay into the frame
    /// after the tree and before the ANSI diff. The overlay participates in
    /// the same double-buffered frame, so the next frame clears its cells.
    pub fn renderWithOverlay(
        self: *Surface,
        writer: *std.Io.Writer,
        options: RenderOptions,
        overlay: ?Overlay,
    ) !void {
        if (self.first_frame) {
            try writer.writeAll("\x1b[2J\x1b[H");
            self.first_frame = false;
        }

        if (self.pointer_shapes) try self.pointer_state.update(writer, self.pointer);

        try self.ensureLayout();
        self.resolveHover();
        self.frame.begin();
        paint.paintTreeWithBorderCapabilities(self.box_tree, &self.doc, &self.frame.next, self.border_capabilities);
        if (overlay) |value| value.paint(value.context, &self.frame.next);

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

    /// The computed mouse pointer shape under a viewport cell, or null when no
    /// box contains it. Style inheritance and hit-test clipping follow
    /// `elementFromPoint`; text nodes report the container's shape.
    pub fn pointerAt(self: *Surface, col: usize, row: usize) !?Pointer {
        try self.ensureLayout();
        const x = @as(f64, @floatFromInt(col)) + 0.5;
        const y = @as(f64, @floatFromInt(row)) + 0.5;
        return self.box_tree.pointerAt(x, y);
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

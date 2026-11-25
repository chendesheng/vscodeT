//! Double-buffered frame state.
//!
//! Painting goes into `next`; presenting diffs it against `prev`, emits ANSI,
//! then swaps the two. `prev` is kept so a later scroll shift can move its
//! rows instead of repainting them.

const std = @import("std");
const cell_border = @import("cell_border.zig");
const grapheme = @import("grapheme.zig");
const CellGrid = @import("cell.zig").CellGrid;

pub const Frame = struct {
    allocator: std.mem.Allocator,
    /// One table for both buffers: a border id means the same set in `prev`
    /// and `next`, so the frame diff can compare ids directly.
    borders: *cell_border.Table,
    /// One intern table for both buffers, for the same reason.
    graphemes: *grapheme.Table,
    prev: CellGrid,
    next: CellGrid,
    have_prev: bool = false,
    /// True when `next` is known to be blank: set by init and by `swap`, which
    /// clears it, and cleared by `begin` because painting dirties it. This lets
    /// the usual begin-after-swap skip the full-grid clear while a second
    /// `begin` without a swap still clears the buffer it just handed out.
    next_clean: bool = true,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Frame {
        const borders = try allocator.create(cell_border.Table);
        borders.* = .{};
        errdefer allocator.destroy(borders);

        const graphemes = try allocator.create(grapheme.Table);
        errdefer allocator.destroy(graphemes);
        graphemes.* = try grapheme.Table.init(allocator);
        errdefer graphemes.deinit();

        var prev = try CellGrid.initWithTables(allocator, cols, rows, borders, graphemes);
        errdefer prev.deinit();
        const next = try CellGrid.initWithTables(allocator, cols, rows, borders, graphemes);
        return .{
            .allocator = allocator,
            .borders = borders,
            .graphemes = graphemes,
            .prev = prev,
            .next = next,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.prev.deinit();
        self.next.deinit();
        self.allocator.destroy(self.borders);
        self.graphemes.deinit();
        self.allocator.destroy(self.graphemes);
    }

    pub fn begin(self: *Frame) void {
        // `next` is already blank right after init or swap; clearing it again
        // is pure cost. Any later begin, or a begin after a paint pass, still
        // clears because the buffer is marked dirty until the next swap.
        if (!self.next_clean) self.next.clear();
        self.next_clean = false;
    }

    pub fn present(self: *Frame) *const CellGrid {
        return if (self.have_prev) &self.prev else &self.next;
    }

    /// The grid a host may decorate after painting. Terminal graphics placeholders
    /// are written here between `paintFrame` and the composite, so they take part
    /// in the next frame diff like any other cell.
    pub fn presentMut(self: *Frame) *CellGrid {
        return if (self.have_prev) &self.prev else &self.next;
    }

    pub fn swap(self: *Frame) void {
        std.mem.swap(CellGrid, &self.prev, &self.next);
        self.next.clear();
        self.next_clean = true;
        self.have_prev = true;
    }
};

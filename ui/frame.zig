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
        self.next.clear();
    }

    pub fn present(self: *Frame) *const CellGrid {
        return if (self.have_prev) &self.prev else &self.next;
    }

    pub fn swap(self: *Frame) void {
        std.mem.swap(CellGrid, &self.prev, &self.next);
        self.next.clear();
        self.have_prev = true;
    }
};

test "Frame swaps buffers and keeps the presented grid" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, 4, 1);
    defer frame.deinit();

    frame.begin();
    frame.next.putCodepoint(0, 0, 'x', 1, .{});
    try std.testing.expectEqual(@as(u32, 'x'), frame.next.cluster[0]);
    frame.swap();
    try std.testing.expectEqual(@as(u32, 'x'), frame.present().cluster[0]);
    try std.testing.expectEqual(@as(u32, 0), frame.next.cluster[0]);
}

//! Double-buffered frame state.
//!
//! Painting goes into `next`; presenting diffs it against `prev`, emits ANSI,
//! then swaps the two. `prev` is kept so a later scroll shift can move its
//! rows instead of repainting them.

const std = @import("std");
const CellGrid = @import("cell.zig").CellGrid;

pub const Frame = struct {
    allocator: std.mem.Allocator,
    prev: CellGrid,
    next: CellGrid,
    have_prev: bool = false,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Frame {
        var prev = try CellGrid.init(allocator, cols, rows);
        errdefer prev.deinit();
        const next = try CellGrid.init(allocator, cols, rows);
        return .{
            .allocator = allocator,
            .prev = prev,
            .next = next,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.prev.deinit();
        self.next.deinit();
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

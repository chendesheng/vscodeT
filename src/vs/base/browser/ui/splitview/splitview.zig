// Port of the two-view resize path in src/vs/base/browser/ui/splitview/splitview.ts.
// Terminal cells replace CSS pixels. The workbench branches have two views,
// no snapping, and no modifier-driven resize of a second sash.

const std = @import("std");

pub const ViewSize = struct {
    size: usize,
    minimum: usize,
    maximum: usize,
};

/// SplitView.onSashStart captures the initial view sizes. Every change is
/// relative to that snapshot, including after the pointer leaves the sash.
pub const SashDragState = struct {
    start: usize,
    sizes: [2]usize,

    pub fn onSashStart(start: usize, views: [2]ViewSize) SashDragState {
        return .{ .start = start, .sizes = .{ views[0].size, views[1].size } };
    }

    pub fn onSashChange(self: SashDragState, current: usize, views: [2]ViewSize) [2]usize {
        return resize(offset(current, self.start), self.sizes, views);
    }
};

/// SplitView.resize for the sash at index zero. Clamp against both view
/// bounds, grow the item before the sash and shrink the item after it.
pub fn resize(delta: i64, sizes: [2]usize, views: [2]ViewSize) [2]usize {
    const min_delta = @max(offset(views[0].minimum, sizes[0]), offset(sizes[1], views[1].maximum));
    const max_delta = @min(offset(views[0].maximum, sizes[0]), offset(sizes[1], views[1].minimum));
    const clamped = std.math.clamp(delta, min_delta, max_delta);
    return .{
        if (clamped >= 0) sizes[0] + @as(usize, @intCast(clamped)) else sizes[0] - @as(usize, @intCast(-clamped)),
        if (clamped >= 0) sizes[1] - @as(usize, @intCast(clamped)) else sizes[1] + @as(usize, @intCast(-clamped)),
    };
}

fn offset(current: usize, start: usize) i64 {
    const current_signed: i64 = std.math.lossyCast(i64, current);
    const start_signed: i64 = std.math.lossyCast(i64, start);
    return current_signed - start_signed;
}

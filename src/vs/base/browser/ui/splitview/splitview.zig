// Port of the two-view resize path in src/vs/base/browser/ui/splitview/splitview.ts.
// Terminal cells replace CSS pixels. The workbench branches have two views,
// with an optional snapping view before the sash.

const std = @import("std");

pub const ViewSize = struct {
    size: usize,
    minimum: usize,
    maximum: usize,
    snap: bool = false,
};

/// SplitView.onSashStart captures the initial view sizes. Every change is
/// relative to that snapshot, including after the pointer leaves the sash.
pub const SashDragState = struct {
    start: usize,
    sizes: [2]usize,
    snap_before_limit: ?i64 = null,
    alt: bool = false,

    pub fn onSashStart(start: usize, views: [2]ViewSize) SashDragState {
        const before = views[0];
        var state = SashDragState{ .start = start, .sizes = .{ before.size, views[1].size } };
        if (before.snap) {
            const half: i64 = @intCast(before.minimum / 2);
            const visible = before.size != 0;
            const min_delta = @max(offset(if (visible) before.minimum else 0, before.size), offset(views[1].size, views[1].maximum));
            state.snap_before_limit = min_delta + if (visible) -half else half;
        }
        return state;
    }

    pub fn onSashChange(self: SashDragState, current: usize, views: [2]ViewSize) [2]usize {
        var bounds = views;
        var delta = offset(current, self.start);
        if (self.snap_before_limit) |limit| {
            // A hidden ViewItem exposes zero for both effective bounds.
            const visible = if (self.alt) self.sizes[0] != 0 else delta >= limit;
            if (!visible) {
                bounds[0].minimum = 0;
                bounds[0].maximum = 0;
            }
            if (self.alt) {
                // The last sash resizes its preceding view with half bounds.
                delta = std.math.clamp(delta, @divTrunc(offset(bounds[0].minimum, self.sizes[0]), 2), @divTrunc(offset(bounds[0].maximum, self.sizes[0]), 2));
            }
        }
        return resize(delta, self.sizes, bounds);
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

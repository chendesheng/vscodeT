//! One-dimensional whole-cell scroll state shared by scrollable widgets.
//!
//! `ScrollView` holds one instance per axis; `InputBox` holds one for its
//! horizontal text window. The helper owns the extent clamping, relative and
//! absolute scrolling, and the "bring this range into view" calculation used
//! by caret-follow and reveal logic. It owns no nodes and no allocator, so the
//! caller decides what a scroll offset means in its own coordinate space.

const std = @import("std");

pub const ScrollWindow = struct {
    /// Visible extent in cells.
    viewport: usize = 0,
    /// Content extent in cells.
    content: usize = 0,
    /// First visible cell.
    offset: usize = 0,

    pub fn init(viewport: usize, content: usize, offset: usize) ScrollWindow {
        var window = ScrollWindow{ .viewport = viewport, .content = content };
        window.setOffsetUnclamped(offset);
        return window;
    }

    pub fn maxOffset(self: *const ScrollWindow) usize {
        return self.content -| self.viewport;
    }

    /// Updates the extents and clamps the offset into the new range.
    pub fn setExtents(self: *ScrollWindow, viewport: usize, content: usize) void {
        self.viewport = viewport;
        self.content = content;
        self.offset = @min(self.offset, self.maxOffset());
    }

    /// Scrolls by `delta` cells (positive moves toward larger offsets).
    /// Returns whether the offset changed.
    pub fn scrollBy(self: *ScrollWindow, delta: i32) bool {
        const max: isize = @intCast(self.maxOffset());
        const current: isize = @intCast(self.offset);
        const wanted: usize = @intCast(@max(0, @min(max, current + @as(isize, delta))));
        return self.scrollTo(wanted);
    }

    /// Sets the offset, clamped to the content. Returns whether it changed.
    pub fn scrollTo(self: *ScrollWindow, offset: usize) bool {
        const wanted = @min(offset, self.maxOffset());
        if (wanted == self.offset) return false;
        self.offset = wanted;
        return true;
    }

    /// Scrolls the smallest amount that makes `[start, end)` visible with
    /// `padding` cells of margin on the edges. Oversized ranges reveal their
    /// start, matching the browser/editor minimum-scrolling rule.
    pub fn ensureVisible(self: *ScrollWindow, start: usize, end: usize, padding: usize) bool {
        const clamped_end = @max(start, end);
        var box_start = start -| padding;
        const box_end = clamped_end +| padding;
        if (box_end -| box_start >= self.viewport) {
            // The range cannot fit: reveal its beginning.
            return self.scrollTo(box_start);
        }
        if (box_start < self.offset) {
            return self.scrollTo(box_start);
        }
        if (box_end > self.offset +| self.viewport) {
            box_start = box_end -| self.viewport;
            return self.scrollTo(box_start);
        }
        return false;
    }

    pub fn visibleStart(self: *const ScrollWindow) usize {
        return self.offset;
    }

    pub fn visibleEnd(self: *const ScrollWindow) usize {
        return @min(self.offset +| self.viewport, self.content);
    }

    fn setOffsetUnclamped(self: *ScrollWindow, offset: usize) void {
        self.offset = @min(offset, self.maxOffset());
    }
};

test "scroll window clamps and scrolls" {
    const testing = std.testing;
    var window = ScrollWindow.init(10, 30, 0);
    try testing.expectEqual(@as(usize, 20), window.maxOffset());
    try testing.expect(!window.scrollBy(0));
    try testing.expect(window.scrollBy(5));
    try testing.expectEqual(@as(usize, 5), window.offset);
    try testing.expect(window.scrollBy(100));
    try testing.expectEqual(@as(usize, 20), window.offset);
    try testing.expect(!window.scrollBy(1));
    try testing.expect(window.scrollTo(0));
    try testing.expectEqual(@as(usize, 0), window.offset);

    window.setExtents(10, 4);
    try testing.expectEqual(@as(usize, 0), window.maxOffset());
    try testing.expectEqual(@as(usize, 0), window.offset);
    try testing.expect(!window.scrollTo(10));
}

test "scroll window ensures a range is visible" {
    const testing = std.testing;
    const window_viewport = 10;

    var window = ScrollWindow.init(window_viewport, 40, 0);
    try testing.expect(!window.ensureVisible(0, 1, 1));
    try testing.expect(!window.ensureVisible(1, 8, 1));
    // Reaching the right edge scrolls the minimum amount.
    try testing.expect(window.ensureVisible(9, 10, 1));
    try testing.expectEqual(@as(usize, 1), window.offset);
    // A range before the viewport scrolls back.
    try testing.expect(window.ensureVisible(0, 2, 1));
    try testing.expectEqual(@as(usize, 0), window.offset);
    // A range that cannot fit reveals its start.
    try testing.expect(window.ensureVisible(20, 40, 1));
    try testing.expectEqual(@as(usize, 19), window.offset);
    // No change when the range is already visible.
    try testing.expect(!window.ensureVisible(24, 26, 1));
}

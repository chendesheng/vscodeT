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

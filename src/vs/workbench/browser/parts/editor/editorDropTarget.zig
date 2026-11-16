// Port of the portable drop-target decisions in
// `src/vs/workbench/browser/parts/editor/editorDropTarget.ts` and the drop
// locations of `src/vs/base/browser/ui/grid/grid.ts`.
//
// The browser target owns DOM overlay elements and drag events. This port keeps
// the hit-zone split (center/edges), the resulting split orientation and the
// insert-before/after decision; the TUI paints the overlay and routes mice.

const std = @import("std");
const ui = @import("ui");
const grid = @import("../../../../base/browser/ui/grid/grid.zig");

pub const Zone = enum { center, left, right, top, bottom };

pub fn Target(comptime Pane: type) type {
    return struct {
        pane: Pane,
        zone: Zone,
    };
}

/// Computes the drop zone for a pointer inside a pane. The outer quarter of
/// each axis is an edge zone, matching the grid's drop targets; the middle is
/// a move into the pane.
pub fn zoneAt(rect: ui.Rect, x: usize, y: usize) ?Zone {
    const x0 = ui.cell.snap(rect.x);
    const y0 = ui.cell.snap(rect.y);
    const width = ui.cell.snap(rect.right()) -| x0;
    const height = ui.cell.snap(rect.bottom()) -| y0;
    if (width == 0 or height == 0) return null;
    if (x < x0 or x >= x0 + width or y < y0 or y >= y0 + height) return null;

    const rel_x = x -| x0;
    const rel_y = y -| y0;
    if (rel_y * 4 < height) return .top;
    if (rel_y * 4 >= height * 3) return .bottom;
    if (rel_x * 4 < width) return .left;
    if (rel_x * 4 >= width * 3) return .right;
    return .center;
}

pub fn orientation(zone: Zone) grid.Orientation {
    return switch (zone) {
        .left, .right => .horizontal,
        .top, .bottom => .vertical,
        .center => .horizontal,
    };
}

pub fn newFirst(zone: Zone) bool {
    return zone == .left or zone == .top;
}

test "editorDropTarget: edge quarters are split zones" {
    const rect = ui.Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    try std.testing.expectEqual(Zone.top, zoneAt(rect, 50, 1).?);
    try std.testing.expectEqual(Zone.bottom, zoneAt(rect, 50, 38).?);
    try std.testing.expectEqual(Zone.left, zoneAt(rect, 1, 20).?);
    try std.testing.expectEqual(Zone.right, zoneAt(rect, 98, 20).?);
    try std.testing.expectEqual(Zone.center, zoneAt(rect, 50, 20).?);
    try std.testing.expect(zoneAt(rect, 101, 20) == null);
}

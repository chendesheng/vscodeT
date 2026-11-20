// Port of the pane geometry/synchronization subset of
// `src/vs/editor/browser/widget/diffEditor/components/diffEditorEditors.ts`.
//
// Terminal adaptation: the widget owns the two snapshot `Editor`/`View`
// instances directly (the terminal `Editor` bundles model, undo and view, and a
// separate editor-pane wrapper would add no behavior). This module keeps the
// portable pane math and top-line synchronization shared by the widget and its
// tests.
const std = @import("std");

pub const PaneWidths = struct {
    original: usize,
    modified: usize,
    gutter: usize,
};

/// Splits the cell width into the original pane, the one-cell gutter and the
/// modified pane. Below `minimum_width` the modified pane uses the full width.
pub fn computePaneWidths(width: usize, side_by_side: bool, ratio: f64, minimum_width: usize) PaneWidths {
    if (!side_by_side or width < minimum_width) {
        return .{ .original = 0, .modified = width, .gutter = 0 };
    }
    const gutter: usize = 1;
    const available = width -| gutter;
    const clamped_ratio = if (std.math.isFinite(ratio)) std.math.clamp(ratio, 0.2, 0.8) else 0.5;
    var original: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(available)) * clamped_ratio));
    original = std.math.clamp(original, 1, available -| 1);
    return .{ .original = original, .modified = available - original, .gutter = gutter };
}

/// Returns the display row that keeps the secondary pane aligned with the
/// focused pane's top row.
pub fn alignedTopLine(focused_top: usize) usize {
    return @max(focused_top, 1);
}

test "diffEditorEditors: pane widths and narrow fallback" {
    const wide = computePaneWidths(80, true, 0.5, 50);
    try std.testing.expectEqual(@as(usize, 39), wide.original);
    try std.testing.expectEqual(@as(usize, 40), wide.modified);
    try std.testing.expectEqual(@as(usize, 1), wide.gutter);
    try std.testing.expectEqual(wide.original + wide.modified + wide.gutter, 80);

    const narrow = computePaneWidths(30, true, 0.5, 50);
    try std.testing.expectEqual(@as(usize, 0), narrow.original);
    try std.testing.expectEqual(@as(usize, 30), narrow.modified);

    // The ratio is clamped to the upstream 0.2..0.8 range.
    const extreme = computePaneWidths(100, true, 0.99, 50);
    try std.testing.expectEqual(@as(usize, 79), extreme.original);
    try std.testing.expectEqual(@as(usize, 20), extreme.modified);
    try std.testing.expectEqual(@as(usize, 5), alignedTopLine(5));
    try std.testing.expectEqual(@as(usize, 1), alignedTopLine(0));
}

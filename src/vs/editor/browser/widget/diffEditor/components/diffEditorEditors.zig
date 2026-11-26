// Port of the pane geometry/synchronization subset of
// `src/vs/editor/browser/widget/diffEditor/components/diffEditorEditors.ts`.
//
// Terminal adaptation: the widget owns the two snapshot `Editor`/`View`
// instances directly (the terminal `Editor` bundles model, undo and view, and a
// separate editor-pane wrapper would add no behavior). This module keeps the
// portable pane math and top-line synchronization shared by the widget and its
// tests.
const std = @import("std");

const DiffWordWrap = @import("../diffEditorOptions.zig").DiffWordWrap;
const WordWrap = @import("../../../../common/config/editorOptions.zig").WordWrap;
const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;

/// _adjustOptionsForLeftHandSide/_adjustOptionsForRightHandSide: the
/// original editor never wraps when hidden; both visible editors inherit
/// the editor setting unless the diff-specific override is on or off.
pub fn applyWordWrap(original: *Editor, modified: *Editor, mode: DiffWordWrap, side_by_side: bool) void {
    const override: ?WordWrap = switch (mode) {
        .inherit => null,
        .on => .on,
        .off => .off,
    };
    original.setWordWrapOverride(if (side_by_side) override else .off);
    modified.setWordWrapOverride(override);
}

pub const PaneWidths = struct {
    original: usize,
    modified: usize,
    gutter: usize,
    overview: usize = 0,
};

/// Splits the cell width into the original pane, the one-cell gutter and the
/// modified pane. Below `minimum_width` the modified pane uses the full width.
pub fn computePaneWidths(width: usize, side_by_side: bool, ratio: f64, default_ratio: f64, minimum_width: usize) PaneWidths {
    if (!side_by_side or width < minimum_width) {
        return .{ .original = 0, .modified = width, .gutter = 0 };
    }
    const gutter: usize = 1;
    const available = width -| gutter;
    // SashLayout uses the default midpoint when both minimum editor widths
    // cannot fit; otherwise the desired ratio is constrained by those widths.
    const effective_ratio = if (available <= 12 or !std.math.isFinite(ratio)) default_ratio else ratio;
    var original: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(available)) * std.math.clamp(effective_ratio, 0, 1)));
    const minimum = if (available > 12) @as(usize, 6) else 1;
    original = std.math.clamp(original, minimum, available -| minimum);
    return .{ .original = original, .modified = available - original, .gutter = gutter };
}

/// Returns the display row that keeps the secondary pane aligned with the
/// focused pane's top row.
pub fn alignedTopLine(focused_top: usize) usize {
    return @max(focused_top, 1);
}

test "diffEditorEditors: pane widths and narrow fallback" {
    const wide = computePaneWidths(80, true, 0.5, 0.5, 50);
    try std.testing.expectEqual(@as(usize, 39), wide.original);
    try std.testing.expectEqual(@as(usize, 40), wide.modified);
    try std.testing.expectEqual(@as(usize, 1), wide.gutter);
    try std.testing.expectEqual(wide.original + wide.modified + wide.gutter, 80);

    const narrow = computePaneWidths(30, true, 0.5, 0.5, 50);
    try std.testing.expectEqual(@as(usize, 0), narrow.original);
    try std.testing.expectEqual(@as(usize, 30), narrow.modified);

    // Dragging is clamped by the minimum editor width, not the default-ratio validation.
    const extreme = computePaneWidths(100, true, 0.99, 0.5, 50);
    try std.testing.expectEqual(@as(usize, 93), extreme.original);
    try std.testing.expectEqual(@as(usize, 6), extreme.modified);
    try std.testing.expectEqual(@as(usize, 5), alignedTopLine(5));
    try std.testing.expectEqual(@as(usize, 1), alignedTopLine(0));
}

// Port of the center-gutter marker subset of
// `src/vs/editor/browser/widget/diffEditor/features/gutterFeature.ts`.
//
// Terminal adaptation: upstream builds a DOM gutter with revert/insert/delete
// indicators and drag handles. The terminal has one cell between the panes, so
// this module maps each aligned mapping to the marker glyph (`+`, `~`, `-`) and
// paints `│` on the rest of the block; the widget owns hit testing and the
// split-ratio drag.
const std = @import("std");

const view_model = @import("../diffEditorViewModel.zig");
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;

pub const marker_column_width: usize = 1;

pub const ChangeKind = enum { add, delete, modify };

pub fn changeKind(mapping: view_model.DetailedLineRangeMapping) ChangeKind {
    if (mapping.original.isEmpty()) return .add;
    if (mapping.modified.isEmpty()) return .delete;
    return .modify;
}

pub fn markerGlyph(kind: ChangeKind) u21 {
    return switch (kind) {
        .add => '+',
        .delete => '-',
        .modify => '~',
    };
}

pub fn markerForMapping(mapping: view_model.DetailedLineRangeMapping) u21 {
    return markerGlyph(changeKind(mapping));
}

/// The glyph for a display row inside a changed block: the marker on the block
/// start row, the vertical continuation elsewhere.
pub fn gutterGlyph(mapping: view_model.DetailedLineRangeMapping, display_row: usize) u21 {
    if (display_row == mapping.modified.startLineNumber) return markerForMapping(mapping);
    return '│';
}

/// Locate the containing hunk in the sorted, non-overlapping aligned ranges.
/// This also handles pure deletions, whose real modified range is empty.
pub fn mappingIndexAtRow(mappings: []const @import("../components/diffEditorViewZones.zig").AlignedMapping, row: usize) ?usize {
    var lo: usize = 0;
    var hi = mappings.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = mappings[mid].modified;
        if (row < range.startLineNumber) {
            hi = mid;
        } else if (row >= range.endLineNumberExclusive) {
            lo = mid + 1;
        } else return mid;
    }
    return null;
}

test "gutterFeature: markers for insert, delete and modify" {
    const add = view_model.DetailedLineRangeMapping{
        .original = LineRange.ofLength(2, 0),
        .modified = LineRange.ofLength(2, 1),
        .inner_changes = null,
    };
    const remove = view_model.DetailedLineRangeMapping{
        .original = LineRange.ofLength(2, 1),
        .modified = LineRange.ofLength(2, 0),
        .inner_changes = null,
    };
    const modify = view_model.DetailedLineRangeMapping{
        .original = LineRange.ofLength(2, 1),
        .modified = LineRange.ofLength(2, 1),
        .inner_changes = null,
    };
    try std.testing.expectEqual(ChangeKind.add, changeKind(add));
    try std.testing.expectEqual(@as(u21, '+'), markerForMapping(add));
    try std.testing.expectEqual(@as(u21, '-'), markerForMapping(remove));
    try std.testing.expectEqual(@as(u21, '~'), markerForMapping(modify));
    try std.testing.expectEqual(@as(u21, '~'), gutterGlyph(modify, 2));
    try std.testing.expectEqual(@as(u21, '│'), gutterGlyph(modify, 3));
}

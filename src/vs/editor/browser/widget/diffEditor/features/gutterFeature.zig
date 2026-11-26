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
pub fn mappingIndexAtRow(mappings: []const @import("../components/diffEditorViewZones/diffEditorViewZones.zig").AlignedMapping, row: usize) ?usize {
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

const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;

fn rangeRows(editor: *Editor, range: LineRange) ?LineRange {
    if (range.isEmpty()) return null;
    const start = editor.viewPositionOfModelPosition(.{ .lineNumber = range.startLineNumber, .column = 1 }).lineNumber;
    const last = range.endLineNumberExclusive - 1;
    const end = editor.viewPositionOfModelPosition(.{ .lineNumber = last, .column = editor.model.getLineMaxColumn(last) }).lineNumber;
    const layout = editor.viewLayout();
    return LineRange.init(@intFromFloat(layout.getVerticalOffsetForLineNumber(start, false)), @intFromFloat(layout.getVerticalOffsetAfterLineNumber(end, false)));
}

/// Hunk bounds on the common vertical axis, including the longer side's
/// text and the shorter side's alignment zone. Coordinates are zero-based
/// layout offsets, not model or view line numbers.
pub fn hunkBounds(mapping: view_model.DetailedLineRangeMapping, original: *Editor, modified: *Editor) LineRange {
    const left = rangeRows(original, mapping.original);
    const right = rangeRows(modified, mapping.modified);
    if (left) |l| {
        if (right) |r| return LineRange.init(@min(l.startLineNumber, r.startLineNumber), @max(l.endLineNumberExclusive, r.endLineNumberExclusive));
        return l;
    }
    return right orelse LineRange.init(0, 0);
}

pub fn mappingIndexAtVerticalOffset(mappings: []const view_model.DiffMapping, original: *Editor, modified: *Editor, offset: usize) ?usize {
    var low: usize = 0;
    var high = mappings.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const bounds = hunkBounds(mappings[mid].line_range_mapping, original, modified);
        if (offset < bounds.startLineNumber) {
            high = mid;
        } else if (offset >= bounds.endLineNumberExclusive) {
            low = mid + 1;
        } else return mid;
    }
    return null;
}

pub fn mappingIndexAtModelLine(mappings: []const view_model.DiffMapping, original: bool, line: usize) ?usize {
    var low: usize = 0;
    var high = mappings.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const mapping = mappings[mid].line_range_mapping;
        const range = if (original) mapping.original else mapping.modified;
        if (line < range.startLineNumber) {
            high = mid;
        } else if (line >= range.endLineNumberExclusive) {
            low = mid + 1;
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

test "gutterFeature: benchmark 1k and 10k aligned hunks" {
    const AlignedMapping = @import("../components/diffEditorViewZones/diffEditorViewZones.zig").AlignedMapping;
    const time = @import("../../../../../base/common/timeCompat.zig");
    const allocator = std.testing.allocator;
    for ([_]usize{ 1000, 10000 }) |count| {
        const mappings = try allocator.alloc(AlignedMapping, count);
        defer allocator.free(mappings);
        for (mappings, 0..) |*mapping, index| {
            const range = LineRange.ofLength(index * 2 + 1, 1);
            mapping.* = .{ .original = range, .modified = range, .source = .{
                .original = range,
                .modified = range,
                .inner_changes = null,
            } };
        }
        const start = time.milliTimestamp();
        var sum: usize = 0;
        // Sample visible viewport rows across 1,000 distinct scroll offsets.
        for (0..1000) |frame| {
            const top = (frame * 31) % (count * 2);
            for (0..40) |offset| {
                const row = (top + offset) % (count * 2) + 1;
                const index = mappingIndexAtRow(mappings, row);
                try std.testing.expectEqual(if (row % 2 == 1) @as(?usize, (row - 1) / 2) else null, index);
                sum += index orelse 0;
            }
        }
        std.debug.print("[bench] diff gutter: {d} hunks, 40000 lookups, {d} ms, checksum {d}\n", .{ count, time.milliTimestamp() - start, sum });
    }
}

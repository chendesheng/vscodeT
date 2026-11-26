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

const range_mod = @import("../../../../common/core/range.zig");
const Range = range_mod.Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const LineRangeSet = @import("../../../../common/core/ranges/lineRange.zig").LineRangeSet;
const AbstractText = @import("../../../../common/core/text/abstractText.zig").AbstractText;
const TextModel = @import("../../../../common/model/textModel.zig").TextModel;

pub const SelectedDiffs = struct {
    mapping_indices: []usize,
    range_mappings: []view_model.RangeMapping,

    pub fn deinit(self: *SelectedDiffs, allocator: std.mem.Allocator) void {
        allocator.free(self.mapping_indices);
        allocator.free(self.range_mappings);
    }
};

/// Shared upstream _selectedDiffs calculation for the gutter and legacy
/// revert buttons. Selections are modified-model ranges, not view rows.
pub fn selectedDiffs(allocator: std.mem.Allocator, mappings: []const view_model.DiffMapping, selections: []const Selection) !SelectedDiffs {
    var any_nonempty = false;
    var selected_lines = LineRangeSet.empty(allocator);
    defer selected_lines.deinit();
    for (selections) |selection| {
        any_nonempty = any_nonempty or !selection.isEmpty();
        try selected_lines.addRange(LineRange.fromRangeInclusive(Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn)));
    }
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    var ranges: std.ArrayList(view_model.RangeMapping) = .empty;
    defer ranges.deinit(allocator);
    if (any_nonempty) for (mappings, 0..) |mapping, index| {
        const change = mapping.line_range_mapping;
        const inner = change.inner_changes orelse continue;
        if (!selected_lines.intersects(change.modified)) continue;
        try indices.append(allocator, index);
        for (inner) |range_mapping| {
            for (selections) |selection| {
                const range = Range.init(selection.startLineNumber, selection.startColumn, selection.endLineNumber, selection.endColumn);
                if (range_mod.areIntersecting(&range_mapping.modifiedRange, &range)) {
                    try ranges.append(allocator, range_mapping);
                    break;
                }
            }
        }
    };
    // Upstream returns the shared empty result when no inner change intersects.
    if (ranges.items.len == 0) indices.clearRetainingCapacity();
    const owned_indices = try indices.toOwnedSlice(allocator);
    errdefer allocator.free(owned_indices);
    return .{ .mapping_indices = owned_indices, .range_mappings = try ranges.toOwnedSlice(allocator) };
}

/// DiffEditorGutter.computeStagedValue: apply only the provided changes to the
/// original model. TextModelText preserves the models' own EOLs and validates
/// the inclusive line ranges (including the upstream end-column sentinel).
pub fn computeStagedValue(allocator: std.mem.Allocator, mapping: view_model.DetailedLineRangeMapping, original: *TextModel, modified: *TextModel) ![]u8 {
    var temporary = std.heap.ArenaAllocator.init(allocator);
    defer temporary.deinit();
    var original_text = AbstractText.initTextModel(allocator, original);
    defer original_text.deinit();
    var modified_text = AbstractText.initTextModel(temporary.allocator(), modified);
    defer modified_text.deinit();
    var edit = try view_model.DetailedLineRangeMapping.toTextEdit(allocator, &.{mapping}, &modified_text);
    defer edit.deinit();
    return edit.apply(allocator, &original_text);
}

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

const Editor = @import("../../codeEditor/codeEditorWidgetTerminal.zig").Editor;

fn rangeRows(editor: *Editor, range: LineRange) ?LineRange {
    if (range.isEmpty() or range.startLineNumber < 1 or range.startLineNumber > editor.model.getLineCount()) return null;
    const start = editor.viewPositionOfModelPosition(.{ .lineNumber = range.startLineNumber, .column = 1 }).lineNumber;
    const last = @min(range.endLineNumberExclusive - 1, editor.model.getLineCount());
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

const EditorGutter = @import("../utils/editorGutter.zig").EditorGutter;
const IGutterItemProvider = @import("../utils/editorGutter.zig").IGutterItemProvider;

/// The diff gutter supplies the hunk items and their common-axis geometry to
/// the shared gutter layout. The view owns the viewport clipping.
pub const DiffEditorGutter = struct {
    mappings: []const view_model.DiffMapping,
    original: *Editor,
    modified: *Editor,

    fn bounds(context: *const anyopaque, index: usize) LineRange {
        const self: *const DiffEditorGutter = @ptrCast(@alignCast(context));
        return hunkBounds(self.mappings[index].line_range_mapping, self.original, self.modified);
    }

    pub fn render(self: *const DiffEditorGutter, top: usize, height: usize) EditorGutter {
        const provider: IGutterItemProvider = .{ .context = self, .item_count = self.mappings.len, .bounds = bounds };
        return EditorGutter.render(provider, LineRange.ofLength(top, height));
    }
};

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

test "gutterFeature: selection toolbar intersects inner mappings and stages only selected text" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
    var original = try TestModel.init(allocator, "prefix\r\nabc old def stale\r\nsuffix", "plaintext");
    defer original.deinit();
    var modified = try TestModel.init(allocator, "prefix\r\nabc new def fresh\r\nsuffix", "plaintext");
    defer modified.deinit();
    var inner = [_]view_model.RangeMapping{
        .{ .originalRange = Range.init(2, 5, 2, 8), .modifiedRange = Range.init(2, 5, 2, 8) },
        .{ .originalRange = Range.init(2, 13, 2, 18), .modifiedRange = Range.init(2, 13, 2, 18) },
    };
    const mappings = [_]view_model.DiffMapping{.{ .line_range_mapping = .{
        .original = LineRange.ofLength(2, 1),
        .modified = LineRange.ofLength(2, 1),
        .inner_changes = &inner,
    } }};
    var selected = try selectedDiffs(allocator, &mappings, &.{ Selection.init(2, 6, 2, 7), Selection.init(2, 10, 2, 10) });
    defer selected.deinit(allocator);
    try std.testing.expectEqualSlices(usize, &.{0}, selected.mapping_indices);
    try std.testing.expectEqualSlices(view_model.RangeMapping, inner[0..1], selected.range_mappings);
    var selected_mapping = try view_model.DetailedLineRangeMapping.fromRangeMappings(allocator, selected.range_mappings);
    defer selected_mapping.deinit(allocator);
    const selected_value = try computeStagedValue(allocator, selected_mapping, original.model, modified.model);
    defer allocator.free(selected_value);
    try std.testing.expectEqualStrings("prefix\r\nabc new def stale\r\nsuffix", selected_value);

    var hunk = try mappings[0].line_range_mapping.withInnerChangesFromLineRanges(allocator);
    defer hunk.deinit(allocator);
    const hunk_value = try computeStagedValue(allocator, hunk, original.model, modified.model);
    defer allocator.free(hunk_value);
    try std.testing.expectEqualStrings("prefix\r\nabc new def fresh\r\nsuffix", hunk_value);

    var empty = try selectedDiffs(allocator, &mappings, &.{Selection.init(2, 8, 2, 9)});
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.mapping_indices.len);
    try std.testing.expectEqual(@as(usize, 0), empty.range_mappings.len);
}

test "gutterFeature: whole-line staging handles document boundaries" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
    for ([_]struct { old: []const u8, new: []const u8, original: LineRange, modified: LineRange }{
        .{ .old = "tail", .new = "head\ntail", .original = LineRange.ofLength(1, 0), .modified = LineRange.ofLength(1, 1) },
        .{ .old = "head\ntail", .new = "tail", .original = LineRange.ofLength(1, 1), .modified = LineRange.ofLength(1, 0) },
        .{ .old = "head", .new = "head\ntail", .original = LineRange.ofLength(2, 0), .modified = LineRange.ofLength(2, 1) },
        .{ .old = "head\ntail", .new = "head", .original = LineRange.ofLength(2, 1), .modified = LineRange.ofLength(2, 0) },
    }) |fixture| {
        var original = try TestModel.init(allocator, fixture.old, "plaintext");
        defer original.deinit();
        var modified = try TestModel.init(allocator, fixture.new, "plaintext");
        defer modified.deinit();
        const change: view_model.DetailedLineRangeMapping = .{ .original = fixture.original, .modified = fixture.modified, .inner_changes = null };
        var hunk = try change.withInnerChangesFromLineRanges(allocator);
        defer hunk.deinit(allocator);
        const value = try computeStagedValue(allocator, hunk, original.model, modified.model);
        defer allocator.free(value);
        try std.testing.expectEqualStrings(fixture.new, value);
    }
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

test "gutterFeature: benchmark 1k and 10k real-layout hunks" {
    const time = @import("../../../../../base/common/timeCompat.zig");
    const allocator = std.testing.allocator;
    for ([_]usize{ 1000, 10000 }) |count| {
        const text = try allocator.alloc(u8, count * 2 - 1);
        defer allocator.free(text);
        @memset(text, '\n');
        const original = try Editor.createFromText(allocator, std.testing.io, text, "original.txt", 40, 40);
        defer {
            original.deinit();
            allocator.destroy(original);
        }
        const modified = try Editor.createFromText(allocator, std.testing.io, text, "modified.txt", 40, 40);
        defer {
            modified.deinit();
            allocator.destroy(modified);
        }
        const mappings = try allocator.alloc(view_model.DiffMapping, count);
        defer allocator.free(mappings);
        for (mappings, 0..) |*mapping, index| {
            const range = LineRange.ofLength(index * 2 + 1, 1);
            mapping.* = .{ .line_range_mapping = .{ .original = range, .modified = range, .inner_changes = null } };
        }
        const start = time.milliTimestamp();
        var sum: usize = 0;
        for (0..1000) |frame| {
            const top = (frame * 31) % (count * 2);
            for (0..40) |offset| {
                const row = (top + offset) % (count * 2);
                const index = mappingIndexAtVerticalOffset(mappings, original, modified, row);
                try std.testing.expectEqual(if (row % 2 == 0) @as(?usize, row / 2) else null, index);
                sum += index orelse 0;
            }
        }
        std.debug.print("[bench] diff real-layout gutter: {d} hunks, 40000 lookups, {d} ms, checksum {d}\n", .{ count, time.milliTimestamp() - start, sum });
        const provider: DiffEditorGutter = .{ .mappings = mappings, .original = original, .modified = modified };
        const item_start = time.milliTimestamp();
        var item_sum: usize = 0;
        for (0..1000) |frame| {
            const top = (frame * 31) % (count * 2);
            const first_height = @min(40, count * 2 - top);
            var items = provider.render(top, first_height);
            while (items.next()) |item| {
                try std.testing.expectEqual(item.index * 2, item.bounds.startLineNumber);
                item_sum += item.index;
            }
            if (first_height < 40) {
                items = provider.render(0, 40 - first_height);
                while (items.next()) |item| item_sum += item.index;
            }
        }
        try std.testing.expectEqual(sum, item_sum);
        std.debug.print("[bench] diff visible gutter items: {d} hunks, 1000 frames, {d} ms, checksum {d}\n", .{ count, time.milliTimestamp() - item_start, item_sum });
    }
}

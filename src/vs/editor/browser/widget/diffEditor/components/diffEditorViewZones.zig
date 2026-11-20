// Terminal replacement for the view-zone alignment subset of
// `src/vs/editor/browser/widget/diffEditor/components/diffEditorViewZones.ts`.
//
// Upstream inserts view zones and filler lines through the editor's view-zone
// API so both panes render equal-height rows. The terminal editor has no view
// zones, so this module pre-aligns both sides into display line arrays: each
// mapping becomes an unchanged segment followed by a changed block of height
// `max(originalLen, modifiedLen)`; the shorter side is padded with blank filler
// rows at the block end. Top-of-file insert/delete blocks pad at the start so
// the changed real lines stay at the top of the file exactly like upstream's
// leading filler lines. Display rows are 1-based; `null` entries are fillers.
const std = @import("std");
const Allocator = std.mem.Allocator;

const range_mapping = @import("../../../../common/diff/rangeMapping.zig");
const LineRange = @import("../../../../common/core/ranges/lineRange.zig").LineRange;

pub const DetailedLineRangeMapping = range_mapping.DetailedLineRangeMapping;

/// One changed block in display coordinates. `original`/`modified` are
/// exclusive line ranges over the aligned display rows and include fillers.
pub const AlignedMapping = struct {
    original: LineRange,
    modified: LineRange,
    /// The real (un-aligned) mapping, borrowed from the view model state.
    source: DetailedLineRangeMapping,
};

pub const AlignedRows = struct {
    allocator: Allocator,
    /// Index 0 is display row 1; a value is the real line number, `null` is a
    /// filler row.
    original: []?usize,
    modified: []?usize,
    mappings: []AlignedMapping,
    /// Real line number -> display row (1-based), or null when the real line is
    /// not present in the display text.
    original_to_display: []?usize,
    modified_to_display: []?usize,

    pub fn deinit(self: *AlignedRows) void {
        self.allocator.free(self.original);
        self.allocator.free(self.modified);
        self.allocator.free(self.mappings);
        self.allocator.free(self.original_to_display);
        self.allocator.free(self.modified_to_display);
        self.* = undefined;
    }

    pub fn lineCount(self: *const AlignedRows) usize {
        return self.original.len;
    }

    pub fn displayRowForOriginal(self: *const AlignedRows, real_line: usize) ?usize {
        if (real_line == 0 or real_line > self.original_to_display.len) return null;
        return self.original_to_display[real_line - 1];
    }

    pub fn displayRowForModified(self: *const AlignedRows, real_line: usize) ?usize {
        if (real_line == 0 or real_line > self.modified_to_display.len) return null;
        return self.modified_to_display[real_line - 1];
    }

    /// Display line number map for a snapshot editor (1-based view line ->
    /// display number). Fillers map to `null`.
    pub fn originalLineNumberMap(self: *const AlignedRows) []const ?usize {
        return self.original;
    }

    pub fn modifiedLineNumberMap(self: *const AlignedRows) []const ?usize {
        return self.modified;
    }
};

pub fn computeAlignedRows(
    allocator: Allocator,
    original_line_count: usize,
    modified_line_count: usize,
    changes: []const DetailedLineRangeMapping,
) !AlignedRows {
    var original = std.array_list.Managed(?usize).init(allocator);
    errdefer original.deinit();
    var modified = std.array_list.Managed(?usize).init(allocator);
    errdefer modified.deinit();
    var mappings = std.array_list.Managed(AlignedMapping).init(allocator);
    errdefer mappings.deinit();

    var original_cursor: usize = 1;
    var modified_cursor: usize = 1;

    for (changes) |change| {
        // Unchanged segment before the changed block. Insertions have an empty
        // original range at the insertion point, so the segment length is zero
        // on both sides there.
        const original_unchanged = change.original.startLineNumber -| original_cursor;
        const modified_unchanged = change.modified.startLineNumber -| modified_cursor;
        const unchanged = @min(original_unchanged, modified_unchanged);
        var index: usize = 0;
        while (index < unchanged) : (index += 1) {
            try original.append(original_cursor + index);
            try modified.append(modified_cursor + index);
        }
        original_cursor += unchanged;
        modified_cursor += unchanged;

        const original_start_display = original.items.len + 1;
        const modified_start_display = modified.items.len + 1;

        const original_length = change.original.length();
        const modified_length = change.modified.length();
        const height = @max(original_length, modified_length);

        // Top-of-file pure insert/delete uses leading fillers, matching the
        // upstream leading filler rows. Other blocks pad at the end.
        const top_of_file = original_cursor == 1 and modified_cursor == 1 and
            (original_length == 0 or modified_length == 0);

        if (top_of_file) {
            try appendFillers(&original, height -| original_length);
            try appendFillers(&modified, height -| modified_length);
            index = 0;
            while (index < original_length) : (index += 1) try original.append(original_cursor + index);
            index = 0;
            while (index < modified_length) : (index += 1) try modified.append(modified_cursor + index);
        } else {
            index = 0;
            while (index < original_length) : (index += 1) try original.append(original_cursor + index);
            try appendFillers(&original, height -| original_length);
            index = 0;
            while (index < modified_length) : (index += 1) try modified.append(modified_cursor + index);
            try appendFillers(&modified, height -| modified_length);
        }

        try mappings.append(.{
            .original = LineRange.ofLength(original_start_display, height),
            .modified = LineRange.ofLength(modified_start_display, height),
            .source = change,
        });

        original_cursor += original_length;
        modified_cursor += modified_length;
    }

    // Trailing unchanged segment.
    const original_remaining = original_line_count -| (original_cursor - 1);
    const modified_remaining = modified_line_count -| (modified_cursor - 1);
    const remaining = @min(original_remaining, modified_remaining);
    var index: usize = 0;
    while (index < remaining) : (index += 1) {
        try original.append(original_cursor + index);
        try modified.append(modified_cursor + index);
    }

    const original_rows = try original.toOwnedSlice();
    errdefer allocator.free(original_rows);
    const modified_rows = try modified.toOwnedSlice();
    errdefer allocator.free(modified_rows);
    const aligned_mappings = try mappings.toOwnedSlice();
    errdefer allocator.free(aligned_mappings);

    if (original_rows.len != modified_rows.len) return error.AlignmentMismatch;

    const original_to_display = try allocator.alloc(?usize, original_line_count);
    errdefer allocator.free(original_to_display);
    @memset(original_to_display, null);
    for (original_rows, 0..) |row, display_index| {
        if (row) |line| {
            if (line <= original_line_count) original_to_display[line - 1] = display_index + 1;
        }
    }

    const modified_to_display = try allocator.alloc(?usize, modified_line_count);
    errdefer allocator.free(modified_to_display);
    @memset(modified_to_display, null);
    for (modified_rows, 0..) |row, display_index| {
        if (row) |line| {
            if (line <= modified_line_count) modified_to_display[line - 1] = display_index + 1;
        }
    }

    return .{
        .allocator = allocator,
        .original = original_rows,
        .modified = modified_rows,
        .mappings = aligned_mappings,
        .original_to_display = original_to_display,
        .modified_to_display = modified_to_display,
    };
}

fn appendFillers(list: *std.array_list.Managed(?usize), count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try list.append(null);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_support = @import("../../../../test/common/port/testSupport.zig");
const TestModel = test_support.TestModel;
const doc_diff = @import("../../../../common/diff/documentDiffProvider.zig");
const LineDiffProvider = doc_diff.LineDiffProvider;
const deinitDiff = doc_diff.deinitDiff;

fn compute(allocator: Allocator, original_lines: []const []const u8, modified_lines: []const []const u8) !struct {
    diff: doc_diff.IDocumentDiff,
    rows: AlignedRows,
} {
    var provider = LineDiffProvider.init(.advanced);
    var diff = try provider.computeDiffFromLines(allocator, original_lines, modified_lines, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    errdefer deinitDiff(allocator, &diff);
    const rows = try computeAlignedRows(allocator, original_lines.len, modified_lines.len, diff.changes);
    return .{ .diff = diff, .rows = rows };
}

test "viewZones: equal row counts and aligned block starts" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "a", "b", "c", "d" };
    const modified = [_][]const u8{ "a", "B1", "B2", "c", "d", "e" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    try testing.expectEqual(result.rows.original.len, result.rows.modified.len);
    // One changed line that becomes two, plus a trailing inserted line.
    try testing.expectEqual(@as(usize, 2), result.rows.mappings.len);
    for (result.rows.mappings) |mapping| {
        try testing.expectEqual(mapping.original.startLineNumber, mapping.modified.startLineNumber);
        try testing.expectEqual(mapping.original.length(), mapping.modified.length());
    }
    // Each changed block pads the shorter original side with one filler, so the
    // following unchanged lines stay aligned.
    try testing.expectEqual(@as(usize, 2), countFillers(result.rows.original));

    const original_c = result.rows.displayRowForOriginal(3).?;
    const modified_c = result.rows.displayRowForModified(4).?;
    try testing.expectEqual(original_c, modified_c);
}

test "viewZones: middle insertion and deletion keep both sides aligned" {
    const allocator = testing.allocator;

    const original_insert = [_][]const u8{ "a", "b", "c" };
    const modified_insert = [_][]const u8{ "a", "x", "b", "c" };
    var insert = try compute(allocator, &original_insert, &modified_insert);
    defer {
        insert.rows.deinit();
        deinitDiff(allocator, &insert.diff);
    }
    try testing.expectEqual(insert.rows.original.len, insert.rows.modified.len);
    try testing.expectEqual(@as(usize, 1), countFillers(insert.rows.original));
    try testing.expectEqual(@as(usize, 0), countFillers(insert.rows.modified));

    const original_delete = [_][]const u8{ "a", "x", "b", "c" };
    const modified_delete = [_][]const u8{ "a", "b", "c" };
    var deleted = try compute(allocator, &original_delete, &modified_delete);
    defer {
        deleted.rows.deinit();
        deinitDiff(allocator, &deleted.diff);
    }
    try testing.expectEqual(deleted.rows.original.len, deleted.rows.modified.len);
    try testing.expectEqual(@as(usize, 0), countFillers(deleted.rows.original));
    try testing.expectEqual(@as(usize, 1), countFillers(deleted.rows.modified));
}

test "viewZones: top-of-file insertion uses leading fillers" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "a", "b" };
    const modified = [_][]const u8{ "x", "y", "a", "b" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    try testing.expectEqual(result.rows.original.len, result.rows.modified.len);
    try testing.expectEqual(@as(?usize, null), result.rows.original[0]);
    try testing.expectEqual(@as(?usize, null), result.rows.original[1]);
    try testing.expectEqual(@as(?usize, 1), result.rows.original[2]);
    try testing.expectEqual(@as(?usize, 1), result.rows.modified[0]);
    try testing.expectEqual(@as(?usize, 2), result.rows.modified[1]);
    // The unchanged 'a' line is aligned after the leading block.
    try testing.expectEqual(result.rows.displayRowForOriginal(1), result.rows.displayRowForModified(3));
}

test "viewZones: top-of-file deletion uses leading fillers" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "x", "a", "b" };
    const modified = [_][]const u8{ "a", "b" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    try testing.expectEqual(result.rows.original.len, result.rows.modified.len);
    try testing.expectEqual(@as(?usize, null), result.rows.modified[0]);
    try testing.expectEqual(@as(?usize, 1), result.rows.modified[1]);
    // The unchanged lines after the deleted top line stay aligned.
    try testing.expectEqual(result.rows.displayRowForOriginal(2), result.rows.displayRowForModified(1));
}

test "viewZones: line number maps expose fillers" {
    const allocator = testing.allocator;
    const original = [_][]const u8{ "a", "c" };
    const modified = [_][]const u8{ "a", "b", "c" };
    var result = try compute(allocator, &original, &modified);
    defer {
        result.rows.deinit();
        deinitDiff(allocator, &result.diff);
    }

    const map = result.rows.originalLineNumberMap();
    try testing.expectEqual(@as(usize, 3), map.len);
    try testing.expectEqual(@as(?usize, 1), map[0]);
    try testing.expectEqual(@as(?usize, null), map[1]);
    try testing.expectEqual(@as(?usize, 2), map[2]);
    const modified_map = result.rows.modifiedLineNumberMap();
    try testing.expectEqual(@as(?usize, 2), modified_map[1]);
}

fn countFillers(rows: []const ?usize) usize {
    var count: usize = 0;
    for (rows) |row| {
        if (row == null) count += 1;
    }
    return count;
}

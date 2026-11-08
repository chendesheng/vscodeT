const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const utils = @import("../../../../base/common/utils.zig");
const findLastIdxMonotonous = utils.findLastIdxMonotonous;
const diff = @import("algorithms/diffAlgorithm.zig");
const ITimeout = diff.ITimeout;
const InfiniteTimeout = diff.InfiniteTimeout;
const SequenceDiff = diff.SequenceDiff;
const MyersDiffAlgorithm = @import("algorithms/myersDiffAlgorithm.zig").MyersDiffAlgorithm;
const LineRange = @import("../../core/ranges/lineRange.zig").LineRange;
const LineRangeSet = @import("../../core/ranges/lineRange.zig").LineRangeSet;
const Range = @import("../../core/range.zig").Range;
const LineRangeMapping = @import("../rangeMapping.zig").LineRangeMapping;
const DetailedLineRangeMapping = @import("../rangeMapping.zig").DetailedLineRangeMapping;
const LinesSliceCharSequence = @import("linesSliceCharSequence.zig").LinesSliceCharSequence;
const LineRangeFragment = @import("utils.zig").LineRangeFragment;
const isSpace = @import("utils.zig").isSpace;

pub fn computeMovedLines(
    allocator: Allocator,
    changes: []DetailedLineRangeMapping,
    original_lines: []const []const u8,
    modified_lines: []const []const u8,
    hashed_original_lines: []const u64,
    hashed_modified_lines: []const u64,
    timeout: ITimeout,
) ![]LineRangeMapping {
    const simple = try computeMovesFromSimpleDeletionsToSimpleInsertions(allocator, changes, original_lines, modified_lines, timeout);
    defer allocator.free(simple.moves);
    defer allocator.free(simple.excluded_changes);

    var moves = ArrayList(LineRangeMapping).init(allocator);
    defer moves.deinit();
    try moves.appendSlice(simple.moves);

    if (!timeout.isValid()) {
        return allocator.alloc(LineRangeMapping, 0);
    }

    var filtered_changes = ArrayList(DetailedLineRangeMapping).init(allocator);
    defer filtered_changes.deinit();
    for (changes, 0..) |change, i| {
        if (!simple.excluded_changes[i]) {
            try filtered_changes.append(change);
        }
    }

    const unchanged_moves = try computeUnchangedMoves(
        allocator,
        filtered_changes.items,
        hashed_original_lines,
        hashed_modified_lines,
        original_lines,
        modified_lines,
        timeout,
    );
    defer allocator.free(unchanged_moves);
    try moves.appendSlice(unchanged_moves);

    const joined = try joinCloseConsecutiveMoves(allocator, moves.items);
    defer allocator.free(joined);

    // Ignore too short moves
    var filtered_moves = ArrayList(LineRangeMapping).init(allocator);
    defer filtered_moves.deinit();
    for (joined) |current| {
        const original_offset_range = current.original.toOffsetRange();
        const lines = original_lines[original_offset_range.start..original_offset_range.endExclusive];
        var original_text_len: usize = 0;
        var long_line_count: usize = 0;
        for (lines, 0..) |line, i| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len >= 2) {
                long_line_count += 1;
            }
            original_text_len += trimmed.len;
            if (i + 1 < lines.len) {
                original_text_len += 1;
            }
        }
        if (original_text_len >= 15 and long_line_count >= 2) {
            try filtered_moves.append(current);
        }
    }

    return removeMovesInSameDiff(allocator, changes, filtered_moves.items);
}

const SimpleMoves = struct {
    moves: []LineRangeMapping,
    excluded_changes: []bool,
};

const DeletionFragment = struct {
    fragment: LineRangeFragment,
    source_index: usize,
};

fn computeMovesFromSimpleDeletionsToSimpleInsertions(
    allocator: Allocator,
    changes: []DetailedLineRangeMapping,
    original_lines: []const []const u8,
    modified_lines: []const []const u8,
    timeout: ITimeout,
) !SimpleMoves {
    var deletions = ArrayList(DeletionFragment).init(allocator);
    defer deletions.deinit();

    var insertions = ArrayList(DeletionFragment).init(allocator);
    defer insertions.deinit();

    var moves = ArrayList(LineRangeMapping).init(allocator);
    errdefer moves.deinit();

    const excluded_changes = try allocator.alloc(bool, changes.len);
    errdefer allocator.free(excluded_changes);
    @memset(excluded_changes, false);

    for (changes, 0..) |change, i| {
        if (change.modified.isEmpty() and change.original.length() >= 3) {
            try deletions.append(.{
                .fragment = LineRangeFragment.init(change.original, original_lines, change),
                .source_index = i,
            });
        }
        if (change.original.isEmpty() and change.modified.length() >= 3) {
            try insertions.append(.{
                .fragment = LineRangeFragment.init(change.modified, modified_lines, change),
                .source_index = i,
            });
        }
    }

    for (deletions.items) |deletion| {
        var highest_similarity: f64 = -1;
        var best: ?usize = null;
        for (insertions.items, 0..) |insertion, i| {
            const similarity = deletion.fragment.computeSimilarity(&insertion.fragment);
            if (similarity > highest_similarity) {
                highest_similarity = similarity;
                best = i;
            }
        }

        if (highest_similarity > 0.90) {
            if (best) |best_index| {
                const insertion = insertions.orderedRemove(best_index);
                try moves.append(LineRangeMapping.init(deletion.fragment.range, insertion.fragment.range));
                excluded_changes[deletion.source_index] = true;
                excluded_changes[insertion.source_index] = true;
            }
        }

        if (!timeout.isValid()) {
            return SimpleMoves{
                .moves = try moves.toOwnedSlice(),
                .excluded_changes = excluded_changes,
            };
        }
    }

    return SimpleMoves{
        .moves = try moves.toOwnedSlice(),
        .excluded_changes = excluded_changes,
    };
}

const PossibleMapping = struct {
    modified_line_range: LineRange,
    original_line_range: LineRange,
};

fn computeUnchangedMoves(
    allocator: Allocator,
    changes: []DetailedLineRangeMapping,
    hashed_original_lines: []const u64,
    hashed_modified_lines: []const u64,
    original_lines: []const []const u8,
    modified_lines: []const []const u8,
    timeout: ITimeout,
) ![]LineRangeMapping {
    var moves = ArrayList(LineRangeMapping).init(allocator);
    errdefer moves.deinit();

    var original3_line_hashes = std.StringHashMap(ArrayList(LineRange)).init(allocator);
    defer {
        var key_iterator = original3_line_hashes.keyIterator();
        while (key_iterator.next()) |key| {
            allocator.free(key.*);
        }
        var value_iterator = original3_line_hashes.valueIterator();
        while (value_iterator.next()) |list| {
            list.deinit();
        }
        original3_line_hashes.deinit();
    }

    for (changes) |change| {
        var i = change.original.startLineNumber;
        while (i + 2 < change.original.endLineNumberExclusive) : (i += 1) {
            const key = try std.fmt.allocPrint(allocator, "{d}:{d}:{d}", .{
                hashed_original_lines[i - 1],
                hashed_original_lines[i],
                hashed_original_lines[i + 1],
            });
            const line_range = LineRange.init(i, i + 3);
            if (original3_line_hashes.getPtr(key)) |list| {
                defer allocator.free(key);
                try list.append(line_range);
            } else {
                var list = ArrayList(LineRange).init(allocator);
                list.append(line_range) catch |e| {
                    list.deinit();
                    allocator.free(key);
                    return e;
                };
                original3_line_hashes.put(key, list) catch |e| {
                    list.deinit();
                    allocator.free(key);
                    return e;
                };
            }
        }
    }

    var possible_mappings = ArrayList(PossibleMapping).init(allocator);
    defer possible_mappings.deinit();

    std.mem.sort(DetailedLineRangeMapping, changes, {}, struct {
        fn lessThan(_: void, a: DetailedLineRangeMapping, b: DetailedLineRangeMapping) bool {
            return a.modified.startLineNumber < b.modified.startLineNumber;
        }
    }.lessThan);

    for (changes) |change| {
        var last_mappings = ArrayList(usize).init(allocator);
        defer last_mappings.deinit();

        var i = change.modified.startLineNumber;
        while (i + 2 < change.modified.endLineNumberExclusive) : (i += 1) {
            const key = try std.fmt.allocPrint(allocator, "{d}:{d}:{d}", .{
                hashed_modified_lines[i - 1],
                hashed_modified_lines[i],
                hashed_modified_lines[i + 1],
            });
            defer allocator.free(key);

            const current_modified_range = LineRange.init(i, i + 3);
            var next_mappings = ArrayList(usize).init(allocator);
            errdefer next_mappings.deinit();

            if (original3_line_hashes.get(key)) |ranges| {
                for (ranges.items) |range| {
                    var extended = false;
                    for (last_mappings.items) |last_index| {
                        const last_mapping = &possible_mappings.items[last_index];
                        // does this match extend some last match?
                        if (last_mapping.original_line_range.endLineNumberExclusive + 1 == range.endLineNumberExclusive and
                            last_mapping.modified_line_range.endLineNumberExclusive + 1 == current_modified_range.endLineNumberExclusive)
                        {
                            last_mapping.original_line_range = LineRange.init(last_mapping.original_line_range.startLineNumber, range.endLineNumberExclusive);
                            last_mapping.modified_line_range = LineRange.init(last_mapping.modified_line_range.startLineNumber, current_modified_range.endLineNumberExclusive);
                            try next_mappings.append(last_index);
                            extended = true;
                            break;
                        }
                    }
                    if (extended) {
                        continue;
                    }

                    const mapping_index = possible_mappings.items.len;
                    try possible_mappings.append(.{
                        .modified_line_range = current_modified_range,
                        .original_line_range = range,
                    });
                    try next_mappings.append(mapping_index);
                }
            }

            last_mappings.deinit();
            last_mappings = next_mappings;
        }

        if (!timeout.isValid()) {
            return allocator.alloc(LineRangeMapping, 0);
        }
    }

    std.mem.sort(PossibleMapping, possible_mappings.items, {}, struct {
        fn lessThan(_: void, a: PossibleMapping, b: PossibleMapping) bool {
            return a.modified_line_range.length() > b.modified_line_range.length();
        }
    }.lessThan);

    var modified_set = LineRangeSet.empty(allocator);
    defer modified_set.deinit();
    var original_set = LineRangeSet.empty(allocator);
    defer original_set.deinit();

    for (possible_mappings.items) |mapping| {
        const diff_orig_to_mod: isize = @as(isize, @intCast(mapping.modified_line_range.startLineNumber)) -
            @as(isize, @intCast(mapping.original_line_range.startLineNumber));

        var modified_sections = try modified_set.subtractFrom(mapping.modified_line_range);
        defer modified_sections.deinit();
        var original_subtracted = try original_set.subtractFrom(mapping.original_line_range);
        defer original_subtracted.deinit();
        var original_translated_sections = try original_subtracted.getWithDeltaSigned(diff_orig_to_mod);
        defer original_translated_sections.deinit();

        var modified_intersected_sections = try modified_sections.getIntersection(original_translated_sections);
        defer modified_intersected_sections.deinit();

        for (modified_intersected_sections.ranges()) |s| {
            if (s.length() < 3) {
                continue;
            }
            const modified_line_range = s;
            const original_line_range = s.deltaSigned(-diff_orig_to_mod);

            try moves.append(LineRangeMapping.init(original_line_range, modified_line_range));

            try modified_set.addRange(modified_line_range);
            try original_set.addRange(original_line_range);
        }
    }

    std.mem.sort(LineRangeMapping, moves.items, {}, struct {
        fn lessThan(_: void, a: LineRangeMapping, b: LineRangeMapping) bool {
            return a.original.startLineNumber < b.original.startLineNumber;
        }
    }.lessThan);

    for (moves.items, 0..) |move, move_index| {
        const first_touching_change_orig_index = findLastIdxMonotonous(
            DetailedLineRangeMapping,
            changes,
            move.original.startLineNumber,
            struct {
                fn pred(change: DetailedLineRangeMapping, line: usize) bool {
                    return change.original.startLineNumber <= line;
                }
            }.pred,
            0,
            changes.len,
        );
        const first_touching_change_mod_index = findLastIdxMonotonous(
            DetailedLineRangeMapping,
            changes,
            move.modified.startLineNumber,
            struct {
                fn pred(change: DetailedLineRangeMapping, line: usize) bool {
                    return change.modified.startLineNumber <= line;
                }
            }.pred,
            0,
            changes.len,
        );

        const first_touching_change_orig = changes[first_touching_change_orig_index orelse continue];
        const first_touching_change_mod = changes[first_touching_change_mod_index orelse continue];

        const lines_above = @max(
            move.original.startLineNumber - first_touching_change_orig.original.startLineNumber,
            move.modified.startLineNumber - first_touching_change_mod.modified.startLineNumber,
        );

        const last_touching_change_orig_index = findLastIdxMonotonous(
            DetailedLineRangeMapping,
            changes,
            move.original.endLineNumberExclusive,
            struct {
                fn pred(change: DetailedLineRangeMapping, line: usize) bool {
                    return change.original.startLineNumber < line;
                }
            }.pred,
            0,
            changes.len,
        );
        const last_touching_change_mod_index = findLastIdxMonotonous(
            DetailedLineRangeMapping,
            changes,
            move.modified.endLineNumberExclusive,
            struct {
                fn pred(change: DetailedLineRangeMapping, line: usize) bool {
                    return change.modified.startLineNumber < line;
                }
            }.pred,
            0,
            changes.len,
        );

        const last_touching_change_orig = changes[last_touching_change_orig_index orelse continue];
        const last_touching_change_mod = changes[last_touching_change_mod_index orelse continue];

        const lines_below_signed: isize = @max(
            @as(isize, @intCast(last_touching_change_orig.original.endLineNumberExclusive)) - @as(isize, @intCast(move.original.endLineNumberExclusive)),
            @as(isize, @intCast(last_touching_change_mod.modified.endLineNumberExclusive)) - @as(isize, @intCast(move.modified.endLineNumberExclusive)),
        );
        const lines_below: usize = if (lines_below_signed < 0) 0 else @intCast(lines_below_signed);

        var extend_to_top: usize = 0;
        while (extend_to_top < lines_above) : (extend_to_top += 1) {
            const orig_line = move.original.startLineNumber - extend_to_top - 1;
            const mod_line = move.modified.startLineNumber - extend_to_top - 1;
            if (orig_line < 1 or mod_line < 1) {
                break;
            }
            if (modified_set.contains(mod_line) or original_set.contains(orig_line)) {
                break;
            }
            if (!try areLinesSimilar(allocator, original_lines[orig_line - 1], modified_lines[mod_line - 1], timeout)) {
                break;
            }
        }

        if (extend_to_top > 0) {
            try original_set.addRange(LineRange.init(move.original.startLineNumber - extend_to_top, move.original.startLineNumber));
            try modified_set.addRange(LineRange.init(move.modified.startLineNumber - extend_to_top, move.modified.startLineNumber));
        }

        var extend_to_bottom: usize = 0;
        while (extend_to_bottom < lines_below) : (extend_to_bottom += 1) {
            const orig_line = move.original.endLineNumberExclusive + extend_to_bottom;
            const mod_line = move.modified.endLineNumberExclusive + extend_to_bottom;
            if (orig_line > original_lines.len or mod_line > modified_lines.len) {
                break;
            }
            if (modified_set.contains(mod_line) or original_set.contains(orig_line)) {
                break;
            }
            if (!try areLinesSimilar(allocator, original_lines[orig_line - 1], modified_lines[mod_line - 1], timeout)) {
                break;
            }
        }

        if (extend_to_bottom > 0) {
            try original_set.addRange(LineRange.init(move.original.endLineNumberExclusive, move.original.endLineNumberExclusive + extend_to_bottom));
            try modified_set.addRange(LineRange.init(move.modified.endLineNumberExclusive, move.modified.endLineNumberExclusive + extend_to_bottom));
        }

        if (extend_to_top > 0 or extend_to_bottom > 0) {
            moves.items[move_index] = LineRangeMapping.init(
                LineRange.init(move.original.startLineNumber - extend_to_top, move.original.endLineNumberExclusive + extend_to_bottom),
                LineRange.init(move.modified.startLineNumber - extend_to_top, move.modified.endLineNumberExclusive + extend_to_bottom),
            );
        }
    }

    return moves.toOwnedSlice();
}

fn areLinesSimilar(
    allocator: Allocator,
    line1: []const u8,
    line2: []const u8,
    timeout: ITimeout,
) !bool {
    if (std.mem.eql(u8, std.mem.trim(u8, line1, " \t\r\n"), std.mem.trim(u8, line2, " \t\r\n"))) {
        return true;
    }
    if (line1.len > 300 and line2.len > 300) {
        return false;
    }

    var sequence1 = try LinesSliceCharSequence.init(allocator, &[_][]const u8{line1}, Range.init(1, 1, 1, line1.len), false);
    defer sequence1.deinit();
    var sequence2 = try LinesSliceCharSequence.init(allocator, &[_][]const u8{line2}, Range.init(1, 1, 1, line2.len), false);
    defer sequence2.deinit();

    const algorithm = MyersDiffAlgorithm{};
    var result = try algorithm.compute(allocator, sequence1.sequence(), sequence2.sequence(), timeout);
    defer result.deinit(allocator);

    var common_non_space_char_count: usize = 0;
    const inverted = try SequenceDiff.invert(allocator, result.diffs, line1.len);
    defer allocator.free(inverted);
    for (inverted) |seq| {
        var idx = seq.seq1Range.start;
        while (idx < seq.seq1Range.endExclusive) : (idx += 1) {
            if (!isSpace(@intCast(line1[idx]))) {
                common_non_space_char_count += 1;
            }
        }
    }

    const longer_line = if (line1.len > line2.len) line1 else line2;
    var longer_line_length: usize = 0;
    // Note: the original implementation iterates over `line1.length` here.
    var idx: usize = 0;
    while (idx < line1.len) : (idx += 1) {
        if (!isSpace(@intCast(longer_line[idx]))) {
            longer_line_length += 1;
        }
    }

    if (longer_line_length == 0) {
        return false;
    }

    const ratio = @as(f64, @floatFromInt(common_non_space_char_count)) / @as(f64, @floatFromInt(longer_line_length));
    return ratio > 0.6 and longer_line_length > 10;
}

fn joinCloseConsecutiveMoves(allocator: Allocator, moves: []LineRangeMapping) ![]LineRangeMapping {
    if (moves.len == 0) {
        return allocator.alloc(LineRangeMapping, 0);
    }

    std.mem.sort(LineRangeMapping, moves, {}, struct {
        fn lessThan(_: void, a: LineRangeMapping, b: LineRangeMapping) bool {
            return a.original.startLineNumber < b.original.startLineNumber;
        }
    }.lessThan);

    var result = ArrayList(LineRangeMapping).init(allocator);
    errdefer result.deinit();
    try result.append(moves[0]);

    for (moves[1..]) |current| {
        const last = result.items[result.items.len - 1];

        const original_dist: isize = @as(isize, @intCast(current.original.startLineNumber)) - @as(isize, @intCast(last.original.endLineNumberExclusive));
        const modified_dist: isize = @as(isize, @intCast(current.modified.startLineNumber)) - @as(isize, @intCast(last.modified.endLineNumberExclusive));
        const current_move_after_last = original_dist >= 0 and modified_dist >= 0;

        if (current_move_after_last and original_dist + modified_dist <= 2) {
            result.items[result.items.len - 1] = last.join(current);
            continue;
        }

        try result.append(current);
    }

    return result.toOwnedSlice();
}

fn removeMovesInSameDiff(
    allocator: Allocator,
    changes: []DetailedLineRangeMapping,
    moves: []const LineRangeMapping,
) ![]LineRangeMapping {
    var result = ArrayList(LineRangeMapping).init(allocator);
    errdefer result.deinit();

    for (moves) |move| {
        const diff_before_end_of_move_original = findLastIdxMonotonous(
            DetailedLineRangeMapping,
            changes,
            move.original.endLineNumberExclusive,
            struct {
                fn pred(change: DetailedLineRangeMapping, line: usize) bool {
                    return change.original.startLineNumber < line;
                }
            }.pred,
            0,
            changes.len,
        );
        const diff_before_end_of_move_modified = findLastIdxMonotonous(
            DetailedLineRangeMapping,
            changes,
            move.modified.endLineNumberExclusive,
            struct {
                fn pred(change: DetailedLineRangeMapping, line: usize) bool {
                    return change.modified.startLineNumber < line;
                }
            }.pred,
            0,
            changes.len,
        );

        const different_diffs = !std.meta.eql(diff_before_end_of_move_original, diff_before_end_of_move_modified);
        if (different_diffs) {
            try result.append(move);
        }
    }

    return result.toOwnedSlice();
}

test "computeMovedLines: detects a moved block" {
    const allocator = std.testing.allocator;

    const original_lines = [_][]const u8{ "aaaaaa", "bbbbbb", "cccccc", "x", "y" };
    const modified_lines = [_][]const u8{ "x", "y", "aaaaaa", "bbbbbb", "cccccc" };

    const changes = [_]DetailedLineRangeMapping{
        DetailedLineRangeMapping.init(LineRange.init(1, 4), LineRange.init(1, 1), null),
        DetailedLineRangeMapping.init(LineRange.init(5, 5), LineRange.init(3, 6), null),
    };

    const hashes = [_]u64{};
    const timeout = InfiniteTimeout.getInstance();
    const moves = try computeMovedLines(allocator, @constCast(&changes), &original_lines, &modified_lines, &hashes, &hashes, timeout);
    defer allocator.free(moves);

    try std.testing.expectEqual(@as(usize, 1), moves.len);
    try std.testing.expectEqual(LineRange.init(1, 4), moves[0].original);
    try std.testing.expectEqual(LineRange.init(3, 6), moves[0].modified);
}

test "computeMovedLines: ignores short moves" {
    const allocator = std.testing.allocator;

    const original_lines = [_][]const u8{ "a", "b", "c", "x", "y" };
    const modified_lines = [_][]const u8{ "x", "y", "a", "b", "c" };

    const changes = [_]DetailedLineRangeMapping{
        DetailedLineRangeMapping.init(LineRange.init(1, 4), LineRange.init(1, 1), null),
        DetailedLineRangeMapping.init(LineRange.init(5, 5), LineRange.init(3, 6), null),
    };

    const hashes = [_]u64{};
    const timeout = InfiniteTimeout.getInstance();
    const moves = try computeMovedLines(allocator, @constCast(&changes), &original_lines, &modified_lines, &hashes, &hashes, timeout);
    defer allocator.free(moves);

    try std.testing.expectEqual(@as(usize, 0), moves.len);
}

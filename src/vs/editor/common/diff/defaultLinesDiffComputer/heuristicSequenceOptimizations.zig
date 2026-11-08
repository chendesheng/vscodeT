const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const forEachWithNeighbors = @import("../../../../base/common/arrays.zig").forEachWithNeighbors;
const OffsetRange = @import("../../core/ranges/offsetRange.zig").OffsetRange;
const diff = @import("algorithms/diffAlgorithm.zig");
const ISequence = diff.ISequence;
const OffsetPair = diff.SequenceDiff.OffsetPair;
const SequenceDiff = diff.SequenceDiff;
const LineSequence = @import("lineSequence.zig").LineSequence;
const LinesSliceCharSequence = @import("linesSliceCharSequence.zig").LinesSliceCharSequence;

pub fn optimizeSequenceDiffs(
    allocator: Allocator,
    sequence1: ISequence,
    sequence2: ISequence,
    sequence_diffs: []const SequenceDiff,
) ![]SequenceDiff {
    var result = try joinSequenceDiffsByShifting(allocator, sequence1, sequence2, sequence_diffs);
    errdefer allocator.free(result);
    const result2 = try joinSequenceDiffsByShifting(allocator, sequence1, sequence2, result);
    allocator.free(result);
    result = result2;
    shiftSequenceDiffs(sequence1, sequence2, result);
    return result;
}

/// This function fixes issues like this:
/// ```
/// import { Baz, Bar } from "foo";
/// ```
/// <->
/// ```
/// import { Baz, Bar, Foo } from "foo";
/// ```
/// Computed diff: [ {Add "," after Bar}, {Add "Foo " after space} }
/// Improved diff: [{Add ", Foo" after Bar}]
fn joinSequenceDiffsByShifting(
    allocator: Allocator,
    sequence1: ISequence,
    sequence2: ISequence,
    sequence_diffs: []const SequenceDiff,
) ![]SequenceDiff {
    if (sequence_diffs.len == 0) {
        return allocator.alloc(SequenceDiff, 0);
    }

    var result = ArrayList(SequenceDiff).init(allocator);
    defer result.deinit();
    try result.append(sequence_diffs[0]);

    // First move them all to the left as much as possible and join them if possible
    var i: usize = 1;
    while (i < sequence_diffs.len) : (i += 1) {
        const prev_result = result.items[result.items.len - 1];
        var cur = sequence_diffs[i];

        if (cur.seq1Range.isEmpty() or cur.seq2Range.isEmpty()) {
            const length = cur.seq1Range.start - prev_result.seq1Range.endExclusive;
            var d: usize = 1;
            while (d <= length) : (d += 1) {
                if (sequence1.getElement(cur.seq1Range.start - d) != sequence1.getElement(cur.seq1Range.endExclusive - d) or
                    sequence2.getElement(cur.seq2Range.start - d) != sequence2.getElement(cur.seq2Range.endExclusive - d))
                {
                    break;
                }
            }
            d -= 1;

            if (d == length) {
                // Merge previous and current diff
                result.items[result.items.len - 1] = SequenceDiff.init(
                    OffsetRange.init(prev_result.seq1Range.start, cur.seq1Range.endExclusive - length),
                    OffsetRange.init(prev_result.seq2Range.start, cur.seq2Range.endExclusive - length),
                );
                continue;
            }

            cur = cur.delta(-@as(isize, @intCast(d)));
        }

        try result.append(cur);
    }

    // Then move them all to the right and join them again if possible
    var result2 = ArrayList(SequenceDiff).init(allocator);
    errdefer result2.deinit();
    i = 0;
    while (i + 1 < result.items.len) : (i += 1) {
        const next_result = result.items[i + 1];
        var cur = result.items[i];

        if (cur.seq1Range.isEmpty() or cur.seq2Range.isEmpty()) {
            const length = next_result.seq1Range.start - cur.seq1Range.endExclusive;
            var d: usize = 0;
            while (d < length) : (d += 1) {
                if (!sequence1.isStronglyEqual(cur.seq1Range.start + d, cur.seq1Range.endExclusive + d) or
                    !sequence2.isStronglyEqual(cur.seq2Range.start + d, cur.seq2Range.endExclusive + d))
                {
                    break;
                }
            }

            if (d == length) {
                // Merge previous and current diff, write to result!
                result.items[i + 1] = SequenceDiff.init(
                    OffsetRange.init(cur.seq1Range.start + length, next_result.seq1Range.endExclusive),
                    OffsetRange.init(cur.seq2Range.start + length, next_result.seq2Range.endExclusive),
                );
                continue;
            }

            if (d > 0) {
                cur = cur.delta(@intCast(d));
            }
        }

        try result2.append(cur);
    }

    if (result.items.len > 0) {
        try result2.append(result.items[result.items.len - 1]);
    }

    return result2.toOwnedSlice();
}

/// Align character level diffs at whitespace characters.
fn shiftSequenceDiffs(sequence1: ISequence, sequence2: ISequence, sequence_diffs: []SequenceDiff) void {
    if (sequence1.get_boundary_score == null or sequence2.get_boundary_score == null) {
        return;
    }

    for (sequence_diffs, 0..) |diff_value, i| {
        const prev_diff: ?SequenceDiff = if (i > 0) sequence_diffs[i - 1] else null;
        const next_diff: ?SequenceDiff = if (i + 1 < sequence_diffs.len) sequence_diffs[i + 1] else null;

        const seq1_valid_range = OffsetRange.init(
            if (prev_diff) |value| value.seq1Range.endExclusive + 1 else 0,
            if (next_diff) |value| value.seq1Range.start -| 1 else sequence1.length(),
        );
        const seq2_valid_range = OffsetRange.init(
            if (prev_diff) |value| value.seq2Range.endExclusive + 1 else 0,
            if (next_diff) |value| value.seq2Range.start -| 1 else sequence2.length(),
        );

        if (diff_value.seq1Range.isEmpty()) {
            sequence_diffs[i] = shiftDiffToBetterPosition(diff_value, sequence1, sequence2, seq1_valid_range, seq2_valid_range);
        } else if (diff_value.seq2Range.isEmpty()) {
            sequence_diffs[i] = shiftDiffToBetterPosition(diff_value.swap(), sequence2, sequence1, seq2_valid_range, seq1_valid_range).swap();
        }
    }
}

fn shiftDiffToBetterPosition(
    diff_value: SequenceDiff,
    sequence1: ISequence,
    sequence2: ISequence,
    seq1_valid_range: OffsetRange,
    seq2_valid_range: OffsetRange,
) SequenceDiff {
    const max_shift_limit = 100; // To prevent performance issues

    // don't touch previous or next!
    var delta_before: usize = 1;
    while (diff_value.seq1Range.start >= seq1_valid_range.start + delta_before and
        diff_value.seq2Range.start >= seq2_valid_range.start + delta_before and
        sequence2.isStronglyEqual(diff_value.seq2Range.start - delta_before, diff_value.seq2Range.endExclusive - delta_before) and
        delta_before < max_shift_limit)
    {
        delta_before += 1;
    }
    delta_before -= 1;

    var delta_after: usize = 0;
    while (diff_value.seq1Range.start + delta_after < seq1_valid_range.endExclusive and
        diff_value.seq2Range.endExclusive + delta_after < seq2_valid_range.endExclusive and
        sequence2.isStronglyEqual(diff_value.seq2Range.start + delta_after, diff_value.seq2Range.endExclusive + delta_after) and
        delta_after < max_shift_limit)
    {
        delta_after += 1;
    }

    if (delta_before == 0 and delta_after == 0) {
        return diff_value;
    }

    var best_delta: isize = 0;
    var best_score: isize = -1;
    // find best scored delta
    var delta: isize = -@as(isize, @intCast(delta_before));
    while (delta <= @as(isize, @intCast(delta_after))) : (delta += 1) {
        const seq2_offset_start = addOffset(diff_value.seq2Range.start, delta);
        const seq2_offset_end_exclusive = addOffset(diff_value.seq2Range.endExclusive, delta);
        const seq1_offset = addOffset(diff_value.seq1Range.start, delta);

        const score = sequence1.getBoundaryScore(seq1_offset) +
            sequence2.getBoundaryScore(seq2_offset_start) +
            sequence2.getBoundaryScore(seq2_offset_end_exclusive);
        if (score > best_score) {
            best_score = score;
            best_delta = delta;
        }
    }

    return diff_value.delta(best_delta);
}

fn addOffset(offset: usize, delta: isize) usize {
    return @intCast(@as(isize, @intCast(offset)) + delta);
}

pub fn removeShortMatches(
    allocator: Allocator,
    sequence1: ISequence,
    sequence2: ISequence,
    sequence_diffs: []const SequenceDiff,
) ![]SequenceDiff {
    var result = ArrayList(SequenceDiff).init(allocator);
    errdefer result.deinit();
    for (sequence_diffs) |s| {
        if (result.items.len == 0) {
            try result.append(s);
            continue;
        }

        const last = result.items[result.items.len - 1];
        if (s.seq1Range.start - last.seq1Range.endExclusive <= 2 or
            s.seq2Range.start - last.seq2Range.endExclusive <= 2)
        {
            result.items[result.items.len - 1] = SequenceDiff.init(
                last.seq1Range.join(s.seq1Range),
                last.seq2Range.join(s.seq2Range),
            );
        } else {
            try result.append(s);
        }
    }

    _ = sequence1;
    _ = sequence2;
    return result.toOwnedSlice();
}

pub fn extendDiffsToEntireWordIfAppropriate(
    allocator: Allocator,
    sequence1: *const LinesSliceCharSequence,
    sequence2: *const LinesSliceCharSequence,
    sequence_diffs: []const SequenceDiff,
    find_parent: *const fn (*const LinesSliceCharSequence, usize) ?OffsetRange,
    force: bool,
) ![]SequenceDiff {
    var equal_mappings = ArrayList(SequenceDiff).init(allocator);
    defer equal_mappings.deinit();
    {
        const inverted = try SequenceDiff.invert(allocator, sequence_diffs, sequence1.length());
        defer allocator.free(inverted);
        try equal_mappings.appendSlice(inverted);
    }

    var additional = ArrayList(SequenceDiff).init(allocator);
    defer additional.deinit();

    const Scanner = struct {
        sequence1: *const LinesSliceCharSequence,
        sequence2: *const LinesSliceCharSequence,
        find_parent: *const fn (*const LinesSliceCharSequence, usize) ?OffsetRange,
        force: bool,
        equal_mappings: *ArrayList(SequenceDiff),
        additional: *ArrayList(SequenceDiff),
        last_point: OffsetPair = OffsetPair.zero,

        fn scanWord(self: *@This(), pair: OffsetPair, equal_mapping: SequenceDiff) !void {
            if (pair.offset1 < self.last_point.offset1 or pair.offset2 < self.last_point.offset2) {
                return;
            }

            const w1 = self.find_parent(self.sequence1, pair.offset1);
            const w2 = self.find_parent(self.sequence2, pair.offset2);
            if (w1 == null or w2 == null) {
                return;
            }
            var w = SequenceDiff.init(w1.?, w2.?);
            const equal_part = w.intersect(equal_mapping) orelse return;

            var equal_chars1 = equal_part.seq1Range.length();
            var equal_chars2 = equal_part.seq2Range.length();

            // The words do not touch previous equals mappings, as we would have processed them already.
            // But they might touch the next ones.

            while (self.equal_mappings.items.len > 0) {
                const next = self.equal_mappings.items[0];
                const intersects = next.seq1Range.intersects(w.seq1Range) or next.seq2Range.intersects(w.seq2Range);
                if (!intersects) {
                    break;
                }

                const v1 = self.find_parent(self.sequence1, next.seq1Range.start) orelse unreachable;
                const v2 = self.find_parent(self.sequence2, next.seq2Range.start) orelse unreachable;
                // Because there is an intersection, we know that the words are not empty.
                const v = SequenceDiff.init(v1, v2);
                const equal_part2 = v.intersect(next) orelse unreachable;

                equal_chars1 += equal_part2.seq1Range.length();
                equal_chars2 += equal_part2.seq2Range.length();

                w = w.join(v);

                if (w.seq1Range.endExclusive >= next.seq1Range.endExclusive) {
                    // The word extends beyond the next equal mapping.
                    _ = self.equal_mappings.orderedRemove(0);
                } else {
                    break;
                }
            }

            const difference = w.seq1Range.length() + w.seq2Range.length();
            if ((self.force and equal_chars1 + equal_chars2 < difference) or
                equal_chars1 + equal_chars2 < @divTrunc(difference * 2, 3))
            {
                try self.additional.append(w);
            }

            self.last_point = w.getEndExclusives();
        }
    };

    var scanner = Scanner{
        .sequence1 = sequence1,
        .sequence2 = sequence2,
        .find_parent = find_parent,
        .force = force,
        .equal_mappings = &equal_mappings,
        .additional = &additional,
    };

    while (equal_mappings.items.len > 0) {
        const next = equal_mappings.orderedRemove(0);
        if (next.seq1Range.isEmpty()) {
            continue;
        }
        try scanner.scanWord(next.getStarts(), next);
        // The equal parts are not empty, so -1 gives us a character that is equal in both parts.
        try scanner.scanWord(next.getEndExclusives().delta(-1), next);
    }

    return mergeSequenceDiffs(allocator, sequence_diffs, additional.items);
}

fn mergeSequenceDiffs(
    allocator: Allocator,
    sequence_diffs1: []const SequenceDiff,
    sequence_diffs2: []const SequenceDiff,
) ![]SequenceDiff {
    var result = ArrayList(SequenceDiff).init(allocator);
    errdefer result.deinit();

    var idx1: usize = 0;
    var idx2: usize = 0;
    while (idx1 < sequence_diffs1.len or idx2 < sequence_diffs2.len) {
        const sd1: ?SequenceDiff = if (idx1 < sequence_diffs1.len) sequence_diffs1[idx1] else null;
        const sd2: ?SequenceDiff = if (idx2 < sequence_diffs2.len) sequence_diffs2[idx2] else null;

        var next: SequenceDiff = undefined;
        if (sd1 != null and (sd2 == null or sd1.?.seq1Range.start < sd2.?.seq1Range.start)) {
            next = sequence_diffs1[idx1];
            idx1 += 1;
        } else {
            next = sequence_diffs2[idx2];
            idx2 += 1;
        }

        if (result.items.len > 0 and result.items[result.items.len - 1].seq1Range.endExclusive >= next.seq1Range.start) {
            result.items[result.items.len - 1] = result.items[result.items.len - 1].join(next);
        } else {
            try result.append(next);
        }
    }

    return result.toOwnedSlice();
}

pub fn removeVeryShortMatchingLinesBetweenDiffs(
    allocator: Allocator,
    sequence1: LineSequence,
    sequence2: LineSequence,
    sequence_diffs: []const SequenceDiff,
) ![]SequenceDiff {
    _ = sequence2;
    if (sequence_diffs.len == 0) {
        return allocator.alloc(SequenceDiff, 0);
    }

    var current = try allocator.dupe(SequenceDiff, sequence_diffs);
    errdefer allocator.free(current);

    var counter: usize = 0;
    while (true) {
        var should_repeat = false;

        var result = ArrayList(SequenceDiff).init(allocator);
        errdefer result.deinit();
        try result.append(current[0]);

        for (current[1..]) |cur| {
            const last_result = result.items[result.items.len - 1];
            const unchanged_range = OffsetRange.init(last_result.seq1Range.endExclusive, cur.seq1Range.start);

            const unchanged_text = try sequence1.getText(allocator, unchanged_range);
            defer allocator.free(unchanged_text);

            var unchanged_without_ws: usize = 0;
            for (unchanged_text) |byte| {
                if (!std.ascii.isWhitespace(byte)) {
                    unchanged_without_ws += 1;
                }
            }

            const should_join = unchanged_without_ws <= 4 and
                (last_result.seq1Range.length() + last_result.seq2Range.length() > 5 or
                    cur.seq1Range.length() + cur.seq2Range.length() > 5);

            if (should_join) {
                should_repeat = true;
                result.items[result.items.len - 1] = result.items[result.items.len - 1].join(cur);
            } else {
                try result.append(cur);
            }
        }

        const new_current = try result.toOwnedSlice();
        allocator.free(current);
        current = new_current;

        const old_counter = counter;
        counter += 1;
        if (!(old_counter < 10 and should_repeat)) {
            break;
        }
    }

    return current;
}

pub fn removeVeryShortMatchingTextBetweenLongDiffs(
    allocator: Allocator,
    sequence1: *const LinesSliceCharSequence,
    sequence2: *const LinesSliceCharSequence,
    sequence_diffs: []const SequenceDiff,
) ![]SequenceDiff {
    if (sequence_diffs.len == 0) {
        return allocator.alloc(SequenceDiff, 0);
    }

    var current = try allocator.dupe(SequenceDiff, sequence_diffs);
    errdefer allocator.free(current);

    var counter: usize = 0;
    while (true) {
        var should_repeat = false;

        var result = ArrayList(SequenceDiff).init(allocator);
        errdefer result.deinit();
        try result.append(current[0]);

        for (current[1..]) |cur| {
            const last_result = result.items[result.items.len - 1];
            const unchanged_range = OffsetRange.init(last_result.seq1Range.endExclusive, cur.seq1Range.start);

            const should_join = try shouldJoinDiffs(allocator, sequence1, sequence2, unchanged_range, last_result, cur);

            if (should_join) {
                should_repeat = true;
                result.items[result.items.len - 1] = result.items[result.items.len - 1].join(cur);
            } else {
                try result.append(cur);
            }
        }

        const new_current = try result.toOwnedSlice();
        allocator.free(current);
        current = new_current;

        const old_counter = counter;
        counter += 1;
        if (!(old_counter < 10 and should_repeat)) {
            break;
        }
    }

    var new_diffs = ArrayList(SequenceDiff).init(allocator);
    errdefer new_diffs.deinit();

    const PostContext = struct {
        allocator: Allocator,
        sequence1: *const LinesSliceCharSequence,
        new_diffs: *ArrayList(SequenceDiff),
        err: ?anyerror = null,

        fn process(self: *@This(), prev: ?SequenceDiff, cur: SequenceDiff, next: ?SequenceDiff) void {
            var new_diff = cur;

            const full_range1 = self.sequence1.extendToFullLines(cur.seq1Range);
            const prefix = self.sequence1.getText(self.allocator, OffsetRange.init(full_range1.start, cur.seq1Range.start)) catch |e| {
                self.err = e;
                return;
            };
            defer self.allocator.free(prefix);
            if (self.shouldMarkAsChanged(prefix, cur)) {
                new_diff = new_diff.deltaStart(-@as(isize, @intCast(prefix.len)));
            }

            const suffix = self.sequence1.getText(self.allocator, OffsetRange.init(cur.seq1Range.endExclusive, full_range1.endExclusive)) catch |e| {
                self.err = e;
                return;
            };
            defer self.allocator.free(suffix);
            if (self.shouldMarkAsChanged(suffix, cur)) {
                new_diff = new_diff.deltaEnd(@intCast(suffix.len));
            }

            const available_space = SequenceDiff.fromOffsetPairs(
                if (prev) |value| value.getEndExclusives() else OffsetPair.zero,
                if (next) |value| value.getStarts() else OffsetPair.max,
            );
            const result = new_diff.intersect(available_space) orelse return;
            if (self.new_diffs.items.len > 0 and
                result.getStarts().equals(self.new_diffs.items[self.new_diffs.items.len - 1].getEndExclusives()))
            {
                self.new_diffs.items[self.new_diffs.items.len - 1] = self.new_diffs.items[self.new_diffs.items.len - 1].join(result);
            } else {
                self.new_diffs.append(result) catch |e| {
                    self.err = e;
                };
            }
        }

        fn shouldMarkAsChanged(self: *@This(), text: []const u8, cur: SequenceDiff) bool {
            _ = self;
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            return text.len > 0 and trimmed.len <= 3 and cur.seq1Range.length() + cur.seq2Range.length() > 100;
        }
    };

    var context = PostContext{
        .allocator = allocator,
        .sequence1 = sequence1,
        .new_diffs = &new_diffs,
    };
    forEachWithNeighbors(SequenceDiff, current, &context, PostContext.process);
    if (context.err) |e| return e;

    allocator.free(current);
    return new_diffs.toOwnedSlice();
}

fn shouldJoinDiffs(
    allocator: Allocator,
    sequence1: *const LinesSliceCharSequence,
    sequence2: *const LinesSliceCharSequence,
    unchanged_range: OffsetRange,
    before: SequenceDiff,
    after: SequenceDiff,
) !bool {
    const unchanged_line_count = sequence1.countLinesIn(unchanged_range);
    if (unchanged_line_count > 5 or unchanged_range.length() > 500) {
        return false;
    }

    const unchanged_text = try sequence1.getText(allocator, unchanged_range);
    defer allocator.free(unchanged_text);
    const trimmed = std.mem.trim(u8, unchanged_text, " \t\r\n");
    if (trimmed.len > 20 or std.mem.indexOfAny(u8, trimmed, "\r\n") != null) {
        return false;
    }

    const before_line_count1 = sequence1.countLinesIn(before.seq1Range);
    const before_seq1_length = before.seq1Range.length();
    const before_line_count2 = sequence2.countLinesIn(before.seq2Range);
    const before_seq2_length = before.seq2Range.length();

    const after_line_count1 = sequence1.countLinesIn(after.seq1Range);
    const after_seq1_length = after.seq1Range.length();
    const after_line_count2 = sequence2.countLinesIn(after.seq2Range);
    const after_seq2_length = after.seq2Range.length();

    const max: f64 = 2 * 40 + 50;
    const cap = struct {
        fn cap(v: f64, maximum: f64) f64 {
            return @min(v, maximum);
        }
    }.cap;

    const before_score = std.math.pow(f64, cap(@floatFromInt(before_line_count1 * 40 + before_seq1_length), max), 1.5) +
        std.math.pow(f64, cap(@floatFromInt(before_line_count2 * 40 + before_seq2_length), max), 1.5);
    const after_score = std.math.pow(f64, cap(@floatFromInt(after_line_count1 * 40 + after_seq1_length), max), 1.5) +
        std.math.pow(f64, cap(@floatFromInt(after_line_count2 * 40 + after_seq2_length), max), 1.5);

    return std.math.pow(f64, before_score, 1.5) + std.math.pow(f64, after_score, 1.5) > std.math.pow(f64, std.math.pow(f64, max, 1.5), 1.5) * 1.3;
}

fn findWordContainingAny(sequence: *const LinesSliceCharSequence, index: usize) ?OffsetRange {
    return sequence.findWordContaining(index);
}

test "optimizeSequenceDiffs: joins shifted diffs" {
    const allocator = std.testing.allocator;
    const Range = @import("../../core/range.zig").Range;

    const line1 = "import { Baz, Bar } from \"foo\";";
    const line2 = "import { Baz, Bar, Foo } from \"foo\";";
    const lines1 = [_][]const u8{line1};
    const lines2 = [_][]const u8{line2};

    var sequence1 = try LinesSliceCharSequence.init(allocator, &lines1, Range.init(1, 1, 1, line1.len + 1), true);
    defer sequence1.deinit();
    var sequence2 = try LinesSliceCharSequence.init(allocator, &lines2, Range.init(1, 1, 1, line2.len + 1), true);
    defer sequence2.deinit();

    const MyersDiffAlgorithm = @import("algorithms/myersDiffAlgorithm.zig").MyersDiffAlgorithm;
    const algorithm = MyersDiffAlgorithm{};
    var result = try algorithm.compute(allocator, sequence1.sequence(), sequence2.sequence(), null);
    defer result.deinit(allocator);

    const before = result.diffs.len;
    const optimized = try optimizeSequenceDiffs(allocator, sequence1.sequence(), sequence2.sequence(), result.diffs);
    defer allocator.free(optimized);

    try std.testing.expect(before > optimized.len);
    try std.testing.expectEqual(@as(usize, 1), optimized.len);
    try std.testing.expect(optimized[0].seq1Range.isEmpty());
    try std.testing.expect(!optimized[0].seq2Range.isEmpty());
}

test "removeShortMatches: joins close diffs" {
    const allocator = std.testing.allocator;
    const lines1 = [_][]const u8{ "a", "b", "c", "d" };
    const lines2 = [_][]const u8{ "a", "x", "b", "y", "c", "d" };
    const hashes1 = [_]u64{ 1, 2, 3, 4 };
    const hashes2 = [_]u64{ 1, 5, 2, 6, 3, 4 };
    var sequence1 = LineSequence.init(&hashes1, &lines1);
    var sequence2 = LineSequence.init(&hashes2, &lines2);

    const diffs = [_]SequenceDiff{
        SequenceDiff.init(OffsetRange.init(1, 1), OffsetRange.init(1, 2)),
        SequenceDiff.init(OffsetRange.init(2, 2), OffsetRange.init(3, 4)),
    };

    const result = try removeShortMatches(allocator, sequence1.sequence(), sequence2.sequence(), &diffs);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(OffsetRange.init(1, 2), result[0].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(1, 4), result[0].seq2Range);
}

test "extendDiffsToEntireWordIfAppropriate: extends to the word" {
    const allocator = std.testing.allocator;
    const Range = @import("../../core/range.zig").Range;

    const lines1 = [_][]const u8{"abcdefghij"};
    const lines2 = [_][]const u8{"abcXXXXXXj"};
    var sequence1 = try LinesSliceCharSequence.init(allocator, &lines1, Range.init(1, 1, 1, 11), true);
    defer sequence1.deinit();
    var sequence2 = try LinesSliceCharSequence.init(allocator, &lines2, Range.init(1, 1, 1, 11), true);
    defer sequence2.deinit();

    const diffs = [_]SequenceDiff{
        SequenceDiff.init(OffsetRange.init(3, 9), OffsetRange.init(3, 9)),
    };

    const result = try extendDiffsToEntireWordIfAppropriate(allocator, &sequence1, &sequence2, &diffs, findWordContainingAny, false);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(OffsetRange.init(0, 10), result[0].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(0, 10), result[0].seq2Range);
}

test "removeVeryShortMatchingLinesBetweenDiffs: joins across a tiny line" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "aaaaaaaaaa",
        "bbbbbbbbbb",
        "cccccccccc",
        "d",
        "eeeeeeeeee",
        "ffffffffff",
        "gggggggggg",
    };
    const hashes = [_]u64{ 1, 2, 3, 4, 5, 6, 7 };
    const sequence1 = LineSequence.init(&hashes, &lines);
    const sequence2 = LineSequence.init(&hashes, &lines);

    const diffs = [_]SequenceDiff{
        SequenceDiff.init(OffsetRange.init(0, 3), OffsetRange.init(0, 3)),
        SequenceDiff.init(OffsetRange.init(4, 7), OffsetRange.init(4, 7)),
    };

    const result = try removeVeryShortMatchingLinesBetweenDiffs(allocator, sequence1, sequence2, &diffs);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(OffsetRange.init(0, 7), result[0].seq1Range);
}

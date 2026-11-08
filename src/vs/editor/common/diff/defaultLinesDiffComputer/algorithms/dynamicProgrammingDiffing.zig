const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const OffsetRange = @import("../../../core/ranges/offsetRange.zig").OffsetRange;
const diff = @import("diffAlgorithm.zig");
const utils = @import("../utils.zig");

pub const EqualityScore = struct {
    context: *anyopaque,
    score: *const fn (context: *anyopaque, offset1: usize, offset2: usize) isize,
};

/// A O(MN) diffing algorithm that supports a score function.
pub const DynamicProgrammingDiffing = struct {
    const Self = @This();

    pub fn compute(
        _: Self,
        allocator: Allocator,
        sequence1: diff.ISequence,
        sequence2: diff.ISequence,
        timeout: ?diff.ITimeout,
        equality_score: ?EqualityScore,
    ) !diff.DiffAlgorithmResult {
        if (sequence1.length() == 0 or sequence2.length() == 0) {
            return diff.DiffAlgorithmResult.trivial(allocator, sequence1, sequence2);
        }

        var lcs_lengths = try utils.Array2D(isize).init(allocator, sequence1.length(), sequence2.length(), 0);
        defer lcs_lengths.deinit();
        var directions = try utils.Array2D(u8).init(allocator, sequence1.length(), sequence2.length(), 0);
        defer directions.deinit();
        var lengths = try utils.Array2D(usize).init(allocator, sequence1.length(), sequence2.length(), 0);
        defer lengths.deinit();

        // ==== Initializing lcsLengths ====
        var s1: usize = 0;
        while (s1 < sequence1.length()) : (s1 += 1) {
            var s2: usize = 0;
            while (s2 < sequence2.length()) : (s2 += 1) {
                if (timeout) |t| {
                    if (!t.isValid()) {
                        return diff.DiffAlgorithmResult.trivialTimedOut(allocator, sequence1, sequence2);
                    }
                }

                const horizontal_len: isize = if (s1 == 0) 0 else lcs_lengths.get(s1 - 1, s2);
                const vertical_len: isize = if (s2 == 0) 0 else lcs_lengths.get(s1, s2 - 1);

                var extended_seq_score: isize = undefined;
                if (sequence1.getElement(s1) == sequence2.getElement(s2)) {
                    if (s1 == 0 or s2 == 0) {
                        extended_seq_score = 0;
                    } else {
                        extended_seq_score = lcs_lengths.get(s1 - 1, s2 - 1);
                    }
                    if (s1 > 0 and s2 > 0 and directions.get(s1 - 1, s2 - 1) == 3) {
                        // Prefer consecutive diagonals.
                        extended_seq_score += @intCast(lengths.get(s1 - 1, s2 - 1));
                    }
                    extended_seq_score += if (equality_score) |score| score.score(score.context, s1, s2) else 1;
                } else {
                    extended_seq_score = -1;
                }

                const new_value = @max(horizontal_len, @max(vertical_len, extended_seq_score));

                if (new_value == extended_seq_score) {
                    // Prefer diagonals.
                    const prev_len = if (s1 > 0 and s2 > 0) lengths.get(s1 - 1, s2 - 1) else 0;
                    lengths.set(s1, s2, prev_len + 1);
                    directions.set(s1, s2, 3);
                } else if (new_value == horizontal_len) {
                    lengths.set(s1, s2, 0);
                    directions.set(s1, s2, 1);
                } else if (new_value == vertical_len) {
                    lengths.set(s1, s2, 0);
                    directions.set(s1, s2, 2);
                }

                lcs_lengths.set(s1, s2, new_value);
            }
        }

        // ==== Backtracking ====
        var result = ArrayList(diff.SequenceDiff).init(allocator);
        errdefer result.deinit();

        var last_aligning_pos_s1: isize = @intCast(sequence1.length());
        var last_aligning_pos_s2: isize = @intCast(sequence2.length());

        const reportDecreasingAligningPositions = struct {
            fn report(
                out: *ArrayList(diff.SequenceDiff),
                s1_value: isize,
                s2_value: isize,
                last_s1: *isize,
                last_s2: *isize,
            ) !void {
                if (s1_value + 1 != last_s1.* or s2_value + 1 != last_s2.*) {
                    try out.append(diff.SequenceDiff.init(
                        OffsetRange.init(@intCast(s1_value + 1), @intCast(last_s1.*)),
                        OffsetRange.init(@intCast(s2_value + 1), @intCast(last_s2.*)),
                    ));
                }
                last_s1.* = s1_value;
                last_s2.* = s2_value;
            }
        }.report;

        var current_s1: isize = @as(isize, @intCast(sequence1.length())) - 1;
        var current_s2: isize = @as(isize, @intCast(sequence2.length())) - 1;
        while (current_s1 >= 0 and current_s2 >= 0) {
            if (directions.get(@intCast(current_s1), @intCast(current_s2)) == 3) {
                try reportDecreasingAligningPositions(&result, current_s1, current_s2, &last_aligning_pos_s1, &last_aligning_pos_s2);
                current_s1 -= 1;
                current_s2 -= 1;
            } else {
                if (directions.get(@intCast(current_s1), @intCast(current_s2)) == 1) {
                    current_s1 -= 1;
                } else {
                    current_s2 -= 1;
                }
            }
        }
        try reportDecreasingAligningPositions(&result, -1, -1, &last_aligning_pos_s1, &last_aligning_pos_s2);

        std.mem.reverse(diff.SequenceDiff, result.items);
        return diff.DiffAlgorithmResult.init(try result.toOwnedSlice(), false);
    }
};

test "DynamicProgrammingDiffing: simple diff" {
    const allocator = std.testing.allocator;

    var seq1 = TestSequence.init(&.{ 1, 2, 3, 4 });
    var seq2 = TestSequence.init(&.{ 1, 3, 4, 5 });

    var result = try DynamicProgrammingDiffing.compute(.{}, allocator, seq1.sequence(), seq2.sequence(), null, null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.diffs.len);
    try std.testing.expectEqual(OffsetRange.init(1, 2), result.diffs[0].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(1, 1), result.diffs[0].seq2Range);
    try std.testing.expectEqual(OffsetRange.init(4, 4), result.diffs[1].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(3, 4), result.diffs[1].seq2Range);
}

test "DynamicProgrammingDiffing: identical sequences" {
    const allocator = std.testing.allocator;

    var seq1 = TestSequence.init(&.{ 1, 2, 3 });
    var result = try DynamicProgrammingDiffing.compute(.{}, allocator, seq1.sequence(), seq1.sequence(), null, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.diffs.len);
}

const TestSequence = struct {
    items: []const u64,

    fn init(items: []const u64) TestSequence {
        return .{ .items = items };
    }

    fn getElement(context: *anyopaque, offset: usize) u64 {
        const self: *TestSequence = @ptrCast(@alignCast(context));
        return self.items[offset];
    }

    fn getLength(context: *anyopaque) usize {
        const self: *TestSequence = @ptrCast(@alignCast(context));
        return self.items.len;
    }

    fn isStronglyEqual(context: *anyopaque, offset1: usize, offset2: usize) bool {
        const self: *TestSequence = @ptrCast(@alignCast(context));
        return self.items[offset1] == self.items[offset2];
    }

    fn sequence(self: *TestSequence) diff.ISequence {
        return diff.ISequence.init(self, &getElement, &getLength, null, &isStronglyEqual);
    }
};

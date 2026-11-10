const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const OffsetRange = @import("../../../core/ranges/offsetRange.zig").OffsetRange;
const time = @import("../../../../../base/common/timeCompat.zig");

/// A sequence that can be diffed.
pub const ISequence = struct {
    context: *anyopaque,
    get_element: *const fn (context: *anyopaque, offset: usize) u64,
    get_length: *const fn (context: *anyopaque) usize,
    get_boundary_score: ?*const fn (context: *anyopaque, length: usize) isize = null,
    is_strongly_equal: *const fn (context: *anyopaque, offset1: usize, offset2: usize) bool,

    pub fn init(
        context: *anyopaque,
        get_element: *const fn (context: *anyopaque, offset: usize) u64,
        get_length: *const fn (context: *anyopaque) usize,
        get_boundary_score: ?*const fn (context: *anyopaque, length: usize) isize,
        is_strongly_equal: *const fn (context: *anyopaque, offset1: usize, offset2: usize) bool,
    ) ISequence {
        return .{
            .context = context,
            .get_element = get_element,
            .get_length = get_length,
            .get_boundary_score = get_boundary_score,
            .is_strongly_equal = is_strongly_equal,
        };
    }

    pub fn length(self: ISequence) usize {
        return self.get_length(self.context);
    }

    pub fn getElement(self: ISequence, offset: usize) u64 {
        return self.get_element(self.context, offset);
    }

    /// The higher the score, the better that offset can be used to split the
    /// sequence. Is used to optimize insertions. Must not be negative.
    pub fn getBoundaryScore(self: ISequence, sequence_length: usize) isize {
        if (self.get_boundary_score) |f| {
            return f(self.context, sequence_length);
        }
        return 0;
    }

    /// For line sequences, `getElement` returns a number representing trimmed
    /// lines. This however checks equality for the original lines.
    pub fn isStronglyEqual(self: ISequence, offset1: usize, offset2: usize) bool {
        return self.is_strongly_equal(self.context, offset1, offset2);
    }
};

/// A synchronous diff algorithm. Should be executed in a worker.
pub const DiffAlgorithm = struct {
    context: *anyopaque,
    compute_fn: *const fn (context: *anyopaque, allocator: Allocator, sequence1: ISequence, sequence2: ISequence, timeout: ?ITimeout) anyerror!DiffAlgorithmResult,

    pub fn compute(
        self: DiffAlgorithm,
        allocator: Allocator,
        sequence1: ISequence,
        sequence2: ISequence,
        timeout: ?ITimeout,
    ) !DiffAlgorithmResult {
        return self.compute_fn(self.context, allocator, sequence1, sequence2, timeout);
    }
};

pub const DiffAlgorithmResult = struct {
    diffs: []SequenceDiff,
    /// Indicates if the time out was reached. In that case, the diffs might be
    /// an approximation and the user should be asked to rerun the diff.
    hit_timeout: bool,

    pub fn init(diffs: []SequenceDiff, hit_timeout: bool) DiffAlgorithmResult {
        return .{ .diffs = diffs, .hit_timeout = hit_timeout };
    }

    pub fn deinit(self: *DiffAlgorithmResult, allocator: Allocator) void {
        allocator.free(self.diffs);
    }

    pub fn trivial(allocator: Allocator, seq1: ISequence, seq2: ISequence) !DiffAlgorithmResult {
        const diffs = try allocator.alloc(SequenceDiff, 1);
        diffs[0] = SequenceDiff.init(
            OffsetRange.ofLength(seq1.length()),
            OffsetRange.ofLength(seq2.length()),
        );
        return DiffAlgorithmResult.init(diffs, false);
    }

    pub fn trivialTimedOut(allocator: Allocator, seq1: ISequence, seq2: ISequence) !DiffAlgorithmResult {
        const diffs = try allocator.alloc(SequenceDiff, 1);
        diffs[0] = SequenceDiff.init(
            OffsetRange.ofLength(seq1.length()),
            OffsetRange.ofLength(seq2.length()),
        );
        return DiffAlgorithmResult.init(diffs, true);
    }
};

/// Maps a range in the first sequence to a range in the second sequence.
pub const SequenceDiff = struct {
    seq1Range: OffsetRange,
    seq2Range: OffsetRange,

    pub const OffsetPair = struct {
        offset1: usize,
        offset2: usize,

        pub const zero = OffsetPair{ .offset1 = 0, .offset2 = 0 };
        pub const max = OffsetPair{ .offset1 = std.math.maxInt(usize), .offset2 = std.math.maxInt(usize) };

        pub fn init(offset1: usize, offset2: usize) OffsetPair {
            return .{ .offset1 = offset1, .offset2 = offset2 };
        }

        pub fn delta(self: OffsetPair, offset: isize) OffsetPair {
            if (offset == 0) {
                return self;
            }
            return OffsetPair.init(
                @intCast(@as(isize, @intCast(self.offset1)) + offset),
                @intCast(@as(isize, @intCast(self.offset2)) + offset),
            );
        }

        pub fn equals(self: OffsetPair, other: OffsetPair) bool {
            return self.offset1 == other.offset1 and self.offset2 == other.offset2;
        }

        pub fn toString(self: OffsetPair, writer: *Io.Writer) !void {
            try writer.print("{d} <-> {d}", .{ self.offset1, self.offset2 });
        }
    };

    pub fn init(seq1_range: OffsetRange, seq2_range: OffsetRange) SequenceDiff {
        return .{ .seq1Range = seq1_range, .seq2Range = seq2_range };
    }

    pub fn invert(allocator: Allocator, sequence_diffs: []const SequenceDiff, doc1_length: usize) ![]SequenceDiff {
        var result = ArrayList(SequenceDiff).init(allocator);
        errdefer result.deinit();

        var i: usize = 0;
        while (i <= sequence_diffs.len) : (i += 1) {
            const a: ?SequenceDiff = if (i > 0) sequence_diffs[i - 1] else null;
            const b: ?SequenceDiff = if (i < sequence_diffs.len) sequence_diffs[i] else null;

            const start: OffsetPair = if (a) |value| value.getEndExclusives() else OffsetPair.zero;
            const end: OffsetPair = if (b) |value| value.getStarts() else blk: {
                const end_delta: isize = if (a) |value|
                    @as(isize, @intCast(value.seq2Range.endExclusive)) - @as(isize, @intCast(value.seq1Range.endExclusive))
                else
                    0;
                break :blk OffsetPair.init(
                    doc1_length,
                    @intCast(end_delta + @as(isize, @intCast(doc1_length))),
                );
            };

            try result.append(SequenceDiff.fromOffsetPairs(start, end));
        }
        return result.toOwnedSlice();
    }

    pub fn fromOffsetPairs(start: OffsetPair, end_exclusive: OffsetPair) SequenceDiff {
        return SequenceDiff.init(
            OffsetRange.init(start.offset1, end_exclusive.offset1),
            OffsetRange.init(start.offset2, end_exclusive.offset2),
        );
    }

    pub fn assertSorted(sequence_diffs: []const SequenceDiff) !void {
        var last: ?SequenceDiff = null;
        for (sequence_diffs) |current| {
            if (last) |previous| {
                if (!(previous.seq1Range.endExclusive <= current.seq1Range.start and
                    previous.seq2Range.endExclusive <= current.seq2Range.start))
                {
                    return error.SequenceDiffsNotSorted;
                }
            }
            last = current;
        }
    }

    pub fn swap(self: SequenceDiff) SequenceDiff {
        return SequenceDiff.init(self.seq2Range, self.seq1Range);
    }

    pub fn toString(self: SequenceDiff, writer: *Io.Writer) !void {
        try self.seq1Range.toString(writer);
        try writer.writeAll(" <-> ");
        try self.seq2Range.toString(writer);
    }

    pub fn join(self: SequenceDiff, other: SequenceDiff) SequenceDiff {
        return SequenceDiff.init(
            self.seq1Range.join(other.seq1Range),
            self.seq2Range.join(other.seq2Range),
        );
    }

    pub fn delta(self: SequenceDiff, offset: isize) SequenceDiff {
        if (offset == 0) {
            return self;
        }
        return SequenceDiff.init(
            self.seq1Range.delta(offset),
            self.seq2Range.delta(offset),
        );
    }

    pub fn deltaStart(self: SequenceDiff, offset: isize) SequenceDiff {
        if (offset == 0) {
            return self;
        }
        return SequenceDiff.init(
            self.seq1Range.deltaStart(offset),
            self.seq2Range.deltaStart(offset),
        );
    }

    pub fn deltaEnd(self: SequenceDiff, offset: isize) SequenceDiff {
        if (offset == 0) {
            return self;
        }
        return SequenceDiff.init(
            self.seq1Range.deltaEnd(offset),
            self.seq2Range.deltaEnd(offset),
        );
    }

    pub fn intersectsOrTouches(self: SequenceDiff, other: SequenceDiff) bool {
        return self.seq1Range.intersectsOrTouches(other.seq1Range) or
            self.seq2Range.intersectsOrTouches(other.seq2Range);
    }

    pub fn intersect(self: SequenceDiff, other: SequenceDiff) ?SequenceDiff {
        const intersection1 = self.seq1Range.intersect(other.seq1Range);
        const intersection2 = self.seq2Range.intersect(other.seq2Range);
        if (intersection1 == null or intersection2 == null) {
            return null;
        }
        return SequenceDiff.init(intersection1.?, intersection2.?);
    }

    pub fn getStarts(self: SequenceDiff) OffsetPair {
        return OffsetPair.init(self.seq1Range.start, self.seq2Range.start);
    }

    pub fn getEndExclusives(self: SequenceDiff) OffsetPair {
        return OffsetPair.init(self.seq1Range.endExclusive, self.seq2Range.endExclusive);
    }
};

/// A timeout abstraction. `null` timeouts are treated as infinite.
pub const ITimeout = struct {
    context: *anyopaque,
    is_valid: *const fn (context: *anyopaque) bool,

    pub fn isValid(self: ITimeout) bool {
        return self.is_valid(self.context);
    }
};

pub const InfiniteTimeout = struct {
    const Self = @This();

    var instance: Self = .{};

    pub fn isValid(_: *Self) bool {
        return true;
    }

    fn isValidAny(context: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.isValid();
    }

    pub fn timeout(self: *Self) ITimeout {
        return .{ .context = self, .is_valid = &isValidAny };
    }

    pub fn getInstance() ITimeout {
        return instance.timeout();
    }
};

pub const DateTimeout = struct {
    const Self = @This();

    start_time: i64,
    timeout_ms: i64,
    valid: bool = true,

    pub fn init(timeout_ms: i64) !Self {
        if (timeout_ms <= 0) {
            return error.InvalidTimeout;
        }
        return .{
            .start_time = time.milliTimestamp(),
            .timeout_ms = timeout_ms,
        };
    }

    pub fn isValid(self: *Self) bool {
        const valid = time.milliTimestamp() - self.start_time < self.timeout_ms;
        if (!valid and self.valid) {
            self.valid = false; // timeout reached
        }
        return self.valid;
    }

    pub fn disable(self: *Self) void {
        self.timeout_ms = std.math.maxInt(i64);
        self.valid = true;
    }

    fn isValidAny(context: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.isValid();
    }

    pub fn interface(self: *Self) ITimeout {
        return .{ .context = self, .is_valid = &isValidAny };
    }
};

test "SequenceDiff: invert" {
    const allocator = std.testing.allocator;

    const diffs = [_]SequenceDiff{
        SequenceDiff.init(OffsetRange.init(1, 3), OffsetRange.init(2, 4)),
        SequenceDiff.init(OffsetRange.init(6, 8), OffsetRange.init(5, 7)),
    };
    const inverted = try SequenceDiff.invert(allocator, &diffs, 10);
    defer allocator.free(inverted);

    try std.testing.expectEqual(@as(usize, 3), inverted.len);
    try std.testing.expectEqual(OffsetRange.init(0, 1), inverted[0].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(0, 2), inverted[0].seq2Range);
    try std.testing.expectEqual(SequenceDiff.OffsetPair.init(0, 0), inverted[0].getStarts());
    try std.testing.expectEqual(OffsetRange.init(3, 6), inverted[1].seq1Range);
}

test "SequenceDiff: helpers" {
    const diff = SequenceDiff.init(OffsetRange.init(1, 2), OffsetRange.init(3, 4));
    try std.testing.expectEqual(SequenceDiff.OffsetPair.init(1, 3), diff.getStarts());
    try std.testing.expectEqual(SequenceDiff.OffsetPair.init(2, 4), diff.getEndExclusives());
    try std.testing.expectEqualDeep(SequenceDiff.init(OffsetRange.init(2, 3), OffsetRange.init(4, 5)), diff.delta(1));
    try std.testing.expect(diff.intersectsOrTouches(SequenceDiff.init(OffsetRange.init(2, 3), OffsetRange.init(1, 2))));
    try std.testing.expect(diff.intersect(SequenceDiff.init(OffsetRange.init(1, 2), OffsetRange.init(3, 4))) != null);
    try std.testing.expect(diff.intersect(SequenceDiff.init(OffsetRange.init(5, 6), OffsetRange.init(5, 6))) == null);
}

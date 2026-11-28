// Port of `src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/myersDiffAlgorithm.ts`.
// Upstream's FastInt32Array/FastArrayNegativeIndices are native growable
// arrays. X offsets use usize to match the Zig sequence interface.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const OffsetRange = @import("../../../core/ranges/offsetRange.zig").OffsetRange;
const diff = @import("diffAlgorithm.zig");

const SnakePath = struct {
    prev: ?*SnakePath,
    x: usize,
    y: usize,
    length: usize,
};

/// Upstream FastInt32Array and FastArrayNegativeIndices use two contiguous
/// arrays, one for each sign. A negative index -1 maps to slot 0. Preserve
/// the growing diagonal band rather than allocating space for every line.
fn FastArrayNegativeIndices(comptime T: type, comptime default: T) type {
    return struct {
        const Self = @This();
        positive: std.ArrayList(T) = .empty,
        negative: std.ArrayList(T) = .empty,

        fn deinit(self: *Self, allocator: Allocator) void {
            self.positive.deinit(allocator);
            self.negative.deinit(allocator);
        }

        fn get(self: *const Self, idx: isize) T {
            const arr = if (idx < 0) &self.negative else &self.positive;
            const index: usize = @intCast(if (idx < 0) -(idx + 1) else idx);
            return if (index < arr.items.len) arr.items[index] else default;
        }

        fn set(self: *Self, allocator: Allocator, idx: isize, value: T) !void {
            const arr = if (idx < 0) &self.negative else &self.positive;
            const index: usize = @intCast(if (idx < 0) -(idx + 1) else idx);
            if (index >= arr.items.len) {
                const old_len = arr.items.len;
                const new_len = @max(10, @max(old_len * 2, index + 1));
                try arr.resize(allocator, new_len);
                @memset(arr.items[old_len..], default);
            }
            arr.items[index] = value;
        }
    };
}

const FastIntArray = FastArrayNegativeIndices(usize, 0);
const FastPathArray = FastArrayNegativeIndices(?*SnakePath, null);

/// An O(ND) diff algorithm that has a quadratic space worst-case complexity.
pub const MyersDiffAlgorithm = struct {
    const Self = @This();

    pub fn compute(
        _: Self,
        allocator: Allocator,
        seq1: diff.ISequence,
        seq2: diff.ISequence,
        timeout: ?diff.ITimeout,
    ) !diff.DiffAlgorithmResult {
        // These are common special cases. The early return improves performance dramatically.
        if (seq1.length() == 0 or seq2.length() == 0) {
            return diff.DiffAlgorithmResult.trivial(allocator, seq1, seq2);
        }

        const seq_x = seq1; // Text on the x axis
        const seq_y = seq2; // Text on the y axis
        const len_x = seq_x.length();
        const len_y = seq_y.length();

        var v: FastIntArray = .{};
        defer v.deinit(allocator);

        var paths: FastPathArray = .{};
        defer paths.deinit(allocator);

        var path_arena = std.heap.ArenaAllocator.init(allocator);
        defer path_arena.deinit();
        const path_allocator = path_arena.allocator();

        const initial_x = getXAfterSnake(seq_x, seq_y, len_x, len_y, 0, 0);
        try v.set(allocator, 0, initial_x);
        try paths.set(allocator, 0, if (initial_x == 0) null else try newPath(path_allocator, null, 0, 0, initial_x));

        var d: usize = 0;
        var k: isize = 0;

        loop: while (true) {
            d += 1;
            if (timeout) |t| {
                if (!t.isValid()) {
                    return diff.DiffAlgorithmResult.trivialTimedOut(allocator, seq_x, seq_y);
                }
            }

            const lower_bound: isize = -@as(isize, @intCast(@min(d, len_y + (d % 2))));
            const upper_bound: isize = @intCast(@min(d, len_x + (d % 2)));

            k = lower_bound;
            while (k <= upper_bound) : (k += 2) {
                const max_x_of_d_line_top: isize = if (k == upper_bound) -1 else @intCast(v.get(k + 1));
                const max_x_of_d_line_left: isize = if (k == lower_bound) -1 else @as(isize, @intCast(v.get(k - 1))) + 1;

                const x: isize = @min(@max(max_x_of_d_line_top, max_x_of_d_line_left), @as(isize, @intCast(len_x)));
                const y: isize = x - k;

                if (x > @as(isize, @intCast(len_x)) or y > @as(isize, @intCast(len_y))) {
                    // This diagonal is irrelevant for the result.
                    continue;
                }

                // Upstream JavaScript tolerates a negative `y`: `getElement(-1)`
                // is `undefined`, so the snake loop never advances and the
                // result is `x`. Keep that behavior instead of trapping in the
                // `usize` conversion; such a diagonal has no matching prefix.
                const new_max_x = if (y < 0)
                    @as(usize, @intCast(x))
                else
                    getXAfterSnake(seq_x, seq_y, len_x, len_y, @intCast(x), @intCast(y));
                try v.set(allocator, k, new_max_x);

                const last_path: ?*SnakePath = if (x == max_x_of_d_line_top)
                    paths.get(k + 1)
                else
                    paths.get(k - 1);
                try paths.set(allocator, k, if (new_max_x != @as(usize, @intCast(x))) try newPath(path_allocator, last_path, @intCast(x), @intCast(y), new_max_x - @as(usize, @intCast(x))) else last_path);

                if (new_max_x == len_x and @as(isize, @intCast(new_max_x)) - k == @as(isize, @intCast(len_y))) {
                    break :loop;
                }
            }
        }

        var path = paths.get(k);
        var result = ArrayList(diff.SequenceDiff).init(allocator);
        errdefer result.deinit();

        var last_aligning_pos_s1: usize = len_x;
        var last_aligning_pos_s2: usize = len_y;

        while (true) {
            const end_x = if (path) |p| p.x + p.length else 0;
            const end_y = if (path) |p| p.y + p.length else 0;

            if (end_x != last_aligning_pos_s1 or end_y != last_aligning_pos_s2) {
                try result.append(diff.SequenceDiff.init(
                    OffsetRange.init(end_x, last_aligning_pos_s1),
                    OffsetRange.init(end_y, last_aligning_pos_s2),
                ));
            }
            const current = path orelse break;
            last_aligning_pos_s1 = current.x;
            last_aligning_pos_s2 = current.y;

            path = current.prev;
        }

        std.mem.reverse(diff.SequenceDiff, result.items);
        return diff.DiffAlgorithmResult.init(try result.toOwnedSlice(), false);
    }

    fn getXAfterSnake(seq_x: diff.ISequence, seq_y: diff.ISequence, len_x: usize, len_y: usize, start_x: usize, start_y: usize) usize {
        var x = start_x;
        var y = start_y;
        while (x < len_x and y < len_y and seq_x.getElement(x) == seq_y.getElement(y)) {
            x += 1;
            y += 1;
        }
        return x;
    }

    fn newPath(allocator: Allocator, prev: ?*SnakePath, x: usize, y: usize, length: usize) !*SnakePath {
        const path = try allocator.create(SnakePath);
        path.* = .{ .prev = prev, .x = x, .y = y, .length = length };
        return path;
    }
};

test "MyersDiffAlgorithm: dense diagonal arrays preserve signed indices and growth" {
    const allocator = std.testing.allocator;
    var v: FastIntArray = .{};
    defer v.deinit(allocator);
    try v.set(allocator, 0, 7);
    try v.set(allocator, -1, 9);
    try v.set(allocator, 40, 11);
    try v.set(allocator, -42, 13);
    try std.testing.expectEqual(@as(usize, 7), v.get(0));
    try std.testing.expectEqual(@as(usize, 9), v.get(-1));
    try std.testing.expectEqual(@as(usize, 11), v.get(40));
    try std.testing.expectEqual(@as(usize, 13), v.get(-42));
    try std.testing.expectEqual(@as(usize, 0), v.get(39));
    try std.testing.expectEqual(@as(usize, 0), v.get(-41));
    try std.testing.expectEqual(@as(usize, 0), v.get(-1000));
}

test "MyersDiffAlgorithm: many separated edits retain exact ranges after diagonal growth" {
    const allocator = std.testing.allocator;
    var original: [128]u64 = undefined;
    var modified: [128]u64 = undefined;
    for (&original, &modified, 0..) |*before, *after, i| {
        before.* = i;
        after.* = if (i % 4 == 2) i + original.len else i;
    }
    var seq1 = TestSequence.init(&original);
    var seq2 = TestSequence.init(&modified);
    var result = try MyersDiffAlgorithm.compute(.{}, allocator, seq1.sequence(), seq2.sequence(), null);
    defer result.deinit(allocator);
    try std.testing.expect(!result.hit_timeout);
    try std.testing.expectEqual(@as(usize, 32), result.diffs.len);
    for (result.diffs, 0..) |change, i| {
        const offset = i * 4 + 2;
        try std.testing.expectEqual(OffsetRange.init(offset, offset + 1), change.seq1Range);
        try std.testing.expectEqual(OffsetRange.init(offset, offset + 1), change.seq2Range);
    }
}

test "MyersDiffAlgorithm: simple diff" {
    const allocator = std.testing.allocator;

    var seq1 = TestSequence.init(&.{ 1, 2, 3, 4 });
    var seq2 = TestSequence.init(&.{ 1, 3, 4, 5 });

    var result = try MyersDiffAlgorithm.compute(.{}, allocator, seq1.sequence(), seq2.sequence(), null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.diffs.len);
    try std.testing.expectEqual(OffsetRange.init(1, 2), result.diffs[0].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(1, 1), result.diffs[0].seq2Range);
    try std.testing.expectEqual(OffsetRange.init(4, 4), result.diffs[1].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(3, 4), result.diffs[1].seq2Range);
}

test "MyersDiffAlgorithm: identical sequences" {
    const allocator = std.testing.allocator;

    var seq1 = TestSequence.init(&.{ 1, 2, 3 });
    var result = try MyersDiffAlgorithm.compute(.{}, allocator, seq1.sequence(), seq1.sequence(), null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.diffs.len);
}

test "MyersDiffAlgorithm: unequal lengths with an unmatched tail" {
    const allocator = std.testing.allocator;

    // This reaches d=3, k=2 with x=1 and y=-1: the diagonal is past the end of
    // the x sequence, so it has no snake and the old port trapped in @intCast.
    var seq1 = TestSequence.init(&.{1});
    var seq2 = TestSequence.init(&.{ 2, 3 });

    var result = try MyersDiffAlgorithm.compute(.{}, allocator, seq1.sequence(), seq2.sequence(), null);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.diffs.len);
    try std.testing.expectEqual(OffsetRange.init(0, 1), result.diffs[0].seq1Range);
    try std.testing.expectEqual(OffsetRange.init(0, 2), result.diffs[0].seq2Range);
}

test "MyersDiffAlgorithm: unequal lengths keep ranges in bounds" {
    const allocator = std.testing.allocator;

    var len_a: usize = 1;
    while (len_a <= 5) : (len_a += 1) {
        var len_b: usize = 1;
        while (len_b <= 5) : (len_b += 1) {
            var items_a: [5]u64 = undefined;
            var items_b: [5]u64 = undefined;
            for (0..len_a) |index| items_a[index] = index + 1;
            for (0..len_b) |index| items_b[index] = index + 100;

            var seq_a = TestSequence.init(items_a[0..len_a]);
            var seq_b = TestSequence.init(items_b[0..len_b]);
            var result = try MyersDiffAlgorithm.compute(.{}, allocator, seq_a.sequence(), seq_b.sequence(), null);
            defer result.deinit(allocator);

            for (result.diffs) |change| {
                try std.testing.expect(change.seq1Range.start <= change.seq1Range.endExclusive);
                try std.testing.expect(change.seq1Range.endExclusive <= len_a);
                try std.testing.expect(change.seq2Range.start <= change.seq2Range.endExclusive);
                try std.testing.expect(change.seq2Range.endExclusive <= len_b);
            }
        }
    }
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

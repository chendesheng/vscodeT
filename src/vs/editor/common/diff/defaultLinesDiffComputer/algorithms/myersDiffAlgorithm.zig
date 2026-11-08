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

const FastIntMap = std.AutoHashMapUnmanaged(isize, usize);
const FastPathMap = std.AutoHashMapUnmanaged(isize, ?*SnakePath);

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

        var v: FastIntMap = .empty;
        defer v.deinit(allocator);

        var paths: FastPathMap = .empty;
        defer paths.deinit(allocator);

        var path_arena = std.heap.ArenaAllocator.init(allocator);
        defer path_arena.deinit();
        const path_allocator = path_arena.allocator();

        const initial_x = getXAfterSnake(seq_x, seq_y, 0, 0);
        try v.put(allocator, 0, initial_x);
        try paths.put(allocator, 0, if (initial_x == 0) null else try newPath(path_allocator, null, 0, 0, initial_x));

        var d: usize = 0;
        var k: isize = 0;

        loop: while (true) {
            d += 1;
            if (timeout) |t| {
                if (!t.isValid()) {
                    return diff.DiffAlgorithmResult.trivialTimedOut(allocator, seq_x, seq_y);
                }
            }

            const lower_bound: isize = -@as(isize, @intCast(@min(d, seq_y.length() + (d % 2))));
            const upper_bound: isize = @intCast(@min(d, seq_x.length() + (d % 2)));

            k = lower_bound;
            while (k <= upper_bound) : (k += 2) {
                const max_x_of_d_line_top: isize = if (k == upper_bound) -1 else @intCast(v.get(k + 1) orelse 0);
                const max_x_of_d_line_left: isize = if (k == lower_bound) -1 else @as(isize, @intCast(v.get(k - 1) orelse 0)) + 1;

                const x: isize = @min(@max(max_x_of_d_line_top, max_x_of_d_line_left), @as(isize, @intCast(seq_x.length())));
                const y: isize = x - k;

                if (x > @as(isize, @intCast(seq_x.length())) or y > @as(isize, @intCast(seq_y.length()))) {
                    // This diagonal is irrelevant for the result.
                    continue;
                }

                const new_max_x = getXAfterSnake(seq_x, seq_y, @intCast(x), @intCast(y));
                try v.put(allocator, k, new_max_x);

                const last_path: ?*SnakePath = if (x == max_x_of_d_line_top)
                    paths.get(k + 1) orelse null
                else
                    paths.get(k - 1) orelse null;
                try paths.put(allocator, k, if (new_max_x != @as(usize, @intCast(x))) try newPath(path_allocator, last_path, @intCast(x), @intCast(y), new_max_x - @as(usize, @intCast(x))) else last_path);

                if (v.get(k).? == seq_x.length() and @as(isize, @intCast(v.get(k).?)) - k == @as(isize, @intCast(seq_y.length()))) {
                    break :loop;
                }
            }
        }

        var path = paths.get(k) orelse null;
        var result = ArrayList(diff.SequenceDiff).init(allocator);
        errdefer result.deinit();

        var last_aligning_pos_s1: usize = seq_x.length();
        var last_aligning_pos_s2: usize = seq_y.length();

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

    fn getXAfterSnake(seq_x: diff.ISequence, seq_y: diff.ISequence, start_x: usize, start_y: usize) usize {
        var x = start_x;
        var y = start_y;
        while (x < seq_x.length() and y < seq_y.length() and seq_x.getElement(x) == seq_y.getElement(y)) {
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

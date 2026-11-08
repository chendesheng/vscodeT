// Port of the parts of `src/vs/base/common/arraysFind.ts` that this port needs.
const std = @import("std");

/// Returns the last index in `[start_idx, end_idx_ex)` where the monotonic
/// predicate holds, or `start_idx - 1` when it never holds.
///
/// The predicate must be monotonic: true for a prefix of the range followed by
/// false for the rest.
pub fn findLastIdxMonotonous(
    comptime T: type,
    array: []const T,
    context: anytype,
    comptime predicate: fn (@TypeOf(context), T) bool,
    start_idx: usize,
    end_idx_ex: usize,
) usize {
    var low = start_idx;
    var high = end_idx_ex;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (predicate(context, array[mid])) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    // `low` is the first index where the predicate is false; the answer is one
    // before it. `low == start_idx` means it never held, so the unsigned result
    // wraps to `start_idx - 1`, i.e. `maxInt(usize)` for a start of 0.
    return low -% 1;
}

/// Same as `findLastIdxMonotonous`, but returns `null` instead of
/// `start_idx - 1` when the predicate never holds.
pub fn findLastIdxMonotonousOrNull(
    comptime T: type,
    array: []const T,
    context: anytype,
    comptime predicate: fn (@TypeOf(context), T) bool,
    start_idx: usize,
    end_idx_ex: usize,
) ?usize {
    const index = findLastIdxMonotonous(T, array, context, predicate, start_idx, end_idx_ex);
    if (index == std.math.maxInt(usize)) {
        return null;
    }
    return index;
}

const TestPredicate = struct {
    fn lessThanOrEqual(threshold: usize, value: usize) bool {
        return value <= threshold;
    }

    fn greaterThan(threshold: usize, value: usize) bool {
        return value > threshold;
    }
};

test "findLastIdxMonotonous: finds the last matching element" {
    const array = [_]usize{ 0, 1, 2, 3, 5, 8 };
    try std.testing.expectEqual(@as(usize, 3), findLastIdxMonotonous(usize, &array, @as(usize, 3), TestPredicate.lessThanOrEqual, 0, array.len));
    try std.testing.expectEqual(@as(usize, 5), findLastIdxMonotonous(usize, &array, @as(usize, 100), TestPredicate.lessThanOrEqual, 0, array.len));
}

test "findLastIdxMonotonous: wraps when the predicate is never true" {
    const array = [_]usize{ 0, 1, 2 };
    try std.testing.expectEqual(std.math.maxInt(usize), findLastIdxMonotonous(usize, &array, @as(usize, 100), TestPredicate.greaterThan, 0, array.len));
    // A non-zero start index returns `start_idx - 1`.
    try std.testing.expectEqual(@as(usize, 2), findLastIdxMonotonous(usize, &array, @as(usize, 100), TestPredicate.greaterThan, 3, array.len));
}

test "findLastIdxMonotonousOrNull: reports a miss as null" {
    const array = [_]usize{ 10, 20, 30 };
    try std.testing.expectEqual(@as(?usize, null), findLastIdxMonotonousOrNull(usize, &array, @as(usize, 100), TestPredicate.greaterThan, 0, array.len));
    try std.testing.expectEqual(@as(?usize, 1), findLastIdxMonotonousOrNull(usize, &array, @as(usize, 25), TestPredicate.lessThanOrEqual, 0, array.len));
}

// Port of `src/vs/base/common/range.ts`.

const std = @import("std");

pub const Range = struct {
    start: i64,
    end: i64,
};

/// Returns the intersection between two ranges. An empty intersection is
/// `{ start: 0, end: 0 }`, matching upstream.
pub fn intersect(one: Range, other: Range) Range {
    if (one.start >= other.end or other.start >= one.end) {
        return .{ .start = 0, .end = 0 };
    }
    const start = @max(one.start, other.start);
    const end = @min(one.end, other.end);
    if (end - start <= 0) return .{ .start = 0, .end = 0 };
    return .{ .start = start, .end = end };
}

pub fn isEmpty(range: Range) bool {
    return range.end - range.start <= 0;
}

pub fn intersects(one: Range, other: Range) bool {
    return !isEmpty(intersect(one, other));
}

/// The parts of `one` outside `other`, in order.
pub fn relativeComplement(allocator: std.mem.Allocator, one: Range, other: Range) ![]Range {
    var result: std.array_list.Managed(Range) = .init(allocator);
    errdefer result.deinit();
    const first = Range{
        .start = one.start,
        .end = @min(other.start, one.end),
    };
    const second = Range{
        .start = @max(other.end, one.start),
        .end = one.end,
    };
    if (!isEmpty(first)) try result.append(first);
    if (!isEmpty(second)) try result.append(second);
    return result.toOwnedSlice();
}

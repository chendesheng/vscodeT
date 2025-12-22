const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const usizeAdd = @import("utils.zig").usizeAdd;
const clamp = @import("utils.zig").clamp;

// A range of offsets (0-based).
pub const OffsetRange = struct {
    start: usize,
    endExclusive: usize,

    pub fn init(start: usize, endExclusive: usize) OffsetRange {
        return OffsetRange{ .start = start, .endExclusive = endExclusive };
    }

    pub fn addRange(range: OffsetRange, sortedRanges: *ArrayList(OffsetRange)) !void {
        var i: usize = 0;
        while (i < sortedRanges.len and sortedRanges[i].endExclusive < range.start) {
            i += 1;
        }
        var j: usize = i;
        while (j < sortedRanges.len and sortedRanges[j].start <= range.endExclusive) {
            j += 1;
        }
        if (i == j) {
            try sortedRanges.insert(i, range);
        } else {
            const start = @min(range.start, sortedRanges[i].start);
            const end = @max(range.endExclusive, sortedRanges[j - 1].endExclusive);
            try sortedRanges.insert(i, OffsetRange.init(start, end));
        }
    }

    pub fn tryCreate(start: usize, endExclusive: usize) !OffsetRange {
        if (start > endExclusive) {
            return error.InvalidRange;
        }
        return OffsetRange.init(start, endExclusive);
    }

    pub fn ofLength(len: usize) OffsetRange {
        return OffsetRange.init(0, len);
    }

    pub fn ofStartAndLength(start: usize, len: usize) OffsetRange {
        return OffsetRange.init(start, start + len);
    }

    pub fn emptyAt(offset: usize) OffsetRange {
        return OffsetRange.init(offset, offset);
    }

    pub fn isEmpty(self: OffsetRange) bool {
        return self.start == self.endExclusive;
    }

    pub fn delta(self: OffsetRange, offset: isize) OffsetRange {
        return OffsetRange.init(usizeAdd(self.start, offset), usizeAdd(self.endExclusive, offset));
    }

    pub fn deltaStart(self: OffsetRange, offset: usize) OffsetRange {
        return OffsetRange.init(self.start + offset, self.endExclusive);
    }

    pub fn deltaEnd(self: OffsetRange, offset: usize) OffsetRange {
        return OffsetRange.init(self.start, self.endExclusive + offset);
    }

    pub fn length(self: OffsetRange) usize {
        return self.endExclusive - self.start;
    }

    pub fn toString(self: OffsetRange, allocator: Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "[{}, {})", .{ self.start, self.endExclusive });
    }

    pub fn equals(self: OffsetRange, other: OffsetRange) bool {
        return self.start == other.start and self.endExclusive == other.endExclusive;
    }

    pub fn containsRange(self: OffsetRange, other: OffsetRange) bool {
        return self.start <= other.start and other.endExclusive <= self.endExclusive;
    }

    pub fn contains(self: OffsetRange, offset: usize) bool {
        return self.start <= offset and offset < self.endExclusive;
    }

    // for all numbers n: range1.contains(n) or range2.contains(n) => range1.join(range2).contains(n)
    // The joined range is the smallest range that contains both ranges.
    pub fn join(self: OffsetRange, other: OffsetRange) OffsetRange {
        return OffsetRange.init(@min(self.start, other.start), @max(self.endExclusive, other.endExclusive));
    }

    // for all numbers n: range1.contains(n) and range2.contains(n) <=> range1.intersect(range2).contains(n)
    // The resulting range is empty if the ranges do not intersect, but touch.
    // If the ranges don't even touch, the result is undefined.
    pub fn intersect(self: OffsetRange, other: OffsetRange) ?OffsetRange {
        const start = @max(self.start, other.start);
        const end = @min(self.endExclusive, other.endExclusive);
        if (start <= end) {
            return OffsetRange.init(start, end);
        }
        return null;
    }

    pub fn intersectionLength(self: OffsetRange, range: OffsetRange) usize {
        const start = @max(self.start, range.start);
        const end = @min(self.endExclusive, range.endExclusive);
        if (end >= start) return end - start;
        return 0;
    }

    pub fn intersects(self: OffsetRange, other: OffsetRange) bool {
        const start = @max(self.start, other.start);
        const end = @min(self.endExclusive, other.endExclusive);
        return start < end;
    }

    pub fn intersectsOrTouches(self: OffsetRange, other: OffsetRange) bool {
        const start = @max(self.start, other.start);
        const end = @min(self.endExclusive, other.endExclusive);
        return start <= end;
    }

    pub fn isBefore(self: OffsetRange, other: OffsetRange) bool {
        return self.endExclusive <= other.start;
    }

    pub fn isAfter(self: OffsetRange, other: OffsetRange) bool {
        return self.start >= other.endExclusive;
    }

    pub fn slice(comptime T: type, self: OffsetRange, arr: []T) []T {
        return arr[self.start..self.endExclusive];
    }

    pub fn substring(self: OffsetRange, str: []const u8) []const u8 {
        return str[self.start..self.endExclusive];
    }

    // Returns the given value if it is contained in this instance, otherwise the closest value that is contained.
    // The range must not be empty.
    pub fn clip(self: OffsetRange, value: usize) !usize {
        if (self.isEmpty()) {
            return error.InvalidRange;
        }
        return clamp(value, self.start, self.endExclusive - 1);
    }

    // Returns `r := value + k * length` such that `r` is contained in this range.
    // The range must not be empty.
    //
    // E.g. `[5, 10).clipCyclic(10) === 5`, `[5, 10).clipCyclic(11) === 6` and `[5, 10).clipCyclic(4) === 9`.
    pub fn clipCyclic(self: OffsetRange, value: usize) !usize {
        if (self.isEmpty()) {
            return error.InvalidRange;
        }
        if (value < self.start) {
            return self.endExclusive - ((self.start - value) % self.length());
        }
        if (value >= self.endExclusive) {
            return self.start + ((value - self.start) % self.length());
        }
        return value;
    }

    pub fn map(comptime T: type, allocator: Allocator, self: OffsetRange, context: anytype, f: fn (offset: usize, ctx: @TypeOf(context)) T) !ArrayList(T) {
        var result = ArrayList(T).init(allocator);
        for (self.start..self.endExclusive) |i| {
            try result.append(try f(i, context));
        }
        return result;
    }

    pub fn forEach(self: OffsetRange, context: anytype, f: fn (offset: usize, ctx: @TypeOf(context)) void) void {
        for (self.start..self.endExclusive) |i| {
            f(i, context);
        }
    }

    // this: [ 5, 10), range: [10, 15) => [5, 15)]
    // Throws if the ranges are not touching.
    pub fn joinRightTouching(self: OffsetRange, range: OffsetRange) !OffsetRange {
        if (self.endExclusive != range.start) {
            return error.InvalidRange;
        }
        return OffsetRange.init(self.start, range.endExclusive);
    }
};

test "OffsetRange" {
    const allocator = std.testing.allocator;
    const range = OffsetRange.init(5, 9);
    try std.testing.expectEqual(5, range.start);
    try std.testing.expectEqual(9, range.endExclusive);
    try std.testing.expectEqual(4, range.length());
    try std.testing.expectEqual(true, range.contains(6));
    const str = try range.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("[5, 9)", str);
    try std.testing.expect(range.containsRange(OffsetRange.init(5, 8)));
    try std.testing.expectEqualDeep(OffsetRange.init(5, 10), range.join(OffsetRange.init(6, 10)));
    try std.testing.expectEqualDeep(OffsetRange.init(5, 8), range.intersect(OffsetRange.init(4, 8)));
    try std.testing.expectEqual(null, range.intersect(OffsetRange.init(3, 4)));
    try std.testing.expectEqual(0, range.intersectionLength(OffsetRange.init(3, 4)));
    try std.testing.expectEqual(3, range.intersectionLength(OffsetRange.init(3, 8)));
}

test "OffsetRange.clipCyclic" {
    // E.g. `[5, 10).clipCyclic(10) === 5`, `[5, 10).clipCyclic(11) === 6` and `[5, 10).clipCyclic(4) === 9`.
    const range = OffsetRange.init(5, 10);
    try std.testing.expectEqual(5, try range.clipCyclic(10));
    try std.testing.expectEqual(6, try range.clipCyclic(11));
    try std.testing.expectEqual(9, try range.clipCyclic(4));
}

pub const OffsetRangeSet = struct {
    sortedRanges: ArrayList(OffsetRange),

    pub fn init(allocator: Allocator) OffsetRangeSet {
        return OffsetRangeSet{ .sortedRanges = ArrayList(OffsetRange).init(allocator) };
    }

    pub fn getRanges(self: OffsetRangeSet) []OffsetRange {
        return self.sortedRanges.items;
    }

    pub fn addRange(self: *OffsetRangeSet, range: OffsetRange) !void {
        var i: usize = 0;
        while (i < self.sortedRanges.len and self.sortedRanges.items[i].endExclusive < range.start) {
            i += 1;
        }
        var j: usize = i;
        while (j < self.sortedRanges.len and self.sortedRanges.items[j].start <= range.endExclusive) {
            j += 1;
        }
        if (i == j) {
            try self.sortedRanges.insert(i, range);
        } else {
            const start = @min(range.start, self.sortedRanges.items[i].start);
            const end = @max(range.endExclusive, self.sortedRanges.items[j - 1].endExclusive);
            try self.sortedRanges.insert(i, OffsetRange.init(start, end));
            self.sortedRanges.orderedRemove(i + 1, j - i);
        }
    }

    pub fn toString(self: OffsetRangeSet) !ArrayList(u8) {
        const allocator = self.sortedRanges.allocator;
        var result = ArrayList(u8).init(allocator);
        for (self.sortedRanges.items, 0..) |range, i| {
            const part = try range.toString(allocator);
            defer allocator.free(part);
            try result.append(part);
            if (i < self.sortedRanges.len - 1) {
                try result.append(", ");
            }
        }
        return result;
    }

    // Returns of there is a value that is contained in this instance and the given range.
    pub fn intersectsStrict(self: *OffsetRangeSet, other: OffsetRange) bool {
        // TODO use binary search
        var i: usize = 0;
        while (i < self.sortedRanges.len and self.sortedRanges.items[i].endExclusive <= other.start) {
            i += 1;
        }
        return i < self.sortedRanges.len and self.sortedRanges.items[i].start < other.endExclusive;
    }

    pub fn intersectWithRange(self: *OffsetRangeSet, other: OffsetRange) !OffsetRangeSet {
        // TODO use binary search + slice
        var result = OffsetRangeSet.init(self.sortedRanges.allocator);
        for (self.sortedRanges.items) |range| {
            if (range.intersect(other)) |intersection| {
                try result.addRange(intersection);
            }
        }
        return result;
    }

    pub fn intersectWithRangeLength(self: *OffsetRangeSet, other: OffsetRange) usize {
        return (try self.intersectWithRange(other)).length();
    }

    pub fn length(self: OffsetRangeSet) usize {
        var result: usize = 0;
        for (self.sortedRanges.items) |range| {
            result += range.length();
        }
        return result;
    }
};

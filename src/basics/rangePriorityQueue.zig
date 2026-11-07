const std = @import("std");
const Io = std.Io;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const OffsetRange = @import("offsetRange.zig").OffsetRange;
const OffsetRangeSet = @import("offsetRange.zig").OffsetRangeSet;
const findIndex = @import("utils.zig").findIndex;
const usizeAdd = @import("utils.zig").usizeAdd;
const usizeSub = @import("utils.zig").usizeSub;

const Self = @This();

_ranges: ArrayList(OffsetRange),

pub fn init(allocator: Allocator) Self {
    return Self{ ._ranges = ArrayList(OffsetRange).init(allocator) };
}

pub fn deinit(self: *const Self) void {
    self._ranges.deinit();
}

pub fn getRanges(self: *const Self) []OffsetRange {
    return self._ranges.items;
}

pub fn min(self: *const Self) ?usize {
    if (self._ranges.items.len == 0) return null;
    return self._ranges.items[0].start;
}

pub fn removeMin(self: *Self) ?usize {
    if (self._ranges.items.len == 0) return null;
    const range = self._ranges.items[0];
    if (range.start + 1 == range.endExclusive) {
        _ = self._ranges.orderedRemove(0);
    } else {
        self._ranges.items[0] = OffsetRange.init(range.start + 1, range.endExclusive);
    }
    return range.start;
}

pub fn delete(self: *Self, value: usize) !void {
    if (findIndex(OffsetRange, self._ranges.items, value, struct {
        fn pred(r: OffsetRange, val: usize) bool {
            return r.contains(val);
        }
    }.pred)) |idx| {
        const range = self._ranges.items[idx];
        if (range.start == value) {
            if (range.endExclusive == value + 1) {
                _ = self._ranges.orderedRemove(idx);
            } else {
                self._ranges.items[idx] = OffsetRange.init(value + 1, range.endExclusive);
            }
        } else {
            if (range.endExclusive == value + 1) {
                self._ranges.items[idx] = OffsetRange.init(range.start, value);
            } else {
                self._ranges.items[idx] = OffsetRange.init(range.start, value);
                try self._ranges.insert(idx + 1, OffsetRange.init(value + 1, range.endExclusive));
            }
        }
    }
}

pub fn addRange(self: *Self, range: OffsetRange) !void {
    try OffsetRange.addRange(range, &self._ranges);
}

pub fn addRangeAndResize(self: *Self, range: OffsetRange, newLength: usize) !void {
    var idxFirstMightBeIntersecting: usize = 0;
    while (!(idxFirstMightBeIntersecting >= self._ranges.items.len or range.start <= self._ranges.items[idxFirstMightBeIntersecting].endExclusive)) {
        idxFirstMightBeIntersecting += 1;
    }
    var idxFirstIsAfter = idxFirstMightBeIntersecting;
    while (!(idxFirstIsAfter >= self._ranges.items.len or range.endExclusive < self._ranges.items[idxFirstIsAfter].start)) {
        idxFirstIsAfter += 1;
    }
    const delta = usizeSub(newLength, range.length());

    for (self._ranges.items[idxFirstIsAfter..]) |*item| {
        item.* = item.delta(delta);
    }

    if (idxFirstMightBeIntersecting == idxFirstIsAfter) {
        const newRange = OffsetRange.init(range.start, range.start + newLength);
        if (!newRange.isEmpty()) {
            try self._ranges.insert(idxFirstMightBeIntersecting, newRange);
        }
    } else {
        const start = @min(range.start, self._ranges.items[idxFirstMightBeIntersecting].start);
        const endEx = @max(range.endExclusive, self._ranges.items[idxFirstIsAfter - 1].endExclusive);

        const newRange = OffsetRange.init(start, usizeAdd(endEx, delta));
        if (!newRange.isEmpty()) {
            try self._ranges.replaceRange(idxFirstMightBeIntersecting, idxFirstIsAfter - idxFirstMightBeIntersecting, &[_]OffsetRange{newRange});
        } else {
            try self._ranges.replaceRange(idxFirstMightBeIntersecting, idxFirstIsAfter - idxFirstMightBeIntersecting, &[_]OffsetRange{});
        }
    }
}

pub fn toString(self: *Self, writer: *Io.Writer) !void {
    for (self._ranges.items, 0..) |range, i| {
        try range.toString(writer);
        if (i < self._ranges.items.len - 1) try writer.writeAll(" + ");
    }
}

test "RangePriorityQueue/addRange" {
    var queue = init(std.testing.allocator);
    defer queue.deinit();
    try queue.addRange(OffsetRange.init(8, 10));
    try queue.addRange(OffsetRange.init(10, 12));
    try std.testing.expectEqualDeep(&[_]OffsetRange{.init(8, 12)}, queue.getRanges());
}

test "RangePriorityQueue/removeMin" {
    var queue = init(std.testing.allocator);
    defer queue.deinit();
    try queue.addRange(OffsetRange.init(8, 10));
    _ = queue.removeMin();
    try std.testing.expectEqual(9, queue.min());
    _ = queue.removeMin();
    try std.testing.expectEqual(null, queue.min());
}

test "RangePriorityQueue/delete" {
    var queue = init(std.testing.allocator);
    defer queue.deinit();
    try queue.addRange(OffsetRange.init(8, 10));
    try queue.delete(9);
    try std.testing.expectEqualDeep(&[_]OffsetRange{.init(8, 9)}, queue.getRanges());
    try queue.delete(8);
    try std.testing.expectEqualDeep(&[_]OffsetRange{}, queue.getRanges());

    try queue.addRange(OffsetRange.init(8, 11));
    try queue.delete(9);
    try std.testing.expectEqualDeep(&[_]OffsetRange{ .init(8, 9), .init(10, 11) }, queue.getRanges());
}

test "RangePriorityQueue/toString" {
    var queue = init(std.testing.allocator);
    defer queue.deinit();
    try queue.addRange(OffsetRange.init(8, 10));
    try queue.addRange(OffsetRange.init(11, 12));
    var str: Io.Writer.Allocating = .init(std.testing.allocator);
    defer str.deinit();
    try queue.toString(&str.writer);
    try std.testing.expectEqualStrings("[8, 10) + [11, 12)", str.writer.buffered());
}

test "RangePriorityQueue/addRangeAndResize" {
    const cases = [_]struct {
        initialRanges: []const OffsetRange,
        range: OffsetRange,
        newLength: usize,
        expectedRanges: []const OffsetRange,
    }{
        .{ .initialRanges = &[_]OffsetRange{}, .range = OffsetRange.init(5, 8), .newLength = 4, .expectedRanges = &[_]OffsetRange{.init(5, 9)} },
        .{ .initialRanges = &[_]OffsetRange{.init(10, 15)}, .range = OffsetRange.init(5, 8), .newLength = 4, .expectedRanges = &[_]OffsetRange{ .init(5, 9), .init(11, 16) } },
        .{ .initialRanges = &[_]OffsetRange{.init(1, 5)}, .range = OffsetRange.init(10, 12), .newLength = 2, .expectedRanges = &[_]OffsetRange{ .init(1, 5), .init(10, 12) } },
        .{ .initialRanges = &[_]OffsetRange{.init(5, 8)}, .range = OffsetRange.init(5, 8), .newLength = 3, .expectedRanges = &[_]OffsetRange{.init(5, 8)} },
        .{ .initialRanges = &[_]OffsetRange{ .init(1, 5), .init(10, 15) }, .range = OffsetRange.init(3, 7), .newLength = 0, .expectedRanges = &[_]OffsetRange{ .init(1, 3), .init(6, 11) } },
        .{ .initialRanges = &[_]OffsetRange{ .init(1, 5), .init(10, 15) }, .range = OffsetRange.init(1, 100), .newLength = 0, .expectedRanges = &[_]OffsetRange{} },
    };

    for (cases) |c| {
        var queue = init(std.testing.allocator);
        defer queue.deinit();
        for (c.initialRanges) |rg| {
            try queue.addRange(rg);
        }
        try queue.addRangeAndResize(c.range, c.newLength);
        try std.testing.expectEqualDeep(c.expectedRanges, queue.getRanges());
    }
}

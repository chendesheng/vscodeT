const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const OffsetRange = @import("offsetRange.zig").OffsetRange;
const OffsetRangeSet = @import("offsetRange.zig").OffsetRangeSet;
const findIndex = @import("utils.zig").findIndex;
const usizeAdd = @import("utils.zig").usizeAdd;
const usizeSub = @import("utils.zig").usizeSub;

pub const RangePriorityQueue = struct {
    _ranges: ArrayList(OffsetRange),

    pub fn init(allocator: Allocator) RangePriorityQueue {
        return RangePriorityQueue{ ._ranges = ArrayList(OffsetRange).init(allocator) };
    }

    pub fn getRanges(self: *RangePriorityQueue) []OffsetRange {
        return self._ranges.items;
    }

    pub fn min(self: *RangePriorityQueue) ?usize {
        if (self._ranges.items.len == 0) return null;
        return self._ranges.items[0].start;
    }

    pub fn removeMin(self: *RangePriorityQueue) ?usize {
        if (self._ranges.items.len == 0) return null;
        const range = self._ranges.items[0];
        if (range.start + 1 == range.endExclusive) {
            self._ranges.orderedRemove(0);
        } else {
            self._ranges.items[0] = OffsetRange.init(range.start + 1, range.endExclusive);
        }
        return range.start;
    }

    pub fn delete(self: *RangePriorityQueue, value: usize) !void {
        if (findIndex(OffsetRange, self._ranges.items, value, struct {
            fn pred(r: OffsetRange, val: usize) bool {
                return r.contains(val);
            }
        }.pred)) |idx| {
            const range = self._ranges.items[idx];
            if (range.start == value) {
                if (range.endExclusive == value + 1) {
                    self._ranges.orderedRemove(idx);
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

    pub fn addRange(self: *RangePriorityQueue, range: OffsetRange) !void {
        try OffsetRange.addRange(range, self._ranges);
    }

    pub fn addRangeAndResize(self: *RangePriorityQueue, range: OffsetRange, newLength: usize) !void {
        var idxFirstMightBeIntersecting: usize = 0;
        while (!(idxFirstMightBeIntersecting >= self._ranges.items.len or range.start <= self._ranges.items[idxFirstMightBeIntersecting].endExclusive)) {
            idxFirstMightBeIntersecting += 1;
        }
        var idxFirstIsAfter = idxFirstMightBeIntersecting;
        while (!(idxFirstIsAfter >= self._ranges.items.len or range.endExclusive < self._ranges.items[idxFirstIsAfter].start)) {
            idxFirstIsAfter += 1;
        }
        const delta = usizeSub(newLength, range.length());

        for (self._ranges.items, idxFirstIsAfter..) |_, i| {
            self._ranges.items[i] = self._ranges.items[i].delta(delta);
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
                try self._ranges.insert(idxFirstMightBeIntersecting, newRange);
            } else {
                try self._ranges.replaceRange(idxFirstMightBeIntersecting, idxFirstIsAfter - idxFirstMightBeIntersecting, &[_]OffsetRange{});
            }
        }
    }

    pub fn toString(self: *RangePriorityQueue) !ArrayList(u8) {
        const allocator = self._ranges.allocator;
        var result = ArrayList(u8).init(allocator);
        for (self._ranges.items) |range| {
            const part = try range.toString(allocator);
            defer allocator.free(part);
            try result.append(part);
        }
        return result;
    }
};

const std = @import("std");
const io = std.io;
const BoundedArray = std.BoundedArray;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const findFirstIdxMonotonousOrArrLen = @import("./utils.zig").findFirstIdxMonotonousOrArrLen;
const findLastIdxMonotonous = @import("./utils.zig").findLastIdxMonotonous;
const findLastMonotonous = @import("./utils.zig").findLastMonotonous;
const OffsetRange = @import("./offsetRange.zig").OffsetRange;
const Range = @import("./range.zig").Range;

// A range of lines (1-based).
pub const LineRange = struct {
    // The start line number.
    startLineNumber: usize,

    // The end line number (exclusive).
    endLineNumberExclusive: usize,

    pub fn ofLength(startLineNumber: usize, length_: usize) LineRange {
        return LineRange.init(startLineNumber, startLineNumber + length_);
    }

    pub fn fromRange(range: Range) LineRange {
        return LineRange.init(range.startLineNumber, range.endLineNumber);
    }

    pub fn fromRangeInclusive(range: Range) LineRange {
        return LineRange.init(range.startLineNumber, range.endLineNumber + 1);
    }

    // public static readonly compareByStart: Comparator<LineRange> = compareBy(l => l.startLineNumber, numberComparator);

    pub fn subtract(a: LineRange, b_: ?LineRange) BoundedArray(LineRange, 2) {
        var result = BoundedArray(LineRange, 2).init(0) catch unreachable;
        if (b_) |b| {
            if (a.startLineNumber < b.startLineNumber and b.endLineNumberExclusive < a.endLineNumberExclusive) {
                result.appendAssumeCapacity(.init(a.startLineNumber, b.startLineNumber));
                result.appendAssumeCapacity(.init(b.endLineNumberExclusive, a.endLineNumberExclusive));
            } else if (b.startLineNumber <= a.startLineNumber and a.endLineNumberExclusive <= b.endLineNumberExclusive) {
                //
            } else if (b.endLineNumberExclusive < a.endLineNumberExclusive) {
                result.appendAssumeCapacity(.init(@max(b.endLineNumberExclusive, a.startLineNumber), a.endLineNumberExclusive));
            } else {
                result.appendAssumeCapacity(.init(a.startLineNumber, @min(b.startLineNumber, a.endLineNumberExclusive)));
            }
        } else {
            result.appendAssumeCapacity(a);
        }
        return result;
    }

    // @param lineRanges An array of arrays of of sorted line ranges.
    pub fn joinMany(lineRanges: [][]LineRange) []LineRange {
        if (lineRanges.len == 0) {
            return [_]LineRange{};
        }
        var result = LineRangeSet.init(lineRanges[0]);
        for (lineRanges[1..]) |lineRange| {
            result = result.getUnion(LineRangeSet.init(lineRange));
        }
        return result.ranges;
    }

    pub const JoinBuilder = struct {
        result: LineRangeSet,
        allocator: Allocator,
        pub fn add(self: *JoinBuilder, lineRanges: []LineRange) !void {
            for (lineRanges) |lineRange| {
                try self.result.addRange(lineRange);
            }
        }

        pub fn ranges(self: *JoinBuilder) LineRangeSet {
            return self.result;
        }
    };

    pub fn joinBuilder(allocator: Allocator) JoinBuilder {
        return JoinBuilder{
            .result = LineRangeSet.empty(allocator),
            .allocator = allocator,
        };
    }

    pub fn joinAll(lineRanges: []LineRange) !LineRange {
        if (lineRanges.len == 0) {
            return error.LineRangesCannotBeEmpty;
        }
        var startLineNumber = lineRanges[0].startLineNumber;
        var endLineNumberExclusive = lineRanges[0].endLineNumberExclusive;
        for (lineRanges[1..]) |lineRange| {
            startLineNumber = @min(startLineNumber, lineRange.startLineNumber);
            endLineNumberExclusive = @max(endLineNumberExclusive, lineRange.endLineNumberExclusive);
        }
        return LineRange.init(startLineNumber, endLineNumberExclusive);
    }

    // @internal
    pub fn deserialize(lineRange: ISerializedLineRange) LineRange {
        return LineRange.init(lineRange[0], lineRange[1]);
    }

    pub fn init(startLineNumber: usize, endLineNumberExclusive: usize) LineRange {
        if (startLineNumber > endLineNumberExclusive) {
            // return error.StartLineNumberCannotBeAfterEndLineNumberExclusive;
            unreachable;
        }
        return LineRange{
            .startLineNumber = startLineNumber,
            .endLineNumberExclusive = endLineNumberExclusive,
        };
    }

    // Indicates if this line range contains the given line number.
    pub fn contains(self: LineRange, lineNumber: usize) bool {
        return self.startLineNumber <= lineNumber and lineNumber < self.endLineNumberExclusive;
    }

    pub fn containsRange(self: LineRange, range: LineRange) bool {
        return self.startLineNumber <= range.startLineNumber and range.endLineNumberExclusive <= self.endLineNumberExclusive;
    }

    // Indicates if this line range is empty.
    pub fn isEmpty(self: LineRange) bool {
        return self.startLineNumber == self.endLineNumberExclusive;
    }

    // Moves this line range by the given offset of line numbers.
    pub fn delta(self: LineRange, offset: usize) LineRange {
        return LineRange.init(self.startLineNumber + offset, self.endLineNumberExclusive + offset);
    }

    pub fn deltaLength(self: LineRange, offset: usize) LineRange {
        return LineRange.init(self.startLineNumber, self.endLineNumberExclusive + offset);
    }

    // The number of lines this line range spans.
    pub fn length(self: *const LineRange) usize {
        return self.endLineNumberExclusive - self.startLineNumber;
    }

    // Creates a line range that combines this and the given line range.
    pub fn join(self: *const LineRange, other: LineRange) LineRange {
        return LineRange.init(@min(self.startLineNumber, other.startLineNumber), @max(self.endLineNumberExclusive, other.endLineNumberExclusive));
    }

    pub fn toString(self: *const LineRange, writer: io.AnyWriter) !void {
        try writer.print("[{d},{d})", .{ self.startLineNumber, self.endLineNumberExclusive });
    }

    // The resulting range is empty if the ranges do not intersect, but touch.
    // If the ranges don't even touch, the result is undefined.
    pub fn intersect(self: *const LineRange, other: LineRange) ?LineRange {
        const startLineNumber = @max(self.startLineNumber, other.startLineNumber);
        const endLineNumberExclusive = @min(self.endLineNumberExclusive, other.endLineNumberExclusive);
        if (startLineNumber <= endLineNumberExclusive) {
            return LineRange.init(startLineNumber, endLineNumberExclusive);
        }
        return null;
    }

    pub fn intersectsStrict(self: *const LineRange, other: LineRange) bool {
        return self.startLineNumber < other.endLineNumberExclusive and other.startLineNumber < self.endLineNumberExclusive;
    }

    pub fn intersectsOrTouches(self: *const LineRange, other: LineRange) bool {
        return self.startLineNumber <= other.endLineNumberExclusive and other.startLineNumber <= self.endLineNumberExclusive;
    }

    pub fn equals(self: *const LineRange, other: LineRange) bool {
        return self.startLineNumber == other.startLineNumber and self.endLineNumberExclusive == other.endLineNumberExclusive;
    }

    pub fn toInclusiveRange(self: *const LineRange) ?LineRange {
        if (self.isEmpty()) {
            return null;
        }
        return LineRange.init(self.startLineNumber, self.endLineNumberExclusive - 1);
    }

    // @deprecated Using this function is discouraged because it might lead to bugs: The end position is not guaranteed to be a valid position!
    pub fn toExclusiveRange(self: *const LineRange) LineRange {
        return LineRange.init(self.startLineNumber, self.endLineNumberExclusive);
    }

    pub fn mapToLineArray(self: *const LineRange, comptime T: type, context: anytype, f: fn (lineNumber: usize, ctx: @TypeOf(context)) T) !ArrayList(T) {
        var result = ArrayList(T).init(context.allocator);
        for (self.startLineNumber..self.endLineNumberExclusive) |lineNumber| {
            try result.append(f(lineNumber, context));
        }
        return result;
    }

    pub fn forEach(self: *const LineRange, f: fn (lineNumber: usize) void) void {
        for (self.startLineNumber..self.endLineNumberExclusive) |lineNumber| {
            f(lineNumber);
        }
    }

    // @internal
    pub fn serialize(self: *const LineRange) ISerializedLineRange {
        return [2]usize{ self.startLineNumber, self.endLineNumberExclusive };
    }

    // Converts this 1-based line range to a 0-based offset range (subtracts 1!).
    // @internal
    pub fn toOffsetRange(self: *const LineRange) OffsetRange {
        return OffsetRange.init(self.startLineNumber - 1, self.endLineNumberExclusive - 1);
    }

    pub fn distanceToRange(self: *const LineRange, other: LineRange) usize {
        if (self.endLineNumberExclusive <= other.startLineNumber) {
            return other.startLineNumber - self.endLineNumberExclusive;
        }
        if (other.endLineNumberExclusive <= self.startLineNumber) {
            return self.startLineNumber - other.endLineNumberExclusive;
        }
        return 0;
    }

    pub fn distanceToLine(self: *const LineRange, lineNumber: usize) usize {
        if (self.contains(lineNumber)) {
            return 0;
        }
        if (lineNumber < self.startLineNumber) {
            return self.startLineNumber - lineNumber;
        }
        return lineNumber - self.endLineNumberExclusive;
    }

    pub fn addMargin(self: *const LineRange, marginTop: usize, marginBottom: usize) LineRange {
        return LineRange.init(self.startLineNumber - marginTop, self.endLineNumberExclusive + marginBottom);
    }
};

test "LineRange/inits" {
    var rg = LineRange.ofLength(1, 10);
    try std.testing.expectEqual(1, rg.startLineNumber);
    try std.testing.expectEqual(11, rg.endLineNumberExclusive);

    rg = LineRange.fromRange(Range.init(1, 10, 10, 10));
    try std.testing.expectEqual(1, rg.startLineNumber);
    try std.testing.expectEqual(10, rg.endLineNumberExclusive);

    rg = LineRange.fromRangeInclusive(Range.init(1, 10, 10, 10));
    try std.testing.expectEqual(1, rg.startLineNumber);
    try std.testing.expectEqual(11, rg.endLineNumberExclusive);
}

test "LineRange/subtract" {
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{ .init(1, 3), .init(5, 10) }, LineRange.subtract(.init(1, 10), .init(3, 5)).slice());
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{}, LineRange.subtract(.init(5, 10), .init(3, 40)).slice());
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{.init(5, 10)}, LineRange.subtract(.init(5, 10), null).slice());
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{.init(8, 10)}, LineRange.subtract(.init(5, 10), .init(3, 8)).slice());
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{.init(5, 10)}, LineRange.subtract(.init(5, 10), .init(20, 30)).slice());
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{.init(20, 30)}, LineRange.subtract(.init(20, 30), .init(8, 10)).slice());
}

pub const ISerializedLineRange = [2]usize;

pub const LineRangeSet = struct {
    // Sorted by start line number.
    // No two line ranges are touching or intersecting.
    _normalizedRanges: ArrayList(LineRange),

    pub fn init(
        rgs: ArrayList(LineRange),
    ) LineRangeSet {
        return LineRangeSet{
            ._normalizedRanges = rgs,
        };
    }

    pub fn empty(allocator: Allocator) LineRangeSet {
        return LineRangeSet{
            ._normalizedRanges = ArrayList(LineRange).init(allocator),
        };
    }

    pub fn deinit(self: *LineRangeSet) void {
        self._normalizedRanges.deinit();
    }

    pub fn ranges(self: *const LineRangeSet) []const LineRange {
        return self._normalizedRanges.items;
    }

    pub fn addRange(self: *LineRangeSet, range: LineRange) !void {
        if (range.length() == 0) {
            return;
        }

        // Idea: Find joinRange such that:
        // replaceRange = _normalizedRanges.replaceRange(joinRange, range.joinAll(joinRange.map(idx => this._normalizedRanges[idx])))

        // idx of first element that touches range or that is after range
        const joinRangeStartIdx = findFirstIdxMonotonousOrArrLen(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.endLineNumberExclusive >= rg.startLineNumber;
            }
        }.pred, 0, self._normalizedRanges.items.len);
        // idx of element after { last element that touches range or that is before range }
        const joinRangeEndIdxExclusive = if (findLastIdxMonotonous(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.startLineNumber <= rg.endLineNumberExclusive;
            }
        }.pred, 0, self._normalizedRanges.items.len)) |i| i + 1 else 0;

        if (joinRangeStartIdx == joinRangeEndIdxExclusive) {
            // If there is no element that touches range, then joinRangeStartIdx === joinRangeEndIdxExclusive and that value is the index of the element after range
            try self._normalizedRanges.insert(joinRangeStartIdx, range);
        } else if (joinRangeStartIdx == joinRangeEndIdxExclusive - 1) {
            // Else, there is an element that touches range and in this case it is both the first and last element. Thus we can replace it
            const joinRange = self._normalizedRanges.items[joinRangeStartIdx];
            self._normalizedRanges.items[joinRangeStartIdx] = joinRange.join(range);
        } else {
            // First and last element are different - we need to replace the entire range
            const joinRange = self._normalizedRanges.items[joinRangeStartIdx].join(self._normalizedRanges.items[joinRangeEndIdxExclusive - 1]).join(range);
            try self._normalizedRanges.replaceRange(joinRangeStartIdx, joinRangeEndIdxExclusive - joinRangeStartIdx, &[_]LineRange{joinRange});
        }
    }

    pub fn contains(self: *LineRangeSet, lineNumber: usize) bool {
        if (findLastMonotonous(LineRange, self._normalizedRanges.items, lineNumber, struct {
            fn pred(r: LineRange, n: usize) bool {
                return r.startLineNumber <= n;
            }
        }.pred)) |rangeThatStartsBeforeEnd| {
            return rangeThatStartsBeforeEnd.endLineNumberExclusive > lineNumber;
        }
        return false;
    }

    pub fn intersects(self: *LineRangeSet, range: LineRange) bool {
        if (findLastMonotonous(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.startLineNumber < rg.endLineNumberExclusive;
            }
        }.pred)) |rangeThatStartsBeforeEnd| {
            return rangeThatStartsBeforeEnd.endLineNumberExclusive > range.startLineNumber;
        }
        return false;
    }

    pub fn getUnion(self: *const LineRangeSet, other: LineRangeSet) !LineRangeSet {
        if (self._normalizedRanges.items.len == 0) {
            return other;
        }
        if (other._normalizedRanges.items.len == 0) {
            return self.*;
        }

        var result = ArrayList(LineRange).init(self._normalizedRanges.allocator);
        var i_1: usize = 0;
        var i_2: usize = 0;
        var current: ?LineRange = null;
        while (i_1 < self._normalizedRanges.items.len or i_2 < other._normalizedRanges.items.len) {
            var next: LineRange = undefined;
            if (i_1 < self._normalizedRanges.items.len and i_2 < other._normalizedRanges.items.len) {
                const lineRange1 = self._normalizedRanges.items[i_1];
                const lineRange2 = other._normalizedRanges.items[i_2];
                if (lineRange1.startLineNumber < lineRange2.startLineNumber) {
                    next = lineRange1;
                    i_1 += 1;
                } else {
                    next = lineRange2;
                    i_2 += 1;
                }
            } else if (i_1 < self._normalizedRanges.items.len) {
                next = self._normalizedRanges.items[i_1];
                i_1 += 1;
            } else {
                next = other._normalizedRanges.items[i_2];
                i_2 += 1;
            }

            if (current) |current_| {
                if (current_.endLineNumberExclusive >= next.startLineNumber) {
                    // merge
                    current = LineRange.init(current_.startLineNumber, @max(current_.endLineNumberExclusive, next.endLineNumberExclusive));
                } else {
                    // push
                    try result.append(current_);
                    current = next;
                }
            } else {
                current = next;
            }
        }
        if (current) |current_| {
            try result.append(current_);
        }
        return LineRangeSet.init(result);
    }

    // Subtracts all ranges in this set from `range` and returns the result.
    pub fn subtractFrom(self: *const LineRangeSet, range: LineRange) !LineRangeSet {
        const allocator = self._normalizedRanges.allocator;
        // idx of first element that touches range or that is after range
        const joinRangeStartIdx = findFirstIdxMonotonousOrArrLen(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.endLineNumberExclusive >= rg.startLineNumber;
            }
        }.pred, 0, self._normalizedRanges.items.len);
        // idx of element after { last element that touches range or that is before range }
        const joinRangeEndIdxExclusive = if (findLastIdxMonotonous(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.startLineNumber <= rg.endLineNumberExclusive;
            }
        }.pred, 0, self._normalizedRanges.items.len)) |i| i + 1 else 0;

        if (joinRangeStartIdx == joinRangeEndIdxExclusive) {
            var rgs = ArrayList(LineRange).init(allocator);
            try rgs.append(range);
            return LineRangeSet.init(rgs);
        }

        var result = ArrayList(LineRange).init(allocator);
        var startLineNumber = range.startLineNumber;
        for (joinRangeStartIdx..joinRangeEndIdxExclusive) |i| {
            const r = self._normalizedRanges.items[i];
            if (r.startLineNumber > startLineNumber) {
                try result.append(LineRange.init(startLineNumber, r.startLineNumber));
            }
            startLineNumber = r.endLineNumberExclusive;
        }
        if (startLineNumber < range.endLineNumberExclusive) {
            try result.append(LineRange.init(startLineNumber, range.endLineNumberExclusive));
        }

        return LineRangeSet.init(result);
    }

    pub fn toString(self: *const LineRangeSet, writer: io.AnyWriter) !void {
        for (self._normalizedRanges.items, 0..) |r, i| {
            try r.toString(writer);
            if (i < self._normalizedRanges.items.len - 1) {
                try writer.print(", ", .{});
            }
        }
    }

    pub fn getIntersection(self: *const LineRangeSet, other: LineRangeSet) !LineRangeSet {
        const allocator = self._normalizedRanges.allocator;
        var result = ArrayList(LineRange).init(allocator);

        var i_1: usize = 0;
        var i_2: usize = 0;
        while (i_1 < self._normalizedRanges.items.len and i_2 < other._normalizedRanges.items.len) {
            const r1 = self._normalizedRanges.items[i_1];
            const r2 = other._normalizedRanges.items[i_2];

            if (r1.intersect(r2)) |i| {
                if (!i.isEmpty()) {
                    try result.append(i);
                }
            }

            if (r1.endLineNumberExclusive < r2.endLineNumberExclusive) {
                i_1 += 1;
            } else {
                i_2 += 1;
            }
        }

        return LineRangeSet.init(result);
    }

    pub fn getWithDelta(self: *const LineRangeSet, value: usize) !LineRangeSet {
        const allocator = self._normalizedRanges.allocator;
        var result = ArrayList(LineRange).init(allocator);
        for (self._normalizedRanges.items) |r| {
            try result.append(r.delta(value));
        }
        return LineRangeSet.init(result);
    }
};

test "LineRangeSet/addRange" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(9, 11));
    try set.addRange(.init(11, 12));
    try set.addRange(.init(100, 200));
    try set.addRange(.init(50, 70));
    try set.addRange(.init(30, 60));
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{ .init(1, 12), .init(30, 70), .init(100, 200) }, set.ranges());
}

test "LineRangeSet/contains" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(100, 110));
    for (1..10) |i| {
        try std.testing.expect(set.contains(i));
    }
    try std.testing.expect(!set.contains(10));
    for (100..110) |i| {
        try std.testing.expect(set.contains(i));
    }
    try std.testing.expect(!set.contains(110));
}

test "LineRangeSet/intersects" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(100, 200));
    try std.testing.expect(set.intersects(.init(8, 10)));
    try std.testing.expect(!set.intersects(.init(10, 12)));
    try std.testing.expect(!set.intersects(.init(10, 100)));
}

test "LineRangeSet/getUnion" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(100, 200));

    var set2 = LineRangeSet.empty(std.testing.allocator);
    defer set2.deinit();
    try set2.addRange(.init(10, 100));

    var unioned = try set.getUnion(set2);
    defer unioned.deinit();
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{.init(1, 200)}, unioned.ranges());
}

test "LineRangeSet/subtractFrom" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(100, 200));

    var subtracted = try set.subtractFrom(.init(1, 300));
    defer subtracted.deinit();
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{ .init(10, 100), .init(200, 300) }, subtracted.ranges());
}

test "LineRangeSet/toString" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(100, 200));

    var buf: [1024]u8 = undefined;
    var stream = io.fixedBufferStream(&buf);
    try set.toString(stream.writer().any());
    try std.testing.expectEqualStrings("[1,10), [100,200)", stream.getWritten());
}

test "LineRangeSet/getIntersection" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(100, 200));

    var set2 = LineRangeSet.empty(std.testing.allocator);
    defer set2.deinit();
    try set2.addRange(.init(5, 15));

    try set2.addRange(.init(80, 120));
    var intersection = try set.getIntersection(set2);
    defer intersection.deinit();
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{ .init(5, 10), .init(100, 120) }, intersection.ranges());
}

test "LineRangeSet/getWithDelta" {
    var set = LineRangeSet.empty(std.testing.allocator);
    defer set.deinit();
    try set.addRange(.init(1, 10));
    try set.addRange(.init(100, 200));

    var withDelta = try set.getWithDelta(10);
    defer withDelta.deinit();
    try std.testing.expectEqualSlices(LineRange, &[_]LineRange{ .init(11, 20), .init(110, 210) }, withDelta.ranges());
}

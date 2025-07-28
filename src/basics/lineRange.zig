const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const findFirstIdxMonotonousOrArrLen = @import("./utils.zig").findFirstIdxMonotonousOrArrLen;
const findLastIdxMonotonous = @import("./utils.zig").findLastIdxMonotonous;
const findLastMonotonous = @import("./utils.zig").findLastMonotonous;

// A range of lines (1-based).
pub const LineRange = struct {
    // The start line number.
    startLineNumber: usize,

    // The end line number (exclusive).
    endLineNumberExclusive: usize,

    pub fn ofLength(startLineNumber: usize, length: usize) LineRange {
        return LineRange{
            .startLineNumber = startLineNumber,
            .endLineNumberExclusive = startLineNumber + length,
        };
    }

    pub fn fromRange(range: Range) LineRange {
        return LineRange{
            .startLineNumber = range.startLineNumber,
            .endLineNumberExclusive = range.endLineNumber,
        };
    }

    pub fn fromRangeInclusive(range: Range) LineRange {
        return LineRange{
            .startLineNumber = range.startLineNumber,
            .endLineNumberExclusive = range.endLineNumber + 1,
        };
    }

    // public static readonly compareByStart: Comparator<LineRange> = compareBy(l => l.startLineNumber, numberComparator);

    pub fn subtract(a: LineRange, b: ?LineRange) []LineRange {
        if (b == null) {
            return [_]LineRange{a};
        }
        if (a.startLineNumber < b.startLineNumber and b.endLineNumberExclusive < a.endLineNumberExclusive) {
            return [_]LineRange{
                LineRange{
                    .startLineNumber = a.startLineNumber,
                    .endLineNumberExclusive = b.startLineNumber,
                },
                LineRange{
                    .startLineNumber = b.endLineNumberExclusive,
                    .endLineNumberExclusive = a.endLineNumberExclusive,
                },
            };
        } else if (b.startLineNumber <= a.startLineNumber and a.endLineNumberExclusive <= b.endLineNumberExclusive) {
            return [_]LineRange{};
        } else if (b.endLineNumberExclusive < a.endLineNumberExclusive) {
            return [_]LineRange{
                LineRange{
                    .startLineNumber = @max(b.endLineNumberExclusive, a.startLineNumber),
                    .endLineNumberExclusive = a.endLineNumberExclusive,
                },
            };
        } else {
            return [_]LineRange{
                LineRange{
                    .startLineNumber = a.startLineNumber,
                    .endLineNumberExclusive = @min(b.startLineNumber, a.endLineNumberExclusive),
                },
            };
        }
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

    pub fn join(lineRanges: []LineRange) LineRange {
        if (lineRanges.len == 0) {
            return error.LineRangesCannotBeEmpty;
        }
        var startLineNumber = lineRanges[0].startLineNumber;
        var endLineNumberExclusive = lineRanges[0].endLineNumberExclusive;
        for (lineRanges[1..]) |lineRange| {
            startLineNumber = @min(startLineNumber, lineRange.startLineNumber);
            endLineNumberExclusive = @max(endLineNumberExclusive, lineRange.endLineNumberExclusive);
        }
        return LineRange{
            .startLineNumber = startLineNumber,
            .endLineNumberExclusive = endLineNumberExclusive,
        };
    }

    // @internal
    pub fn deserialize(lineRange: ISerializedLineRange) LineRange {
        return LineRange{
            .startLineNumber = lineRange[0],
            .endLineNumberExclusive = lineRange[1],
        };
    }

    pub fn init(
        startLineNumber: usize,
        endLineNumberExclusive: usize,
    ) LineRange {
        if (startLineNumber > endLineNumberExclusive) {
            return error.StartLineNumberCannotBeAfterEndLineNumberExclusive;
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
        return LineRange{
            .startLineNumber = self.startLineNumber + offset,
            .endLineNumberExclusive = self.endLineNumberExclusive + offset,
        };
    }

    pub fn deltaLength(self: LineRange, offset: usize) LineRange {
        return LineRange{
            .startLineNumber = self.startLineNumber,
            .endLineNumberExclusive = self.endLineNumberExclusive + offset,
        };
    }

    // The number of lines this line range spans.
    pub fn length(self: *LineRange) usize {
        return self.endLineNumberExclusive - self.startLineNumber;
    }

    // Creates a line range that combines this and the given line range.
    pub fn join(self: *LineRange, other: LineRange) LineRange {
        return LineRange{
            .startLineNumber = @min(self.startLineNumber, other.startLineNumber),
            .endLineNumberExclusive = @max(self.endLineNumberExclusive, other.endLineNumberExclusive),
        };
    }

    pub fn toString(self: *LineRange) []const u8 {
        return std.fmt.bufPrint(buf, "[{d},{d})", .{ self.startLineNumber, self.endLineNumberExclusive });
    }

    // The resulting range is empty if the ranges do not intersect, but touch.
    // If the ranges don't even touch, the result is undefined.
    pub fn intersect(self: *LineRange, other: LineRange) ?LineRange {
        const startLineNumber = @max(self.startLineNumber, other.startLineNumber);
        const endLineNumberExclusive = @min(self.endLineNumberExclusive, other.endLineNumberExclusive);
        if (startLineNumber <= endLineNumberExclusive) {
            return LineRange{
                .startLineNumber = startLineNumber,
                .endLineNumberExclusive = endLineNumberExclusive,
            };
        }
        return undefined;
    }

    pub fn intersectsStrict(self: *LineRange, other: LineRange) bool {
        return self.startLineNumber < other.endLineNumberExclusive and other.startLineNumber < self.endLineNumberExclusive;
    }

    pub fn intersectsOrTouches(self: *LineRange, other: LineRange) bool {
        return self.startLineNumber <= other.endLineNumberExclusive and other.startLineNumber <= self.endLineNumberExclusive;
    }

    pub fn equals(self: *LineRange, other: LineRange) bool {
        return self.startLineNumber == other.startLineNumber and self.endLineNumberExclusive == other.endLineNumberExclusive;
    }

    pub fn toInclusiveRange(self: *LineRange) ?LineRange {
        if (self.isEmpty()) {
            return null;
        }
        return LineRange{
            .startLineNumber = self.startLineNumber,
            .endLineNumberExclusive = self.endLineNumberExclusive - 1,
        };
    }

    // @deprecated Using this function is discouraged because it might lead to bugs: The end position is not guaranteed to be a valid position!
    pub fn toExclusiveRange(self: *LineRange) LineRange {
        return LineRange{
            .startLineNumber = self.startLineNumber,
            .endLineNumberExclusive = self.endLineNumberExclusive,
        };
    }

    pub fn mapToLineArray(self: *LineRange, f: fn (lineNumber: usize) T) []T {
        var result: []T = &[_]T{};
        for (self.startLineNumber..self.endLineNumberExclusive) |lineNumber| {
            result.push(f(lineNumber));
        }
        return result;
    }

    pub fn forEach(self: *LineRange, f: fn (lineNumber: usize) void) void {
        for (self.startLineNumber..self.endLineNumberExclusive) |lineNumber| {
            f(lineNumber);
        }
    }

    // @internal
    pub fn serialize(self: *LineRange) [2]usize {
        return [2]usize{ self.startLineNumber, self.endLineNumberExclusive };
    }

    // Converts this 1-based line range to a 0-based offset range (subtracts 1!).
    // @internal
    pub fn toOffsetRange(self: *LineRange) OffsetRange {
        return OffsetRange{
            .start = self.startLineNumber - 1,
            .end = self.endLineNumberExclusive - 1,
        };
    }

    pub fn distanceToRange(self: *LineRange, other: LineRange) usize {
        if (self.endLineNumberExclusive <= other.startLineNumber) {
            return other.startLineNumber - self.endLineNumberExclusive;
        }
        if (other.endLineNumberExclusive <= self.startLineNumber) {
            return self.startLineNumber - other.endLineNumberExclusive;
        }
        return 0;
    }

    pub fn distanceToLine(self: *LineRange, lineNumber: usize) usize {
        if (self.contains(lineNumber)) {
            return 0;
        }
        if (lineNumber < self.startLineNumber) {
            return self.startLineNumber - lineNumber;
        }
        return lineNumber - self.endLineNumberExclusive;
    }

    pub fn addMargin(self: *LineRange, marginTop: usize, marginBottom: usize) LineRange {
        return LineRange{
            .startLineNumber = self.startLineNumber - marginTop,
            .endLineNumberExclusive = self.endLineNumberExclusive + marginBottom,
        };
    }
};

// pub const ISerializedLineRange = [startLineNumber: number, endLineNumberExclusive: number];

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

    pub fn ranges(self: *LineRangeSet) []LineRange {
        return self._normalizedRanges;
    }

    pub fn addRange(self: *LineRangeSet, range: LineRange) void {
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
        }.pred);
        // idx of element after { last element that touches range or that is before range }
        const joinRangeEndIdxExclusive = findLastIdxMonotonous(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.startLineNumber <= rg.endLineNumberExclusive;
            }
        }.pred) + 1;

        if (joinRangeStartIdx == joinRangeEndIdxExclusive) {
            // If there is no element that touches range, then joinRangeStartIdx === joinRangeEndIdxExclusive and that value is the index of the element after range
            self._normalizedRanges.splice(joinRangeStartIdx, 0, range);
        } else if (joinRangeStartIdx == joinRangeEndIdxExclusive - 1) {
            // Else, there is an element that touches range and in this case it is both the first and last element. Thus we can replace it
            const joinRange = self._normalizedRanges[joinRangeStartIdx];
            self._normalizedRanges[joinRangeStartIdx] = joinRange.join(range);
        } else {
            // First and last element are different - we need to replace the entire range
            const joinRange = self._normalizedRanges[joinRangeStartIdx].join(self._normalizedRanges[joinRangeEndIdxExclusive - 1]).join(range);
            self._normalizedRanges.splice(joinRangeStartIdx, joinRangeEndIdxExclusive - joinRangeStartIdx, joinRange);
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

    pub fn getUnion(self: *LineRangeSet, other: LineRangeSet) !LineRangeSet {
        if (self._normalizedRanges.items.len == 0) {
            return other;
        }
        if (other._normalizedRanges.items.len == 0) {
            return self.*;
        }

        var result = ArrayList(LineRange).init(self._normalizedRanges.allocator);
        var i1: usize = 0;
        var i2: usize = 0;
        var current: ?LineRange = null;
        while (i1 < self._normalizedRanges.items.len or i2 < other._normalizedRanges.items.len) {
            var next: ?LineRange = null;
            if (i1 < self._normalizedRanges.items.len and i2 < other._normalizedRanges.items.len) {
                const lineRange1 = self._normalizedRanges.items[i1];
                const lineRange2 = other._normalizedRanges.items[i2];
                if (lineRange1.startLineNumber < lineRange2.startLineNumber) {
                    next = &lineRange1;
                    i1 += 1;
                } else {
                    next = &lineRange2;
                    i2 += 1;
                }
            } else if (i1 < self._normalizedRanges.items.len) {
                next = &self._normalizedRanges.items[i1];
                i1 += 1;
            } else {
                next = &other._normalizedRanges.items[i2];
                i2 += 1;
            }

            if (current == null) {
                current = next;
            } else {
                if (current.endLineNumberExclusive >= next.startLineNumber) {
                    // merge
                    current = LineRange{
                        .startLineNumber = current.startLineNumber,
                        .endLineNumberExclusive = @max(current.endLineNumberExclusive, next.endLineNumberExclusive),
                    };
                } else {
                    // push
                    try result.append(current);
                    current = next;
                }
            }
        }
        if (current != null) {
            try result.append(current);
        }
        return LineRangeSet.init(result);
    }

    // Subtracts all ranges in this set from `range` and returns the result.
    pub fn subtractFrom(self: *LineRangeSet, range: LineRange) !LineRangeSet {
        const allocator = self._normalizedRanges.allocator;
        // idx of first element that touches range or that is after range
        const joinRangeStartIdx = findFirstIdxMonotonousOrArrLen(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.endLineNumberExclusive >= rg.startLineNumber;
            }
        }.pred);
        // idx of element after { last element that touches range or that is before range }
        const joinRangeEndIdxExclusive = findLastIdxMonotonous(LineRange, self._normalizedRanges.items, range, struct {
            fn pred(r: LineRange, rg: LineRange) bool {
                return r.startLineNumber <= rg.endLineNumberExclusive;
            }
        }.pred) + 1;

        if (joinRangeStartIdx == joinRangeEndIdxExclusive) {
            var rgs = ArrayList(LineRange).init(allocator);
            try rgs.append(range);
            return LineRangeSet.init(rgs);
        }

        var result = ArrayList(LineRange).init(allocator);
        var startLineNumber = range.startLineNumber;
        for (joinRangeStartIdx..joinRangeEndIdxExclusive) |i| {
            const r = self._normalizedRanges[i];
            if (r.startLineNumber > startLineNumber) {
                try result.append(LineRange{
                    .startLineNumber = startLineNumber,
                    .endLineNumberExclusive = r.startLineNumber,
                });
            }
            startLineNumber = r.endLineNumberExclusive;
        }
        if (startLineNumber < range.endLineNumberExclusive) {
            try result.append(LineRange{
                .startLineNumber = startLineNumber,
                .endLineNumberExclusive = range.endLineNumberExclusive,
            });
        }

        return LineRangeSet.init(result);
    }

    pub fn toString(self: *LineRangeSet) []const u8 {
        const allocator = self._normalizedRanges.allocator;
        // var buf: [1024]u8 = undefined;
        var result = std.ArrayList(u8).init(allocator);
        for (self._normalizedRanges.items) |r| {
            try result.append(r.toString());
        }
        return result.items;
    }

    pub fn getIntersection(self: *LineRangeSet, other: LineRangeSet) !LineRangeSet {
        const allocator = self._normalizedRanges.allocator;
        var result = ArrayList(LineRange).init(allocator);

        var i1: usize = 0;
        var i2: usize = 0;
        while (i1 < self._normalizedRanges.items.len and i2 < other._normalizedRanges.items.len) {
            const r1 = self._normalizedRanges.items[i1];
            const r2 = other._normalizedRanges.items[i2];

            const i = r1.intersect(r2);
            if (i and !i.isEmpty) {
                try result.append(i);
            }

            if (r1.endLineNumberExclusive < r2.endLineNumberExclusive) {
                i1 += 1;
            } else {
                i2 += 1;
            }
        }

        return LineRangeSet.init(result);
    }

    pub fn getWithDelta(self: *LineRangeSet, value: usize) !LineRangeSet {
        const allocator = self._normalizedRanges.allocator;
        var result = ArrayList(LineRange).init(allocator);
        for (self._normalizedRanges.items) |r| {
            try result.append(r.delta(value));
        }
        return LineRangeSet.init(result);
    }
};

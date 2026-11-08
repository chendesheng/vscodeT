const std = @import("std");
const StringHashMap = std.StringHashMap;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;

pub fn usizeSub(a: usize, b: usize) isize {
    return @as(isize, @intCast(a)) - @as(isize, @intCast(b));
}

pub fn usizeAdd(a: usize, b: isize) usize {
    return @intCast(@as(isize, @intCast(a)) + b);
}

pub fn getKeys(comptime T: type, map: StringHashMap(T)) ArrayList([]const u8) {
    var keys = ArrayList([]const u8).init(map.allocator);
    var iter = map.keyIterator();
    while (iter.next()) |key| {
        try keys.append(key.*);
    }
    return keys;
}

pub fn Pair(comptime T1: type, comptime T2: type) type {
    return struct { first: T1, second: T2 };
}

pub fn pair(first: anytype, second: anytype) Pair(@TypeOf(first), @TypeOf(second)) {
    return Pair(@TypeOf(first), @TypeOf(second)){ .first = first, .second = second };
}

pub fn toIndexedPair(T: type, allocator: Allocator, items: []T) !ArrayList(Pair(*T, usize)) {
    var result = ArrayList(Pair(*T, usize)).init(allocator);
    for (0..items.len) |index| {
        try result.append(pair(&items[index], index));
    }
    return result;
}

pub fn fromIndexedPair(T: type, allocator: Allocator, items: []Pair(*T, usize)) !ArrayList(T) {
    var result = ArrayList(T).init(allocator);
    for (items) |item| {
        try result.append(item.first.*);
    }
    return result;
}

test "toIndexedPair" {
    const allocator = std.testing.allocator;
    var items = [_]i32{ 1, 2, 3 };
    var result = try toIndexedPair(i32, allocator, &items);
    defer result.deinit();
    try std.testing.expectEqual(3, result.items.len);
    try std.testing.expectEqual(1, result.items[0].first.*);
    try std.testing.expectEqual(0, result.items[0].second);
    try std.testing.expectEqual(2, result.items[1].first.*);
    try std.testing.expectEqual(1, result.items[1].second);
    try std.testing.expectEqual(3, result.items[2].first.*);
    try std.testing.expectEqual(2, result.items[2].second);
}

test "fromIndexedPair" {
    const allocator = std.testing.allocator;
    var xs = [_]i32{ 1, 2, 3 };
    var pairs = try toIndexedPair(i32, allocator, &xs);
    defer pairs.deinit();

    const result = try fromIndexedPair(i32, allocator, pairs.items);
    defer result.deinit();

    try std.testing.expectEqual(3, result.items.len);
    try std.testing.expectEqual(1, result.items[0]);
    try std.testing.expectEqual(2, result.items[1]);
    try std.testing.expectEqual(3, result.items[2]);
}

pub fn clamp(value: anytype, min: @TypeOf(value), max: @TypeOf(value)) @TypeOf(value) {
    return @max(min, @min(value, max));
}

pub fn findIndex(T: type, items: []const T, context: anytype, predicate: fn (T, @TypeOf(context)) bool) ?usize {
    for (items, 0..) |item, index| {
        if (predicate(item, context)) return index;
    }
    return null;
}

test "findIndex" {
    const items = [_]i32{ 1, 2, 3 };
    try std.testing.expectEqual(1, findIndex(i32, &items, {}, struct {
        fn pred(item: i32, _: void) bool {
            return item == 2;
        }
    }.pred));
    try std.testing.expectEqual(null, findIndex(i32, &items, {}, struct {
        fn pred(item: i32, _: void) bool {
            return item == 4;
        }
    }.pred));
}

// Finds the last item where predicate is true using binary search.
// `predicate` must be monotonous, i.e. `arr.map(predicate)` must be like `[true, ..., true, false, ..., false]`!
//
// @returns `null` if no item matches, otherwise the last item that matches the predicate.
pub fn findLastMonotonous(comptime T: type, array: []const T, context: anytype, predicate: fn (T, @TypeOf(context)) bool) ?T {
    if (findLastIdxMonotonous(T, array, context, predicate, 0, array.len)) |i| {
        return array[i];
    }
    return null;
}

test "findLastMonotonous" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const lessThanOrEqual = struct {
        fn gen(comptime n: usize) fn (i32, _: void) bool {
            return struct {
                fn pred(item: i32, _: void) bool {
                    return item <= n;
                }
            }.pred;
        }
    }.gen;
    try std.testing.expectEqual(null, findLastMonotonous(i32, &items, {}, lessThanOrEqual(0)));
    try std.testing.expectEqual(1, findLastMonotonous(i32, &items, {}, lessThanOrEqual(1)));
    try std.testing.expectEqual(2, findLastMonotonous(i32, &items, {}, lessThanOrEqual(2)));
    try std.testing.expectEqual(3, findLastMonotonous(i32, &items, {}, lessThanOrEqual(3)));
    try std.testing.expectEqual(4, findLastMonotonous(i32, &items, {}, lessThanOrEqual(4)));
    try std.testing.expectEqual(5, findLastMonotonous(i32, &items, {}, lessThanOrEqual(5)));
    try std.testing.expectEqual(6, findLastMonotonous(i32, &items, {}, lessThanOrEqual(6)));
    try std.testing.expectEqual(7, findLastMonotonous(i32, &items, {}, lessThanOrEqual(7)));
    try std.testing.expectEqual(8, findLastMonotonous(i32, &items, {}, lessThanOrEqual(8)));
    try std.testing.expectEqual(9, findLastMonotonous(i32, &items, {}, lessThanOrEqual(9)));
    try std.testing.expectEqual(10, findLastMonotonous(i32, &items, {}, lessThanOrEqual(10)));
    try std.testing.expectEqual(10, findLastMonotonous(i32, &items, {}, lessThanOrEqual(11)));
}

// Finds the last item where predicate is true using binary search.
// `predicate` must be monotonous, i.e. `arr.map(predicate)` must be like `[true, ..., true, false, ..., false]`!
// @returns `startIdx - 1` if predicate is false for all items, otherwise the index of the last item that matches the predicate.
pub fn findLastIdxMonotonous(comptime T: type, array: []const T, context: anytype, predicate: fn (T, @TypeOf(context)) bool, startIdx: usize, endIdxEx: usize) ?usize {
    var i = startIdx;
    var j = endIdxEx;
    while (i < j) {
        const k = @divFloor(i + j, 2);
        if (predicate(array[k], context)) {
            i = k + 1;
        } else {
            j = k;
        }
    }
    if (i >= 1) return i - 1;
    return null;
}

test "findLastIdxMonotonous" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const lessThanOrEqual = struct {
        fn gen(comptime n: usize) fn (i32, _: void) bool {
            return struct {
                fn pred(item: i32, _: void) bool {
                    return item <= n;
                }
            }.pred;
        }
    }.gen;
    try std.testing.expectEqual(null, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(0), 0, items.len));
    try std.testing.expectEqual(0, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(1), 0, items.len));
    try std.testing.expectEqual(1, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(2), 0, items.len));
    try std.testing.expectEqual(2, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(3), 0, items.len));
    try std.testing.expectEqual(3, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(4), 0, items.len));
    try std.testing.expectEqual(4, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(5), 0, items.len));
    try std.testing.expectEqual(5, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(6), 2, items.len));
    try std.testing.expectEqual(6, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(7), 0, items.len));
    try std.testing.expectEqual(7, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(8), 0, items.len));
    try std.testing.expectEqual(8, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(9), 0, items.len));
    try std.testing.expectEqual(9, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(10), 0, items.len));
    try std.testing.expectEqual(9, findLastIdxMonotonous(i32, &items, {}, lessThanOrEqual(11), 0, items.len));
}

// Finds the first item where predicate is true using binary search.
// `predicate` must be monotonous, i.e. `arr.map(predicate)` must be like `[false, ..., false, true, ..., true]`!
// @returns `endIdxEx` if predicate is false for all items, otherwise the index of the first item that matches the predicate.
/// Finds the first item where `predicate` is true using binary search.
/// `predicate` must be monotonous: `[false, ..., false, true, ..., true]`.
pub fn findFirstMonotonous(comptime T: type, array: []const T, context: anytype, predicate: fn (T, @TypeOf(context)) bool) ?T {
    const idx = findFirstIdxMonotonousOrArrLen(T, array, context, predicate, 0, array.len);
    if (idx == array.len) {
        return null;
    }
    return array[idx];
}

pub fn findFirstIdxMonotonousOrArrLen(comptime T: type, array: []const T, context: anytype, predicate: fn (T, @TypeOf(context)) bool, startIdx: usize, endIdxEx: usize) usize {
    var i = startIdx;
    var j = endIdxEx;
    while (i < j) {
        const k = @divFloor(i + j, 2);
        if (predicate(array[k], context)) {
            j = k;
        } else {
            i = k + 1;
        }
    }
    return i;
}

test "findFirstIdxMonotonousOrArrLen" {
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const greaterThanOrEqual = struct {
        fn gen(comptime n: usize) fn (i32, _: void) bool {
            return struct {
                fn pred(item: i32, _: void) bool {
                    return item >= n;
                }
            }.pred;
        }
    }.gen;
    try std.testing.expectEqual(0, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(0), 0, items.len));
    try std.testing.expectEqual(0, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(1), 0, items.len));
    try std.testing.expectEqual(1, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(2), 0, items.len));
    try std.testing.expectEqual(2, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(3), 0, items.len));
    try std.testing.expectEqual(3, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(4), 0, items.len));
    try std.testing.expectEqual(4, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(5), 0, items.len));
    try std.testing.expectEqual(5, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(6), 2, items.len));
    try std.testing.expectEqual(6, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(7), 0, items.len));
    try std.testing.expectEqual(7, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(8), 0, items.len));
    try std.testing.expectEqual(8, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(9), 0, items.len));
    try std.testing.expectEqual(9, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(10), 0, items.len));
    try std.testing.expectEqual(10, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(11), 0, items.len));
    try std.testing.expectEqual(10, findFirstIdxMonotonousOrArrLen(i32, &items, {}, greaterThanOrEqual(12), 0, items.len));
}

// Word inside a model. Owns its text.
pub const WordAtPosition = struct {
    // The word.
    word: ArrayList(u8),
    // The column where the word starts.
    startColumn: usize,
    // The column where the word ends.
    endColumn: usize,

    pub fn deinit(self: *WordAtPosition) void {
        self.word.deinit();
    }
};

pub const IdleDeadline = struct {
    didTimeout: bool,
    pub fn timeRemaining(self: *IdleDeadline) i64 {
        _ = self;
        return 0;
    }
};

pub fn runWhenGlobalIdle(ctx: anytype, callback: fn (deadline: IdleDeadline, @TypeOf(ctx)) void) void {
    callback(.{ .didTimeout = true }, ctx);
}

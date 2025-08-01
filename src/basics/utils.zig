const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub fn usizeSub(a: usize, b: usize) isize {
    return @as(isize, @intCast(a)) - @as(isize, @intCast(b));
}

pub fn usizeAdd(a: usize, b: isize) usize {
    return @intCast(@as(isize, @intCast(a)) + b);
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
// @returns `undefined` if no item matches, otherwise the last item that matches the predicate.
pub fn findLastMonotonous(comptime T: type, array: []const T, context: anytype, predicate: fn (T, @TypeOf(context)) bool) ?T {
    const idx = findLastIdxMonotonous(T, array, context, predicate, 0, array.len);
    return if (idx == -1) null else array[idx];
}

// Finds the last item where predicate is true using binary search.
// `predicate` must be monotonous, i.e. `arr.map(predicate)` must be like `[true, ..., true, false, ..., false]`!
// @returns `startIdx - 1` if predicate is false for all items, otherwise the index of the last item that matches the predicate.
pub fn findLastIdxMonotonous(comptime T: type, array: []const T, context: anytype, predicate: fn (T, @TypeOf(context)) bool, startIdx: usize, endIdxEx: usize) usize {
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
    return i - 1;
}

// Finds the first item where predicate is true using binary search.
// `predicate` must be monotonous, i.e. `arr.map(predicate)` must be like `[false, ..., false, true, ..., true]`!
// @returns `endIdxEx` if predicate is false for all items, otherwise the index of the first item that matches the predicate.
pub fn findFirstIdxMonotonousOrArrLen(comptime T: type, array: []T, context: anytype, predicate: fn (T, @TypeOf(context)) bool, startIdx: usize, endIdxEx: usize) usize {
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

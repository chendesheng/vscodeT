const std = @import("std");
const ArrayList = std.array_list.Managed;
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

pub fn findIndex(T: type, items: []T, context: anytype, predicate: fn (T, @TypeOf(context)) bool) ?usize {
    for (items, 0..) |item, index| {
        if (predicate(item)) return index;
    }
    return null;
}

pub fn readInt(reader: *std.Io.Reader, comptime T: type, endian: std.builtin.Endian) !T {
    var buf: [1]T = undefined;
    try reader.readSliceEndian(T, buf[0..], endian);
    return buf[0];
}

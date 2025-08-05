const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;

// Uses an unbounded cache to memoize the results of the given function.
pub fn CachedFunction(comptime TArg: type, comptime TComputed: type) type {
    return struct {
        const Self = @This();

        _map: AutoHashMap(TArg, TComputed),
        _map2: StringHashMap(TComputed),
        _fn: *const fn (arg: TArg) TComputed,
        _computeKey: *const fn (allocator: Allocator, arg: TArg) []const u8,

        fn init(allocator: Allocator, f: *const fn (arg: TArg) TComputed, computeKey: *const fn (allocator: Allocator, arg: TArg) []const u8) Self {
            return Self{
                ._map = AutoHashMap(TArg, TComputed).init(allocator),
                ._map2 = StringHashMap(TComputed).init(allocator),
                ._fn = f,
                ._computeKey = computeKey,
            };
        }

        fn deinit(self: *Self) void {
            self._map.deinit();
            var keysIterator = self._map2.keyIterator();
            while (keysIterator.next()) |k| {
                const key = k.*;
                _ = self._map2.remove(key);
                self._map2.allocator.free(key);
            }
            self._map2.deinit();
        }

        pub fn cachedValues(self: *Self) AutoHashMap(TArg, TComputed) {
            return self._map;
        }

        pub fn get(self: *Self, arg: TArg) !TComputed {
            const key = self._computeKey(self._map2.allocator, arg);
            if (self._map2.get(key)) |value| {
                self._map2.allocator.free(key);
                return value;
            }

            const value = self._fn(arg);
            try self._map.put(arg, value);
            try self._map2.put(key, value);
            return value;
        }
    };
}

test "CachedFunction" {
    const toString = struct {
        fn f(arg: i32) []u8 {
            return std.fmt.allocPrint(std.testing.allocator, "{}", .{arg}) catch unreachable;
        }
    }.f;
    const toKey = struct {
        fn f(allocator: Allocator, arg: i32) []u8 {
            return std.fmt.allocPrint(allocator, "{}", .{arg}) catch unreachable;
        }
    }.f;
    var cachedFunction = CachedFunction(i32, []u8).init(std.testing.allocator, toString, toKey);
    defer cachedFunction.deinit();
    const one = try cachedFunction.get(1);
    defer std.testing.allocator.free(one);
    const two = try cachedFunction.get(2);
    defer std.testing.allocator.free(two);
    const one_ = try cachedFunction.get(1);

    try std.testing.expectEqual(cachedFunction.cachedValues().count(), 2);
    try std.testing.expectEqualSlices(u8, "1", one);
    try std.testing.expectEqualSlices(u8, "2", two);
    try std.testing.expectEqual(one.ptr, one_.ptr);
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| {
            return ptr.size == .slice or ptr.size == .many;
        },
        else => false,
    };
}

pub fn Set(comptime T: type) type {
    const equal = if (isSlice(T)) struct {
        fn eq(a: T, b: T) bool {
            return std.mem.eql(@typeInfo(T).pointer.child, a, b);
        }
    }.eq else struct {
        fn eq(a: T, b: T) bool {
            return a == b;
        }
    }.eq;

    return struct {
        const Self = @This();
        list: ArrayList(T),

        pub fn init(allocator: Allocator) Self {
            return Self{
                .list = ArrayList(T).init(allocator),
            };
        }

        pub fn deinit(self: *const Self) void {
            self.list.deinit();
        }

        pub fn add(self: *Self, item: T) !void {
            for (self.list.items) |i| {
                if (equal(i, item)) {
                    return;
                }
            }

            _ = try self.list.append(item);
        }

        pub fn delete(self: *Self, item: T) void {
            for (self.list.items) |i| {
                if (equal(i, item)) {
                    _ = self.list.items.swapRemove(item);
                    return;
                }
            }
        }

        pub fn has(self: *const Self, item: T) bool {
            for (self.list.items) |i| {
                if (equal(i, item)) {
                    return true;
                }
            }

            return false;
        }

        pub fn count(self: *const Self) usize {
            return self.list.items.len;
        }

        pub fn values(self: *const Self) []T {
            return self.list.items;
        }
    };
}

test "Set(usize)" {
    var set = Set(usize).init(std.testing.allocator);
    defer set.deinit();

    try set.add(1);
    try set.add(2);
    try set.add(3);

    try std.testing.expectEqual(3, set.count());
    try set.add(3);
    try std.testing.expectEqual(3, set.count());
}

test "Set(u8)" {
    var set = Set(u8).init(std.testing.allocator);
    defer set.deinit();

    try set.add(1);
    try set.add(2);
    try set.add(3);

    try std.testing.expectEqual(3, set.count());
    try set.add(3);
    try std.testing.expectEqual(3, set.count());
}

test "Set([]u8)" {
    var set = Set([]const u8).init(std.testing.allocator);
    defer set.deinit();

    try set.add("hello");
    try set.add("world");
    try set.add("zig");

    try std.testing.expectEqual(3, set.count());
    try set.add("hello");
    try std.testing.expectEqual(3, set.count());
}

pub fn SetWithKey(comptime V: type) type {
    return struct {
        const Self = @This();
        map: std.StringHashMap(V),
        toKey: *const fn (allocator: Allocator, v: V) []const u8,

        pub fn init(allocator: Allocator, toKeyFn: *const fn (allocator: Allocator, v: V) []const u8) Self {
            return Self{
                .map = std.StringHashMap(V).init(allocator),
                .toKey = toKeyFn,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.keyIterator();
            while (it.next()) |key| {
                self.map.allocator.free(key.*);
            }

            self.map.deinit();
        }

        pub fn add(self: *Self, item: V) !void {
            const allocator = self.map.allocator;
            const key = self.toKey(allocator, item);
            if (self.map.contains(key)) {
                try self.map.put(key, item);
                allocator.free(key);
            } else {
                try self.map.put(key, item);
            }
        }

        pub fn delete(self: *Self, item: V) void {
            const allocator = self.map.allocator;
            const key = self.toKey(allocator, item);
            _ = self.map.remove(key);
        }

        pub fn has(self: *Self, item: V) bool {
            const allocator = self.map.allocator;
            const key = self.toKey(allocator, item);
            return self.map.contains(key);
        }

        pub fn count(self: *Self) usize {
            return self.map.count();
        }
    };
}

const TestStruct = struct {
    a: u8,
    b: u8,
};

fn toKey(allocator: Allocator, v: TestStruct) []const u8 {
    return std.fmt.allocPrint(allocator, "{d}+{d}", .{ v.a, v.b }) catch unreachable;
}

test "SetWithKey" {
    var set = SetWithKey(TestStruct).init(std.testing.allocator, toKey);
    defer set.deinit();

    try set.add(TestStruct{ .a = 1, .b = 2 });
    try set.add(TestStruct{ .a = 3, .b = 4 });

    try std.testing.expectEqual(2, set.count());

    try set.add(TestStruct{ .a = 1, .b = 2 });
    try std.testing.expectEqual(2, set.count());
}

test "Set values" {
    var set = Set(u8).init(std.testing.allocator);
    defer set.deinit();

    try set.add(1);
    try set.add(2);
    try set.add(3);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, set.values());
}

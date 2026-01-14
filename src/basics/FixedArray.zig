const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;

// An array that avoids being sparse by always
// filling up unused indices with a default value.
pub fn FixedArray(comptime T: type) type {
    return struct {
        const Self = @This();

        _store: ArrayList(T),
        _default: T,

        pub fn init(allocator: Allocator, default: T) Self {
            return Self{ ._store = ArrayList(T).init(allocator), ._default = default };
        }

        pub fn deinit(self: *Self) void {
            self._store.deinit();
        }

        pub fn get(self: *const Self, index: usize) T {
            if (index < self._store.items.len) {
                return self._store.items[index];
            }
            return self._default;
        }

        pub fn set(self: *Self, index: usize, value: T) !void {
            while (index >= self._store.items.len) {
                try self._store.append(self._default);
            }
            self._store.items[index] = value;
        }

        pub fn replace(self: *Self, index: usize, oldLength: usize, newLength: usize) !void {
            if (index >= self._store.items.len) {
                return;
            }

            if (oldLength == 0) {
                try self.insert(index, newLength);
                return;
            } else if (newLength == 0) {
                try self.delete(index, oldLength);
                return;
            }

            if (oldLength < newLength) {
                _ = try self._store.addManyAt(index, newLength - oldLength);
            } else if (oldLength > newLength) {
                try self.delete(index + newLength, oldLength - newLength);
            }

            for (0..newLength) |i| {
                self._store.items[index + i] = self._default;
            }
        }

        pub fn delete(self: *Self, deleteIndex: usize, deleteCount: usize) !void {
            if (deleteCount == 0 or deleteIndex >= self._store.items.len) {
                return;
            }
            const cnt = @min(deleteCount, self._store.items.len - deleteIndex);
            try self._store.replaceRange(deleteIndex, cnt, &[_]T{});
        }

        pub fn insert(self: *Self, insertIndex: usize, insertCount: usize) !void {
            if (insertCount == 0 or insertIndex >= self._store.items.len) {
                return;
            }

            const newItems = try self._store.addManyAt(insertIndex, insertCount);
            for (newItems) |*item| {
                item.* = self._default;
            }
        }

        pub fn items(self: *const Self) []const T {
            return self._store.items;
        }
    };
}

test "FixedArray.set" {
    var ones = FixedArray(i32).init(std.testing.allocator, 1);
    defer ones.deinit();
    try ones.set(0, 100);
    try std.testing.expectEqualSlices(i32, &[_]i32{100}, ones.items());
    try ones.set(1, 100);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 100, 100 }, ones.items());
    try ones.set(10, 100);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 100, 100, 1, 1, 1, 1, 1, 1, 1, 1, 100 }, ones.items());
}

test "FixedArray.delete" {
    var ones = FixedArray(i32).init(std.testing.allocator, 1);
    defer ones.deinit();
    try ones.set(5, 100);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 1, 1, 1, 1, 100 }, ones.items());
    try ones.delete(0, 3);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 1, 100 }, ones.items());
    try ones.delete(0, 100);
    try std.testing.expectEqualSlices(i32, &[_]i32{}, ones.items());
}

test "FixedArray.insert" {
    var ones = FixedArray(i32).init(std.testing.allocator, 1);
    defer ones.deinit();
    try ones.set(0, 0);
    try ones.insert(2, 3);
    try std.testing.expectEqualSlices(i32, &[_]i32{0}, ones.items());
    try ones.insert(0, 4);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 1, 1, 1, 0 }, ones.items());
}

test "FixedArray.replace" {
    var ones = FixedArray(i32).init(std.testing.allocator, 1);
    defer ones.deinit();
    try ones.set(0, 0);
    try ones.replace(0, 1, 3);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 1, 1 }, ones.items());
    try ones.replace(0, 2, 1);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 1 }, ones.items());

    try ones.set(0, 100);
    try std.testing.expectEqual(100, ones.get(0));
    try ones.replace(0, 2, 2);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 1 }, ones.items());
}

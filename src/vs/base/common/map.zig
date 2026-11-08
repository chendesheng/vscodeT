// Port of the `LinkedMap`/`LRUCache`/`MRUCache` parts of
// `src/vs/base/common/map.ts`.
//
// `LinkedMap` is a map that also keeps its entries in insertion order, with
// optional reordering on access. Unlike upstream, entries are heap allocated and
// owned by the map, so `remove`/`trimOld`/`trimNew` release them.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Touch = enum {
    None,
    /// Move the entry to the front of the list.
    AsOld,
    /// Move the entry to the back of the list.
    AsNew,
};

/// `AutoContext` rejects slices, so byte-string keys use the string context.
fn KeyContext(comptime K: type) type {
    if (K == []const u8) return std.hash_map.StringContext;
    return std.hash_map.AutoContext(K);
}

pub fn LinkedMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            key: K,
            value: V,
            next: ?*Item = null,
            previous: ?*Item = null,
        };

        pub const Entry = struct {
            key: K,
            value: V,
        };

        allocator: Allocator,
        _map: std.HashMap(K, *Item, KeyContext(K), std.hash_map.default_max_load_percentage),
        _head: ?*Item,
        _tail: ?*Item,
        _size: usize,
        _state: u64,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                ._map = std.HashMap(K, *Item, KeyContext(K), std.hash_map.default_max_load_percentage).init(allocator),
                ._head = null,
                ._tail = null,
                ._size = 0,
                ._state = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self._map.deinit();
        }

        pub fn clear(self: *Self) void {
            var current = self._head;
            while (current) |item| {
                const next = item.next;
                self.allocator.destroy(item);
                current = next;
            }
            self._map.clearRetainingCapacity();
            self._head = null;
            self._tail = null;
            self._size = 0;
            self._state += 1;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self._head == null and self._tail == null;
        }

        pub fn size(self: *const Self) usize {
            return self._size;
        }

        pub fn first(self: *const Self) ?V {
            return if (self._head) |head| head.value else null;
        }

        pub fn last(self: *const Self) ?V {
            return if (self._tail) |tail| tail.value else null;
        }

        pub fn has(self: *const Self, key: K) bool {
            return self._map.contains(key);
        }

        pub fn get(self: *Self, key: K, touch_mode: Touch) ?V {
            const item = self._map.get(key) orelse return null;
            if (touch_mode != .None) {
                self.touch(item, touch_mode);
            }
            return item.value;
        }

        pub fn set(self: *Self, key: K, value: V, touch_mode: Touch) !void {
            if (self._map.get(key)) |item| {
                item.value = value;
                if (touch_mode != .None) {
                    self.touch(item, touch_mode);
                }
                return;
            }

            const item = try self.allocator.create(Item);
            item.* = .{ .key = key, .value = value };
            errdefer self.allocator.destroy(item);

            switch (touch_mode) {
                .AsOld => self.addItemFirst(item),
                else => self.addItemLast(item),
            }
            try self._map.put(key, item);
            self._size += 1;
        }

        pub fn remove(self: *Self, key: K) ?V {
            const entry = self._map.fetchRemove(key) orelse return null;
            const item = entry.value;
            const value = item.value;
            self.removeItem(item);
            self.allocator.destroy(item);
            self._size -= 1;
            return value;
        }

        pub fn delete(self: *Self, key: K) bool {
            return self.remove(key) != null;
        }

        pub fn shift(self: *Self) ?V {
            const item = self._head orelse return null;
            const value = item.value;
            _ = self._map.remove(item.key);
            self.removeItem(item);
            self.allocator.destroy(item);
            self._size -= 1;
            return value;
        }

        /// Removes the oldest `size - newSize` entries.
        pub fn trimOld(self: *Self, new_size: usize) void {
            if (new_size >= self._size) return;
            if (new_size == 0) {
                self.clear();
                return;
            }
            var current = self._head;
            var current_size = self._size;
            while (current != null and current_size > new_size) {
                const item = current.?;
                current = item.next;
                _ = self._map.remove(item.key);
                self.allocator.destroy(item);
                current_size -= 1;
            }
            self._head = current;
            self._size = current_size;
            if (current) |head| head.previous = null;
            self._state += 1;
        }

        /// Removes the newest `size - newSize` entries.
        pub fn trimNew(self: *Self, new_size: usize) void {
            if (new_size >= self._size) return;
            if (new_size == 0) {
                self.clear();
                return;
            }
            var current = self._tail;
            var current_size = self._size;
            while (current != null and current_size > new_size) {
                const item = current.?;
                current = item.previous;
                _ = self._map.remove(item.key);
                self.allocator.destroy(item);
                current_size -= 1;
            }
            self._tail = current;
            self._size = current_size;
            if (current) |tail| tail.next = null;
            self._state += 1;
        }

        fn addItemFirst(self: *Self, item: *Item) void {
            if (self._head == null and self._tail == null) {
                self._tail = item;
            } else if (self._head) |head| {
                item.next = head;
                head.previous = item;
            }
            self._head = item;
            self._state += 1;
        }

        fn addItemLast(self: *Self, item: *Item) void {
            if (self._head == null and self._tail == null) {
                self._head = item;
            } else if (self._tail) |tail| {
                item.previous = tail;
                tail.next = item;
            }
            self._tail = item;
            self._state += 1;
        }

        fn removeItem(self: *Self, item: *Item) void {
            if (item == self._head and item == self._tail) {
                self._head = null;
                self._tail = null;
            } else if (item == self._head) {
                item.next.?.previous = null;
                self._head = item.next;
            } else if (item == self._tail) {
                item.previous.?.next = null;
                self._tail = item.previous;
            } else {
                const next = item.next.?;
                const previous = item.previous.?;
                next.previous = previous;
                previous.next = next;
            }
            item.next = null;
            item.previous = null;
            self._state += 1;
        }

        fn touch(self: *Self, item: *Item, touch_mode: Touch) void {
            switch (touch_mode) {
                .None => return,
                .AsOld => {
                    if (item == self._head) return;
                    self.removeItem(item);
                    self.addItemFirst(item);
                },
                .AsNew => {
                    if (item == self._tail) return;
                    self.removeItem(item);
                    self.addItemLast(item);
                },
            }
        }

        pub const Iterator = struct {
            map: *const Self,
            current: ?*Item,
            state: u64,

            pub fn next(self: *Iterator) ?Entry {
                std.debug.assert(self.map._state == self.state);
                const item = self.current orelse return null;
                self.current = item.next;
                return .{ .key = item.key, .value = item.value };
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .map = self, .current = self._head, .state = self._state };
        }
    };
}

pub fn LRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        map: LinkedMap(K, V),
        _limit: usize,
        _ratio: f64,

        pub fn init(allocator: Allocator, limit_: usize, ratio_: f64) Self {
            return .{
                .map = LinkedMap(K, V).init(allocator),
                ._limit = limit_,
                ._ratio = std.math.clamp(ratio_, 0, 1),
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        pub fn limit(self: *const Self) usize {
            return self._limit;
        }

        pub fn ratio(self: *const Self) f64 {
            return self._ratio;
        }

        pub fn size(self: *const Self) usize {
            return self.map.size();
        }

        pub fn has(self: *const Self, key: K) bool {
            return self.map.has(key);
        }

        pub fn get(self: *Self, key: K) ?V {
            return self.map.get(key, .AsNew);
        }

        pub fn peek(self: *const Self, key: K) ?V {
            // `peek` must not reorder, but `LinkedMap.get` needs a mutable map
            // only when touching; reuse it through a const cast.
            const mutable: *Self = @constCast(self);
            return mutable.map.get(key, .None);
        }

        pub fn set(self: *Self, key: K, value: V) !void {
            try self.map.set(key, value, .AsNew);
            self.checkTrim();
        }

        pub fn remove(self: *Self, key: K) ?V {
            return self.map.remove(key);
        }

        fn checkTrim(self: *Self) void {
            if (self.map.size() > self._limit) {
                const new_size: usize = @intFromFloat(@round(@as(f64, @floatFromInt(self._limit)) * self._ratio));
                self.map.trimOld(new_size);
            }
        }
    };
}

pub fn MRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        map: LinkedMap(K, V),
        _limit: usize,
        _ratio: f64,

        pub fn init(allocator: Allocator, limit_: usize, ratio_: f64) Self {
            return .{
                .map = LinkedMap(K, V).init(allocator),
                ._limit = limit_,
                ._ratio = std.math.clamp(ratio_, 0, 1),
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        pub fn size(self: *const Self) usize {
            return self.map.size();
        }

        pub fn has(self: *const Self, key: K) bool {
            return self.map.has(key);
        }

        pub fn get(self: *Self, key: K) ?V {
            return self.map.get(key, .AsNew);
        }

        pub fn set(self: *Self, key: K, value: V) !void {
            if (self._limit <= self.map.size() and !self.map.has(key)) {
                const target: usize = @intFromFloat(@round(@as(f64, @floatFromInt(self._limit)) * self._ratio));
                self.map.trimNew(target -| 1);
            }
            try self.map.set(key, value, .None);
        }

        pub fn remove(self: *Self, key: K) ?V {
            return self.map.remove(key);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "LinkedMap keeps insertion order" {
    var map = LinkedMap(u32, []const u8).init(testing.allocator);
    defer map.deinit();

    try testing.expect(map.isEmpty());
    try map.set(1, "one", .None);
    try map.set(2, "two", .None);
    try map.set(3, "three", .None);

    try testing.expectEqual(@as(usize, 3), map.size());
    try testing.expectEqualStrings("one", map.first().?);
    try testing.expectEqualStrings("three", map.last().?);

    var it = map.iterator();
    try testing.expectEqual(@as(u32, 1), it.next().?.key);
    try testing.expectEqual(@as(u32, 2), it.next().?.key);
    try testing.expectEqual(@as(u32, 3), it.next().?.key);
    try testing.expect(it.next() == null);
}

test "LinkedMap touch moves entries" {
    var map = LinkedMap(u32, u32).init(testing.allocator);
    defer map.deinit();

    try map.set(1, 10, .None);
    try map.set(2, 20, .None);
    try map.set(3, 30, .None);

    // AsNew moves to the back.
    _ = map.get(1, .AsNew);
    var it = map.iterator();
    try testing.expectEqual(@as(u32, 2), it.next().?.key);
    try testing.expectEqual(@as(u32, 3), it.next().?.key);
    try testing.expectEqual(@as(u32, 1), it.next().?.key);

    // AsOld moves to the front.
    _ = map.get(2, .AsOld);
    var it2 = map.iterator();
    try testing.expectEqual(@as(u32, 2), it2.next().?.key);
    try testing.expectEqual(@as(u32, 3), it2.next().?.key);
    try testing.expectEqual(@as(u32, 1), it2.next().?.key);

    // None does not reorder.
    _ = map.get(2, .None);
    var it3 = map.iterator();
    try testing.expectEqual(@as(u32, 2), it3.next().?.key);

    // Inserting with AsOld prepends.
    try map.set(4, 40, .AsOld);
    try testing.expectEqual(@as(u32, 40), map.first().?);
    // `first`/`last` expose values, so read the key through the iterator.
    var head = map.iterator();
    try testing.expectEqual(@as(u32, 4), head.next().?.key);
}

test "LinkedMap remove, shift and update" {
    var map = LinkedMap(u32, u32).init(testing.allocator);
    defer map.deinit();

    try map.set(1, 10, .None);
    try map.set(2, 20, .None);

    try testing.expectEqual(@as(u32, 10), map.remove(1).?);
    try testing.expect(map.remove(1) == null);
    try testing.expectEqual(@as(usize, 1), map.size());

    try map.set(2, 25, .None);
    try testing.expectEqual(@as(u32, 25), map.get(2, .None).?);
    try testing.expectEqual(@as(usize, 1), map.size());

    try testing.expectEqual(@as(u32, 25), map.shift().?);
    try testing.expect(map.isEmpty());
    try testing.expect(map.shift() == null);
}

test "LinkedMap trimOld and trimNew" {
    var map = LinkedMap(u32, u32).init(testing.allocator);
    defer map.deinit();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try map.set(i, i * 10, .None);
    }

    map.trimOld(6);
    try testing.expectEqual(@as(usize, 6), map.size());
    // Keys 4..9 remain; the values are key * 10.
    try testing.expectEqual(@as(u32, 40), map.first().?);
    var head = map.iterator();
    try testing.expectEqual(@as(u32, 4), head.next().?.key);

    map.trimNew(3);
    try testing.expectEqual(@as(usize, 3), map.size());
    try testing.expectEqual(@as(u32, 40), map.first().?);
    try testing.expectEqual(@as(u32, 60), map.last().?);

    map.trimOld(0);
    try testing.expect(map.isEmpty());
}

test "LRUCache evicts the oldest entries" {
    var cache = LRUCache(u32, u32).init(testing.allocator, 3, 1);
    defer cache.deinit();

    try cache.set(1, 10);
    try cache.set(2, 20);
    try cache.set(3, 30);

    // Touching 1 makes it the most recently used.
    try testing.expectEqual(@as(u32, 10), cache.get(1).?);
    try cache.set(4, 40);

    try testing.expectEqual(@as(usize, 3), cache.size());
    try testing.expect(cache.has(1));
    try testing.expect(!cache.has(2));
    try testing.expect(cache.has(3));
    try testing.expect(cache.has(4));

    // `peek` does not count as a touch.
    try testing.expectEqual(@as(u32, 30), cache.peek(3).?);
    try cache.set(5, 50);
    try testing.expect(!cache.has(3));
}

test "LRUCache trims down to limit * ratio" {
    var cache = LRUCache(u32, u32).init(testing.allocator, 10, 0.5);
    defer cache.deinit();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try cache.set(i, i);
    }
    try testing.expectEqual(@as(usize, 10), cache.size());

    try cache.set(100, 100);
    // 11 entries exceed the limit of 10, so it trims down to 5.
    try testing.expectEqual(@as(usize, 5), cache.size());
    try testing.expectEqual(@as(u32, 6), cache.map.first().?);
}

test "MRUCache evicts the newest entries" {
    var cache = MRUCache(u32, u32).init(testing.allocator, 3, 1);
    defer cache.deinit();

    try cache.set(1, 10);
    try cache.set(2, 20);
    try cache.set(3, 30);
    try cache.set(4, 40);

    try testing.expectEqual(@as(usize, 3), cache.size());
    try testing.expect(cache.has(1));
    try testing.expect(cache.has(4));
    try testing.expect(!cache.has(3) or !cache.has(2));
}

test "LinkedMap works with string keys" {
    var map = LinkedMap([]const u8, u32).init(testing.allocator);
    defer map.deinit();

    try map.set("one", 1, .None);
    try map.set("two", 2, .None);

    try testing.expectEqual(@as(u32, 1), map.get("one", .None).?);
    try testing.expectEqual(@as(u32, 2), map.get("two", .None).?);
    try testing.expect(map.get("three", .None) == null);
}

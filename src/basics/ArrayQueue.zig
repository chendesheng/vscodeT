const std = @import("std");

pub fn ArrayQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []const T,
        firstIdx: usize,
        lastIdx: isize,

        // Constructs a queue that is backed by the given array. Runtime is O(1).
        pub fn init(items: []const T) Self {
            return Self{
                .items = items,
                .firstIdx = 0,
                .lastIdx = @as(isize, @intCast(items.len)) - 1,
            };
        }

        pub fn length(self: *const Self) usize {
            return @intCast(self.lastIdx - @as(isize, @intCast(self.firstIdx)) + 1);
        }

        // Consumes elements from the beginning of the queue as long as the predicate returns true.
        // If no elements were consumed, `null` is returned. Has a runtime of O(result.length).
        pub fn takeWhile(self: *Self, comptime C: type, context: C, predicate: (fn (context: C, value: T) bool)) ?[]const T {
            // P(k) := k <= this.lastIdx && predicate(this.items[k])
            // Find s := min { k | k >= this.firstIdx && !P(k) } and return this.data[this.firstIdx...s)

            var startIdx = self.firstIdx;
            while (startIdx < self.items.len and predicate(context, self.items[startIdx])) {
                startIdx += 1;
            }
            const result = if (startIdx == self.firstIdx) null else self.items[self.firstIdx..startIdx];
            self.firstIdx = startIdx;
            return result;
        }

        // Consumes elements from the end of the queue as long as the predicate returns true.
        // If no elements were consumed, `null` is returned.
        // The result has the same order as the underlying array!
        pub fn takeFromEndWhile(self: *Self, comptime C: type, context: C, predicate: (fn (context: C, value: T) bool)) ?[]const T {
            // P(k) := this.firstIdx >= k && predicate(this.items[k])
            // Find s := max { k | k <= this.lastIdx && !P(k) } and return this.data(s...this.lastIdx]

            var endIdx = self.lastIdx;
            while (endIdx >= 0 and predicate(context, self.items[@intCast(endIdx)])) {
                endIdx -= 1;
            }
            const result = if (endIdx == self.lastIdx) null else self.items[@intCast(endIdx + 1)..@intCast(self.lastIdx + 1)];
            self.lastIdx = endIdx;
            return result;
        }

        pub fn peek(self: *const Self) ?T {
            if (self.length() == 0) {
                return null;
            }
            return self.items[self.firstIdx];
        }

        pub fn peekLast(self: *const Self) ?T {
            if (self.length() == 0) {
                return null;
            }
            return self.items[@intCast(self.lastIdx)];
        }

        pub fn dequeue(self: *Self) ?T {
            if (self.length() == 0) {
                return null;
            }
            const result = self.items[self.firstIdx];
            self.firstIdx += 1;
            return result;
        }

        pub fn removeLast(self: *Self) ?T {
            if (self.length() == 0) {
                return null;
            }
            const result = self.items[@intCast(self.lastIdx)];
            self.lastIdx -= 1;
            return result;
        }

        pub fn takeCount(self: *Self, count: usize) []const T {
            const result = self.items[self.firstIdx .. self.firstIdx + count];
            self.firstIdx += count;
            return result;
        }
    };
}

test "ArrayQueue.length" {
    var queue = ArrayQueue(i32).init(&[_]i32{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(5, queue.length());
    _ = queue.removeLast();
    try std.testing.expectEqual(4, queue.length());
    _ = queue.dequeue();
    try std.testing.expectEqual(3, queue.length());
}

test "ArrayQueue.takeWhile" {
    var queue = ArrayQueue(i32).init(&[_]i32{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2 }, queue.takeWhile(i32, 3, struct {
        fn predicate(ctx: i32, value: i32) bool {
            return value < ctx;
        }
    }.predicate).?);
}

test "ArrayQueue.takeWhile empty" {
    var queue = ArrayQueue(i32).init(&[_]i32{});
    try std.testing.expectEqual(null, queue.takeWhile(i32, 3, struct {
        fn predicate(ctx: i32, value: i32) bool {
            return value > ctx;
        }
    }.predicate));
    try std.testing.expectEqual(0, queue.length());
}

test "ArrayQueue.takeFromEndWhile" {
    var queue = ArrayQueue(i32).init(&[_]i32{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqualSlices(i32, &[_]i32{ 4, 5 }, queue.takeFromEndWhile(i32, 3, struct {
        fn predicate(ctx: i32, value: i32) bool {
            return value > ctx;
        }
    }.predicate).?);
}
test "ArrayQueue.takeFromEndWhile empty" {
    var queue = ArrayQueue(i32).init(&[_]i32{});
    try std.testing.expectEqual(null, queue.takeFromEndWhile(i32, 3, struct {
        fn predicate(ctx: i32, value: i32) bool {
            return value > ctx;
        }
    }.predicate));
    try std.testing.expectEqual(0, queue.length());
}

test "ArrayQueue.takeCount" {
    var queue = ArrayQueue(i32).init(&[_]i32{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, queue.takeCount(3));
}

test "ArrayQueue.removeLast" {
    var queue = ArrayQueue(i32).init(&[_]i32{1});
    try std.testing.expectEqual(1, queue.removeLast().?);
    try std.testing.expectEqual(null, queue.removeLast());
}

test "ArrayQueue.dequeue" {
    var queue = ArrayQueue(i32).init(&[_]i32{ 1, 2 });
    try std.testing.expectEqual(1, queue.dequeue().?);
    try std.testing.expectEqual(2, queue.dequeue().?);
    try std.testing.expectEqual(null, queue.dequeue());
}

test "ArrayQueue.peek" {
    var queue = ArrayQueue(i32).init(&[_]i32{ 1, 2 });
    try std.testing.expectEqual(1, queue.peek().?);
    try std.testing.expectEqual(1, queue.peek().?);
}

test "ArrayQueue.peek empty" {
    var queue = ArrayQueue(i32).init(&[_]i32{});
    try std.testing.expectEqual(null, queue.peek());
}

test "ArrayQueue.peekLast" {
    var queue = ArrayQueue(i32).init(&[_]i32{ 1, 2 });
    try std.testing.expectEqual(2, queue.peekLast().?);
    try std.testing.expectEqual(2, queue.peekLast().?);
}

test "ArrayQueue.peekLast empty" {
    var queue = ArrayQueue(i32).init(&[_]i32{});
    try std.testing.expectEqual(null, queue.peekLast());
}

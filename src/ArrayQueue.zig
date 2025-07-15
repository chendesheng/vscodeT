const std = @import("std");

pub fn ArrayQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []const T,
        firstIdx: usize,
        lastIdx: usize,

        // Constructs a queue that is backed by the given array. Runtime is O(1).
        pub fn init(items: []const T) Self {
            return Self{
                .items = items,
                .firstIdx = 0,
                .lastIdx = items.len - 1,
            };
        }

        pub fn length(self: *const Self) usize {
            return self.lastIdx - self.firstIdx + 1;
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
            while (endIdx >= 0 and predicate(context, self.items[endIdx])) {
                endIdx -= 1;
            }
            const result = if (endIdx == self.lastIdx) null else self.items[endIdx + 1 .. self.lastIdx + 1];
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
            return self.items[self.lastIdx];
        }

        pub fn dequeue(self: *Self) ?T {
            const result = self.items[self.firstIdx];
            self.firstIdx += 1;
            return result;
        }

        pub fn removeLast(self: *Self) ?T {
            const result = self.items[self.lastIdx];
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

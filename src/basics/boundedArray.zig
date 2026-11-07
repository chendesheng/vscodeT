//! Minimal replacement for the `std.BoundedArray` that was removed in Zig
//! 0.17. Only the operations used by this project are provided.
const std = @import("std");

pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn init(len: usize) !Self {
            if (len > capacity) return error.Overflow;
            return .{ .len = len };
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.len < capacity);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn append(self: *Self, item: T) !void {
            if (self.len >= capacity) return error.Overflow;
            self.appendAssumeCapacity(item);
        }

        pub fn slice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn items(self: *const Self) []T {
            return self.buffer[0..self.len];
        }
    };
}

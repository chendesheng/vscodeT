const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Emitter(comptime T: type) type {
    return struct {
        const Self = @This();
        _listeners: std.ArrayList(fn (T) void),

        pub fn init(allocator: Allocator) Self {
            return Self{
                ._listeners = std.ArrayList(fn (T) void).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self._listeners.deinit();
        }

        pub fn fire(self: *Self, evt: T) void {
            for (self._listeners.items) |listener| {
                listener(evt);
            }
        }

        pub fn hasListeners(self: *Self) bool {
            return self._listeners.items.len > 0;
        }

        pub fn event(self: *Self, callback: fn (T) void) !void {
            try self._listeners.append(callback);
        }
    };
}

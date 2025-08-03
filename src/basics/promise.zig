const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const pair = @import("./utils.zig").pair;
const Pair = @import("./utils.zig").Pair;
const Emitter = @import("./event.zig").Emitter;

pub fn PromiseState(comptime T: type) type {
    return union(enum) {
        pending: void,
        fulfilled: T,
        rejected: anyerror,
    };
}

var _allPromises: *ArrayList(*Promise(*anyopaque)) = undefined;

pub fn init(allocator: Allocator) !void {
    _allPromises = try allocator.create(ArrayList(*Promise(*anyopaque)));
    _allPromises.* = ArrayList(*Promise(*anyopaque)).init(allocator);
}

pub fn deinit() void {
    const allocator = _allPromises.allocator;
    _allPromises.deinit();
    allocator.destroy(_allPromises);
}

pub fn add(data: *Promise(*anyopaque)) !void {
    try _allPromises.append(data);
}

pub fn remove(data: *Promise(*anyopaque)) void {
    for (0.._allPromises.items.len) |i| {
        if (_allPromises.items[i] == data) {
            _ = _allPromises.swapRemove(i);
            break;
        }
    }
}

// run inside some event loop
pub fn tick() !void {
    for (_allPromises.items) |p| {
        try p._events.fire(p);
    }

    var len = _allPromises.items.len;
    if (len == 0) {
        return;
    }

    var i = len - 1;
    while (true) {
        if (_allPromises.items[i].isResolved()) {
            _ = _allPromises.swapRemove(i);
            len -= 1;
        }

        if (i == 0) {
            break;
        }
        i -= 1;
    }

    if (len < _allPromises.items.len) {
        try _allPromises.resize(len);
    }
}

pub fn Promise(comptime T: type) type {
    // const info = @typeInfo(T);
    // switch (info) {
    //     .Pointer => {},
    //     else => @compileError("T must be a pointer type"),
    // }

    return struct {
        const Self = @This();

        _lock: std.Thread.Mutex,
        _state: PromiseState(T),
        _events: Emitter(*Self),
        _allocator: Allocator,

        pub fn init(allocator: Allocator, callback: fn (PromiseResolver(T)) anyerror!void) !*Self {
            const self = try allocator.create(Self);
            self.* = Self{
                ._lock = std.Thread.Mutex{},
                ._state = .{ .pending = {} },
                ._events = Emitter(*Self).init(allocator),
                ._allocator = allocator,
            };

            try add(@ptrCast(self));

            try callback(PromiseResolver(T){ .promise = self });
            return self;
        }

        pub fn deinit(self: *Self) void {
            self._events.deinit();
            remove(@ptrCast(self));
            self._allocator.destroy(self);
        }

        pub fn isPending(self: *Self) bool {
            self._lock.lock();
            defer self._lock.unlock();

            return self._state == .pending;
        }

        pub fn isResolved(self: *Self) bool {
            self._lock.lock();
            defer self._lock.unlock();

            return self._state != .pending;
        }

        pub fn then(self: *Self, onFulfilled: fn (value: T) anyerror!void) !void {
            try self._events.event(&onFulfilled, struct {
                fn cb(this: *Self, f: @TypeOf(&onFulfilled)) anyerror!void {
                    this._lock.lock();
                    defer this._lock.unlock();

                    switch (this._state) {
                        .fulfilled => try f(this._state.fulfilled),
                        else => {},
                    }
                }
            }.cb);
        }

        pub fn catch_(self: *Self, onRejected: fn (reason: anyerror) anyerror!void) !void {
            try self._events.event(onRejected, struct {
                fn cb(this: Self, f: @TypeOf(&onRejected)) anyerror!void {
                    this._lock.lock();

                    switch (this._state) {
                        .rejected => {
                            this._lock.unlock();

                            try f(this._state.rejected);
                        },
                        _ => {
                            this._lock.unlock();
                        },
                    }
                }
            }.cb);
        }

        pub fn finally(self: *Self, onFinally: fn () anyerror!void) !void {
            try self._events.event(onFinally, struct {
                fn cb(this: Self, f: @TypeOf(&onFinally)) anyerror!void {
                    this._lock.lock();

                    switch (this._state) {
                        .fulfilled, .rejected => {
                            this._lock.unlock();

                            try f();
                        },
                        _ => {
                            this._lock.unlock();
                        },
                    }
                }
            }.cb);
        }
    };
}

pub fn PromiseResolver(comptime T: type) type {
    return struct {
        const Self = @This();
        promise: *Promise(T),

        pub fn resolve(self: *Self, value: T) void {
            self.promise._lock.lock();
            defer self.promise._lock.unlock();

            if (self.promise._state == .pending) {
                self.promise._state = .{ .fulfilled = value };
            }
        }

        pub fn reject(self: *Self, reason: anyerror) void {
            self.promise._lock.lock();
            defer self.promise._lock.unlock();

            if (self.promise._state == .pending) {
                self.promise._state = .{ .rejected = reason };
            }
        }
    };
}

pub fn promise(comptime T: type, callback: fn (resolver: PromiseResolver(T)) anyerror!void) !*Promise(T) {
    return try Promise(T).init(std.testing.allocator, callback);
}

test "Promise/sleep" {
    const allocator = std.testing.allocator;
    try init(allocator);
    defer deinit();

    const sleeper = try promise(*const []const u8, struct {
        fn callback(resolver: PromiseResolver(*const []const u8)) !void {
            _ = try std.Thread.spawn(.{}, struct {
                fn run(res: @TypeOf(resolver)) void {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    var r = res;
                    r.resolve(&"I'm awake");
                }
            }.run, .{resolver});
        }
    }.callback);
    defer sleeper.deinit();

    try sleeper.then(struct {
        fn onFulfilled(value: *const []const u8) !void {
            try std.testing.expectEqualStrings("I'm awake", value.*);
        }
    }.onFulfilled);

    // "event loop"
    for (0..3) |_| {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        try tick();
    }
    try std.testing.expect(sleeper.isResolved());
}

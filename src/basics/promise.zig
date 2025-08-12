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
    const info = @typeInfo(T);
    switch (info) {
        .pointer => {},
        else => @compileError("T must be a pointer type"),
    }

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
            self._lock.lock();
            defer self._lock.unlock();

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

        fn callOnFulfilled(self: *Self, ctx: anytype, comptime onFulfilled: fn (value: T, ctx: @TypeOf(ctx)) anyerror!void) !void {
            self._lock.lock();

            switch (self._state) {
                .fulfilled => {
                    const value = self._state.fulfilled;
                    self._lock.unlock();
                    try onFulfilled(value, ctx);
                },
                else => {
                    self._lock.unlock();
                },
            }
        }

        fn callOnRejected(self: *Self, ctx: anytype, comptime onRejected: fn (reason: anyerror, ctx: @TypeOf(ctx)) anyerror!void) !void {
            self._lock.lock();

            switch (self._state) {
                .rejected => {
                    const reason = self._state.rejected;
                    self._lock.unlock();
                    try onRejected(reason, ctx);
                },
                else => {
                    self._lock.unlock();
                },
            }
        }

        fn callOnFinally(self: *Self, ctx: anytype, comptime onFinally: fn (promise: *Self, ctx: @TypeOf(ctx)) anyerror!void) !void {
            self._lock.lock();

            switch (self._state) {
                .fulfilled, .rejected => {
                    self._lock.unlock();
                    try onFinally(self, ctx);
                },
                else => {
                    self._lock.unlock();
                },
            }
        }

        pub fn then(self: *Self, ctx: anytype, comptime onFulfilled: fn (value: T, ctx: @TypeOf(ctx)) anyerror!void) !void {
            if (self.isResolved()) {
                try self.callOnFulfilled(ctx, onFulfilled);
                return;
            }

            try self._events.event(ctx, struct {
                fn cb(this: *Self, ctx_: @TypeOf(ctx)) anyerror!void {
                    try this.callOnFulfilled(ctx_, onFulfilled);
                }
            }.cb);
        }

        pub fn catch_(self: *Self, ctx: anytype, comptime onRejected: fn (reason: anyerror, ctx: @TypeOf(ctx)) anyerror!void) !void {
            if (self.isResolved()) {
                try self.callOnRejected(ctx, onRejected);
                return;
            }

            try self._events.event(ctx, struct {
                fn cb(this: *Self, ctx_: @TypeOf(ctx)) anyerror!void {
                    try this.callOnRejected(ctx_, onRejected);
                }
            }.cb);
        }

        pub fn finally(self: *Self, ctx: anytype, comptime onFinally: fn (promise: *Self, ctx: @TypeOf(ctx)) anyerror!void) !void {
            if (self.isResolved()) {
                try self.callOnFinally(ctx, onFinally);
                return;
            }

            try self._events.event(ctx, struct {
                fn cb(this: *Self, ctx_: @TypeOf(ctx)) anyerror!void {
                    try this.callOnFinally(ctx_, onFinally);
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

test "Promise/resolve" {
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

    var fulfilled: bool = false;
    _ = try sleeper.then(&fulfilled, struct {
        fn onFulfilled(value: *const []const u8, fulfilled_: *bool) !void {
            try std.testing.expectEqualStrings("I'm awake", value.*);
            fulfilled_.* = true;
        }
    }.onFulfilled);

    var rejected: bool = false;
    _ = try sleeper.catch_(&rejected, struct {
        fn onRejected(_: anyerror, rejected_: *bool) !void {
            rejected_.* = true;
        }
    }.onRejected);

    var finally_called: bool = false;
    _ = try sleeper.finally(&finally_called, struct {
        fn onFinally(p: *Promise(*const []const u8), finally_called_: *bool) !void {
            finally_called_.* = true;
            p.deinit();
        }
    }.onFinally);

    try std.testing.expect(!fulfilled);
    try std.testing.expect(!rejected);
    try std.testing.expect(!finally_called);

    // "event loop"
    for (0..3) |_| {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        try tick();
    }
    try std.testing.expect(fulfilled);
    try std.testing.expect(!rejected);
    try std.testing.expect(finally_called);
}

test "Promise/catch" {
    const allocator = std.testing.allocator;
    try init(allocator);
    defer deinit();

    const sleeper = try promise(*const []const u8, struct {
        fn callback(resolver: PromiseResolver(*const []const u8)) !void {
            _ = try std.Thread.spawn(.{}, struct {
                fn run(res: @TypeOf(resolver)) void {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    var r = res;
                    r.reject(error.TestError);
                }
            }.run, .{resolver});
        }
    }.callback);

    var fulfilled: bool = false;
    try sleeper.then(&fulfilled, struct {
        fn onFulfilled(_: *const []const u8, fulfilled_: *bool) !void {
            fulfilled_.* = true;
        }
    }.onFulfilled);

    var rejected: bool = false;
    try sleeper.catch_(&rejected, struct {
        fn onRejected(reason: anyerror, rejected_: *bool) !void {
            try std.testing.expectEqual(error.TestError, reason);
            rejected_.* = true;
        }
    }.onRejected);

    var finally_called: bool = false;
    try sleeper.finally(&finally_called, struct {
        fn onFinally(p: *Promise(*const []const u8), finally_called_: *bool) !void {
            finally_called_.* = true;
            p.deinit();
        }
    }.onFinally);

    try std.testing.expect(!fulfilled);
    try std.testing.expect(!rejected);
    try std.testing.expect(!finally_called);

    // "event loop"
    for (0..3) |_| {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        try tick();
    }
    try std.testing.expect(!fulfilled);
    try std.testing.expect(rejected);
    try std.testing.expect(finally_called);
}

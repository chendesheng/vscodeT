const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
// The resolver tests drive the promise from a worker thread. The global
// single-threaded instance explicitly does not support concurrency; the test
// runner installs a threaded Io for each test instead.
const io = if (builtin.is_test) std.testing.io else Io.Threaded.global_single_threaded.io();
const ArrayList = std.array_list.Managed;
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

// Dispatch settled promises on the owning event loop. Test/worker resolvers
// may settle concurrently: inspect settlement *before* removing and firing,
// never remove a promise based on a later state read after an empty delivery.
pub fn tick() !void {
    var index: usize = 0;
    while (index < _allPromises.items.len) {
        const p = _allPromises.items[index];
        if (!p.isResolved()) {
            index += 1;
            continue;
        }
        _ = _allPromises.orderedRemove(index);
        try p._events.fire(p);
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

        _lock: Io.Mutex,
        _state: PromiseState(T),
        _events: Emitter(*Self),
        _allocator: Allocator,

        pub fn init(allocator: Allocator, callback: fn (PromiseResolver(T)) anyerror!void) !*Self {
            const self = try allocator.create(Self);
            self.* = Self{
                ._lock = Io.Mutex.init,
                ._state = .{ .pending = {} },
                ._events = Emitter(*Self).init(allocator),
                ._allocator = allocator,
            };

            try add(@ptrCast(self));

            try callback(PromiseResolver(T){ .promise = self });
            return self;
        }

        pub fn deinit(self: *Self) void {
            self._lock.lockUncancelable(io);

            self._events.deinit();
            remove(@ptrCast(self));

            const allocator = self._allocator;
            self._lock.unlock(io);
            allocator.destroy(self);
        }

        pub fn isPending(self: *Self) bool {
            self._lock.lockUncancelable(io);
            defer self._lock.unlock(io);

            return self._state == .pending;
        }

        pub fn isResolved(self: *Self) bool {
            self._lock.lockUncancelable(io);
            defer self._lock.unlock(io);

            return self._state != .pending;
        }

        fn callOnFulfilled(self: *Self, ctx: anytype, comptime onFulfilled: fn (value: T, ctx: @TypeOf(ctx)) anyerror!void) !void {
            self._lock.lockUncancelable(io);

            switch (self._state) {
                .fulfilled => {
                    const value = self._state.fulfilled;
                    self._lock.unlock(io);
                    try onFulfilled(value, ctx);
                },
                else => {
                    self._lock.unlock(io);
                },
            }
        }

        fn callOnRejected(self: *Self, ctx: anytype, comptime onRejected: fn (reason: anyerror, ctx: @TypeOf(ctx)) anyerror!void) !void {
            self._lock.lockUncancelable(io);

            switch (self._state) {
                .rejected => {
                    const reason = self._state.rejected;
                    self._lock.unlock(io);
                    try onRejected(reason, ctx);
                },
                else => {
                    self._lock.unlock(io);
                },
            }
        }

        fn callOnFinally(self: *Self, ctx: anytype, comptime onFinally: fn (promise: *Self, ctx: @TypeOf(ctx)) anyerror!void) !void {
            self._lock.lockUncancelable(io);

            switch (self._state) {
                .fulfilled, .rejected => {
                    self._lock.unlock(io);
                    try onFinally(self, ctx);
                },
                else => {
                    self._lock.unlock(io);
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
            self.promise._lock.lockUncancelable(io);
            defer self.promise._lock.unlock(io);

            if (self.promise._state == .pending) {
                self.promise._state = .{ .fulfilled = value };
            }
        }

        pub fn reject(self: *Self, reason: anyerror) void {
            self.promise._lock.lockUncancelable(io);
            defer self.promise._lock.unlock(io);

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
        fn callback(_: PromiseResolver(*const []const u8)) !void {}
    }.callback);
    defer sleeper.deinit();

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
        fn onFinally(_: *Promise(*const []const u8), finally_called_: *bool) !void {
            finally_called_.* = true;
        }
    }.onFinally);

    try std.testing.expect(!fulfilled);
    try std.testing.expect(!rejected);
    try std.testing.expect(!finally_called);

    // A pending dispatch cannot consume the callback. Settle from a worker
    // only after registration, and join instead of relying on a sleep race.
    try tick();
    try std.testing.expect(!finally_called);
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(res: PromiseResolver(*const []const u8)) void {
            var r = res;
            r.resolve(&"I'm awake");
        }
    }.run, .{PromiseResolver(*const []const u8){ .promise = sleeper }});
    worker.join();
    try tick();
    try std.testing.expect(fulfilled);
    try std.testing.expect(!rejected);
    try std.testing.expect(finally_called);
}

test "Promise/catch" {
    const allocator = std.testing.allocator;
    try init(allocator);
    defer deinit();

    const sleeper = try promise(*const []const u8, struct {
        fn callback(_: PromiseResolver(*const []const u8)) !void {}
    }.callback);
    defer sleeper.deinit();

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
        fn onFinally(_: *Promise(*const []const u8), finally_called_: *bool) !void {
            finally_called_.* = true;
        }
    }.onFinally);

    try std.testing.expect(!fulfilled);
    try std.testing.expect(!rejected);
    try std.testing.expect(!finally_called);

    // A pending dispatch cannot consume the callback. Settle from a worker
    // only after registration, and join instead of relying on a sleep race.
    try tick();
    try std.testing.expect(!finally_called);
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(res: PromiseResolver(*const []const u8)) void {
            var r = res;
            r.reject(error.TestError);
        }
    }.run, .{PromiseResolver(*const []const u8){ .promise = sleeper }});
    worker.join();
    try tick();
    try std.testing.expect(!fulfilled);
    try std.testing.expect(rejected);
    try std.testing.expect(finally_called);
}

test "Promise: settlement during another callback remains queued for delivery" {
    const allocator = std.testing.allocator;
    try init(allocator);
    defer deinit();
    const T = *const []const u8;
    const Resolver = PromiseResolver(T);
    const Callbacks = struct {
        fn pending(_: Resolver) !void {}
        fn resolveOther(_: T, other: *Promise(T)) !void {
            var resolver = Resolver{ .promise = other };
            resolver.resolve(&"second");
        }
        fn delivered(value: T, count: *usize) !void {
            try std.testing.expectEqualStrings("second", value.*);
            count.* += 1;
        }
    };
    const second = try promise(T, Callbacks.pending);
    defer second.deinit();
    const first = try promise(T, Callbacks.pending);
    defer first.deinit();
    var deliveries: usize = 0;
    try second.then(&deliveries, Callbacks.delivered);
    try first.then(second, Callbacks.resolveOther);
    var resolver = Resolver{ .promise = first };
    resolver.resolve(&"first");

    try tick();
    try tick();
    try tick();
    try std.testing.expectEqual(@as(usize, 1), deliveries);
}

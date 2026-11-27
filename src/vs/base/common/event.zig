const std = @import("std");
const Allocator = std.mem.Allocator;

/// Disposable subscription to an emitter.
pub const SignalSubscription = struct {
    emitter: *anyopaque,
    listener_id: usize,
    remove: *const fn (*anyopaque, usize) void,

    pub fn dispose(self: SignalSubscription) void {
        self.remove(self.emitter, self.listener_id);
    }
};

pub fn Emitter(comptime T: type) type {
    return struct {
        const Self = @This();

        const ListenerWithContext = struct {
            func: *const fn (e: T, ctx: *anyopaque) anyerror!void,
            context: *anyopaque,

            pub fn call(self: *const ListenerWithContext, e: T) anyerror!void {
                try self.func(e, self.context);
            }
        };

        const Listener = union(enum) {
            with_context: ListenerWithContext,
            without_context: *const fn (e: T, ctx: void) anyerror!void,
            plain: *const fn (e: T) void,

            pub fn call(self: *const Listener, e: T) anyerror!void {
                switch (self.*) {
                    .with_context => |listener| try listener.call(e),
                    .without_context => |listener| try listener(e, {}),
                    .plain => |listener| listener(e),
                }
            }
        };

        pub const ListenerId = usize;

        _listeners: std.array_list.Managed(?Listener),

        pub fn init(allocator: Allocator) Self {
            return Self{
                ._listeners = std.array_list.Managed(?Listener).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self._listeners.deinit();
        }

        pub fn fire(self: *Self, evt: T) anyerror!void {
            // A callback may register another listener, reallocating the
            // list, or dispose a later listener. Capture only the initial
            // length and fetch each current slot immediately before delivery.
            const count = self._listeners.items.len;
            for (0..count) |index| {
                if (self._listeners.items[index]) |listener| {
                    try listener.call(evt);
                }
            }
        }

        pub fn listenerCount(self: *const Self) usize {
            var count: usize = 0;
            for (self._listeners.items) |entry| {
                if (entry != null) count += 1;
            }
            return count;
        }

        pub fn hasListeners(self: *const Self) bool {
            for (self._listeners.items) |entry| {
                if (entry != null) return true;
            }
            return false;
        }

        /// Registers a listener and returns an id that can be passed to
        /// `unlisten` when the listener's context is destroyed.
        pub fn listen(self: *Self, ctx: anytype, callback: fn (e: T, ctx: @TypeOf(ctx)) anyerror!void) !ListenerId {
            const listener = switch (@typeInfo(@TypeOf(ctx))) {
                .void => Listener{ .without_context = callback },
                else => Listener{
                    .with_context = ListenerWithContext{
                        .func = struct {
                            fn wrapped(e: T, ctx_opaque: *anyopaque) anyerror!void {
                                const typed_ctx: @TypeOf(ctx) = @ptrCast(@alignCast(ctx_opaque));
                                try callback(e, typed_ctx);
                            }
                        }.wrapped,
                        .context = @ptrCast(@alignCast(@constCast(ctx))),
                    },
                },
            };

            try self._listeners.append(listener);
            return self._listeners.items.len - 1;
        }

        /// Upstream Event subscriptions return an IDisposable.
        pub fn listenDisposable(self: *Self, ctx: anytype, comptime callback: fn (T, @TypeOf(ctx)) anyerror!void) !SignalSubscription {
            const Adapter = struct {
                fn remove(source: *anyopaque, id: usize) void {
                    const emitter: *Self = @ptrCast(@alignCast(source));
                    emitter.unlisten(id);
                }
            };
            return .{ .emitter = self, .listener_id = try self.listen(ctx, callback), .remove = Adapter.remove };
        }

        /// Port of Event.signal. Subscribe to the original emitter in its
        /// normal listener order, ignoring the event payload.
        pub fn listenSignal(self: *Self, ctx: anytype, comptime notify: fn (@TypeOf(ctx)) anyerror!void) !SignalSubscription {
            const Adapter = struct {
                fn call(_: T, target: @TypeOf(ctx)) anyerror!void {
                    try notify(target);
                }
            };
            return self.listenDisposable(ctx, Adapter.call);
        }

        pub fn unlisten(self: *Self, id: ListenerId) void {
            if (id < self._listeners.items.len) {
                self._listeners.items[id] = null;
            }
        }

        pub fn event(self: *Self, ctx: anytype, callback: fn (e: T, ctx: @TypeOf(ctx)) anyerror!void) !void {
            _ = try self.listen(ctx, callback);
        }

        /// Registers a listener that cannot fail.
        pub fn eventVoid(self: *Self, callback: *const fn (e: T) void) !void {
            try self._listeners.append(.{ .plain = callback });
        }
    };
}

test "hasListeners" {
    var emitter = Emitter(i32).init(std.testing.allocator);
    defer emitter.deinit();

    try emitter.event({}, struct {
        fn cb(e: i32, ctx: void) !void {
            _ = e;
            _ = ctx;
        }
    }.cb);

    try std.testing.expect(emitter.hasListeners());
}

test "fire" {
    var emitter = Emitter(i32).init(std.testing.allocator);
    defer emitter.deinit();

    var count: i32 = 0;
    try emitter.event(&count, struct {
        fn cb(e: i32, ctx: *i32) !void {
            ctx.* = e;
        }
    }.cb);

    try emitter.fire(1);
    try std.testing.expectEqual(1, count);
}

test "two listeners" {
    var emitter = Emitter(i32).init(std.testing.allocator);
    defer emitter.deinit();

    var count: i32 = 0;
    try emitter.event(&count, struct {
        fn cb(_: i32, ctx: *i32) !void {
            ctx.* += 1;
        }
    }.cb);

    try emitter.event(&count, struct {
        fn cb(_: i32, ctx: *i32) !void {
            ctx.* += 2;
        }
    }.cb);

    try emitter.fire(1);
    try std.testing.expectEqual(3, count);
}

test "Emitter: registering listeners during delivery does not invalidate the current event" {
    const State = struct {
        emitter: *Emitter(void),
        added: bool = false,
        old_calls: usize = 0,
        new_calls: usize = 0,

        fn register(_: void, self: *@This()) !void {
            if (self.added) return;
            self.added = true;
            for (0..32) |_| _ = try self.emitter.listen(self, addedListener);
        }

        fn oldListener(_: void, self: *@This()) !void {
            self.old_calls += 1;
        }

        fn addedListener(_: void, self: *@This()) !void {
            self.new_calls += 1;
        }
    };
    var emitter = Emitter(void).init(std.testing.allocator);
    defer emitter.deinit();
    var state: State = .{ .emitter = &emitter };
    _ = try emitter.listen(&state, State.register);
    _ = try emitter.listen(&state, State.oldListener);
    try emitter.fire({});
    try std.testing.expectEqual(@as(usize, 1), state.old_calls);
    try std.testing.expectEqual(@as(usize, 0), state.new_calls);
    try emitter.fire({});
    try std.testing.expectEqual(@as(usize, 2), state.old_calls);
    try std.testing.expectEqual(@as(usize, 32), state.new_calls);
}

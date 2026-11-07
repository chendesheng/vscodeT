const std = @import("std");
const Allocator = std.mem.Allocator;

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
            for (self._listeners.items) |*entry| {
                if (entry.*) |listener| {
                    try listener.call(evt);
                }
            }
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

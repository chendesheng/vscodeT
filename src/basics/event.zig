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

            pub fn call(self: *const Listener, e: T) anyerror!void {
                switch (self.*) {
                    .with_context => |listener| try listener.call(e),
                    .without_context => |listener| try listener(e, {}),
                }
            }
        };

        _listeners: std.array_list.Managed(Listener),

        pub fn init(allocator: Allocator) Self {
            return Self{
                ._listeners = std.array_list.Managed(Listener).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self._listeners.deinit();
        }

        pub fn fire(self: *Self, evt: T) anyerror!void {
            for (self._listeners.items) |listener| {
                try listener.call(evt);
            }
        }

        pub fn hasListeners(self: *const Self) bool {
            return self._listeners.items.len > 0;
        }

        pub fn event(self: *Self, ctx: anytype, callback: fn (e: T, ctx: @TypeOf(ctx)) anyerror!void) !void {
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

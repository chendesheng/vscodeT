// Port of `src/vs/workbench/services/extensions/common/rpcProtocol.ts`.
//
// Zig has no promises or dynamic property lookup, so the JavaScript-shaped
// layer is adapted at two boundaries:
//  * local calls take a reply callback instead of returning a promise;
//  * a local actor is a struct with an `invoke` function instead of an object
//    whose methods are looked up by name.
//
// Everything on the wire is the upstream format (docs/extensions.md §5). The
// observable ordering is preserved: a request handler runs, then the
// acknowledgement is sent, then the reply.
const std = @import("std");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const Allocator = std.mem.Allocator;
const cancellation = @import("../../../../base/common/cancellation.zig");
const proxyIdentifier = @import("proxyIdentifier.zig");

pub const MessageType = enum(u8) {
    request_json_args = 1,
    request_json_args_with_cancellation = 2,
    request_mixed_args = 3,
    request_mixed_args_with_cancellation = 4,
    acknowledged = 5,
    cancel = 6,
    reply_ok_empty = 7,
    reply_ok_vs_buffer = 8,
    reply_ok_json = 9,
    reply_ok_json_with_buffers = 10,
    reply_err_error = 11,
    reply_err_empty = 12,
};

pub const ResponsiveState = enum { responsive, unresponsive };

pub const max_frame_size: usize = 64 * 1024 * 1024;
const unresponsive_time_ms: i64 = 3 * 1000;

pub const Arg = union(enum) {
    json: std.json.Value,
    buffer: []const u8,
    undefined,
};

pub const HandlerError = struct {
    name: []const u8,
    message: []const u8,
    stack: []const u8 = "",
    no_telemetry: bool = false,
};

pub const DeferredReply = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque, *RpcProtocol, u32) void,
};

pub const HandlerReply = union(enum) {
    deferred: DeferredReply,
    json: std.json.Value,
    empty,
    buffer: []const u8,
    err: HandlerError,
};

pub const Reply = union(enum) {
    json: std.json.Value,
    empty,
    buffer: []const u8,
    err: HandlerError,
};

pub const ReplyCallback = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, reply: Reply) void,

    pub fn call(self: ReplyCallback, reply: Reply) void {
        self.callback(self.context, reply);
    }
};

pub const ActorHandler = struct {
    context: *anyopaque,
    invoke: *const fn (
        context: *anyopaque,
        method: []const u8,
        args: []const Arg,
        token: ?cancellation.CancellationToken,
        arena: Allocator,
    ) anyerror!HandlerReply,

    pub fn interface(self: *ActorHandler) ActorHandler {
        return self.*;
    }
};

pub const SendFn = *const fn (context: *anyopaque, payload: []const u8) void;

pub const Transport = struct {
    context: *anyopaque,
    send_fn: SendFn,

    pub fn send(self: Transport, payload: []const u8) void {
        self.send_fn(self.context, payload);
    }
};

const CancelContext = struct {
    protocol: *RpcProtocol,
    id: u32,
    fn onCancel(self: *@This()) void {
        self.protocol.sendControl(.cancel, self.id);
    }
};

const PendingReply = struct {
    callback: ReplyCallback,
    cancel_listener: ?@import("../../../../base/common/lifecycle.zig").IDisposable = null,
    cancel_context: ?*CancelContext = null,
};

const CancelHandler = struct {
    source: cancellation.CancellationTokenSource,
    canceling: bool = false,
    finished: bool = false,

    fn finish(self: *CancelHandler, allocator: Allocator) void {
        // A cancellation listener may complete its RPC synchronously. Keep
        // the source alive until MutableToken.cancel has returned.
        if (self.canceling) {
            self.finished = true;
            return;
        }
        self.source.deinit();
        allocator.destroy(self);
    }

    fn cancel(self: *CancelHandler, allocator: Allocator) void {
        if (self.canceling) return;
        self.canceling = true;
        self.source.cancel();
        self.canceling = false;
        if (self.finished) self.finish(allocator);
    }
};

pub const RpcProtocol = struct {
    allocator: Allocator,
    transport: Transport,
    actors: [172]?ActorHandler = @splat(null),
    pending: std.AutoHashMap(u32, PendingReply),
    cancel_handlers: std.AutoHashMap(u32, *CancelHandler),
    last_message_id: u32 = 0,
    disposed: bool = false,
    unacknowledged_count: u32 = 0,
    unresponsive_deadline: i64 = 0,
    responsive_state: ResponsiveState = .responsive,

    pub fn init(allocator: Allocator, transport: Transport) RpcProtocol {
        return .{
            .allocator = allocator,
            .transport = transport,
            .pending = std.AutoHashMap(u32, PendingReply).init(allocator),
            .cancel_handlers = std.AutoHashMap(u32, *CancelHandler).init(allocator),
        };
    }

    pub fn deinit(self: *RpcProtocol) void {
        self.dispose();
        self.pending.deinit();
        self.cancel_handlers.deinit();
    }

    pub fn set(self: *RpcProtocol, identifier: proxyIdentifier.ProxyIdentifier, handler: ActorHandler) void {
        std.debug.assert(identifier.nid != 0 and identifier.nid <= 171);
        self.actors[identifier.nid] = handler;
    }

    pub fn assertRegistered(self: *RpcProtocol, identifiers: []const proxyIdentifier.ProxyIdentifier) !void {
        for (identifiers) |identifier| {
            if (self.actors[identifier.nid] == null) {
                return error.MissingProxyInstance;
            }
        }
    }

    pub fn dispose(self: *RpcProtocol) void {
        if (self.disposed) return;
        self.disposed = true;
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            var pending = entry.value_ptr.*;
            if (pending.cancel_listener) |listener| listener.dispose();
            if (pending.cancel_context) |context| self.allocator.destroy(context);
            pending.callback.call(.{ .err = canceledError() });
        }
        self.pending.clearRetainingCapacity();
        var cancels = self.cancel_handlers.iterator();
        while (cancels.next()) |entry| {
            entry.value_ptr.*.finish(self.allocator);
        }
        self.cancel_handlers.clearRetainingCapacity();
    }

    /// Sends a request to the peer. `callback` runs on the thread that calls
    /// `receive`; the JSON values it receives are only valid during the call.
    pub fn call(
        self: *RpcProtocol,
        identifier: proxyIdentifier.ProxyIdentifier,
        method: []const u8,
        args: []const Arg,
        token: ?cancellation.CancellationToken,
        callback: ReplyCallback,
    ) !u32 {
        if (self.disposed) return error.Canceled;
        if (token) |tok| {
            if (tok.isCancellationRequested()) return error.Canceled;
        }
        if (method.len > 255) return error.MethodNameTooLong;

        const serialized = try self.serializeRequestArguments(args);
        defer self.allocator.free(serialized.payload);

        const id = self.nextRequestId();
        var listener: ?@import("../../../../base/common/lifecycle.zig").IDisposable = null;
        var cancel_context: ?*CancelContext = null;
        errdefer if (listener) |l| l.dispose();
        errdefer if (cancel_context) |context| self.allocator.destroy(context);

        if (token) |tok| {
            const context = try self.allocator.create(CancelContext);
            context.* = .{ .protocol = self, .id = id };
            cancel_context = context;
            listener = tok.onCancellationRequested(cancellation.CancellationListener.from(CancelContext, context, CancelContext.onCancel)) catch |err| {
                self.allocator.destroy(context);
                cancel_context = null;
                return err;
            };
        }

        try self.pending.put(id, .{ .callback = callback, .cancel_listener = listener, .cancel_context = cancel_context });

        var message: std.array_list.Managed(u8) = .init(self.allocator);
        defer message.deinit();
        const message_type: MessageType = if (serialized.mixed)
            (if (token == null) .request_mixed_args else .request_mixed_args_with_cancellation)
        else if (token == null)
            .request_json_args
        else
            .request_json_args_with_cancellation;
        try writeHeader(&message, message_type, id);
        try message.append(identifier.nid);
        try writeShortString(&message, method);
        try message.appendSlice(serialized.payload);
        self.onWillSendRequest();
        self.transport.send(message.items);
        return id;
    }

    /// Cancels a pending request and drops its callback. Late replies are
    /// ignored by `receiveReply`.
    pub fn cancel(self: *RpcProtocol, request_id: u32) void {
        if (self.pending.fetchRemove(request_id)) |entry| {
            if (entry.value.cancel_listener) |listener| listener.dispose();
            if (entry.value.cancel_context) |context| self.allocator.destroy(context);
        }
        if (!self.disposed) self.sendControl(.cancel, request_id);
    }

    /// Sends a notification-shaped call. The upstream protocol still assigns
    /// a request id and expects an empty reply; the callback is ignored.
    pub fn notify(self: *RpcProtocol, identifier: proxyIdentifier.ProxyIdentifier, method: []const u8, args: []const Arg) !void {
        _ = try self.call(identifier, method, args, null, .{
            .context = undefined,
            .callback = struct {
                fn cb(_: *anyopaque, _: Reply) void {}
            }.cb,
        });
    }

    fn nextRequestId(self: *RpcProtocol) u32 {
        self.last_message_id +%= 1;
        if (self.last_message_id == 0) self.last_message_id = 1;
        return self.last_message_id;
    }

    fn sendControl(self: *RpcProtocol, message_type: MessageType, request_id: u32) void {
        if (self.disposed) return;
        var message: std.array_list.Managed(u8) = .init(self.allocator);
        defer message.deinit();
        writeHeader(&message, message_type, request_id) catch return;
        self.transport.send(message.items);
    }

    fn writeHeader(out: *std.array_list.Managed(u8), message_type: MessageType, request_id: u32) !void {
        try out.append(@backingInt(message_type));
        try writeU32(out, request_id);
    }

    const SerializedArgs = struct {
        payload: []u8,
        mixed: bool,
    };

    fn serializeRequestArguments(self: *RpcProtocol, args: []const Arg) !SerializedArgs {
        var needs_mixed = false;
        for (args) |arg| {
            switch (arg) {
                .buffer, .undefined => needs_mixed = true,
                .json => {},
            }
        }
        var out: std.array_list.Managed(u8) = .init(self.allocator);
        errdefer out.deinit();
        if (!needs_mixed) {
            var json_array = std.json.Array.init(self.allocator);
            defer json_array.deinit();
            try json_array.ensureTotalCapacity(args.len);
            for (args) |arg| {
                json_array.appendAssumeCapacity(arg.json);
            }
            const value = std.json.Value{ .array = json_array };
            try writeLongJson(&out, value);
        } else {
            if (args.len > 255) return error.TooManyArguments;
            try out.append(@intCast(args.len));
            for (args) |arg| {
                switch (arg) {
                    .json => |value| {
                        try out.append(1);
                        try writeLongJson(&out, value);
                    },
                    .buffer => |bytes| {
                        try out.append(2);
                        try writeBuffer(&out, bytes);
                    },
                    .undefined => try out.append(4),
                }
            }
        }
        return .{ .payload = try out.toOwnedSlice(), .mixed = needs_mixed };
    }

    pub fn receive(self: *RpcProtocol, payload: []const u8) void {
        if (self.disposed or payload.len < 5) return;
        const message_type: MessageType = std.enums.fromInt(MessageType, payload[0]) orelse return;
        const request_id = std.mem.readInt(u32, payload[1..5], .big);
        switch (message_type) {
            .request_json_args, .request_json_args_with_cancellation => {
                self.receiveRequest(payload, request_id, message_type == .request_json_args_with_cancellation);
            },
            .request_mixed_args, .request_mixed_args_with_cancellation => {
                self.receiveRequest(payload, request_id, message_type == .request_mixed_args_with_cancellation);
            },
            .acknowledged => self.onDidReceiveAcknowledge(),
            .cancel => self.receiveCancel(request_id),
            .reply_ok_empty => self.receiveReply(request_id, .empty),
            .reply_ok_vs_buffer => {
                var offset: usize = 5;
                const bytes = readBuffer(payload, &offset) orelse return;
                self.receiveReply(request_id, .{ .buffer = bytes });
            },
            .reply_ok_json => {
                var offset: usize = 5;
                const json = readLongString(payload, &offset) orelse return;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return;
                self.receiveReply(request_id, .{ .json = value });
            },
            .reply_ok_json_with_buffers => {
                var offset: usize = 5;
                if (offset + 4 > payload.len) return;
                const buffer_count = std.mem.readInt(u32, payload[offset..][0..4], .big);
                offset += 4;
                const json = readLongString(payload, &offset) orelse return;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return;
                var buffers: std.array_list.Managed([]const u8) = .init(self.allocator);
                defer buffers.deinit();
                var index: u32 = 0;
                while (index < buffer_count) : (index += 1) {
                    const bytes = readBuffer(payload, &offset) orelse return;
                    buffers.append(bytes) catch return;
                }
                self.receiveReply(request_id, .{ .json = value });
            },
            .reply_err_error => {
                var offset: usize = 5;
                const json = readLongString(payload, &offset) orelse return;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch return;
                self.receiveReply(request_id, .{ .err = errorFromJson(value) });
            },
            .reply_err_empty => self.receiveReply(request_id, .{ .err = canceledError() }),
        }
    }

    fn receiveRequest(self: *RpcProtocol, payload: []const u8, request_id: u32, with_cancellation: bool) void {
        if (self.cancel_handlers.contains(request_id)) return;
        var offset: usize = 5;
        if (offset >= payload.len) return;
        const nid = payload[offset];
        offset += 1;
        const method = readShortString(payload, &offset) orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const args = decodeRequestArgs(payload, &offset, arena.allocator(), payload[0] == @backingInt(MessageType.request_mixed_args) or payload[0] == @backingInt(MessageType.request_mixed_args_with_cancellation)) catch return;

        const token = if (with_cancellation) self.createCancelHandler(request_id) catch null else null;

        var reply: HandlerReply = .empty;
        const actor = self.actors[nid];
        if (actor == null) {
            reply = .{ .err = .{
                .name = "Error",
                .message = "Unknown actor",
            } };
        } else {
            reply = actor.?.invoke(actor.?.context, method, args, token, arena.allocator()) catch |err| .{ .err = .{
                .name = @errorName(err),
                .message = @errorName(err),
            } };
        }

        self.sendControl(.acknowledged, request_id);
        if (reply == .deferred) {
            reply.deferred.start(reply.deferred.context, self, request_id);
        } else self.sendReply(request_id, reply);
    }

    fn createCancelHandler(self: *RpcProtocol, request_id: u32) !cancellation.CancellationToken {
        const handler = try self.allocator.create(CancelHandler);
        errdefer self.allocator.destroy(handler);
        handler.* = .{ .source = try cancellation.CancellationTokenSource.init(self.allocator) };
        errdefer handler.source.deinit();
        const token = try handler.source.token();
        try self.cancel_handlers.putNoClobber(request_id, handler);
        return token;
    }

    fn finishReceivedRequest(self: *RpcProtocol, request_id: u32) void {
        const entry = self.cancel_handlers.fetchRemove(request_id) orelse return;
        entry.value.finish(self.allocator);
    }

    fn decodeRequestArgs(payload: []const u8, offset: *usize, arena: Allocator, mixed: bool) ![]const Arg {
        var args: std.array_list.Managed(Arg) = .init(arena);
        if (!mixed) {
            const json = readLongString(payload, offset) orelse return error.InvalidMessage;
            const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
            switch (value) {
                .array => |array| {
                    try args.ensureTotalCapacity(array.items.len);
                    for (array.items) |item| args.appendAssumeCapacity(.{ .json = item });
                },
                else => return error.InvalidMessage,
            }
            return args.toOwnedSlice();
        }

        if (offset.* >= payload.len) return error.InvalidMessage;
        const count = payload[offset.*];
        offset.* += 1;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (offset.* >= payload.len) return error.InvalidMessage;
            const arg_type = payload[offset.*];
            offset.* += 1;
            switch (arg_type) {
                1 => {
                    const json = readLongString(payload, offset) orelse return error.InvalidMessage;
                    try args.append(.{ .json = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) });
                },
                2 => {
                    const bytes = readBuffer(payload, offset) orelse return error.InvalidMessage;
                    try args.append(.{ .buffer = bytes });
                },
                3 => {
                    // SerializableObjectWithBuffers: the side table is not
                    // exposed to actors yet; keep the JSON shape so handlers
                    // that only read fields continue to work.
                    if (offset.* + 4 > payload.len) return error.InvalidMessage;
                    const buffer_count = std.mem.readInt(u32, payload[offset.*..][0..4], .big);
                    offset.* += 4;
                    const json = readLongString(payload, offset) orelse return error.InvalidMessage;
                    var buffer_index: u32 = 0;
                    while (buffer_index < buffer_count) : (buffer_index += 1) {
                        _ = readBuffer(payload, offset) orelse return error.InvalidMessage;
                    }
                    try args.append(.{ .json = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) });
                },
                4 => try args.append(.undefined),
                else => return error.InvalidMessage,
            }
        }
        return args.toOwnedSlice();
    }

    pub fn sendReply(self: *RpcProtocol, request_id: u32, reply: HandlerReply) void {
        if (self.disposed) return;
        // Like the upstream promise handlers, release cancellation state only
        // when the invocation settles, including deferred replies.
        defer self.finishReceivedRequest(request_id);
        var message: std.array_list.Managed(u8) = .init(self.allocator);
        defer message.deinit();
        switch (reply) {
            .deferred => unreachable,
            .empty => {
                writeHeader(&message, .reply_ok_empty, request_id) catch return;
            },
            .buffer => |bytes| {
                writeHeader(&message, .reply_ok_vs_buffer, request_id) catch return;
                writeBuffer(&message, bytes) catch return;
            },
            .json => |value| writeReplyJson(&message, request_id, value) catch return,
            .err => |handler_error| {
                if (handler_error.name.len == 0 and handler_error.message.len == 0) {
                    writeHeader(&message, .reply_err_empty, request_id) catch return;
                } else {
                    writeHeader(&message, .reply_err_error, request_id) catch return;
                    var error_arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer error_arena.deinit();
                    var error_object: std.json.ObjectMap = .empty;
                    error_object.put(error_arena.allocator(), "$isError", .{ .bool = true }) catch return;
                    error_object.put(error_arena.allocator(), "name", .{ .string = handler_error.name }) catch return;
                    error_object.put(error_arena.allocator(), "message", .{ .string = handler_error.message }) catch return;
                    error_object.put(error_arena.allocator(), "stack", .{ .string = handler_error.stack }) catch return;
                    error_object.put(error_arena.allocator(), "noTelemetry", .{ .bool = handler_error.no_telemetry }) catch return;
                    writeLongJson(&message, .{ .object = error_object }) catch return;
                }
            },
        }
        self.transport.send(message.items);
    }

    fn writeReplyJson(out: *std.array_list.Managed(u8), request_id: u32, value: std.json.Value) !void {
        writeHeader(out, .reply_ok_json, request_id) catch return;
        try writeLongJson(out, value);
    }

    fn receiveReply(self: *RpcProtocol, request_id: u32, reply: Reply) void {
        const entry = self.pending.fetchRemove(request_id) orelse return;
        if (entry.value.cancel_listener) |listener| listener.dispose();
        if (entry.value.cancel_context) |context| self.allocator.destroy(context);
        entry.value.callback.call(reply);
    }

    fn receiveCancel(self: *RpcProtocol, request_id: u32) void {
        // Cancellation is a signal, not completion. The actor may still be
        // using its token until it produces the reply.
        const handler = self.cancel_handlers.get(request_id) orelse return;
        handler.cancel(self.allocator);
    }

    fn onWillSendRequest(self: *RpcProtocol) void {
        if (self.unacknowledged_count == 0) {
            self.unresponsive_deadline = time_compat.milliTimestamp() + unresponsive_time_ms;
        }
        self.unacknowledged_count += 1;
    }

    fn onDidReceiveAcknowledge(self: *RpcProtocol) void {
        self.unresponsive_deadline = time_compat.milliTimestamp() + unresponsive_time_ms;
        if (self.unacknowledged_count > 0) self.unacknowledged_count -= 1;
        self.responsive_state = .responsive;
    }

    /// Advisory check, matching the upstream one-second scheduler. It never
    /// fails or cancels a request by itself.
    pub fn checkUnresponsive(self: *RpcProtocol, now_ms: i64) void {
        if (self.unacknowledged_count == 0) return;
        if (now_ms > self.unresponsive_deadline) {
            self.responsive_state = .unresponsive;
        }
    }
};

fn canceledError() HandlerError {
    return .{ .name = "Canceled", .message = "Canceled" };
}

fn errorFromJson(value: std.json.Value) HandlerError {
    if (value != .object) return canceledError();
    const object = value.object;
    const name = if (object.get("name")) |item| if (item == .string) item.string else "Error" else "Error";
    const message = if (object.get("message")) |item| if (item == .string) item.string else "" else "";
    const stack = if (object.get("stack")) |item| if (item == .string) item.string else "" else "";
    return .{ .name = name, .message = message, .stack = stack };
}

pub fn cloneJsonValue(allocator: Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .array => |array| blk: {
            const out = try allocator.alloc(std.json.Value, array.items.len);
            for (array.items, 0..) |item, index| out[index] = try cloneJsonValue(allocator, item);
            var result = std.json.Array.init(allocator);
            try result.appendSlice(out);
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var out: std.json.ObjectMap = .empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try out.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

fn writeU32(out: *std.array_list.Managed(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try out.appendSlice(&bytes);
}

fn writeShortString(out: *std.array_list.Managed(u8), text: []const u8) !void {
    if (text.len > 255) return error.MethodNameTooLong;
    try out.append(@intCast(text.len));
    try out.appendSlice(text);
}

fn writeLongString(out: *std.array_list.Managed(u8), text: []const u8) !void {
    if (text.len > std.math.maxInt(u32)) return error.StringTooLong;
    try writeU32(out, @intCast(text.len));
    try out.appendSlice(text);
}

fn writeBuffer(out: *std.array_list.Managed(u8), bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.BufferTooLong;
    try writeU32(out, @intCast(bytes.len));
    try out.appendSlice(bytes);
}

fn writeLongJson(out: *std.array_list.Managed(u8), value: std.json.Value) !void {
    var writer: std.Io.Writer.Allocating = .init(out.allocator);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    const text = writer.written();
    try writeLongString(out, text);
}

fn readShortString(payload: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* >= payload.len) return null;
    const length = payload[offset.*];
    offset.* += 1;
    if (offset.* + length > payload.len) return null;
    const result = payload[offset.* .. offset.* + length];
    offset.* += length;
    return result;
}

fn readLongString(payload: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* + 4 > payload.len) return null;
    const length = std.mem.readInt(u32, payload[offset.*..][0..4], .big);
    offset.* += 4;
    if (length > payload.len - offset.*) return null;
    const result = payload[offset.* .. offset.* + length];
    offset.* += length;
    return result;
}

fn readBuffer(payload: []const u8, offset: *usize) ?[]const u8 {
    return readLongString(payload, offset);
}

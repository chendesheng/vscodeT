// Port of the core request/reply cases of
// `src/vs/workbench/services/extensions/test/common/rpcProtocol.test.ts`.
const std = @import("std");
const rpc = @import("../../common/rpcProtocol.zig");
const proxyIdentifier = @import("../../common/proxyIdentifier.zig");

const Capture = struct {
    allocator: std.mem.Allocator,
    frames: std.array_list.Managed([]u8),

    fn init(allocator: std.mem.Allocator) Capture {
        return .{ .allocator = allocator, .frames = .init(allocator) };
    }

    fn deinit(self: *Capture) void {
        for (self.frames.items) |frame| self.allocator.free(frame);
        self.frames.deinit();
    }

    fn transport(self: *Capture) rpc.Transport {
        return .{ .context = self, .send_fn = send };
    }

    fn send(context: *anyopaque, payload: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(context));
        const copy = self.allocator.alloc(u8, payload.len + 4) catch return;
        std.mem.writeInt(u32, copy[0..4], @intCast(payload.len), .big);
        @memcpy(copy[4..], payload);
        self.frames.append(copy) catch self.allocator.free(copy);
    }
};

const CommandActor = struct {
    allocator: std.mem.Allocator,
    called: usize = 0,
    last_method: []const u8 = "",

    fn handler(self: *CommandActor) rpc.ActorHandler {
        return .{ .context = self, .invoke = invoke };
    }

    fn deinit(self: *CommandActor) void {
        if (self.last_method.len > 0) self.allocator.free(self.last_method);
    }

    fn invoke(context: *anyopaque, method: []const u8, args: []const rpc.Arg, token: ?@import("../../../../../base/common/cancellation.zig").CancellationToken, arena: std.mem.Allocator) anyerror!rpc.HandlerReply {
        _ = token;
        _ = arena;
        const self: *CommandActor = @ptrCast(@alignCast(context));
        self.called += 1;
        if (self.last_method.len > 0) self.allocator.free(self.last_method);
        self.last_method = try self.allocator.dupe(u8, method);
        try std.testing.expectEqual(@as(usize, 3), args.len);
        try std.testing.expectEqualStrings("my.command", args[0].json.string);
        return .{ .json = .{ .string = "result" } };
    }
};

fn emptyJsonArray(allocator: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

test "golden request frame for MainThreadCommands.$executeCommand" {
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    var protocol = rpc.RpcProtocol.init(std.testing.allocator, capture.transport());
    defer protocol.deinit();

    var empty = emptyJsonArray(std.testing.allocator);
    defer empty.array.deinit();
    const args = [_]rpc.Arg{
        .{ .json = .{ .string = "my.command" } },
        .{ .json = empty },
        .{ .json = .{ .bool = false } },
    };
    _ = try protocol.call(.{ .nid = 10, .sid = "MainThreadCommands" }, "$executeCommand", &args, null, .{
        .context = undefined,
        .callback = struct {
            fn cb(_: *anyopaque, _: rpc.Reply) void {}
        }.cb,
    });

    try std.testing.expectEqual(@as(usize, 1), capture.frames.items.len);
    const expected = "\x00\x00\x00\x31\x01\x00\x00\x00\x01\x0a\x0f$executeCommand\x00\x00\x00\x17[\"my.command\",[],false]";
    try std.testing.expectEqualSlices(u8, expected, capture.frames.items[0]);
}

test "receiver invokes the actor, then acknowledges, then replies" {
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    var protocol = rpc.RpcProtocol.init(std.testing.allocator, capture.transport());
    defer protocol.deinit();

    var actor = CommandActor{ .allocator = std.testing.allocator };
    defer actor.deinit();
    protocol.set(.{ .nid = 10, .sid = "MainThreadCommands" }, actor.handler());

    var empty = emptyJsonArray(std.testing.allocator);
    defer empty.array.deinit();
    var request = std.array_list.Managed(u8).init(std.testing.allocator);
    defer request.deinit();
    try request.append(@backingInt(rpc.MessageType.request_json_args));
    try appendU32(&request, 7);
    try request.append(10);
    try request.append(15);
    try request.appendSlice("$executeCommand");
    const json = "[\"my.command\",[],false]";
    try appendU32(&request, @intCast(json.len));
    try request.appendSlice(json);

    protocol.receive(request.items);
    try std.testing.expectEqual(@as(usize, 2), capture.frames.items.len);
    try std.testing.expectEqual(@as(u8, @backingInt(rpc.MessageType.acknowledged)), capture.frames.items[0][4]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, capture.frames.items[0][5..9], .big));
    try std.testing.expectEqual(@as(u8, @backingInt(rpc.MessageType.reply_ok_json)), capture.frames.items[1][4]);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, capture.frames.items[1][5..9], .big));
    const length = std.mem.readInt(u32, capture.frames.items[1][9..13], .big);
    try std.testing.expectEqualStrings("\"result\"", capture.frames.items[1][13 .. 13 + length]);
    try std.testing.expectEqual(@as(usize, 1), actor.called);
    try std.testing.expectEqualStrings("$executeCommand", actor.last_method);
}

test "unknown actor produces an error reply" {
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    var protocol = rpc.RpcProtocol.init(std.testing.allocator, capture.transport());
    defer protocol.deinit();

    var request = std.array_list.Managed(u8).init(std.testing.allocator);
    defer request.deinit();
    try request.append(@backingInt(rpc.MessageType.request_json_args));
    try appendU32(&request, 3);
    try request.append(99);
    try request.append(9);
    try request.appendSlice("$whatever");
    const json = "[]";
    try appendU32(&request, json.len);
    try request.appendSlice(json);

    protocol.receive(request.items);
    try std.testing.expectEqual(@as(usize, 2), capture.frames.items.len);
    try std.testing.expectEqual(@as(u8, @backingInt(rpc.MessageType.reply_err_error)), capture.frames.items[1][4]);
}

test "dispose rejects pending replies as canceled" {
    var capture = Capture.init(std.testing.allocator);
    defer capture.deinit();
    var protocol = rpc.RpcProtocol.init(std.testing.allocator, capture.transport());
    defer protocol.deinit();

    var called: usize = 0;
    const Context = struct {
        called: *usize,
        fn callback(context: *anyopaque, reply: rpc.Reply) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called.* += 1;
            switch (reply) {
                .err => |err| std.testing.expectEqualStrings("Canceled", err.name) catch {},
                else => {},
            }
        }
    };
    var context = Context{ .called = &called };
    const args = [_]rpc.Arg{.{ .json = .{ .integer = 1 } }};
    const id = try protocol.call(.{ .nid = 10, .sid = "MainThreadCommands" }, "$getCommands", &args, null, .{ .context = &context, .callback = Context.callback });
    try std.testing.expect(id > 0);
    protocol.dispose();
    try std.testing.expectEqual(@as(usize, 1), called);
}

fn appendU32(out: *std.array_list.Managed(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try out.appendSlice(&bytes);
}

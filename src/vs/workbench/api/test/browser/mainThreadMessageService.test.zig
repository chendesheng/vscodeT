// Terminal integration tests for the upstream main-thread message bridge.
const std = @import("std");
const t = std.testing;
const a = t.allocator;
const MessageService = @import("../../browser/mainThreadMessageService.zig").MainThreadMessageService;
const Service = @import("../../../services/notification/common/notificationService.zig").NotificationService;
const Storage = @import("../../../../platform/storage/common/storage.zig").InMemoryStorageService;
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");
const Packet = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,
    count: usize = 0,
    fn send(ctx: *anyopaque, value: []const u8) void {
        const self: *Packet = @ptrCast(@alignCast(ctx));
        self.len = @min(value.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], value[0..self.len]);
        self.count += 1;
    }
};

test "MainThreadMessageService: nonmodal messages preserve level, source, actions and asynchronous reply" {
    var storage = Storage.init(a);
    defer storage.deinit();
    const notification = try Service.create(a, &storage);
    defer notification.deinit();
    var messages: MessageService = .{ .allocator = a, .notification_service = notification.interface(), .quick_input = undefined };
    defer messages.deinit();
    var packet: Packet = .{};
    var channel = rpc.RpcProtocol.init(a, .{ .context = &packet, .send_fn = Packet.send });
    defer channel.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "[2,\"[Help](https://example.com)\",{\"source\":{\"label\":\"Extension X\",\"identifier\":{\"value\":\"publisher.extension\"}}},[{\"title\":\"Continue\",\"handle\":7}]]", .{});
    defer parsed.deinit();
    var args: [4]rpc.Arg = undefined;
    for (&args, parsed.value.array.items) |*arg, value| arg.* = .{ .json = value };
    const reply = try messages.showMessage(&args);
    try t.expect(reply == .deferred);
    reply.deferred.start(reply.deferred.context, &channel, 23);
    try t.expectEqual(@as(usize, 0), packet.count);
    const item = notification.model.notifications.items[0];
    try t.expectEqual(@as(usize, 1), item.actions.primary.len);
    try t.expectEqualStrings("publisher.extension", item.source_id.?);
    try t.expectEqualStrings("Extension X", item.source.?);
    try t.expectEqualStrings("_extension_message_handle_7", item.actions.primary[0].id());
    try t.expectEqualStrings("Help", item.message.linked_text.nodes[0].link.label);
    try t.expectEqual(@as(u8, 2), @backingInt(item.severity));
    try item.actions.primary[0].execute(null);
    try t.expectEqual(@as(usize, 0), notification.model.notifications.items.len);
    try t.expectEqual(@as(usize, 1), packet.count);
    try t.expectEqual(@as(u8, @backingInt(rpc.MessageType.reply_ok_json)), packet.bytes[0]);
    try t.expectEqual(@as(u8, '7'), packet.bytes[packet.len - 1]);
}

test "MainThreadMessageService: message without actions resolves when dismissed" {
    var storage = Storage.init(a);
    defer storage.deinit();
    const notification = try Service.create(a, &storage);
    defer notification.deinit();
    var messages: MessageService = .{ .allocator = a, .notification_service = notification.interface(), .quick_input = undefined };
    defer messages.deinit();
    var packet: Packet = .{};
    var channel = rpc.RpcProtocol.init(a, .{ .context = &packet, .send_fn = Packet.send });
    defer channel.deinit();
    var choices: std.json.Array = .init(a);
    defer choices.deinit();
    const reply = try messages.showMessage(&.{ .{ .json = .{ .integer = 1 } }, .{ .json = .{ .string = "Information" } }, .{ .json = .null }, .{ .json = .{ .array = choices } } });
    reply.deferred.start(reply.deferred.context, &channel, 1);
    try t.expectEqual(@as(usize, 0), packet.count);
    try t.expectEqual(@as(usize, 1), notification.model.notifications.items.len);
    notification.model.notifications.items[0].close();
    try t.expectEqual(@as(usize, 1), packet.count);
    try t.expectEqual(@as(u8, @backingInt(rpc.MessageType.reply_ok_empty)), packet.bytes[0]);
}

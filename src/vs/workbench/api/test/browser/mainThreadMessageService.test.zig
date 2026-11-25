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
    var messages: MessageService = .{ .allocator = a, .notification_service = notification.interface(), .dialog_service = undefined };
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
    var messages: MessageService = .{ .allocator = a, .notification_service = notification.interface(), .dialog_service = undefined };
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

test "MainThreadMessageService: modal prompts use dialog service and preserve cancel affordance" {
    const ui = @import("ui");
    const DialogService = @import("../../../services/dialogs/common/dialogService.zig").DialogService;
    const Contribution = @import("../../../browser/parts/dialogs/dialog.web.contribution.zig").DialogHandlerContribution;
    var dialogs = DialogService.init(a);
    defer dialogs.deinit();
    const handler = try Contribution.create(a, &dialogs.model);
    defer handler.destroy();
    var packet: Packet = .{};
    var channel = rpc.RpcProtocol.init(a, .{ .context = &packet, .send_fn = Packet.send });
    defer channel.deinit();
    var messages: MessageService = .{ .allocator = a, .notification_service = undefined, .dialog_service = dialogs.interface() };
    defer messages.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\[3,"Modal",{"modal":true,"detail":"Details"},[{"title":"Old Cancel","handle":2,"isCloseAffordance":true},{"title":"First","handle":5},{"title":"Second","handle":6},{"title":"Third","handle":7},{"title":"Dismiss","handle":8,"isCloseAffordance":true}]]
    , .{});
    defer parsed.deinit();
    var args: [4]rpc.Arg = undefined;
    for (&args, parsed.value.array.items) |*arg, value| arg.* = .{ .json = value };
    const first = try messages.showMessage(&args);
    first.deferred.start(first.deferred.context, &channel, 11);
    const second = try messages.showMessage(&args);
    second.deferred.start(second.deferred.context, &channel, 12);
    try t.expectEqual(@as(usize, 0), packet.count);
    try t.expectEqual(@as(usize, 4), handler.current.?.button_count);
    try t.expectEqualStrings("First", handler.current.?.buttonLabel(0).?);
    try t.expectEqualStrings("Third", handler.current.?.buttonLabel(2).?);
    try t.expectEqualStrings("Dismiss", handler.current.?.buttonLabel(3).?);
    try t.expectEqualStrings("Details", handler.current.?.detail);
    try t.expectEqual(.err, handler.current.?.severity);
    var enter: ui.KeyEvent = .{ .key = .enter };
    try t.expect(handler.handleKey(&enter));
    try t.expectEqual(@as(usize, 1), packet.count);
    try t.expectEqual(@as(u8, '5'), packet.bytes[packet.len - 1]);
    var escape: ui.KeyEvent = .{ .key = .escape };
    try t.expect(handler.handleKey(&escape));
    try t.expectEqual(@as(usize, 2), packet.count);
    try t.expectEqual(@as(u8, '8'), packet.bytes[packet.len - 1]);
    try t.expect(!dialogs.hasDialog());
    const last = try messages.showMessage(&args);
    last.deferred.start(last.deferred.context, &channel, 13);
    const queued = try messages.showMessage(&args);
    queued.deferred.start(queued.deferred.context, &channel, 14);
    // Owner disposal closes both active and queued prompts before RPC teardown.
    messages.deinit();
    messages = .{ .allocator = a, .notification_service = undefined, .dialog_service = dialogs.interface() };
    try t.expectEqual(@as(usize, 4), packet.count);
    try t.expect(!dialogs.hasDialog());
    try t.expect(handler.current == null);
}

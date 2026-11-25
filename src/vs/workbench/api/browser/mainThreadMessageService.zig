// Port of `src/vs/workbench/api/browser/mainThreadMessageService.ts`.
// Nonmodal messages are notifications with extension-specific action IDs;
// the terminal modal-dialog adapter still uses the quick input picker.
const std = @import("std");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const notification = @import("../../../platform/notification/common/notification.zig");
const Severity = @import("../../../base/common/severity.zig").Severity;
const Action = @import("../../../base/common/actions.zig").Action;
const IAction = @import("../../../base/common/actions.zig").IAction;
const legacy = @import("../../../platform/notification/common/notificationLegacy.zig").legacyExtensionLinkParsing;
const QuickInputService = @import("../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const Item = @import("../../../platform/quickinput/common/quickInput.zig").QuickPickItem;

pub const MainThreadMessageService = struct {
    allocator: std.mem.Allocator,
    notification_service: notification.INotificationService,
    quick_input: *QuickInputService,
    pending: std.ArrayList(*Message) = .empty,

    pub fn deinit(self: *MainThreadMessageService) void {
        // Dispose outstanding RPC replies before the channel or contribution
        // action contexts are destroyed.
        while (self.pending.items.len > 0) {
            const message = self.pending.items[self.pending.items.len - 1];
            if (message.handle) |handle| handle.close() else message.finish();
            if (std.mem.indexOfScalar(*Message, self.pending.items, message) != null) message.finish();
        }
        self.pending.deinit(self.allocator);
    }
    pub fn showMessage(self: *MainThreadMessageService, args: []const rpc.Arg) !rpc.HandlerReply {
        if (args.len < 4 or args[1] != .json or args[1].json != .string or args[3] != .json or args[3].json != .array) return error.InvalidNotification;
        const options = if (args[2] == .json and args[2].json == .object) args[2].json else std.json.Value.null;
        if (get(options, "modal")) |modal| if (modal == .bool and modal.bool) return Prompt.show(self.allocator, self.quick_input, args);
        const severity: Severity = if (args[0] == .json and args[0].json == .integer) switch (args[0].json.integer) {
            2 => .Warning,
            3 => .Error,
            else => .Info,
        } else .Info;
        const message = try self.allocator.create(Message);
        errdefer self.allocator.destroy(message);
        message.* = .{ .service = self, .arena = .init(self.allocator), .notification = .{ .severity = severity, .message = undefined, .source = .{ .text = "Extension" }, .legacy_extension_link_parsing = legacy } };
        errdefer message.arena.deinit();
        const a = message.arena.allocator();
        message.notification.message = .{ .text = try a.dupe(u8, args[1].json.string) };
        if (get(options, "source")) |source| {
            if (get(source, "identifier")) |identifier| if (get(identifier, "value")) |id| {
                if (id == .string) {
                    const label: std.json.Value = get(source, "label") orelse .{ .string = id.string };
                    message.notification.source = .{ .source = .{ .id = try a.dupe(u8, id.string), .label = try a.dupe(u8, if (label == .string) label.string else id.string) } };
                    if (std.mem.eql(u8, id.string, "vscode.github-authentication") or std.mem.eql(u8, id.string, "vscode.microsoft-authentication")) {
                        message.notification.priority = .URGENT;
                        message.notification.sticky = true;
                    }
                }
            };
        }
        const commands = args[3].json.array.items;
        message.choices = try a.alloc(Message.Choice, commands.len);
        const primary = try a.alloc(IAction, commands.len);
        for (commands) |command| {
            const title = get(command, "title") orelse continue;
            const handle = get(command, "handle") orelse continue;
            if (title != .string or handle != .integer) continue;
            const choice = &message.choices[message.initialized];
            choice.* = .{ .message = message, .handle = handle.integer, .action = Action.init(a, try std.fmt.allocPrint(a, "_extension_message_handle_{d}", .{handle.integer}), try a.dupe(u8, title.string), null, true, Message.Choice.run, choice) };
            primary[message.initialized] = choice.action.interface();
            message.initialized += 1;
        }
        message.notification.actions = .{ .primary = primary[0..message.initialized] };
        try self.pending.append(self.allocator, message);
        return .{ .deferred = .{ .context = message, .start = Message.start } };
    }
    fn get(value: std.json.Value, key: []const u8) ?std.json.Value {
        return if (value == .object) value.object.get(key) else null;
    }

    const Message = struct {
        service: *MainThreadMessageService,
        arena: std.heap.ArenaAllocator,
        notification: notification.INotification,
        choices: []Choice = &.{},
        initialized: usize = 0,
        channel: ?*rpc.RpcProtocol = null,
        request: u32 = 0,
        result: rpc.HandlerReply = .empty,
        handle: ?notification.INotificationHandle = null,

        const Choice = struct {
            message: *Message,
            handle: i64,
            action: Action,
            fn run(ctx: *anyopaque, _: ?*const anyopaque) !void {
                const self: *Choice = @ptrCast(@alignCast(ctx));
                const message = self.message;
                message.result = .{ .json = .{ .integer = self.handle } };
                if (message.handle) |handle| handle.close();
            }
        };
        fn start(ctx: *anyopaque, channel: *rpc.RpcProtocol, request: u32) void {
            const self: *Message = @ptrCast(@alignCast(ctx));
            self.channel = channel;
            self.request = request;
            const handle = self.service.notification_service.notify(self.notification);
            self.handle = handle;
            if (handle.on_did_close) |event| {
                _ = event.listen(self, onClosed) catch {
                    handle.close();
                    self.finish();
                    return;
                };
            } else self.finish();
        }
        fn onClosed(_: void, self: *Message) !void {
            self.finish();
        }
        fn finish(self: *Message) void {
            const service = self.service;
            if (self.channel) |channel| channel.sendReply(self.request, self.result);
            if (self.handle) |handle| handle.release();
            if (std.mem.indexOfScalar(*Message, service.pending.items, self)) |index| _ = service.pending.swapRemove(index);
            for (self.choices[0..self.initialized]) |*choice| choice.action.deinit();
            self.arena.deinit();
            service.allocator.destroy(self);
        }
    };
};

pub const Prompt = struct {
    allocator: std.mem.Allocator,
    quick_input: *QuickInputService,
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    items: []const Item,
    rpc: *rpc.RpcProtocol = undefined,
    request: u32 = 0,
    result: rpc.HandlerReply = .empty,

    pub fn show(allocator: std.mem.Allocator, quick_input: *QuickInputService, args: []const rpc.Arg) !rpc.HandlerReply {
        if (args.len < 4 or args[1] != .json or args[1].json != .string or args[3] != .json or args[3].json != .array) return error.InvalidNotification;
        const title = args[1].json.string;
        const detail = if (args[2] == .json and args[2].json == .object) args[2].json.object.get("detail") else null;
        const description = if (detail != null and detail.? == .string) detail.?.string else "";
        const commands = args[3].json.array.items;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var items: std.ArrayList(Item) = .empty;
        var cancel_handle: ?i64 = null;
        var cancel_label: []const u8 = if (commands.len == 0) "OK" else "Cancel";
        for (commands) |command| {
            const close = MainThreadMessageService.get(command, "isCloseAffordance") orelse continue;
            if (close != .bool or !close.bool) continue;
            const label = MainThreadMessageService.get(command, "title") orelse continue;
            const handle = MainThreadMessageService.get(command, "handle") orelse continue;
            if (label != .string or handle != .integer) continue;
            cancel_handle = handle.integer;
            cancel_label = try a.dupe(u8, label.string);
        }
        try items.append(a, .{ .item = .{ .id = if (cancel_handle) |handle| try std.fmt.allocPrint(a, "{d}", .{handle}) else "", .label = cancel_label } });
        const instructions = try a.dupe(u8, description);
        for (commands) |command| {
            if (command != .object) continue;
            const label = command.object.get("title") orelse continue;
            const handle = command.object.get("handle") orelse continue;
            if (label != .string or handle != .integer) continue;
            if (cancel_handle == handle.integer) continue;
            try items.append(a, .{ .item = .{ .id = try std.fmt.allocPrint(a, "{d}", .{handle.integer}), .label = try a.dupe(u8, label.string), .description = instructions } });
        }
        const message = try a.dupe(u8, title);
        const self = try allocator.create(Prompt);
        self.* = .{ .allocator = allocator, .quick_input = quick_input, .arena = arena, .title = message, .items = items.items, .result = if (cancel_handle) |handle| .{ .json = .{ .integer = handle } } else .empty };
        return .{ .deferred = .{ .context = self, .start = start } };
    }

    fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
        const self: *Prompt = @ptrCast(@alignCast(context));
        self.rpc = channel;
        self.request = id;
        self.quick_input.showPick(self.items, .{ .placeholder = self.title, .cleanup = finish, .cleanup_context = self }, pick, self) catch finish(self);
    }

    fn pick(context: *anyopaque, picker: *QuickPick) !void {
        const self: *Prompt = @ptrCast(@alignCast(context));
        const item = picker.selectedItem() orelse return;
        const handle = std.fmt.parseInt(i64, item.id, 10) catch return;
        self.result = .{ .json = .{ .integer = handle } };
    }

    fn finish(context: *anyopaque) void {
        const self: *Prompt = @ptrCast(@alignCast(context));
        self.rpc.sendReply(self.request, self.result);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

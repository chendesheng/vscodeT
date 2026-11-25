// Port of `src/vs/workbench/api/browser/mainThreadMessageService.ts`.
// Nonmodal messages use notifications; modal messages use the dialog service.
const std = @import("std");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const notification = @import("../../../platform/notification/common/notification.zig");
const Severity = @import("../../../base/common/severity.zig").Severity;
const Action = @import("../../../base/common/actions.zig").Action;
const IAction = @import("../../../base/common/actions.zig").IAction;
const legacy = @import("../../../platform/notification/common/notificationLegacy.zig").legacyExtensionLinkParsing;
const dialogs = @import("../../../platform/dialogs/common/dialogs.zig");

pub const MainThreadMessageService = struct {
    allocator: std.mem.Allocator,
    notification_service: notification.INotificationService,
    dialog_service: dialogs.IDialogService,
    modal_pending: std.ArrayList(*ModalMessage) = .empty,
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
        while (self.modal_pending.items.len > 0) {
            const modal = self.modal_pending.items[self.modal_pending.items.len - 1];
            if (modal.handle) |handle| handle.cancel() else ModalMessage.dispose(modal);
        }
        self.modal_pending.deinit(self.allocator);
    }
    pub fn showMessage(self: *MainThreadMessageService, args: []const rpc.Arg) !rpc.HandlerReply {
        if (args.len < 4 or args[1] != .json or args[1].json != .string or args[3] != .json or args[3].json != .array) return error.InvalidNotification;
        const options = if (args[2] == .json and args[2].json == .object) args[2].json else std.json.Value.null;
        const severity: Severity = if (args[0] == .json and args[0].json == .integer) switch (args[0].json.integer) {
            2 => .Warning,
            3 => .Error,
            else => .Info,
        } else .Info;
        if (get(options, "modal")) |modal| if (modal == .bool and modal.bool) return self.showModalMessage(severity, args[1].json.string, options, args[3].json.array.items);
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

    fn showModalMessage(self: *MainThreadMessageService, severity: Severity, message: []const u8, options: std.json.Value, commands: []const std.json.Value) !rpc.HandlerReply {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var labels: std.ArrayList([]const u8) = .empty;
        var handles: std.ArrayList(?i64) = .empty;
        var cancel_label: ?[]const u8 = null;
        var cancel_handle: ?i64 = null;
        for (commands) |command| {
            const title = get(command, "title") orelse continue;
            const handle = get(command, "handle") orelse continue;
            if (title != .string or handle != .integer) continue;
            const close = get(command, "isCloseAffordance");
            if (close != null and close.? == .bool and close.?.bool) {
                // As upstream, the last close affordance is the cancel button.
                cancel_label = title.string;
                cancel_handle = handle.integer;
            } else {
                try labels.append(a, try a.dupe(u8, title.string));
                try handles.append(a, handle.integer);
            }
        }
        try labels.append(a, try a.dupe(u8, cancel_label orelse if (labels.items.len > 0) "Cancel" else "OK"));
        try handles.append(a, cancel_handle);
        const detail = get(options, "detail");
        const prompt: dialogs.DialogPrompt = .{
            .message = try a.dupe(u8, message),
            .detail = try a.dupe(u8, if (detail != null and detail.? == .string) detail.?.string else ""),
            .buttons = labels.items,
            .severity = severity,
        };
        const modal = try self.allocator.create(ModalMessage);
        errdefer self.allocator.destroy(modal);
        modal.* = .{ .service = self, .arena = arena, .prompt = prompt, .handles = handles.items };
        try self.modal_pending.append(self.allocator, modal);
        return .{ .deferred = .{ .context = modal, .start = ModalMessage.start } };
    }

    const ModalMessage = struct {
        service: *MainThreadMessageService,
        arena: std.heap.ArenaAllocator,
        prompt: dialogs.DialogPrompt,
        handles: []const ?i64,
        channel: *rpc.RpcProtocol = undefined,
        request: u32 = 0,
        handle: ?dialogs.IDialogHandle = null,

        fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
            const self: *ModalMessage = @ptrCast(@alignCast(context));
            self.channel = channel;
            self.request = id;
            self.handle = self.service.dialog_service.prompt(self.prompt, .{
                .context = self,
                .complete = complete,
                .dispose = dispose,
            }) catch {
                complete(self, null);
                dispose(self);
                return;
            };
        }

        fn complete(context: *anyopaque, selected: ?usize) void {
            const self: *ModalMessage = @ptrCast(@alignCast(context));
            const index = selected orelse self.handles.len - 1;
            const result = if (index < self.handles.len) self.handles[index] else null;
            self.channel.sendReply(self.request, if (result) |handle| .{ .json = .{ .integer = handle } } else .empty);
        }

        fn dispose(context: *anyopaque) void {
            const self: *ModalMessage = @ptrCast(@alignCast(context));
            const service = self.service;
            if (std.mem.indexOfScalar(*ModalMessage, service.modal_pending.items, self)) |index| _ = service.modal_pending.swapRemove(index);
            self.arena.deinit();
            service.allocator.destroy(self);
        }
    };
};

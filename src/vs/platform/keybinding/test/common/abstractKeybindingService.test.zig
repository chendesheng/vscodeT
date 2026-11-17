// Port of the dispatch/chord cases of
// `src/vs/platform/keybinding/test/common/abstractKeybindingService.test.ts`.
// The appendKeybinding/single-modifier cases and the remaining chord-sharing
// cases are still to be ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_codes = @import("../../../../base/common/keyCodes.zig");
const key_bindings = @import("../../../../base/common/keybindings.zig");
const severity = @import("../../../../base/common/severity.zig").Severity;
const contextkey = @import("../../../contextkey/common/contextkey.zig");
const notification_mod = @import("../../../notification/common/notification.zig");
const resolver_mod = @import("../../common/keybindingResolver.zig");
const item_mod = @import("../../common/resolvedKeybindingItem.zig");
const abstract_mod = @import("../../common/abstractKeybindingService.zig");
const test_util = @import("./keybindingsTestUtils.zig");

const KeyCode = key_codes.KeyCode;
const IKeyboardEvent = @import("../../common/keybinding.zig").IKeyboardEvent;
const ResolvedKeybinding = key_bindings.ResolvedKeybinding;

const Harness = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    context_service: contextkey.ContextKeyService,
    resolved: std.array_list.Managed(*@import("../../common/usLayoutResolvedKeybinding.zig").USLayoutResolvedKeybinding),
    items: std.array_list.Managed(*item_mod.ResolvedKeybindingItem),
    resolver: resolver_mod.KeybindingResolver,
    executed: std.array_list.Managed([]const u8),
    statuses: std.array_list.Managed([]const u8),
    statuses_closed: std.array_list.Managed([]const u8),
    service: abstract_mod.AbstractKeybindingService,

    fn init(allocator: Allocator, encoded_keybindings: []const u32) !*Harness {
        const self = try allocator.create(Harness);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .context_service = contextkey.ContextKeyService.init(allocator),
            .resolved = std.array_list.Managed(*@import("../../common/usLayoutResolvedKeybinding.zig").USLayoutResolvedKeybinding).init(allocator),
            .items = std.array_list.Managed(*item_mod.ResolvedKeybindingItem).init(allocator),
            .resolver = undefined,
            .executed = std.array_list.Managed([]const u8).init(allocator),
            .statuses = std.array_list.Managed([]const u8).init(allocator),
            .statuses_closed = std.array_list.Managed([]const u8).init(allocator),
            .service = undefined,
        };
        for (encoded_keybindings, 0..) |encoded, index| {
            const resolved = (try test_util.createUSLayoutResolvedKeybinding(allocator, encoded, .Linux)) orelse continue;
            const held = try allocator.create(@TypeOf(resolved));
            held.* = resolved;
            try self.resolved.append(held);
            const item = try allocator.create(item_mod.ResolvedKeybindingItem);
            item.* = try item_mod.ResolvedKeybindingItem.init(
                allocator,
                held.interface(),
                try std.fmt.allocPrint(allocator, "command{d}", .{index}),
                null,
                null,
                true,
                null,
                false,
                false,
            );
            try self.items.append(item);
        }
        const item_ptrs = try allocator.alloc(*const item_mod.ResolvedKeybindingItem, self.items.items.len);
        for (self.items.items, 0..) |item, index| item_ptrs[index] = item;
        self.resolver = try resolver_mod.KeybindingResolver.init(allocator, item_ptrs, &.{});
        allocator.free(item_ptrs);

        self.service = abstract_mod.AbstractKeybindingService.init(
            allocator,
            self.context_service.interface(),
            .{ .context = self, .execute = executeCommand },
            notificationService(self),
            &self.resolver,
            self,
            resolveEvent,
            resolveBinding,
            resolveUser,
            hasFocus,
        );
        return self;
    }

    fn deinit(self: *Harness) void {
        self.service.deinit();
        self.resolver.deinit();
        for (self.items.items) |item| {
            if (item.command) |command| self.allocator.free(command);
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.items.deinit();
        for (self.resolved.items) |resolved| {
            resolved.deinit();
            self.allocator.destroy(resolved);
        }
        self.resolved.deinit();
        self.executed.deinit();
        self.statuses.deinit();
        self.statuses_closed.deinit();
        self.context_service.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn executeCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
        const self: *Harness = @ptrCast(@alignCast(context));
        try self.executed.append(command_id);
    }

    fn setCommand(self: *Harness, index: usize, command: ?[]const u8) !void {
        const item = self.items.items[index];
        if (item.command) |old| self.allocator.free(old);
        item.command = if (command) |value| try self.allocator.dupe(u8, value) else null;
    }

    fn resolveEvent(context: *anyopaque, _: Allocator, event: IKeyboardEvent) anyerror!?ResolvedKeybinding {
        const self: *Harness = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        var encoded: u32 = @intCast(@backingInt(event.key_code));
        if (event.ctrl) encoded |= key_codes.KeyMod.CtrlCmd;
        if (event.shift) encoded |= key_codes.KeyMod.Shift;
        if (event.alt) encoded |= key_codes.KeyMod.Alt;
        if (event.meta) encoded |= key_codes.KeyMod.WinCtrl;
        const resolved = (try test_util.createUSLayoutResolvedKeybinding(allocator, encoded, .Linux)) orelse return null;
        const held = try allocator.create(@TypeOf(resolved));
        held.* = resolved;
        return held.interface();
    }

    fn resolveBinding(_: *anyopaque, _: Allocator, _: key_bindings.Keybinding) anyerror![]ResolvedKeybinding {
        return &.{};
    }

    fn resolveUser(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]ResolvedKeybinding {
        return &.{};
    }

    fn hasFocus(_: *anyopaque) bool {
        return true;
    }
};

fn notificationService(harness: *Harness) notification_mod.INotificationService {
    return .{
        .context = harness,
        .notify_fn = notify,
        .info_fn = ignored,
        .warn_fn = ignored,
        .error_fn = ignored,
        .prompt_fn = prompt,
        .status_fn = status,
    };
}

fn notify(_: *anyopaque, _: notification_mod.INotification) notification_mod.INotificationHandle {
    return noopHandle();
}
fn ignored(_: *anyopaque, _: notification_mod.NotificationMessage) void {}
fn prompt(_: *anyopaque, _: severity, _: notification_mod.NotificationMessage, _: []const notification_mod.IPromptChoice, _: ?notification_mod.IPromptOptions) notification_mod.INotificationHandle {
    return noopHandle();
}
fn status(context: *anyopaque, message: notification_mod.NotificationMessage, _: ?notification_mod.IStatusMessageOptions) notification_mod.IStatusHandle {
    const self: *Harness = @ptrCast(@alignCast(context));
    const text = switch (message) {
        .text => |text| text,
        else => "",
    };
    const copy = self.arena.allocator().dupe(u8, text) catch "";
    self.statuses.append(copy) catch {};
    return .{ .context = self, .close_fn = closeStatus };
}
fn closeStatus(context: *anyopaque) void {
    const self: *Harness = @ptrCast(@alignCast(context));
    if (self.statuses.items.len > 0) {
        const last = self.statuses.items[self.statuses.items.len - 1];
        self.statuses_closed.append(last) catch {};
    }
}

var noop_notification: notification_mod.NoOpNotification = .{};
fn noopHandle() notification_mod.INotificationHandle {
    return noop_notification.interface();
}

fn eventFor(encoded: u32) IKeyboardEvent {
    const key_code: KeyCode = @fromBackingInt(@intCast(@as(u16, @intCast(encoded & 0xFF))));
    return .{
        .ctrl = (encoded & key_codes.KeyMod.CtrlCmd) != 0,
        .shift = (encoded & key_codes.KeyMod.Shift) != 0,
        .alt = (encoded & key_codes.KeyMod.Alt) != 0,
        .meta = (encoded & key_codes.KeyMod.WinCtrl) != 0,
        .key_code = key_code,
    };
}

test "a single-chord keybinding is dispatched correctly" {
    const allocator = std.testing.allocator;
    const harness = try Harness.init(allocator, &.{key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK)});
    defer harness.deinit();

    try std.testing.expect(harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK))));
    try std.testing.expectEqual(@as(usize, 1), harness.executed.items.len);
    try std.testing.expectEqualStrings("command0", harness.executed.items[0]);
    try std.testing.expectEqual(@as(usize, 0), harness.statuses.items.len);
}

test "a multi-chord keybinding is dispatched correctly" {
    const allocator = std.testing.allocator;
    const encoded = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyI));
    const harness = try Harness.init(allocator, &.{encoded});
    defer harness.deinit();

    const first = eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK));
    try std.testing.expect(harness.service.dispatchEvent(first));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.statuses.items.len);
    try std.testing.expect(std.mem.indexOf(u8, harness.statuses.items[0], "Waiting for second key of chord") != null);

    const second = eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyI));
    try std.testing.expect(harness.service.dispatchEvent(second));
    try std.testing.expectEqual(@as(usize, 1), harness.executed.items.len);
    try std.testing.expectEqualStrings("command0", harness.executed.items[0]);
    try std.testing.expectEqual(@as(usize, 1), harness.statuses_closed.items.len);
}

test "chord mode quits for invalid chords" {
    const allocator = std.testing.allocator;
    const encoded = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyI));
    const harness = try Harness.init(allocator, &.{encoded});
    defer harness.deinit();

    try std.testing.expect(harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK))));
    try std.testing.expect(harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyB))));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    try std.testing.expect(!harness.service.inChordMode());
    try std.testing.expectEqual(@as(usize, 2), harness.statuses.items.len);
    try std.testing.expect(std.mem.indexOf(u8, harness.statuses.items[1], "is not a command") != null);
}

test "a single-chord keybinding with an empty string command ID unbinds it" {
    const allocator = std.testing.allocator;
    const harness = try Harness.init(allocator, &.{key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK)});
    defer harness.deinit();
    try harness.setCommand(0, "");

    try std.testing.expect(!harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK))));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.statuses.items.len);
}

test "a single-chord keybinding with a null command ID unbinds it" {
    const allocator = std.testing.allocator;
    const harness = try Harness.init(allocator, &.{key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK)});
    defer harness.deinit();
    try harness.setCommand(0, null);

    try std.testing.expect(!harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK))));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.statuses.items.len);
}

fn twoChordEncoded() u32 {
    return key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyI));
}

test "a multi-chord keybinding with an empty-string command ID keeps the keybinding until the second chord" {
    const allocator = std.testing.allocator;
    const encoded = twoChordEncoded();
    const harness = try Harness.init(allocator, &.{ encoded, encoded });
    defer harness.deinit();
    try harness.setCommand(0, "myCommand");
    try harness.setCommand(1, "");

    try std.testing.expect(harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyK))));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.statuses.items.len);

    try std.testing.expect(harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyI))));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    try std.testing.expectEqual(@as(usize, 2), harness.statuses.items.len);
    try std.testing.expect(std.mem.indexOf(u8, harness.statuses.items[1], "is not a command") != null);
    try std.testing.expectEqual(@as(usize, 1), harness.statuses_closed.items.len);
}

test "modifier-only keys are not dispatched" {
    const allocator = std.testing.allocator;
    const harness = try Harness.init(allocator, &.{
        @backingInt(KeyCode.Ctrl), @backingInt(KeyCode.Meta),
        @backingInt(KeyCode.Alt),  @backingInt(KeyCode.Shift),
        key_codes.KeyMod.CtrlCmd,  key_codes.KeyMod.WinCtrl,
        key_codes.KeyMod.Alt,      key_codes.KeyMod.Shift,
    });
    defer harness.deinit();

    try std.testing.expect(!harness.service.dispatchEvent(eventFor(@backingInt(KeyCode.Ctrl))));
    try std.testing.expect(!harness.service.dispatchEvent(eventFor(key_codes.KeyMod.CtrlCmd)));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.statuses.items.len);
}

test "keybindings are not dispatched while an IME composition is in progress" {
    const allocator = std.testing.allocator;
    const harness = try Harness.init(allocator, &.{@backingInt(KeyCode.Enter)});
    defer harness.deinit();

    const composing = IKeyboardEvent{ .ctrl = false, .shift = false, .alt = false, .meta = false, .key_code = .KEY_IN_COMPOSITION };
    try std.testing.expect(!harness.service.dispatchEvent(composing));
    try std.testing.expectEqual(@as(usize, 0), harness.executed.items.len);
    const soft = try harness.service.softDispatch(allocator, composing);
    try std.testing.expectEqual(@import("../../common/keybindingResolver.zig").ResultKind.NoMatchingKb, soft.kind);

    const enter = eventFor(@backingInt(KeyCode.Enter));
    try std.testing.expect(harness.service.dispatchEvent(enter));
    try std.testing.expectEqual(@as(usize, 1), harness.executed.items.len);
    const after = try harness.service.softDispatch(allocator, enter);
    try std.testing.expectEqual(@import("../../common/keybindingResolver.zig").ResultKind.KbFound, after.kind);
}

// Port of `src/vs/platform/keybinding/common/abstractKeybindingService.ts`.
//
// Terminal adaptations:
// - There is no DOM target: dispatch/soft-dispatch take no target and use the
//   flat context-key service.
// - The 300 ms single-modifier clear, 500 ms/5 s chord-leave timers and IME
//   enable/disable are not ported (the terminal read loop owns time/IME).
//   Chord mode and single-modifier state are cleared by the next dispatch or by
//   `leaveChordMode`.
// - Telemetry is not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_codes = @import("../../../base/common/keyCodes.zig");
const key_bindings = @import("../../../base/common/keybindings.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");
const notification_mod = @import("../../notification/common/notification.zig");
const keybinding_mod = @import("./keybinding.zig");
const resolver_mod = @import("./keybindingResolver.zig");
const item_mod = @import("./resolvedKeybindingItem.zig");
const emitter = @import("../../../base/common/event.zig");

const KeyCode = key_codes.KeyCode;
const ResolvedKeybinding = key_bindings.ResolvedKeybinding;
const SingleModifierChord = key_bindings.SingleModifierChord;
const IContextKeyService = contextkey.IContextKeyService;
const INotificationService = notification_mod.INotificationService;
const IStatusHandle = notification_mod.IStatusHandle;
const IKeyboardEvent = keybinding_mod.IKeyboardEvent;
const ResolutionResult = resolver_mod.ResolutionResult;
const ResultKind = resolver_mod.ResultKind;
const KeybindingResolver = resolver_mod.KeybindingResolver;
const ResolvedKeybindingItem = item_mod.ResolvedKeybindingItem;

const CurrentChord = struct {
    keypress: []const u8,
    label: ?[]const u8,
};

const ModifierSet = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,

    fn fromChord(chord: ?key_bindings.ResolvedChord) ModifierSet {
        const value = chord orelse return .{};
        return .{ .ctrl = value.ctrl_key, .shift = value.shift_key, .alt = value.alt_key, .meta = value.meta_key };
    }

    fn has(self: ModifierSet, modifier: SingleModifierChord) bool {
        return switch (modifier) {
            .ctrl => self.ctrl,
            .shift => self.shift,
            .alt => self.alt,
            .meta => self.meta,
        };
    }
};

pub const CommandExecutor = struct {
    context: *anyopaque,
    execute: *const fn (context: *anyopaque, command_id: []const u8) anyerror!void,
};

pub const AbstractKeybindingService = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    context_key_service: IContextKeyService,
    command_service: CommandExecutor,
    notification_service: INotificationService,
    resolver: *KeybindingResolver,
    resolve_keyboard_event_fn: *const fn (context: *anyopaque, allocator: Allocator, event: IKeyboardEvent) anyerror!?ResolvedKeybinding,
    resolve_keybinding_fn: *const fn (context: *anyopaque, allocator: Allocator, keybinding: key_bindings.Keybinding) anyerror![]ResolvedKeybinding,
    resolve_user_binding_fn: *const fn (context: *anyopaque, allocator: Allocator, label: []const u8) anyerror![]ResolvedKeybinding,
    document_has_focus_fn: *const fn (context: *anyopaque) bool,
    listener_context: *anyopaque,

    current_chords: std.array_list.Managed(CurrentChord),
    current_chord_status: ?IStatusHandle = null,
    ignore_single_modifiers: ModifierSet = .{},
    current_single_modifier: ?SingleModifierChord = null,
    logging: bool = false,
    currently_dispatching: ?[]const u8 = null,
    onDidUpdateKeybindings: emitter.Emitter(void),

    pub fn init(
        allocator: Allocator,
        context_key_service: IContextKeyService,
        command_service: CommandExecutor,
        notification_service: INotificationService,
        resolver: *KeybindingResolver,
        listener_context: *anyopaque,
        resolve_keyboard_event_fn: *const fn (context: *anyopaque, allocator: Allocator, event: IKeyboardEvent) anyerror!?ResolvedKeybinding,
        resolve_keybinding_fn: *const fn (context: *anyopaque, allocator: Allocator, keybinding: key_bindings.Keybinding) anyerror![]ResolvedKeybinding,
        resolve_user_binding_fn: *const fn (context: *anyopaque, allocator: Allocator, label: []const u8) anyerror![]ResolvedKeybinding,
        document_has_focus_fn: *const fn (context: *anyopaque) bool,
    ) AbstractKeybindingService {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .context_key_service = context_key_service,
            .command_service = command_service,
            .notification_service = notification_service,
            .resolver = resolver,
            .resolve_keyboard_event_fn = resolve_keyboard_event_fn,
            .resolve_keybinding_fn = resolve_keybinding_fn,
            .resolve_user_binding_fn = resolve_user_binding_fn,
            .document_has_focus_fn = document_has_focus_fn,
            .listener_context = listener_context,
            .current_chords = std.array_list.Managed(CurrentChord).init(allocator),
            .onDidUpdateKeybindings = emitter.Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *AbstractKeybindingService) void {
        self.leaveChordMode();
        self.current_chords.deinit();
        self.onDidUpdateKeybindings.deinit();
        self.arena.deinit();
    }

    pub fn inChordMode(self: *const AbstractKeybindingService) bool {
        return self.current_chords.items.len > 0;
    }

    pub fn toggleLogging(self: *AbstractKeybindingService) bool {
        self.logging = !self.logging;
        return self.logging;
    }

    pub fn getDefaultKeybindings(self: *const AbstractKeybindingService) resolver_mod.ItemList {
        return self.resolver.getDefaultKeybindings();
    }

    pub fn getKeybindings(self: *const AbstractKeybindingService) resolver_mod.ItemList {
        return self.resolver.getKeybindings();
    }

    pub fn customKeybindingsCount(_: *const AbstractKeybindingService) usize {
        return 0;
    }

    pub fn resolveKeyboardEvent(self: *AbstractKeybindingService, event: IKeyboardEvent) !?ResolvedKeybinding {
        return self.resolve_keyboard_event_fn(self.listener_context, self.allocator, event);
    }

    pub fn resolveKeybinding(self: *AbstractKeybindingService, keybinding: key_bindings.Keybinding) ![]ResolvedKeybinding {
        return self.resolve_keybinding_fn(self.listener_context, self.allocator, keybinding);
    }

    pub fn resolveUserBinding(self: *AbstractKeybindingService, label: []const u8) ![]ResolvedKeybinding {
        return self.resolve_user_binding_fn(self.listener_context, self.allocator, label);
    }

    pub fn lookupKeybindings(self: *AbstractKeybindingService, allocator: Allocator, command_id: []const u8) ![]ResolvedKeybinding {
        const items = try self.resolver.lookupKeybindings(allocator, command_id);
        defer allocator.free(items);
        var result = std.array_list.Managed(ResolvedKeybinding).init(allocator);
        errdefer result.deinit();
        for (items) |item| {
            if (item.resolvedKeybinding) |resolved| try result.append(resolved);
        }
        return result.toOwnedSlice();
    }

    pub fn lookupKeybinding(self: *AbstractKeybindingService, allocator: Allocator, command_id: []const u8, enforce_context_check: bool) !?ResolvedKeybinding {
        const context = self.context_key_service.getContext();
        const item = self.resolver.lookupPrimaryKeybinding(command_id, context, enforce_context_check) orelse return null;
        _ = allocator;
        return item.resolvedKeybinding;
    }

    pub fn dispatchEvent(self: *AbstractKeybindingService, event: IKeyboardEvent) bool {
        if (isKeyInComposition(event)) return false;
        const keybinding = self.resolveKeyboardEvent(event) catch return false;
        const resolved = keybinding orelse return false;
        return self.doDispatch(resolved, false);
    }

    pub fn softDispatch(self: *AbstractKeybindingService, allocator: Allocator, event: IKeyboardEvent) !ResolutionResult {
        if (isKeyInComposition(event)) return resolver_mod.no_matching_kb;
        const keybinding = (try self.resolveKeyboardEvent(event)) orelse return resolver_mod.no_matching_kb;
        if (keybinding.hasMultipleChords()) return resolver_mod.no_matching_kb;
        const dispatch_chords = keybinding.getDispatchChords();
        if (dispatch_chords.len == 0) return resolver_mod.no_matching_kb;
        const first = dispatch_chords[0] orelse return resolver_mod.no_matching_kb;
        const current = try self.currentChordKeys(allocator);
        defer allocator.free(current);
        return self.resolver.resolve(self.context_key_service.getContext(), current, first);
    }

    pub fn dispatchByUserSettingsLabel(self: *AbstractKeybindingService, label: []const u8) !void {
        const bindings = try self.resolveUserBinding(label);
        defer self.allocator.free(bindings);
        if (bindings.len == 0) return;
        _ = self.doDispatch(bindings[0], false);
    }

    pub fn singleModifierDispatch(self: *AbstractKeybindingService, event: IKeyboardEvent) bool {
        if (isKeyInComposition(event)) return false;
        const keybinding = self.resolveKeyboardEvent(event) catch return false;
        const resolved = keybinding orelse return false;
        const singles = resolved.getSingleModifierDispatchChords();
        const single = if (singles.len > 0) singles[0] else null;
        if (single) |modifier| {
            if (self.ignore_single_modifiers.has(modifier)) {
                self.ignore_single_modifiers = .{};
                self.current_single_modifier = null;
                return false;
            }
            self.ignore_single_modifiers = .{};
            if (self.current_single_modifier == null) {
                self.current_single_modifier = modifier;
                return false;
            }
            if (self.current_single_modifier.? == modifier) {
                self.current_single_modifier = null;
                return self.doDispatch(resolved, true);
            }
            self.current_single_modifier = null;
            return false;
        }
        const chords = resolved.getChords();
        self.ignore_single_modifiers = ModifierSet.fromChord(if (chords.len > 0) chords[0] else null);
        self.current_single_modifier = null;
        return false;
    }

    pub fn appendKeybinding(self: *AbstractKeybindingService, allocator: Allocator, label: []const u8, command_id: ?[]const u8, enforce_context_check: bool) ![]u8 {
        if (command_id) |id| {
            if (try self.lookupKeybinding(allocator, id, enforce_context_check)) |resolved| {
                if (resolved.getLabel()) |keybinding_label| {
                    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ label, keybinding_label });
                }
            }
        }
        return allocator.dupe(u8, label);
    }

    pub fn mightProducePrintableCharacter(_: *AbstractKeybindingService, event: IKeyboardEvent) bool {
        return keybinding_mod.mightProducePrintableCharacter(event);
    }

    fn doDispatch(self: *AbstractKeybindingService, user_keypress: ResolvedKeybinding, is_single_modifier_chord: bool) bool {
        if (user_keypress.hasMultipleChords()) return false;

        var user_pressed_chord: ?[]const u8 = null;
        var current_chords: []const []const u8 = &.{};
        var current_holder: ?[]const []const u8 = null;
        defer if (current_holder) |holder| self.allocator.free(holder);

        if (is_single_modifier_chord) {
            const singles = user_keypress.getSingleModifierDispatchChords();
            const single = if (singles.len > 0) singles[0] else null;
            if (single) |modifier| {
                user_pressed_chord = singleModifierName(modifier);
                const holder = self.allocator.alloc([]const u8, 1) catch return false;
                holder[0] = user_pressed_chord.?;
                current_holder = holder;
                current_chords = holder;
            }
        } else {
            const dispatch_chords = user_keypress.getDispatchChords();
            user_pressed_chord = if (dispatch_chords.len > 0) dispatch_chords[0] else null;
            const holder = self.currentChordKeys(self.allocator) catch return false;
            current_holder = holder;
            current_chords = holder;
        }

        const keypress = user_pressed_chord orelse return false;
        const label = user_keypress.getLabel();
        const result = self.resolver.resolve(self.context_key_service.getContext(), current_chords, keypress) catch return false;

        switch (result.kind) {
            .NoMatchingKb => {
                if (self.inChordMode()) {
                    self.reportMissingChord(label);
                    self.leaveChordMode();
                    return true;
                }
                return false;
            },
            .MoreChordsNeeded => {
                self.expectAnotherChord(keypress, label);
                return true;
            },
            .KbFound => {
                const command_id = result.commandId;
                if (command_id == null or command_id.?.len == 0) {
                    if (self.inChordMode()) {
                        self.reportMissingChord(label);
                        self.leaveChordMode();
                        return true;
                    }
                    return false;
                }
                if (self.inChordMode()) self.leaveChordMode();
                const prevent_default = !result.isBubble;
                self.currently_dispatching = command_id;
                self.command_service.execute(self.command_service.context, command_id.?) catch |err| {
                    self.notification_service.warn(.{ .error_message = @errorName(err) });
                };
                self.currently_dispatching = null;
                return prevent_default;
            },
        }
    }

    fn currentChordKeys(self: *AbstractKeybindingService, allocator: Allocator) ![]const []const u8 {
        const keys = try allocator.alloc([]const u8, self.current_chords.items.len);
        for (self.current_chords.items, 0..) |chord, index| keys[index] = chord.keypress;
        return keys;
    }

    fn expectAnotherChord(self: *AbstractKeybindingService, first_chord: []const u8, keypress_label: ?[]const u8) void {
        self.current_chords.append(.{ .keypress = first_chord, .label = keypress_label }) catch return;
        const label = keypress_label orelse "";
        const message = if (self.current_chords.items.len == 1)
            std.fmt.allocPrint(self.arena.allocator(), "({s}) was pressed. Waiting for second key of chord...", .{label}) catch return
        else
            std.fmt.allocPrint(self.arena.allocator(), "({s}) was pressed. Waiting for next key of chord...", .{self.joinedLabels()}) catch return;
        if (self.current_chord_status) |status| status.close();
        self.current_chord_status = self.notification_service.status(.{ .text = message }, null);
    }

    fn joinedLabels(self: *AbstractKeybindingService) []const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
        for (self.current_chords.items, 0..) |chord, index| {
            if (index != 0) out.writer.writeAll(", ") catch {};
            out.writer.writeAll(chord.label orelse "") catch {};
        }
        return out.written();
    }

    fn reportMissingChord(self: *AbstractKeybindingService, keypress_label: ?[]const u8) void {
        const message = std.fmt.allocPrint(
            self.arena.allocator(),
            "The key combination ({s}, {s}) is not a command.",
            .{ self.joinedLabels(), keypress_label orelse "" },
        ) catch return;
        _ = self.notification_service.status(.{ .text = message }, null);
    }

    pub fn leaveChordMode(self: *AbstractKeybindingService) void {
        if (self.current_chord_status) |status| {
            status.close();
            self.current_chord_status = null;
        }
        self.current_chords.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }
};

fn singleModifierName(modifier: SingleModifierChord) []const u8 {
    return switch (modifier) {
        .ctrl => "ctrl",
        .shift => "shift",
        .alt => "alt",
        .meta => "meta",
    };
}

fn isKeyInComposition(event: IKeyboardEvent) bool {
    return event.key_code == .KEY_IN_COMPOSITION;
}

const test_util = @import("../test/common/keybindingsTestUtils.zig");
const contextkey_service = contextkey.ContextKeyService;

const TestState = struct {
    executed: std.array_list.Managed([]const u8),
    statuses: std.array_list.Managed([]const u8),
    warnings: usize = 0,
    status_closed: usize = 0,

    fn execute(context: *anyopaque, command_id: []const u8) anyerror!void {
        const self: *TestState = @ptrCast(@alignCast(context));
        try self.executed.append(command_id);
    }

    fn notify(_: *anyopaque, _: notification_mod.INotification) notification_mod.INotificationHandle {
        return noop_handle;
    }
    fn ignored(_: *anyopaque, _: notification_mod.NotificationMessage) void {}
    fn warn(context: *anyopaque, _: notification_mod.NotificationMessage) void {
        const self: *TestState = @ptrCast(@alignCast(context));
        self.warnings += 1;
    }
    fn prompt(_: *anyopaque, _: Severity, _: notification_mod.NotificationMessage, _: []const notification_mod.IPromptChoice, _: ?notification_mod.IPromptOptions) notification_mod.INotificationHandle {
        return noop_handle;
    }
    fn status(context: *anyopaque, message: notification_mod.NotificationMessage, _: ?notification_mod.IStatusMessageOptions) notification_mod.IStatusHandle {
        const self: *TestState = @ptrCast(@alignCast(context));
        switch (message) {
            .text => |text| self.statuses.append(text) catch {},
            else => {},
        }
        return .{ .context = context, .close_fn = closeStatus };
    }
    fn closeStatus(context: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(context));
        self.status_closed += 1;
    }
};

const Severity = @import("../../../base/common/severity.zig").Severity;

var noop_notification: notification_mod.NoOpNotification = .{};
var noop_handle = noop_notification.interface();

test "abstract service dispatches matched keybindings and tracks chord mode" {
    const allocator = std.testing.allocator;
    var state = TestState{
        .executed = std.array_list.Managed([]const u8).init(allocator),
        .statuses = std.array_list.Managed([]const u8).init(allocator),
    };
    defer state.executed.deinit();
    defer state.statuses.deinit();

    var context_service = contextkey_service.init(allocator);
    defer context_service.deinit();

    var resolved = (try test_util.createUSLayoutResolvedKeybinding(allocator, key_codes.KeyMod.CtrlCmd | @backingInt(KeyCode.KeyA), .Linux)).?;
    defer resolved.deinit();
    var item = try ResolvedKeybindingItem.init(allocator, resolved.interface(), "test.command", null, null, true, null, false, false);
    defer item.deinit(allocator);

    var resolver = try KeybindingResolver.init(allocator, &.{&item}, &.{});
    defer resolver.deinit();

    const notification = notification_mod.INotificationService{
        .context = &state,
        .notify_fn = TestState.notify,
        .info_fn = TestState.ignored,
        .warn_fn = TestState.warn,
        .error_fn = TestState.ignored,
        .prompt_fn = TestState.prompt,
        .status_fn = TestState.status,
    };

    const CallbackCtx = struct {
        resolved: *@TypeOf(resolved),

        fn resolveEvent(context: *anyopaque, _: Allocator, event: IKeyboardEvent) anyerror!?ResolvedKeybinding {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event.ctrl and !event.shift and !event.alt and !event.meta and event.key_code == .KeyA) {
                return self.resolved.interface();
            }
            return null;
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
    var callback_context = CallbackCtx{ .resolved = &resolved };

    var service = AbstractKeybindingService.init(
        allocator,
        context_service.interface(),
        .{ .context = &state, .execute = TestState.execute },
        notification,
        &resolver,
        &callback_context,
        CallbackCtx.resolveEvent,
        CallbackCtx.resolveBinding,
        CallbackCtx.resolveUser,
        CallbackCtx.hasFocus,
    );
    defer service.deinit();

    const event = IKeyboardEvent{ .ctrl = true, .shift = false, .alt = false, .meta = false, .key_code = .KeyA };
    try std.testing.expect(service.dispatchEvent(event));
    try std.testing.expectEqual(@as(usize, 1), state.executed.items.len);
    try std.testing.expectEqualStrings("test.command", state.executed.items[0]);

    const soft = try service.softDispatch(allocator, event);
    try std.testing.expectEqual(ResultKind.KbFound, soft.kind);
    try std.testing.expectEqualStrings("test.command", soft.commandId.?);

    const no_match = IKeyboardEvent{ .ctrl = true, .shift = false, .alt = false, .meta = false, .key_code = .KeyB };
    try std.testing.expect(!service.dispatchEvent(no_match));
}

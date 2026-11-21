//! Terminal keybinding service on top of the ported
//! `AbstractKeybindingService` (P3 wiring).
//!
//! The workbench-global shortcuts now go through the upstream dispatch path
//! (resolver + context + notification + command execution) instead of the
//! `TuiKeybindings` id-dispatch host. Terminal adaptations: the flat context
//! key service, a no-op notification service (no status bar for chord hints
//! here), `Ctrl` as the command modifier on every host (terminals never
//! deliver Cmd, so `CtrlCmd` rules resolve as Ctrl even on macOS), `Alt` as the
//! only meta-like modifier, and no timers/IME.
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("ui").input;
const platform = @import("../../../../base/common/platform.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const key_bindings = @import("../../../../base/common/keybindings.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const registry_module = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const resolver_module = @import("../../../../platform/keybinding/common/keybindingResolver.zig");
const item_module = @import("../../../../platform/keybinding/common/resolvedKeybindingItem.zig");
const us_module = @import("../../../../platform/keybinding/common/usLayoutResolvedKeybinding.zig");
const notification_mod = @import("../../../../platform/notification/common/notification.zig");
const abstract_mod = @import("../../../../platform/keybinding/common/abstractKeybindingService.zig");
const keybinding_mod = @import("../../../../platform/keybinding/common/keybinding.zig");

const ResolvedKeybindingItem = item_module.ResolvedKeybindingItem;
const USLayoutResolvedKeybinding = us_module.USLayoutResolvedKeybinding;
const AbstractKeybindingService = abstract_mod.AbstractKeybindingService;

/// Operating system used to resolve bindings inside the terminal host.
///
/// Upstream maps `CtrlCmd` to Meta on macOS, which is right for the browser
/// workbench but unreachable from a terminal: terminals only deliver Ctrl
/// (Alt arrives as an ESC prefix, never Cmd). Resolving with Linux semantics
/// on macOS keeps every `CtrlCmd` rule on Ctrl, matching the shortcuts the TUI
/// documents. The registry also selects platform-specific rule variants from
/// this value, so macOS uses the Ctrl-based (Linux) variants too.
pub fn bindingOS() platform.OperatingSystem {
    return switch (platform.OS) {
        .Macintosh => .Linux,
        else => platform.OS,
    };
}

pub const Options = struct {
    rules: []const registry_module.IKeybindingRule,
    executor: abstract_mod.CommandExecutor,
    /// Shared workbench context key service. When null the service owns one
    /// (tests and standalone hosts).
    context: ?*contextkey.ContextKeyService = null,
    /// User-keybinding overrides, including `-command` removal entries. The
    /// resolver borrows them for the lifetime of the service.
    overrides: []const *const ResolvedKeybindingItem = &.{},
};

pub const KeybindingService = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    context: *contextkey.ContextKeyService,
    owns_context: bool,
    overrides: []const *const ResolvedKeybindingItem,
    noop_notification: notification_mod.NoOpNotification = .{},
    commands: abstract_mod.CommandExecutor,
    items: std.array_list.Managed(*ResolvedKeybindingItem),
    resolved: std.array_list.Managed(*USLayoutResolvedKeybinding),
    resolver: resolver_module.KeybindingResolver,
    service: AbstractKeybindingService,
    last_command: ?[]const u8 = null,

    pub fn init(allocator: Allocator, rules: []const registry_module.IKeybindingRule, executor: abstract_mod.CommandExecutor) !*KeybindingService {
        return initWithOptions(allocator, .{ .rules = rules, .executor = executor });
    }

    pub fn initWithOptions(allocator: Allocator, options: Options) !*KeybindingService {
        const self = try allocator.create(KeybindingService);
        errdefer allocator.destroy(self);

        var registry = registry_module.KeybindingsRegistry.init(allocator);
        defer registry.deinit();
        for (options.rules) |rule| {
            var registration = try registry.registerKeybindingRule(rule);
            registration.disposed = true;
        }
        // Decode the rules for the terminal's modifier model, not the host
        // GUI's. `getDefaultKeybindingsForOS` re-decodes the registered rules
        // with the requested OS; the registry's own items are unused here.
        const registry_items = try registry.getDefaultKeybindingsForOS(allocator, bindingOS());
        defer registry_module.deinitKeybindings(allocator, registry_items);

        const context = if (options.context) |shared|
            shared
        else blk: {
            const created = try allocator.create(contextkey.ContextKeyService);
            created.* = contextkey.ContextKeyService.init(allocator);
            break :blk created;
        };
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .context = context,
            .owns_context = options.context == null,
            .overrides = options.overrides,
            .commands = options.executor,
            .items = std.array_list.Managed(*ResolvedKeybindingItem).init(allocator),
            .resolved = std.array_list.Managed(*USLayoutResolvedKeybinding).init(allocator),
            .resolver = undefined,
            .service = undefined,
        };

        for (registry_items) |item| {
            const keybinding = item.keybinding orelse continue;
            const resolved_value = (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, keybinding, bindingOS())) orelse continue;
            const held = try allocator.create(USLayoutResolvedKeybinding);
            held.* = resolved_value;
            try self.resolved.append(held);
            const entry = try allocator.create(ResolvedKeybindingItem);
            entry.* = try ResolvedKeybindingItem.init(
                allocator,
                held.interface(),
                item.command,
                item.commandArgs,
                item.when,
                true,
                item.extensionId,
                item.isBuiltinExtension,
                false,
            );
            try self.items.append(entry);
        }
        const item_ptrs = try allocator.alloc(*const ResolvedKeybindingItem, self.items.items.len);
        defer allocator.free(item_ptrs);
        for (self.items.items, 0..) |item, index| item_ptrs[index] = item;
        self.resolver = try resolver_module.KeybindingResolver.init(allocator, item_ptrs, options.overrides);

        self.service = AbstractKeybindingService.init(
            allocator,
            self.context.interface(),
            .{ .context = self, .execute = executeCommand },
            notificationService(self),
            &self.resolver,
            self,
            resolveEvent,
            resolveKeybinding,
            resolveUserBinding,
            hasFocus,
        );
        return self;
    }

    pub fn deinit(self: *KeybindingService) void {
        self.service.deinit();
        self.resolver.deinit();
        for (self.items.items) |item| {
            item.deinit(self.allocator);
            self.allocator.destroy(item);
        }
        self.items.deinit();
        for (self.resolved.items) |resolved| {
            resolved.deinit();
            self.allocator.destroy(resolved);
        }
        self.resolved.deinit();
        if (self.owns_context) {
            self.context.deinit();
            self.allocator.destroy(self.context);
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Dispatches a decoded terminal key. Returns whether the key was consumed.
    pub fn dispatch(self: *KeybindingService, event: input.KeyEvent) bool {
        self.last_command = null;
        const keyboard = toKeyboardEvent(event) orelse return false;
        const prevented = self.service.dispatchEvent(keyboard);
        return prevented or self.last_command != null or self.service.inChordMode();
    }

    pub fn lastCommand(self: *const KeybindingService) ?[]const u8 {
        return self.last_command;
    }

    fn executeCommand(context: *anyopaque, command_id: []const u8) anyerror!void {
        const self: *KeybindingService = @ptrCast(@alignCast(context));
        self.last_command = command_id;
        try self.commands.execute(self.commands.context, command_id);
    }

    fn resolveEvent(context: *anyopaque, _: Allocator, event: keybinding_mod.IKeyboardEvent) anyerror!?key_bindings.ResolvedKeybinding {
        const self: *KeybindingService = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        var encoded: u32 = @intCast(@backingInt(event.key_code));
        if (event.ctrl) encoded |= key_codes.KeyMod.CtrlCmd;
        if (event.shift) encoded |= key_codes.KeyMod.Shift;
        if (event.alt) encoded |= key_codes.KeyMod.Alt;
        const resolved = (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, .{ .chords = &.{.{ .key_code = .{
            .ctrl_key = event.ctrl,
            .shift_key = event.shift,
            .alt_key = event.alt,
            .meta_key = false,
            .key_code = event.key_code,
        } }} }, bindingOS())) orelse return null;
        const held = try allocator.create(USLayoutResolvedKeybinding);
        held.* = resolved;
        return held.interface();
    }

    fn resolveKeybinding(context: *anyopaque, _: Allocator, keybinding: key_bindings.Keybinding) anyerror![]key_bindings.ResolvedKeybinding {
        const self: *KeybindingService = @ptrCast(@alignCast(context));
        const allocator = self.arena.allocator();
        var resolved = (try USLayoutResolvedKeybinding.resolveKeybinding(allocator, keybinding, bindingOS())) orelse return &.{};
        const result = try allocator.alloc(key_bindings.ResolvedKeybinding, 1);
        result[0] = resolved.interface();
        return result;
    }

    fn resolveUserBinding(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]key_bindings.ResolvedKeybinding {
        return &.{};
    }

    fn hasFocus(_: *anyopaque) bool {
        return true;
    }
};

// ---------------------------------------------------------------------------
// Terminal key decoding
//
// `ui.input.KeyEvent` is the terminal's keyboard event; the workbench
// keybinding service consumes the VS Code shape. The mapping lives here so the
// service and its host adapter have one owner. There is no browser analogue:
// upstream gets `StandardKeyboardEvent` from a DOM `KeyboardEvent`.
// ---------------------------------------------------------------------------

pub fn keyCodeFor(event: input.KeyEvent) ?key_codes.KeyCode {
    return switch (event.key) {
        .enter => .Enter,
        .tab, .backtab => .Tab,
        .escape => .Escape,
        .backspace => .Backspace,
        .delete => .Delete,
        .insert => .Insert,
        .left => .LeftArrow,
        .right => .RightArrow,
        .up => .UpArrow,
        .down => .DownArrow,
        .home => .Home,
        .end => .End,
        .page_up => .PageUp,
        .page_down => .PageDown,
        .f12 => .F12,
        .char => |codepoint| charKeyCode(codepoint),
        .text, .paste_start, .paste_end => null,
    };
}

fn charKeyCode(codepoint: u21) ?key_codes.KeyCode {
    if (codepoint > 127) return null;
    const character: u8 = @intCast(codepoint);

    if (character >= 'a' and character <= 'z') {
        return @fromBackingInt(@intCast(@backingInt(key_codes.KeyCode.KeyA) + (character - 'a')));
    }
    if (character >= 'A' and character <= 'Z') {
        return @fromBackingInt(@intCast(@backingInt(key_codes.KeyCode.KeyA) + (character - 'A')));
    }
    if (character >= '0' and character <= '9') {
        return @fromBackingInt(@intCast(@backingInt(key_codes.KeyCode.Digit0) + (character - '0')));
    }
    return switch (character) {
        ' ' => .Space,
        ';' => .Semicolon,
        '=' => .Equal,
        ',' => .Comma,
        '-' => .Minus,
        '.' => .Period,
        '/' => .Slash,
        '`' => .Backquote,
        '[' => .BracketLeft,
        '\\' => .Backslash,
        ']' => .BracketRight,
        '\'' => .Quote,
        else => null,
    };
}

fn notificationService(service: *KeybindingService) notification_mod.INotificationService {
    return .{
        .context = &service.noop_notification,
        .notify_fn = noopNotify,
        .info_fn = noopMessage,
        .warn_fn = noopMessage,
        .error_fn = noopMessage,
        .prompt_fn = noopPrompt,
        .status_fn = noopStatus,
    };
}

fn noopNotify(context: *anyopaque, _: notification_mod.INotification) notification_mod.INotificationHandle {
    const noop: *notification_mod.NoOpNotification = @ptrCast(@alignCast(context));
    return noop.interface();
}
fn noopMessage(_: *anyopaque, _: notification_mod.NotificationMessage) void {}
fn noopPrompt(context: *anyopaque, _: @import("../../../../base/common/severity.zig").Severity, _: notification_mod.NotificationMessage, _: []const notification_mod.IPromptChoice, _: ?notification_mod.IPromptOptions) notification_mod.INotificationHandle {
    const noop: *notification_mod.NoOpNotification = @ptrCast(@alignCast(context));
    return noop.interface();
}
fn noopStatus(context: *anyopaque, _: notification_mod.NotificationMessage, _: ?notification_mod.IStatusMessageOptions) notification_mod.IStatusHandle {
    return .{ .context = context, .close_fn = noopClose };
}
fn noopClose(_: *anyopaque) void {}

fn toKeyboardEvent(event: input.KeyEvent) ?keybinding_mod.IKeyboardEvent {
    const key_code = keyCodeFor(event) orelse return null;
    const uppercase = switch (event.key) {
        .char => |codepoint| codepoint >= 'A' and codepoint <= 'Z',
        else => false,
    };
    return .{
        .ctrl = event.mods.ctrl,
        .shift = event.mods.shift or uppercase or std.meta.activeTag(event.key) == .backtab,
        .alt = event.mods.alt,
        .meta = false,
        .key_code = key_code,
    };
}

test "keybinding service dispatches single and multi-chord bindings" {
    const allocator = std.testing.allocator;
    const State = struct {
        calls: usize = 0,
        fn execute(context: *anyopaque, _: []const u8) anyerror!void {
            const state: *@This() = @ptrCast(@alignCast(context));
            state.calls += 1;
        }
    };
    var state = State{};

    var registry = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig").KeybindingsRegistry.init(allocator);
    defer registry.deinit();

    const rules = [_]@import("../../../../platform/keybinding/common/keybindingsRegistry.zig").IKeybindingRule{
        .{ .id = "test.single", .weight = 200, .bindings = .{ .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyA) } },
        .{ .id = "test.chord", .weight = 200, .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyI)) } },
    };

    const service = try KeybindingService.init(allocator, &rules, .{ .context = &state, .execute = State.execute });
    defer service.deinit();

    const single = input.KeyEvent{ .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(service.dispatch(single));
    try std.testing.expectEqual(@as(usize, 1), state.calls);

    const first = input.KeyEvent{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(service.dispatch(first));
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(service.service.inChordMode());

    const second = input.KeyEvent{ .key = .{ .char = 'i' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(service.dispatch(second));
    try std.testing.expectEqual(@as(usize, 2), state.calls);

    const unmatched = input.KeyEvent{ .key = .{ .char = 'j' }, .mods = .{ .ctrl = true } };
    try std.testing.expect(!service.dispatch(unmatched));
}

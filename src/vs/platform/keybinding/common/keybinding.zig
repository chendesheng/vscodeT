// Port of `src/vs/platform/keybinding/common/keybinding.ts`.
//
// Terminal adaptations: `IContextKeyServiceTarget` is an opaque optional
// pointer (the terminal has no DOM target), and the JSON-schema contribution
// surface is not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_codes = @import("../../../base/common/keyCodes.zig");
const key_bindings = @import("../../../base/common/keybindings.zig");
const contextkey = @import("../../contextkey/common/contextkey.zig");
const KeyCode = key_codes.KeyCode;
const Keybinding = key_bindings.Keybinding;
const ResolvedKeybinding = key_bindings.ResolvedKeybinding;
const IKeybindingItem = @import("./keybindingsRegistry.zig").IKeybindingItem;
const ResolutionResult = @import("./keybindingResolver.zig").ResolutionResult;
const IContextKeyService = contextkey.IContextKeyService;

pub const IUserFriendlyKeybinding = struct {
    key: []const u8,
    command: []const u8,
    args: ?*const anyopaque = null,
    when: ?[]const u8 = null,
    system_wide: bool = false,
};

pub const IKeyboardEvent = struct {
    ctrl: bool,
    shift: bool,
    alt: bool,
    meta: bool,
    alt_graph: bool = false,
    key_code: KeyCode,
    code: []const u8 = "",
};

pub const IKeybindingService = struct {
    context: *anyopaque,
    in_chord_mode_fn: *const fn (context: *anyopaque) bool,
    listen_updates_fn: *const fn (context: *anyopaque, listener: UpdateListener) anyerror!usize,
    unlisten_updates_fn: *const fn (context: *anyopaque, id: usize) void,
    resolve_keybinding_fn: *const fn (context: *anyopaque, allocator: Allocator, keybinding: Keybinding) anyerror![]ResolvedKeybinding,
    resolve_keyboard_event_fn: *const fn (context: *anyopaque, allocator: Allocator, event: IKeyboardEvent) anyerror!?ResolvedKeybinding,
    dispatch_event_fn: *const fn (context: *anyopaque, event: IKeyboardEvent, target: ?*anyopaque) bool,
    soft_dispatch_fn: *const fn (context: *anyopaque, event: IKeyboardEvent, target: ?*anyopaque) ResolutionResult,
    lookup_keybinding_fn: *const fn (context: *anyopaque, allocator: Allocator, command_id: []const u8, context_service: ?*IContextKeyService, enforce_context_check: bool) anyerror!?ResolvedKeybinding,
    lookup_keybindings_fn: *const fn (context: *anyopaque, allocator: Allocator, command_id: []const u8) anyerror![]ResolvedKeybinding,
    get_default_keybindings_fn: *const fn (context: *anyopaque) []const *const IKeybindingItem,
    get_keybindings_fn: *const fn (context: *anyopaque) []const *const IKeybindingItem,
    custom_keybindings_count_fn: *const fn (context: *anyopaque) usize,
    might_produce_printable_character_fn: *const fn (context: *anyopaque, event: IKeyboardEvent) bool,
    append_keybinding_fn: *const fn (context: *anyopaque, allocator: Allocator, label: []const u8, command_id: ?[]const u8, context_service: ?*IContextKeyService, enforce_context_check: bool) anyerror![]u8,
    toggle_logging_fn: *const fn (context: *anyopaque) bool,

    pub fn inChordMode(self: IKeybindingService) bool {
        return self.in_chord_mode_fn(self.context);
    }
    pub fn listenUpdates(self: IKeybindingService, listener: UpdateListener) !usize {
        return self.listen_updates_fn(self.context, listener);
    }
    pub fn unlistenUpdates(self: IKeybindingService, id: usize) void {
        self.unlisten_updates_fn(self.context, id);
    }
    pub fn resolveKeybinding(self: IKeybindingService, allocator: Allocator, keybinding: Keybinding) ![]ResolvedKeybinding {
        return self.resolve_keybinding_fn(self.context, allocator, keybinding);
    }
    pub fn resolveKeyboardEvent(self: IKeybindingService, allocator: Allocator, event: IKeyboardEvent) !?ResolvedKeybinding {
        return self.resolve_keyboard_event_fn(self.context, allocator, event);
    }
    pub fn dispatchEvent(self: IKeybindingService, event: IKeyboardEvent, target: ?*anyopaque) bool {
        return self.dispatch_event_fn(self.context, event, target);
    }
    pub fn softDispatch(self: IKeybindingService, event: IKeyboardEvent, target: ?*anyopaque) ResolutionResult {
        return self.soft_dispatch_fn(self.context, event, target);
    }
    pub fn lookupKeybinding(self: IKeybindingService, allocator: Allocator, command_id: []const u8, context_service: ?*IContextKeyService, enforce_context_check: bool) !?ResolvedKeybinding {
        return self.lookup_keybinding_fn(self.context, allocator, command_id, context_service, enforce_context_check);
    }
    pub fn lookupKeybindings(self: IKeybindingService, allocator: Allocator, command_id: []const u8) ![]ResolvedKeybinding {
        return self.lookup_keybindings_fn(self.context, allocator, command_id);
    }
    pub fn getDefaultKeybindings(self: IKeybindingService) []const *const IKeybindingItem {
        return self.get_default_keybindings_fn(self.context);
    }
    pub fn getKeybindings(self: IKeybindingService) []const *const IKeybindingItem {
        return self.get_keybindings_fn(self.context);
    }
    pub fn customKeybindingsCount(self: IKeybindingService) usize {
        return self.custom_keybindings_count_fn(self.context);
    }
    pub fn mightProducePrintableCharacter(self: IKeybindingService, event: IKeyboardEvent) bool {
        return self.might_produce_printable_character_fn(self.context, event);
    }
    pub fn appendKeybinding(self: IKeybindingService, allocator: Allocator, label: []const u8, command_id: ?[]const u8, context_service: ?*IContextKeyService, enforce_context_check: bool) ![]u8 {
        return self.append_keybinding_fn(self.context, allocator, label, command_id, context_service, enforce_context_check);
    }
    pub fn toggleLogging(self: IKeybindingService) bool {
        return self.toggle_logging_fn(self.context);
    }
};

pub const UpdateListener = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque) anyerror!void,
};

/// Weak heuristic from the abstract service (a subclass with the keyboard
/// mapper factory refines it).
pub fn mightProducePrintableCharacter(event: IKeyboardEvent) bool {
    if (event.ctrl or event.meta) return false;
    if (event.key_code == .Unknown) return false;
    const code = @backingInt(event.key_code);
    return (code >= @backingInt(KeyCode.KeyA) and code <= @backingInt(KeyCode.KeyZ)) or
        (code >= @backingInt(KeyCode.Digit0) and code <= @backingInt(KeyCode.Digit9));
}

test "printable character heuristic ignores ctrl/meta but accepts letters" {
    const letter = IKeyboardEvent{ .ctrl = false, .shift = false, .alt = false, .meta = false, .key_code = .KeyA };
    try std.testing.expect(mightProducePrintableCharacter(letter));
    const digit = IKeyboardEvent{ .ctrl = false, .shift = false, .alt = false, .meta = false, .key_code = .Digit5 };
    try std.testing.expect(mightProducePrintableCharacter(digit));
    var ctrl = letter;
    ctrl.ctrl = true;
    try std.testing.expect(!mightProducePrintableCharacter(ctrl));
    const escape = IKeyboardEvent{ .ctrl = false, .shift = false, .alt = false, .meta = false, .key_code = .Escape };
    try std.testing.expect(!mightProducePrintableCharacter(escape));
}

// Port of `src/vs/platform/keybinding/common/resolvedKeybindingItem.ts`.
//
// Terminal adaptation: the resolved keybinding is an interface value that
// borrows its implementation (see `USLayoutResolvedKeybinding`); the item keeps
// the `when` expression pointer and a borrowed `chords` array. The outer
// `chords` slice is owned by the item and released by `deinit`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_bindings = @import("../../../base/common/keybindings.zig");
const ResolvedKeybinding = key_bindings.ResolvedKeybinding;
const SingleModifierChord = key_bindings.SingleModifierChord;
const contextkey = @import("../../contextkey/common/contextkey.zig");
const key_codes = @import("../../../base/common/keyCodes.zig");

pub const ContextKeyExpression = *const contextkey.Expr;

pub const ResolvedKeybindingItem = struct {
    resolvedKeybinding: ?ResolvedKeybinding,
    chords: []const []const u8,
    bubble: bool,
    command: ?[]const u8,
    commandArgs: ?*const anyopaque,
    when: ?ContextKeyExpression,
    isDefault: bool,
    extensionId: ?[]const u8,
    isBuiltinExtension: bool,
    systemWide: bool,

    pub fn init(
        allocator: Allocator,
        resolved_keybinding: ?ResolvedKeybinding,
        command: ?[]const u8,
        command_args: ?*const anyopaque,
        when: ?ContextKeyExpression,
        is_default: bool,
        extension_id: ?[]const u8,
        is_builtin_extension: bool,
        system_wide: bool,
    ) !ResolvedKeybindingItem {
        const bubble = if (command) |value| value.len > 0 and value[0] == '^' else false;
        const normalized_command: ?[]const u8 = if (command) |value|
            (if (bubble) value[1..] else value)
        else
            null;

        var chords: []const []const u8 = &.{};
        if (resolved_keybinding) |resolved| {
            chords = try toEmptyArrayIfContainsNull(allocator, resolved.getDispatchChords());
            if (chords.len == 0) {
                // Handle possible single modifier chord keybindings.
                const single_modifiers = resolved.getSingleModifierDispatchChords();
                chords = try singleModifierChords(allocator, single_modifiers);
            }
        }

        return .{
            .resolvedKeybinding = resolved_keybinding,
            .chords = chords,
            .bubble = bubble,
            .command = normalized_command,
            .commandArgs = command_args,
            .when = when,
            .isDefault = is_default,
            .extensionId = extension_id,
            .isBuiltinExtension = is_builtin_extension,
            .systemWide = system_wide,
        };
    }

    pub fn deinit(self: *ResolvedKeybindingItem, allocator: Allocator) void {
        if (self.chords.len > 0) allocator.free(self.chords);
        self.chords = &.{};
    }
};

/// Upstream `toEmptyArrayIfContainsNull`.
pub fn toEmptyArrayIfContainsNull(allocator: Allocator, values: []const ?[]const u8) ![]const []const u8 {
    for (values) |value| {
        if (value == null) return &.{};
    }

    const result = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        result[index] = value.?;
    }
    return result;
}

fn singleModifierChords(allocator: Allocator, values: []const ?SingleModifierChord) ![]const []const u8 {
    for (values) |value| {
        if (value == null) return &.{};
    }

    const result = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        result[index] = switch (value.?) {
            .ctrl => "ctrl",
            .shift => "shift",
            .alt => "alt",
            .meta => "meta",
        };
    }
    return result;
}

test "ResolvedKeybindingItem normalizes bubbles and dispatch chords" {
    const allocator = std.testing.allocator;
    const key_bindings_module = key_bindings;
    const us = @import("usLayoutResolvedKeybinding.zig").USLayoutResolvedKeybinding;

    const encoded = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyA);
    const decoded = (try key_bindings_module.decodeKeybinding(allocator, .{ .single = encoded }, .Linux)).?;
    var resolved = (try us.resolveKeybinding(allocator, decoded, .Linux)).?;
    defer resolved.deinit();
    key_bindings_module.freeChords(allocator, decoded);

    var item = try ResolvedKeybindingItem.init(
        allocator,
        resolved.interface(),
        "^command",
        null,
        null,
        true,
        null,
        false,
        false,
    );
    defer item.deinit(allocator);

    try std.testing.expect(item.bubble);
    try std.testing.expectEqualStrings("command", item.command.?);
    try std.testing.expectEqual(@as(usize, 1), item.chords.len);
    try std.testing.expectEqualStrings("ctrl+A", item.chords[0]);
}

test "ResolvedKeybindingItem falls back to single modifier chords" {
    const allocator = std.testing.allocator;
    const key_bindings_module = key_bindings;
    const us = @import("usLayoutResolvedKeybinding.zig").USLayoutResolvedKeybinding;

    const decoded = (try key_bindings_module.decodeKeybinding(allocator, .{ .single = @backingInt(key_codes.KeyCode.Shift) }, .Windows)).?;
    var resolved = (try us.resolveKeybinding(allocator, decoded, .Windows)).?;
    defer resolved.deinit();
    key_bindings_module.freeChords(allocator, decoded);

    var item = try ResolvedKeybindingItem.init(allocator, resolved.interface(), "cmd", null, null, false, null, false, false);
    defer item.deinit(allocator);

    try std.testing.expect(!item.bubble);
    try std.testing.expectEqual(@as(usize, 1), item.chords.len);
    try std.testing.expectEqualStrings("shift", item.chords[0]);
}

test "ResolvedKeybindingItem without a resolved keybinding has no chords" {
    const allocator = std.testing.allocator;
    var item = try ResolvedKeybindingItem.init(allocator, null, "-cmd", null, null, true, "ext", true, true);
    defer item.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), item.chords.len);
    try std.testing.expectEqualStrings("-cmd", item.command.?);
    try std.testing.expect(item.systemWide);
}

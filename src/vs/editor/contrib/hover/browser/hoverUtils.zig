// Port of the non-DOM helpers from
// `src/vs/editor/contrib/hover/browser/hoverUtils.ts`.
pub const HoverEnabled = enum {
    on,
    off,
    on_keyboard_modifier,
};

pub const MultiCursorModifier = enum {
    alt,
    ctrl,
    meta,
};

pub const ModifierState = struct {
    ctrl_key: bool = false,
    meta_key: bool = false,
    alt_key: bool = false,
};

pub fn isTriggerModifierPressed(multi_cursor_modifier: MultiCursorModifier, state: ModifierState) bool {
    return switch (multi_cursor_modifier) {
        .alt => state.ctrl_key or state.meta_key,
        .ctrl, .meta => state.alt_key,
    };
}

pub fn shouldShowHover(hover_enabled: HoverEnabled, multi_cursor_modifier: MultiCursorModifier, state: ModifierState) bool {
    return switch (hover_enabled) {
        .on => true,
        .off => false,
        .on_keyboard_modifier => isTriggerModifierPressed(multi_cursor_modifier, state),
    };
}

test "hoverUtils: modifier-triggered hover" {
    const none = ModifierState{};
    try @import("std").testing.expect(shouldShowHover(.on, .alt, none));
    try @import("std").testing.expect(!shouldShowHover(.off, .alt, none));
    try @import("std").testing.expect(!shouldShowHover(.on_keyboard_modifier, .alt, none));

    try @import("std").testing.expect(shouldShowHover(.on_keyboard_modifier, .alt, .{ .ctrl_key = true }));
    try @import("std").testing.expect(shouldShowHover(.on_keyboard_modifier, .alt, .{ .meta_key = true }));
    try @import("std").testing.expect(!shouldShowHover(.on_keyboard_modifier, .alt, .{ .alt_key = true }));
    try @import("std").testing.expect(shouldShowHover(.on_keyboard_modifier, .ctrl, .{ .alt_key = true }));
    try @import("std").testing.expect(!shouldShowHover(.on_keyboard_modifier, .ctrl, .{ .ctrl_key = true }));
}

test "hoverUtils: trigger modifier ignores the multi-cursor modifier" {
    try @import("std").testing.expect(!isTriggerModifierPressed(.alt, .{ .alt_key = true }));
    try @import("std").testing.expect(!isTriggerModifierPressed(.meta, .{ .meta_key = true }));
    try @import("std").testing.expect(isTriggerModifierPressed(.meta, .{ .alt_key = true }));
}

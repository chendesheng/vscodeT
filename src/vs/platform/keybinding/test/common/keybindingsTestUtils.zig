// Port of `src/vs/platform/keybinding/test/common/keybindingsTestUtils.ts`.
//
// Terminal adaptation: the decoded keybinding owns its chords and the resolved
// keybinding copies them, so the caller only has to `deinit` the result.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_bindings = @import("../../../../base/common/keybindings.zig");
const platform = @import("../../../../base/common/platform.zig");
const USLayoutResolvedKeybinding = @import("../../common/usLayoutResolvedKeybinding.zig").USLayoutResolvedKeybinding;

pub fn createUSLayoutResolvedKeybinding(
    allocator: Allocator,
    encoded_keybinding: u32,
    os: platform.OperatingSystem,
) !?USLayoutResolvedKeybinding {
    if (encoded_keybinding == 0) return null;
    const decoded = (try key_bindings.decodeKeybinding(allocator, .{ .single = encoded_keybinding }, os)) orelse return null;
    defer key_bindings.freeChords(allocator, decoded);
    return try USLayoutResolvedKeybinding.resolveKeybinding(allocator, decoded, os);
}

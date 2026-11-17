// Terminal key decoding helpers used by `keybindingService.zig`.
//
// The old `TuiKeybindings` id-dispatch host was retired once every TUI host
// moved onto `AbstractKeybindingService`; the dispatch-string and key-code
// helpers remain (the editor and hosts need them to build key events).
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("ui").input;
const key_codes = @import("../vs/base/common/keyCodes.zig");
const key_bindings = @import("../vs/base/common/keybindings.zig");
const platform = @import("../vs/base/common/platform.zig");
const us_module = @import("../vs/platform/keybinding/common/usLayoutResolvedKeybinding.zig");

/// `ctrl+shift+alt+key` dispatch string for a decoded terminal key, or null for
/// keys that cannot participate in a shortcut (bulk text/paste markers).
pub fn dispatchString(allocator: Allocator, event: input.KeyEvent) !?[]u8 {
    const key_code = keyCodeFor(event) orelse return null;
    // Terminals deliver shifted letters as uppercase characters; infer shift so
    // `Shift+B` and `B` do not collapse to the same chord.
    const uppercase = switch (event.key) {
        .char => |codepoint| codepoint >= 'A' and codepoint <= 'Z',
        else => false,
    };
    const chord = key_bindings.KeyCodeChord.init(
        event.mods.ctrl,
        event.mods.shift or uppercase or std.meta.activeTag(event.key) == .backtab,
        event.mods.alt,
        false,
        key_code,
    );
    return us_module.USLayoutResolvedKeybinding.getDispatchStr(allocator, chord);
}

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

test "dispatch keys cover navigation and punctuation" {
    const allocator = std.testing.allocator;
    const left = try dispatchString(allocator, .{ .key = .left });
    defer if (left) |value| allocator.free(value);
    try std.testing.expectEqualStrings("LeftArrow", left.?);

    const quote = try dispatchString(allocator, .{ .key = .{ .char = '\'' }, .mods = .{ .ctrl = true } });
    defer if (quote) |value| allocator.free(value);
    try std.testing.expectEqualStrings("ctrl+'", quote.?);

    const uppercase = try dispatchString(allocator, .{ .key = .{ .char = 'B' }, .mods = .{ .alt = true } });
    defer if (uppercase) |value| allocator.free(value);
    try std.testing.expectEqualStrings("shift+alt+B", uppercase.?);

    const text = try dispatchString(allocator, .{ .key = .{ .text = "abc" } });
    try std.testing.expect(text == null);

    const backtab = try dispatchString(allocator, .{ .key = .backtab });
    defer if (backtab) |value| allocator.free(value);
    try std.testing.expectEqualStrings("shift+Tab", backtab.?);
}

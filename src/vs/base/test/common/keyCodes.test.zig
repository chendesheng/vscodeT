// Port of `src/vs/base/test/common/keyCodes.test.ts`.
//
// Terminal adaptation: `decodeKeybinding` returns an owned chord array
// (`freeChords`) and the expected `Keybinding` values are built from local
// chord arrays. The two `mapping for *` tests and the encoding matrices are
// unchanged in intent.
const std = @import("std");
const key_codes = @import("../../common/keyCodes.zig");
const key_bindings = @import("../../common/keybindings.zig");
const platform = @import("../../common/platform.zig");

const KeyCode = key_codes.KeyCode;
const ScanCode = key_codes.ScanCode;
const KeyMod = key_codes.KeyMod;
const KeyCodeUtils = key_codes.KeyCodeUtils;
const ScanCodeUtils = key_codes.ScanCodeUtils;
const OperatingSystem = platform.OperatingSystem;
const KeyCodeChord = key_bindings.KeyCodeChord;
const Keybinding = key_bindings.Keybinding;
const decodeKeybinding = key_bindings.decodeKeybinding;
const freeChords = key_bindings.freeChords;

fn checkSingle(allocator: std.mem.Allocator, os: OperatingSystem, encoded: u32, expected: ?KeyCodeChord) !void {
    const decoded = try decodeKeybinding(allocator, .{ .single = encoded }, os);
    defer if (decoded) |keybinding| freeChords(allocator, keybinding);

    const expected_chord = expected orelse {
        try std.testing.expect(decoded == null);
        return;
    };
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(usize, 1), decoded.?.chords.len);
    try std.testing.expect(decoded.?.chords[0].equals(.{ .key_code = expected_chord }));
}

fn checkTwo(
    allocator: std.mem.Allocator,
    os: OperatingSystem,
    encoded: u32,
    first: KeyCodeChord,
    second: KeyCodeChord,
) !void {
    const decoded = try decodeKeybinding(allocator, .{ .single = encoded }, os);
    defer if (decoded) |keybinding| freeChords(allocator, keybinding);

    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(usize, 2), decoded.?.chords.len);
    try std.testing.expect(decoded.?.chords[0].equals(.{ .key_code = first }));
    try std.testing.expect(decoded.?.chords[1].equals(.{ .key_code = second }));
}

test "mapping for Minus" {
    // [147, 83, 0, ScanCode.Minus, 'Minus', KeyCode.US_MINUS, '-', 189, 'VK_OEM_MINUS', '-', 'OEM_MINUS'],
    try std.testing.expectEqual(KeyCode.Minus, key_codes.EVENT_KEY_CODE_MAP[189]);
    try std.testing.expectEqual(@as(?KeyCode, .Minus), key_codes.nativeWindowsKeyCodeToKeyCode("VK_OEM_MINUS"));
    try std.testing.expectEqual(ScanCode.Minus, ScanCodeUtils.lowerCaseToEnum("minus"));
    try std.testing.expectEqual(ScanCode.Minus, ScanCodeUtils.toEnum("Minus"));
    try std.testing.expectEqualStrings("Minus", ScanCodeUtils.toString(.Minus));
    try std.testing.expectEqual(KeyCode.DependsOnKbLayout, key_codes.IMMUTABLE_CODE_TO_KEY_CODE[@backingInt(ScanCode.Minus)]);
    try std.testing.expectEqual(ScanCode.DependsOnKbLayout, key_codes.IMMUTABLE_KEY_CODE_TO_CODE[@backingInt(KeyCode.Minus)]);
    try std.testing.expectEqualStrings("-", KeyCodeUtils.toString(.Minus));
    try std.testing.expectEqual(KeyCode.Minus, KeyCodeUtils.fromString("-"));
    try std.testing.expectEqualStrings("-", KeyCodeUtils.toUserSettingsUS(.Minus));
    try std.testing.expectEqualStrings("OEM_MINUS", KeyCodeUtils.toUserSettingsGeneral(.Minus));
    try std.testing.expectEqual(KeyCode.Minus, KeyCodeUtils.fromUserSettings("-"));
    try std.testing.expectEqual(KeyCode.Minus, KeyCodeUtils.fromUserSettings("OEM_MINUS"));
    try std.testing.expectEqual(KeyCode.Minus, KeyCodeUtils.fromUserSettings("oem_minus"));
}

test "mapping for Space" {
    // [21, 10, 1, ScanCode.Space, 'Space', KeyCode.Space, 'Space', 32, 'VK_SPACE', empty, empty],
    try std.testing.expectEqual(KeyCode.Space, key_codes.EVENT_KEY_CODE_MAP[32]);
    try std.testing.expectEqual(@as(?KeyCode, .Space), key_codes.nativeWindowsKeyCodeToKeyCode("VK_SPACE"));
    try std.testing.expectEqual(ScanCode.Space, ScanCodeUtils.lowerCaseToEnum("space"));
    try std.testing.expectEqual(ScanCode.Space, ScanCodeUtils.toEnum("Space"));
    try std.testing.expectEqualStrings("Space", ScanCodeUtils.toString(.Space));
    try std.testing.expectEqual(KeyCode.Space, key_codes.IMMUTABLE_CODE_TO_KEY_CODE[@backingInt(ScanCode.Space)]);
    try std.testing.expectEqual(ScanCode.Space, key_codes.IMMUTABLE_KEY_CODE_TO_CODE[@backingInt(KeyCode.Space)]);
    try std.testing.expectEqualStrings("Space", KeyCodeUtils.toString(.Space));
    try std.testing.expectEqual(KeyCode.Space, KeyCodeUtils.fromString("Space"));
    try std.testing.expectEqualStrings("Space", KeyCodeUtils.toUserSettingsUS(.Space));
    try std.testing.expectEqualStrings("Space", KeyCodeUtils.toUserSettingsGeneral(.Space));
    try std.testing.expectEqual(KeyCode.Space, KeyCodeUtils.fromUserSettings("Space"));
    try std.testing.expectEqual(KeyCode.Space, KeyCodeUtils.fromUserSettings("space"));
}

test "MAC binary encoding" {
    const allocator = std.testing.allocator;
    const os: OperatingSystem = .Macintosh;
    const enter = @backingInt(KeyCode.Enter);

    try checkSingle(allocator, os, 0, null);
    try checkSingle(allocator, os, enter, KeyCodeChord.init(false, false, false, false, .Enter));
    try checkSingle(allocator, os, KeyMod.WinCtrl | enter, KeyCodeChord.init(true, false, false, false, .Enter));
    try checkSingle(allocator, os, KeyMod.Alt | enter, KeyCodeChord.init(false, false, true, false, .Enter));
    try checkSingle(allocator, os, KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, false, true, false, .Enter));
    try checkSingle(allocator, os, KeyMod.Shift | enter, KeyCodeChord.init(false, true, false, false, .Enter));
    try checkSingle(allocator, os, KeyMod.Shift | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, true, false, false, .Enter));
    try checkSingle(allocator, os, KeyMod.Shift | KeyMod.Alt | enter, KeyCodeChord.init(false, true, true, false, .Enter));
    try checkSingle(allocator, os, KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, true, true, false, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | enter, KeyCodeChord.init(false, false, false, true, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, false, false, true, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Alt | enter, KeyCodeChord.init(false, false, true, true, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, false, true, true, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | enter, KeyCodeChord.init(false, true, false, true, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, true, false, true, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | enter, KeyCodeChord.init(false, true, true, true, .Enter));
    try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, true, true, true, .Enter));

    try checkTwo(
        allocator,
        os,
        key_codes.KeyChord(enter, @backingInt(KeyCode.Tab)),
        KeyCodeChord.init(false, false, false, false, .Enter),
        KeyCodeChord.init(false, false, false, false, .Tab),
    );
    try checkTwo(
        allocator,
        os,
        key_codes.KeyChord(KeyMod.CtrlCmd | @backingInt(KeyCode.KeyY), @backingInt(KeyCode.KeyZ)),
        KeyCodeChord.init(false, false, false, true, .KeyY),
        KeyCodeChord.init(false, false, false, false, .KeyZ),
    );
}

test "WINDOWS & LINUX binary encoding" {
    const allocator = std.testing.allocator;
    const operating_systems = [_]OperatingSystem{ .Linux, .Windows };

    for (operating_systems) |os| {
        const enter = @backingInt(KeyCode.Enter);

        try checkSingle(allocator, os, 0, null);
        try checkSingle(allocator, os, enter, KeyCodeChord.init(false, false, false, false, .Enter));
        try checkSingle(allocator, os, KeyMod.WinCtrl | enter, KeyCodeChord.init(false, false, false, true, .Enter));
        try checkSingle(allocator, os, KeyMod.Alt | enter, KeyCodeChord.init(false, false, true, false, .Enter));
        try checkSingle(allocator, os, KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(false, false, true, true, .Enter));
        try checkSingle(allocator, os, KeyMod.Shift | enter, KeyCodeChord.init(false, true, false, false, .Enter));
        try checkSingle(allocator, os, KeyMod.Shift | KeyMod.WinCtrl | enter, KeyCodeChord.init(false, true, false, true, .Enter));
        try checkSingle(allocator, os, KeyMod.Shift | KeyMod.Alt | enter, KeyCodeChord.init(false, true, true, false, .Enter));
        try checkSingle(allocator, os, KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(false, true, true, true, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | enter, KeyCodeChord.init(true, false, false, false, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, false, false, true, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Alt | enter, KeyCodeChord.init(true, false, true, false, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, false, true, true, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | enter, KeyCodeChord.init(true, true, false, false, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, true, false, true, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | enter, KeyCodeChord.init(true, true, true, false, .Enter));
        try checkSingle(allocator, os, KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | enter, KeyCodeChord.init(true, true, true, true, .Enter));

        try checkTwo(
            allocator,
            os,
            key_codes.KeyChord(enter, @backingInt(KeyCode.Tab)),
            KeyCodeChord.init(false, false, false, false, .Enter),
            KeyCodeChord.init(false, false, false, false, .Tab),
        );
        try checkTwo(
            allocator,
            os,
            key_codes.KeyChord(KeyMod.CtrlCmd | @backingInt(KeyCode.KeyY), @backingInt(KeyCode.KeyZ)),
            KeyCodeChord.init(true, false, false, false, .KeyY),
            KeyCodeChord.init(false, false, false, false, .KeyZ),
        );
    }
}

test "Keybinding rejects an empty chord list" {
    const chords = [_]key_bindings.Chord{};
    try std.testing.expectError(error.InvalidArgument, Keybinding.init(&chords));
}

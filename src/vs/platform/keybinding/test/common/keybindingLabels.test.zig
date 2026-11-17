// Port of `src/vs/platform/keybinding/test/common/keybindingLabels.test.ts`.
//
// Terminal adaptation: resolved keybindings own their labels and are torn down
// with `deinit`; getters return slices into that storage. The upstream
// assertion lists are kept as tables so every case is still checked.
const std = @import("std");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const platform = @import("../../../../base/common/platform.zig");
const test_utils = @import("keybindingsTestUtils.zig");

const KeyCode = key_codes.KeyCode;
const KeyMod = key_codes.KeyMod;
const OperatingSystem = platform.OperatingSystem;

const Case = struct { encoded: u32, label: []const u8 };

fn expectUSLabels(allocator: std.mem.Allocator, os: OperatingSystem, cases: []const Case) !void {
    for (cases) |case| {
        var resolved = (try test_utils.createUSLayoutResolvedKeybinding(allocator, case.encoded, os)) orelse return error.MissingResolvedKeybinding;
        defer resolved.deinit();
        const label = resolved.interface().getLabel() orelse return error.MissingLabel;
        try std.testing.expectEqualStrings(case.label, label);
    }
}

test "Windows US label" {
    const allocator = std.testing.allocator;
    const a = @backingInt(KeyCode.KeyA);
    const b = @backingInt(KeyCode.KeyB);
    const cases = [_]Case{
        .{ .encoded = a, .label = "A" },
        .{ .encoded = KeyMod.CtrlCmd | a, .label = "Ctrl+A" },
        .{ .encoded = KeyMod.Shift | a, .label = "Shift+A" },
        .{ .encoded = KeyMod.Alt | a, .label = "Alt+A" },
        .{ .encoded = KeyMod.WinCtrl | a, .label = "Windows+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | a, .label = "Ctrl+Shift+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Alt | a, .label = "Ctrl+Alt+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.WinCtrl | a, .label = "Ctrl+Windows+A" },
        .{ .encoded = KeyMod.Shift | KeyMod.Alt | a, .label = "Shift+Alt+A" },
        .{ .encoded = KeyMod.Shift | KeyMod.WinCtrl | a, .label = "Shift+Windows+A" },
        .{ .encoded = KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Alt+Windows+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | a, .label = "Ctrl+Shift+Alt+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.WinCtrl | a, .label = "Ctrl+Shift+Windows+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Ctrl+Alt+Windows+A" },
        .{ .encoded = KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Shift+Alt+Windows+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Ctrl+Shift+Alt+Windows+A" },
        .{ .encoded = key_codes.KeyChord(KeyMod.CtrlCmd | a, KeyMod.CtrlCmd | b), .label = "Ctrl+A Ctrl+B" },
    };
    try expectUSLabels(allocator, .Windows, &cases);
}

test "Linux US label" {
    const allocator = std.testing.allocator;
    const a = @backingInt(KeyCode.KeyA);
    const b = @backingInt(KeyCode.KeyB);
    const cases = [_]Case{
        .{ .encoded = a, .label = "A" },
        .{ .encoded = KeyMod.CtrlCmd | a, .label = "Ctrl+A" },
        .{ .encoded = KeyMod.Shift | a, .label = "Shift+A" },
        .{ .encoded = KeyMod.Alt | a, .label = "Alt+A" },
        .{ .encoded = KeyMod.WinCtrl | a, .label = "Super+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | a, .label = "Ctrl+Shift+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Alt | a, .label = "Ctrl+Alt+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.WinCtrl | a, .label = "Ctrl+Super+A" },
        .{ .encoded = KeyMod.Shift | KeyMod.Alt | a, .label = "Shift+Alt+A" },
        .{ .encoded = KeyMod.Shift | KeyMod.WinCtrl | a, .label = "Shift+Super+A" },
        .{ .encoded = KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Alt+Super+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | a, .label = "Ctrl+Shift+Alt+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.WinCtrl | a, .label = "Ctrl+Shift+Super+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Ctrl+Alt+Super+A" },
        .{ .encoded = KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Shift+Alt+Super+A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "Ctrl+Shift+Alt+Super+A" },
        .{ .encoded = key_codes.KeyChord(KeyMod.CtrlCmd | a, KeyMod.CtrlCmd | b), .label = "Ctrl+A Ctrl+B" },
    };
    try expectUSLabels(allocator, .Linux, &cases);
}

test "Mac US label" {
    const allocator = std.testing.allocator;
    const a = @backingInt(KeyCode.KeyA);
    const b = @backingInt(KeyCode.KeyB);
    const cases = [_]Case{
        .{ .encoded = a, .label = "A" },
        .{ .encoded = KeyMod.CtrlCmd | a, .label = "\u{2318}A" },
        .{ .encoded = KeyMod.Shift | a, .label = "\u{21e7}A" },
        .{ .encoded = KeyMod.Alt | a, .label = "\u{2325}A" },
        .{ .encoded = KeyMod.WinCtrl | a, .label = "\u{2303}A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | a, .label = "\u{21e7}\u{2318}A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Alt | a, .label = "\u{2325}\u{2318}A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.WinCtrl | a, .label = "\u{2303}\u{2318}A" },
        .{ .encoded = KeyMod.Shift | KeyMod.Alt | a, .label = "\u{21e7}\u{2325}A" },
        .{ .encoded = KeyMod.Shift | KeyMod.WinCtrl | a, .label = "\u{2303}\u{21e7}A" },
        .{ .encoded = KeyMod.Alt | KeyMod.WinCtrl | a, .label = "\u{2303}\u{2325}A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | a, .label = "\u{21e7}\u{2325}\u{2318}A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.WinCtrl | a, .label = "\u{2303}\u{21e7}\u{2318}A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "\u{2303}\u{2325}\u{2318}A" },
        .{ .encoded = KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "\u{2303}\u{21e7}\u{2325}A" },
        .{ .encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | a, .label = "\u{2303}\u{21e7}\u{2325}\u{2318}A" },
        .{ .encoded = key_codes.KeyChord(KeyMod.CtrlCmd | a, KeyMod.CtrlCmd | b), .label = "\u{2318}A \u{2318}B" },
        .{ .encoded = @backingInt(KeyCode.LeftArrow), .label = "\u{2190}" },
        .{ .encoded = @backingInt(KeyCode.UpArrow), .label = "\u{2191}" },
        .{ .encoded = @backingInt(KeyCode.RightArrow), .label = "\u{2192}" },
        .{ .encoded = @backingInt(KeyCode.DownArrow), .label = "\u{2193}" },
    };
    try expectUSLabels(allocator, .Macintosh, &cases);
}

test "Aria label" {
    const allocator = std.testing.allocator;
    const encoded = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | @backingInt(KeyCode.KeyA);
    const cases = [_]struct { os: OperatingSystem, label: []const u8 }{
        .{ .os = .Windows, .label = "Control+Shift+Alt+Windows+A" },
        .{ .os = .Linux, .label = "Control+Shift+Alt+Super+A" },
        .{ .os = .Macintosh, .label = "Control+Shift+Option+Command+A" },
    };
    for (cases) |case| {
        var resolved = (try test_utils.createUSLayoutResolvedKeybinding(allocator, encoded, case.os)) orelse return error.MissingResolvedKeybinding;
        defer resolved.deinit();
        const label = resolved.interface().getAriaLabel() orelse return error.MissingLabel;
        try std.testing.expectEqualStrings(case.label, label);
    }
}

fn expectElectronAccelerator(allocator: std.mem.Allocator, os: OperatingSystem, encoded: u32, expected: ?[]const u8) !void {
    var resolved = (try test_utils.createUSLayoutResolvedKeybinding(allocator, encoded, os)) orelse return error.MissingResolvedKeybinding;
    defer resolved.deinit();
    const label = resolved.interface().getElectronAccelerator();
    if (expected) |value| {
        try std.testing.expect(label != null);
        try std.testing.expectEqualStrings(value, label.?);
    } else {
        try std.testing.expect(label == null);
    }
}

test "Electron Accelerator label" {
    const allocator = std.testing.allocator;
    const all_modifiers = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | @backingInt(KeyCode.KeyA);
    const chord = key_codes.KeyChord(KeyMod.CtrlCmd | @backingInt(KeyCode.KeyA), KeyMod.CtrlCmd | @backingInt(KeyCode.KeyB));

    try expectElectronAccelerator(allocator, .Windows, all_modifiers, "Ctrl+Shift+Alt+Super+A");
    try expectElectronAccelerator(allocator, .Linux, all_modifiers, "Ctrl+Shift+Alt+Super+A");
    try expectElectronAccelerator(allocator, .Macintosh, all_modifiers, "Ctrl+Shift+Alt+Cmd+A");

    // electron cannot handle chords
    try expectElectronAccelerator(allocator, .Windows, chord, null);
    try expectElectronAccelerator(allocator, .Linux, chord, null);
    try expectElectronAccelerator(allocator, .Macintosh, chord, null);

    // electron cannot handle numpad keys
    try expectElectronAccelerator(allocator, .Windows, @backingInt(KeyCode.Numpad1), null);
    try expectElectronAccelerator(allocator, .Linux, @backingInt(KeyCode.Numpad1), null);
    try expectElectronAccelerator(allocator, .Macintosh, @backingInt(KeyCode.Numpad1), null);

    // special
    try expectElectronAccelerator(allocator, .Macintosh, @backingInt(KeyCode.LeftArrow), "Left");
    try expectElectronAccelerator(allocator, .Macintosh, @backingInt(KeyCode.UpArrow), "Up");
    try expectElectronAccelerator(allocator, .Macintosh, @backingInt(KeyCode.RightArrow), "Right");
    try expectElectronAccelerator(allocator, .Macintosh, @backingInt(KeyCode.DownArrow), "Down");
}

fn expectUserSettingsLabel(allocator: std.mem.Allocator, os: OperatingSystem, encoded: u32, expected: []const u8) !void {
    var resolved = (try test_utils.createUSLayoutResolvedKeybinding(allocator, encoded, os)) orelse return error.MissingResolvedKeybinding;
    defer resolved.deinit();
    const label = resolved.interface().getUserSettingsLabel() orelse return error.MissingLabel;
    try std.testing.expectEqualStrings(expected, label);
}

test "User Settings label" {
    const allocator = std.testing.allocator;
    const all_modifiers = KeyMod.CtrlCmd | KeyMod.Shift | KeyMod.Alt | KeyMod.WinCtrl | @backingInt(KeyCode.KeyA);
    const chord = key_codes.KeyChord(KeyMod.CtrlCmd | @backingInt(KeyCode.KeyA), KeyMod.CtrlCmd | @backingInt(KeyCode.KeyB));

    try expectUserSettingsLabel(allocator, .Windows, all_modifiers, "ctrl+shift+alt+win+a");
    try expectUserSettingsLabel(allocator, .Linux, all_modifiers, "ctrl+shift+alt+meta+a");
    try expectUserSettingsLabel(allocator, .Macintosh, all_modifiers, "ctrl+shift+alt+cmd+a");

    try expectUserSettingsLabel(allocator, .Windows, chord, "ctrl+a ctrl+b");
    try expectUserSettingsLabel(allocator, .Linux, chord, "ctrl+a ctrl+b");
    try expectUserSettingsLabel(allocator, .Macintosh, chord, "cmd+a cmd+b");
}

test "issue #91235: Do not end with a +" {
    const allocator = std.testing.allocator;
    var resolved = (try test_utils.createUSLayoutResolvedKeybinding(
        allocator,
        KeyMod.CtrlCmd | KeyMod.Alt | @backingInt(KeyCode.Alt),
        .Windows,
    )) orelse return error.MissingResolvedKeybinding;
    defer resolved.deinit();
    try std.testing.expectEqualStrings("Ctrl+Alt", resolved.interface().getLabel().?);
}

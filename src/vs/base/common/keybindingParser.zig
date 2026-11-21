// Port of `src/vs/base/common/keybindingParser.ts`.
//
// Terminal adaptation: the parser takes an allocator and owns the chord array
// it returns; release it with `keybindings.freeChords`. Upstream throws on an
// empty chord list, which cannot happen here because an empty input string
// returns null and every other input yields at least one (possibly Unknown)
// chord.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const key_codes = @import("keyCodes.zig");
const key_bindings = @import("keybindings.zig");

const KeyCode = key_codes.KeyCode;
const KeyCodeChord = key_bindings.KeyCodeChord;
const ScanCodeChord = key_bindings.ScanCodeChord;
const Chord = key_bindings.Chord;
const Keybinding = key_bindings.Keybinding;

pub const KeybindingParser = struct {
    /// Upstream `KeybindingParser.parseKeybinding`.
    pub fn parseKeybinding(allocator: Allocator, input: []const u8) !?Keybinding {
        if (input.len == 0) return null;

        var chords = ArrayList(Chord).init(allocator);
        errdefer chords.deinit();
        var remaining = input;
        while (true) {
            const trimmed = std.mem.trim(u8, remaining, " \t\r\n");
            if (trimmed.len == 0) break;
            const parsed = parseChord(&remaining);
            try chords.append(parsed);
        }
        if (chords.items.len == 0) {
            chords.deinit();
            return null;
        }
        return Keybinding{ .chords = try chords.toOwnedSlice() };
    }

    /// Parses one chord modifier prefix into the modifier booleans.
    fn readModifiers(input: *[]const u8) Modifiers {
        var mods = Modifiers{};
        var rest = std.mem.trim(u8, input.*, " \t\r\n");
        while (true) {
            if (consumeModifier(&rest, "ctrl")) {
                mods.ctrl = true;
            } else if (consumeModifier(&rest, "shift")) {
                mods.shift = true;
            } else if (consumeModifier(&rest, "alt")) {
                mods.alt = true;
            } else if (consumeModifier(&rest, "meta")) {
                mods.meta = true;
            } else if (consumeModifier(&rest, "win")) {
                mods.meta = true;
            } else if (consumeModifier(&rest, "cmd")) {
                mods.meta = true;
            } else {
                break;
            }
        }
        input.* = rest;
        return mods;
    }

    /// Parses one chord and leaves the rest (including the separating space)
    /// in `input`.
    fn parseChord(input: *[]const u8) Chord {
        const mods = readModifiers(input);
        var rest = input.*;
        const key_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const key = rest[0..key_end];
        rest = rest[key_end..];
        input.* = rest;

        if (key.len >= 2 and key[0] == '[' and key[key.len - 1] == ']') {
            const scan_code = key_codes.ScanCodeUtils.lowerCaseToEnum(key[1 .. key.len - 1]);
            return .{ .scan_code = ScanCodeChord.init(mods.ctrl, mods.shift, mods.alt, mods.meta, scan_code) };
        }
        const key_code = key_codes.KeyCodeUtils.fromUserSettings(key);
        return .{ .key_code = KeyCodeChord.init(mods.ctrl, mods.shift, mods.alt, mods.meta, key_code) };
    }
};

const Modifiers = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,
};

fn consumeModifier(input: *[]const u8, name: []const u8) bool {
    const text = input.*;
    if (text.len < name.len + 1) return false;
    if (!std.ascii.eqlIgnoreCase(text[0..name.len], name)) return false;
    const separator = text[name.len];
    if (separator != '+' and separator != '-') return false;
    input.* = text[name.len + 1 ..];
    return true;
}

test "keybindingParser: modifiers, keys and chords" {
    const allocator = std.testing.allocator;

    const single = (try KeybindingParser.parseKeybinding(allocator, "ctrl+shift+p")).?;
    defer key_bindings.freeChords(allocator, single);
    try std.testing.expectEqual(@as(usize, 1), single.chords.len);
    const chord = single.chords[0].key_code;
    try std.testing.expect(chord.ctrl_key);
    try std.testing.expect(chord.shift_key);
    try std.testing.expect(!chord.alt_key);
    try std.testing.expect(!chord.meta_key);
    try std.testing.expectEqual(KeyCode.KeyP, chord.key_code);

    const chorded = (try KeybindingParser.parseKeybinding(allocator, "g g")).?;
    defer key_bindings.freeChords(allocator, chorded);
    try std.testing.expectEqual(@as(usize, 2), chorded.chords.len);
    try std.testing.expectEqual(KeyCode.KeyG, chorded.chords[0].key_code.key_code);
    try std.testing.expectEqual(KeyCode.KeyG, chorded.chords[1].key_code.key_code);

    const escapes = (try KeybindingParser.parseKeybinding(allocator, "escape escape")).?;
    defer key_bindings.freeChords(allocator, escapes);
    try std.testing.expectEqual(KeyCode.Escape, escapes.chords[0].key_code.key_code);

    const bracket = (try KeybindingParser.parseKeybinding(allocator, "ctrl+[")).?;
    defer key_bindings.freeChords(allocator, bracket);
    try std.testing.expect(bracket.chords[0].key_code.ctrl_key);
    try std.testing.expectEqual(KeyCode.BracketLeft, bracket.chords[0].key_code.key_code);
}

test "keybindingParser: aliases, separators and scan codes" {
    const allocator = std.testing.allocator;

    const alias = (try KeybindingParser.parseKeybinding(allocator, "OEM_1")).?;
    defer key_bindings.freeChords(allocator, alias);
    try std.testing.expectEqual(KeyCode.Semicolon, alias.chords[0].key_code.key_code);

    const dashes = (try KeybindingParser.parseKeybinding(allocator, "ctrl-shift-alt-win-a")).?;
    defer key_bindings.freeChords(allocator, dashes);
    const dash_chord = dashes.chords[0].key_code;
    try std.testing.expect(dash_chord.ctrl_key and dash_chord.shift_key and dash_chord.alt_key and dash_chord.meta_key);
    try std.testing.expectEqual(KeyCode.KeyA, dash_chord.key_code);

    const mixed = (try KeybindingParser.parseKeybinding(allocator, " ctrl-shift-alt-win-A ")).?;
    defer key_bindings.freeChords(allocator, mixed);
    try std.testing.expect(mixed.chords[0].key_code.meta_key);
    try std.testing.expectEqual(KeyCode.KeyA, mixed.chords[0].key_code.key_code);

    const scan = (try KeybindingParser.parseKeybinding(allocator, "ctrl+shift+[comma] ctrl+/")).?;
    defer key_bindings.freeChords(allocator, scan);
    try std.testing.expectEqual(@as(usize, 2), scan.chords.len);
    try std.testing.expect(scan.chords[0] == .scan_code);
    try std.testing.expect(scan.chords[1] == .key_code);
    try std.testing.expectEqual(KeyCode.Slash, scan.chords[1].key_code.key_code);
}

test "keybindingParser: empty input is not a keybinding" {
    try std.testing.expect((try KeybindingParser.parseKeybinding(std.testing.allocator, "")) == null);
}

// Port of `src/vs/platform/keybinding/common/usLayoutResolvedKeybinding.ts`.
//
// Terminal adaptation: the resolved labels/dispatch strings are computed at
// construction time by `BaseResolvedKeybinding`; `resolveKeybinding` returns an
// optional value instead of an array of zero or one element (the caller frees
// the copy of the key-code chords with `deinit`). The vtable callbacks ignore
// their context because the US layout mapping is static.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_codes = @import("../../../base/common/keyCodes.zig");
const key_bindings = @import("../../../base/common/keybindings.zig");
const platform = @import("../../../base/common/platform.zig");
const base_module = @import("baseResolvedKeybinding.zig");

const KeyCode = key_codes.KeyCode;
const ScanCode = key_codes.ScanCode;
const KeyCodeUtils = key_codes.KeyCodeUtils;
const NextChord = key_bindings.Chord;
const KeyCodeChord = key_bindings.KeyCodeChord;
const Keybinding = key_bindings.Keybinding;
const SingleModifierChord = key_bindings.SingleModifierChord;
const ResolvedKeybinding = key_bindings.ResolvedKeybinding;
const OperatingSystem = platform.OperatingSystem;
const BaseResolvedKeybinding = base_module.BaseResolvedKeybinding;

pub const USLayoutResolvedKeybinding = struct {
    base: BaseResolvedKeybinding(KeyCodeChord),
    chords: []const KeyCodeChord,

    /// Upstream returns zero or one resolved keybinding; `null` is the empty
    /// result. The caller owns the result and calls `deinit`.
    pub fn resolveKeybinding(allocator: Allocator, keybinding: Keybinding, os: OperatingSystem) !?USLayoutResolvedKeybinding {
        const chords = try allocator.alloc(KeyCodeChord, keybinding.chords.len);
        errdefer allocator.free(chords);
        for (keybinding.chords, 0..) |chord, index| {
            switch (chord) {
                .key_code => |key_code_chord| chords[index] = key_code_chord,
                .scan_code => |scan_code_chord| {
                    const key_code = scanCodeToKeyCode(scan_code_chord.scan_code);
                    if (key_code == .Unknown) {
                        allocator.free(chords);
                        return null;
                    }
                    chords[index] = KeyCodeChord.init(
                        scan_code_chord.ctrl_key,
                        scan_code_chord.shift_key,
                        scan_code_chord.alt_key,
                        scan_code_chord.meta_key,
                        key_code,
                    );
                },
            }
        }

        const base = BaseResolvedKeybinding(KeyCodeChord).init(allocator, os, chords, methods) catch |err| {
            allocator.free(chords);
            return err;
        };
        return USLayoutResolvedKeybinding{ .base = base, .chords = chords };
    }

    pub fn deinit(self: *USLayoutResolvedKeybinding) void {
        self.base.deinit();
        self.base.allocator.free(self.chords);
        self.chords = &.{};
    }

    pub fn interface(self: *USLayoutResolvedKeybinding) ResolvedKeybinding {
        return base_module.resolvedKeybindingInterface(KeyCodeChord, &self.base);
    }

    /// Do not call before checking for `KeyCode.Unknown`.
    fn scanCodeToKeyCode(scan_code: ScanCode) KeyCode {
        const immutable_key_code = key_codes.IMMUTABLE_CODE_TO_KEY_CODE[@intCast(@backingInt(scan_code))];
        if (immutable_key_code != .DependsOnKbLayout) return immutable_key_code;

        return switch (scan_code) {
            .KeyA => .KeyA,
            .KeyB => .KeyB,
            .KeyC => .KeyC,
            .KeyD => .KeyD,
            .KeyE => .KeyE,
            .KeyF => .KeyF,
            .KeyG => .KeyG,
            .KeyH => .KeyH,
            .KeyI => .KeyI,
            .KeyJ => .KeyJ,
            .KeyK => .KeyK,
            .KeyL => .KeyL,
            .KeyM => .KeyM,
            .KeyN => .KeyN,
            .KeyO => .KeyO,
            .KeyP => .KeyP,
            .KeyQ => .KeyQ,
            .KeyR => .KeyR,
            .KeyS => .KeyS,
            .KeyT => .KeyT,
            .KeyU => .KeyU,
            .KeyV => .KeyV,
            .KeyW => .KeyW,
            .KeyX => .KeyX,
            .KeyY => .KeyY,
            .KeyZ => .KeyZ,
            .Digit1 => .Digit1,
            .Digit2 => .Digit2,
            .Digit3 => .Digit3,
            .Digit4 => .Digit4,
            .Digit5 => .Digit5,
            .Digit6 => .Digit6,
            .Digit7 => .Digit7,
            .Digit8 => .Digit8,
            .Digit9 => .Digit9,
            .Digit0 => .Digit0,
            .Minus => .Minus,
            .Equal => .Equal,
            .BracketLeft => .BracketLeft,
            .BracketRight => .BracketRight,
            .Backslash => .Backslash,
            else => .Unknown,
        };
    }

    fn keyCodeToUILabel(key_code: KeyCode, os: OperatingSystem) []const u8 {
        if (os == .Macintosh) {
            switch (key_code) {
                .LeftArrow => return "\u{2190}",
                .UpArrow => return "\u{2191}",
                .RightArrow => return "\u{2192}",
                .DownArrow => return "\u{2193}",
                else => {},
            }
        }
        return KeyCodeUtils.toString(key_code);
    }

    fn getLabel(_: *anyopaque, allocator: Allocator, os: OperatingSystem, chord: KeyCodeChord) anyerror![]u8 {
        if (chord.isDuplicateModifierCase()) return allocator.dupe(u8, "");
        return allocator.dupe(u8, keyCodeToUILabel(chord.key_code, os));
    }

    fn getAriaLabel(_: *anyopaque, allocator: Allocator, chord: KeyCodeChord) anyerror![]u8 {
        if (chord.isDuplicateModifierCase()) return allocator.dupe(u8, "");
        return allocator.dupe(u8, KeyCodeUtils.toString(chord.key_code));
    }

    fn getElectronAccelerator(_: *anyopaque, allocator: Allocator, chord: KeyCodeChord) anyerror!?[]u8 {
        const value = KeyCodeUtils.toElectronAccelerator(chord.key_code) orelse return null;
        return try allocator.dupe(u8, value);
    }

    fn getUserSettingsLabel(_: *anyopaque, allocator: Allocator, chord: KeyCodeChord) anyerror![]u8 {
        if (chord.isDuplicateModifierCase()) return allocator.dupe(u8, "");
        const result = KeyCodeUtils.toUserSettingsUS(chord.key_code);
        const lower = try allocator.dupe(u8, result);
        for (lower) |*character| character.* = std.ascii.toLower(character.*);
        return lower;
    }

    fn isWYSIWYG(_: *anyopaque, chord: KeyCodeChord) bool {
        _ = chord;
        return true;
    }

    fn isDuplicateModifierCase(chord: KeyCodeChord) bool {
        return chord.isDuplicateModifierCase();
    }

    fn getChordDispatch(_: *anyopaque, allocator: Allocator, chord: KeyCodeChord) anyerror!?[]u8 {
        return getDispatchStr(allocator, chord);
    }

    fn getSingleModifierChordDispatch(_: *anyopaque, chord: KeyCodeChord) ?SingleModifierChord {
        return singleModifierChordDispatch(chord);
    }

    /// Upstream `USLayoutResolvedKeybinding.getDispatchStr`. The caller owns the
    /// returned string.
    pub fn getDispatchStr(allocator: Allocator, chord: KeyCodeChord) !?[]u8 {
        if (chord.isModifierKey()) return null;
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();

        if (chord.ctrl_key) try result.appendSlice("ctrl+");
        if (chord.shift_key) try result.appendSlice("shift+");
        if (chord.alt_key) try result.appendSlice("alt+");
        if (chord.meta_key) try result.appendSlice("meta+");
        try result.appendSlice(KeyCodeUtils.toString(chord.key_code));

        return try result.toOwnedSlice();
    }

    fn singleModifierChordDispatch(chord: KeyCodeChord) ?SingleModifierChord {
        if (chord.key_code == .Ctrl and !chord.shift_key and !chord.alt_key and !chord.meta_key) return .ctrl;
        if (chord.key_code == .Shift and !chord.ctrl_key and !chord.alt_key and !chord.meta_key) return .shift;
        if (chord.key_code == .Alt and !chord.ctrl_key and !chord.shift_key and !chord.meta_key) return .alt;
        if (chord.key_code == .Meta and !chord.ctrl_key and !chord.shift_key and !chord.alt_key) return .meta;
        return null;
    }

    const methods = base_module.BaseResolvedKeybinding(KeyCodeChord).Methods{
        .context = undefined,
        .get_label = getLabel,
        .get_aria_label = getAriaLabel,
        .get_electron_accelerator = getElectronAccelerator,
        .get_user_settings_label = getUserSettingsLabel,
        .is_wysiwyg = isWYSIWYG,
        .is_duplicate_modifier_case = isDuplicateModifierCase,
        .get_chord_dispatch = getChordDispatch,
        .get_single_modifier_chord_dispatch = getSingleModifierChordDispatch,
    };
};

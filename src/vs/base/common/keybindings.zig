// Port of `src/vs/base/common/keybindings.ts`.
//
// Terminal adaptations:
// - `decodeKeybinding` takes an allocator and owns the chord array; the caller
//   releases it with `freeChords`. A `Keybinding` value itself borrows its
//   chords, so stack literals work in tests and registries own the storage.
// - `Chord` is a tagged union instead of an `instanceof` class hierarchy.
// - `KeyCodeChord.toKeybinding()` is not ported: returning a view over a local
//   chord cannot be safe in Zig. Construct `Keybinding{ .chords = ... }`
//   directly instead.
// - `ResolvedKeybinding` is an interface (context + vtable), matching the
//   repository's `I*` adapter convention; concrete terminal adapters live in
//   `src/tui/`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const key_codes = @import("keyCodes.zig");
const KeyCode = key_codes.KeyCode;
const ScanCode = key_codes.ScanCode;
const KeyMod = key_codes.KeyMod;
const platform = @import("platform.zig");
const OperatingSystem = platform.OperatingSystem;

/// Binary encoding:
/// ```
///    1111 11
///    5432 1098 7654 3210
///    ---- CSAW KKKK KKKK
///  C = bit 11 = ctrlCmd flag
///  S = bit 10 = shift flag
///  A = bit 9 = alt flag
///  W = bit 8 = winCtrl flag
///  K = bits 0-7 = key code
/// ```
const BinaryKeybindingsMask = struct {
    const CtrlCmd: u32 = 1 << 11;
    const Shift: u32 = 1 << 10;
    const Alt: u32 = 1 << 9;
    const WinCtrl: u32 = 1 << 8;
    const KeyCodeMask: u32 = 0x000000FF;
};

pub const KeybindingInput = union(enum) {
    /// Upstream `number`.
    single: u32,
    /// Upstream `number[]`.
    multiple: []const u32,
};

/// Upstream `decodeKeybinding`. Returns `null` for the `0` "no keybinding"
/// value; an empty chord list is an invalid argument upstream (the `Keybinding`
/// constructor throws), so it returns `error.InvalidArgument` here. The caller
/// owns the returned chord array and frees it with `freeChords`.
pub fn decodeKeybinding(allocator: Allocator, input: KeybindingInput, os: OperatingSystem) !?Keybinding {
    switch (input) {
        .single => |value| {
            if (value == 0) return null;
            const first_chord: u32 = value & 0x0000FFFF;
            const second_chord: u32 = (value & 0xFFFF0000) >> 16;
            if (second_chord != 0) {
                const chords = try allocator.alloc(Chord, 2);
                errdefer allocator.free(chords);
                chords[0] = .{ .key_code = createSimpleKeybinding(first_chord, os) };
                chords[1] = .{ .key_code = createSimpleKeybinding(second_chord, os) };
                return Keybinding{ .chords = chords };
            }
            const chords = try allocator.alloc(Chord, 1);
            errdefer allocator.free(chords);
            chords[0] = .{ .key_code = createSimpleKeybinding(first_chord, os) };
            return Keybinding{ .chords = chords };
        },
        .multiple => |values| {
            if (values.len == 0) return error.InvalidArgument;
            const chords = try allocator.alloc(Chord, values.len);
            errdefer allocator.free(chords);
            for (values, 0..) |value, index| {
                chords[index] = .{ .key_code = createSimpleKeybinding(value, os) };
            }
            return Keybinding{ .chords = chords };
        },
    }
}

/// Releases chords allocated by `decodeKeybinding`.
pub fn freeChords(allocator: Allocator, keybinding: Keybinding) void {
    allocator.free(keybinding.chords);
}

pub fn createSimpleKeybinding(keybinding: u32, os: OperatingSystem) KeyCodeChord {
    const ctrl_cmd = (keybinding & BinaryKeybindingsMask.CtrlCmd) != 0;
    const win_ctrl = (keybinding & BinaryKeybindingsMask.WinCtrl) != 0;

    const ctrl_key = if (os == .Macintosh) win_ctrl else ctrl_cmd;
    const shift_key = (keybinding & BinaryKeybindingsMask.Shift) != 0;
    const alt_key = (keybinding & BinaryKeybindingsMask.Alt) != 0;
    const meta_key = if (os == .Macintosh) ctrl_cmd else win_ctrl;
    const key_code: KeyCode = @fromBackingInt(@intCast(@as(i16, @intCast(keybinding & BinaryKeybindingsMask.KeyCodeMask))));

    return .{
        .ctrl_key = ctrl_key,
        .shift_key = shift_key,
        .alt_key = alt_key,
        .meta_key = meta_key,
        .key_code = key_code,
    };
}

/// Upstream `Modifiers`.
pub const Modifiers = struct {
    ctrl_key: bool,
    shift_key: bool,
    alt_key: bool,
    meta_key: bool,
};

/// Represents a chord which uses the `keyCode` field of keyboard events.
pub const KeyCodeChord = struct {
    ctrl_key: bool,
    shift_key: bool,
    alt_key: bool,
    meta_key: bool,
    key_code: KeyCode,

    pub fn init(ctrl_key: bool, shift_key: bool, alt_key: bool, meta_key: bool, key_code: KeyCode) KeyCodeChord {
        return .{
            .ctrl_key = ctrl_key,
            .shift_key = shift_key,
            .alt_key = alt_key,
            .meta_key = meta_key,
            .key_code = key_code,
        };
    }

    pub fn equals(self: KeyCodeChord, other: Chord) bool {
        return switch (other) {
            .key_code => |chord| self.ctrl_key == chord.ctrl_key and
                self.shift_key == chord.shift_key and
                self.alt_key == chord.alt_key and
                self.meta_key == chord.meta_key and
                self.key_code == chord.key_code,
            .scan_code => false,
        };
    }

    /// The caller owns the returned string.
    pub fn getHashCode(self: KeyCodeChord, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "K{d}{d}{d}{d}{d}", .{
            @intFromBool(self.ctrl_key),
            @intFromBool(self.shift_key),
            @intFromBool(self.alt_key),
            @intFromBool(self.meta_key),
            @backingInt(self.key_code),
        });
    }

    pub fn isModifierKey(self: KeyCodeChord) bool {
        return self.key_code == .Unknown or self.key_code == .Ctrl or self.key_code == .Meta or
            self.key_code == .Alt or self.key_code == .Shift;
    }

    /// Does this keybinding refer to the key code of a modifier and it also has
    /// the modifier flag?
    pub fn isDuplicateModifierCase(self: KeyCodeChord) bool {
        return (self.ctrl_key and self.key_code == .Ctrl) or
            (self.shift_key and self.key_code == .Shift) or
            (self.alt_key and self.key_code == .Alt) or
            (self.meta_key and self.key_code == .Meta);
    }
};

/// Represents a chord which uses the `code` field of keyboard events.
pub const ScanCodeChord = struct {
    ctrl_key: bool,
    shift_key: bool,
    alt_key: bool,
    meta_key: bool,
    scan_code: ScanCode,

    pub fn init(ctrl_key: bool, shift_key: bool, alt_key: bool, meta_key: bool, scan_code: ScanCode) ScanCodeChord {
        return .{
            .ctrl_key = ctrl_key,
            .shift_key = shift_key,
            .alt_key = alt_key,
            .meta_key = meta_key,
            .scan_code = scan_code,
        };
    }

    pub fn equals(self: ScanCodeChord, other: Chord) bool {
        return switch (other) {
            .scan_code => |chord| self.ctrl_key == chord.ctrl_key and
                self.shift_key == chord.shift_key and
                self.alt_key == chord.alt_key and
                self.meta_key == chord.meta_key and
                self.scan_code == chord.scan_code,
            .key_code => false,
        };
    }

    /// The caller owns the returned string.
    pub fn getHashCode(self: ScanCodeChord, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "S{d}{d}{d}{d}{d}", .{
            @intFromBool(self.ctrl_key),
            @intFromBool(self.shift_key),
            @intFromBool(self.alt_key),
            @intFromBool(self.meta_key),
            @backingInt(self.scan_code),
        });
    }

    /// Does this keybinding refer to the key code of a modifier and it also has
    /// the modifier flag?
    pub fn isDuplicateModifierCase(self: ScanCodeChord) bool {
        return (self.ctrl_key and (self.scan_code == .ControlLeft or self.scan_code == .ControlRight)) or
            (self.shift_key and (self.scan_code == .ShiftLeft or self.scan_code == .ShiftRight)) or
            (self.alt_key and (self.scan_code == .AltLeft or self.scan_code == .AltRight)) or
            (self.meta_key and (self.scan_code == .MetaLeft or self.scan_code == .MetaRight));
    }
};

/// Upstream `Chord`.
pub const Chord = union(enum) {
    key_code: KeyCodeChord,
    scan_code: ScanCodeChord,

    pub fn equals(self: Chord, other: Chord) bool {
        return switch (self) {
            .key_code => |chord| chord.equals(other),
            .scan_code => |chord| chord.equals(other),
        };
    }

    /// The caller owns the returned string.
    pub fn getHashCode(self: Chord, allocator: Allocator) ![]u8 {
        return switch (self) {
            .key_code => |chord| chord.getHashCode(allocator),
            .scan_code => |chord| chord.getHashCode(allocator),
        };
    }

    pub fn isDuplicateModifierCase(self: Chord) bool {
        return switch (self) {
            .key_code => |chord| chord.isDuplicateModifierCase(),
            .scan_code => |chord| chord.isDuplicateModifierCase(),
        };
    }
};

/// A keybinding is a sequence of chords. The chord slice is borrowed; use
/// `decodeKeybinding`/`freeChords` for the owning form.
pub const Keybinding = struct {
    chords: []const Chord,

    /// Upstream `new Keybinding(chords)` rejects an empty chord list with
    /// `illegalArgument`.
    pub fn init(chords: []const Chord) error{InvalidArgument}!Keybinding {
        if (chords.len == 0) return error.InvalidArgument;
        return .{ .chords = chords };
    }

    /// The caller owns the returned string.
    pub fn getHashCode(self: Keybinding, allocator: Allocator) ![]u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();
        for (self.chords, 0..) |chord, index| {
            if (index != 0) try result.append(';');
            const hash = try chord.getHashCode(allocator);
            defer allocator.free(hash);
            try result.appendSlice(hash);
        }
        return result.toOwnedSlice();
    }

    pub fn equals(self: Keybinding, other: ?*const Keybinding) bool {
        const other_value = other orelse return false;
        if (self.chords.len != other_value.chords.len) return false;
        for (self.chords, other_value.chords) |chord, other_chord| {
            if (!chord.equals(other_chord)) return false;
        }
        return true;
    }
};

pub const ResolvedChord = struct {
    ctrl_key: bool,
    shift_key: bool,
    alt_key: bool,
    meta_key: bool,
    key_label: ?[]const u8,
    key_aria_label: ?[]const u8,
};

pub const SingleModifierChord = enum { ctrl, shift, alt, meta };

/// Upstream abstract class `ResolvedKeybinding`. Strings are borrowed from the
/// implementation.
pub const ResolvedKeybinding = struct {
    context: *anyopaque,
    get_label_fn: *const fn (context: *anyopaque) ?[]const u8,
    get_aria_label_fn: *const fn (context: *anyopaque) ?[]const u8,
    get_electron_accelerator_fn: *const fn (context: *anyopaque) ?[]const u8,
    get_user_settings_label_fn: *const fn (context: *anyopaque) ?[]const u8,
    is_wysiwyg_fn: *const fn (context: *anyopaque) bool,
    has_multiple_chords_fn: *const fn (context: *anyopaque) bool,
    get_chords_fn: *const fn (context: *anyopaque) []const ResolvedChord,
    get_dispatch_chords_fn: *const fn (context: *anyopaque) []const ?[]const u8,
    get_single_modifier_dispatch_chords_fn: *const fn (context: *anyopaque) []const ?SingleModifierChord,

    pub fn getLabel(self: ResolvedKeybinding) ?[]const u8 {
        return self.get_label_fn(self.context);
    }

    pub fn getAriaLabel(self: ResolvedKeybinding) ?[]const u8 {
        return self.get_aria_label_fn(self.context);
    }

    pub fn getElectronAccelerator(self: ResolvedKeybinding) ?[]const u8 {
        return self.get_electron_accelerator_fn(self.context);
    }

    pub fn getUserSettingsLabel(self: ResolvedKeybinding) ?[]const u8 {
        return self.get_user_settings_label_fn(self.context);
    }

    pub fn isWYSIWYG(self: ResolvedKeybinding) bool {
        return self.is_wysiwyg_fn(self.context);
    }

    pub fn hasMultipleChords(self: ResolvedKeybinding) bool {
        return self.has_multiple_chords_fn(self.context);
    }

    pub fn getChords(self: ResolvedKeybinding) []const ResolvedChord {
        return self.get_chords_fn(self.context);
    }

    pub fn getDispatchChords(self: ResolvedKeybinding) []const ?[]const u8 {
        return self.get_dispatch_chords_fn(self.context);
    }

    pub fn getSingleModifierDispatchChords(self: ResolvedKeybinding) []const ?SingleModifierChord {
        return self.get_single_modifier_dispatch_chords_fn(self.context);
    }
};

test "decodeKeybinding decodes modifiers per OS" {
    const allocator = std.testing.allocator;

    try std.testing.expect(null == try decodeKeybinding(allocator, .{ .single = 0 }, .Linux));

    const plain = (try decodeKeybinding(allocator, .{ .single = @backingInt(KeyCode.Enter) }, .Linux)).?;
    defer freeChords(allocator, plain);
    try std.testing.expectEqual(@as(usize, 1), plain.chords.len);
    try std.testing.expect(plain.chords[0].equals(.{ .key_code = KeyCodeChord.init(false, false, false, false, .Enter) }));

    const ctrl_cmd = (try decodeKeybinding(allocator, .{ .single = KeyMod.CtrlCmd | @backingInt(KeyCode.Enter) }, .Macintosh)).?;
    defer freeChords(allocator, ctrl_cmd);
    try std.testing.expect(ctrl_cmd.chords[0].equals(.{ .key_code = KeyCodeChord.init(false, false, false, true, .Enter) }));

    const win_ctrl = (try decodeKeybinding(allocator, .{ .single = KeyMod.WinCtrl | @backingInt(KeyCode.Enter) }, .Windows)).?;
    defer freeChords(allocator, win_ctrl);
    try std.testing.expect(win_ctrl.chords[0].equals(.{ .key_code = KeyCodeChord.init(false, false, false, true, .Enter) }));
}

test "decodeKeybinding decodes two chords" {
    const allocator = std.testing.allocator;
    const encoded = key_codes.KeyChord(@backingInt(KeyCode.Enter), @backingInt(KeyCode.Tab));
    const decoded = (try decodeKeybinding(allocator, .{ .single = encoded }, .Linux)).?;
    defer freeChords(allocator, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.chords.len);
    try std.testing.expect(decoded.chords[0].equals(.{ .key_code = KeyCodeChord.init(false, false, false, false, .Enter) }));
    try std.testing.expect(decoded.chords[1].equals(.{ .key_code = KeyCodeChord.init(false, false, false, false, .Tab) }));
}

test "Keybinding equality and hash codes" {
    const allocator = std.testing.allocator;
    const first_chord = KeyCodeChord.init(false, true, false, false, .KeyA);
    const first = Keybinding{ .chords = &.{.{ .key_code = first_chord }} };
    const second = Keybinding{ .chords = &.{.{ .key_code = KeyCodeChord.init(false, true, false, false, .KeyA) }} };

    try std.testing.expect(first.equals(&second));
    try std.testing.expect(!first.equals(null));

    const hash = try first.getHashCode(allocator);
    defer allocator.free(hash);
    try std.testing.expectEqualStrings("K010031", hash);
}

// Port of `src/vs/base/common/keybindingLabels.ts`.
//
// Terminal adaptations:
// - `ModifierLabelProvider.toLabel` takes the per-chord labels (allocated by
//   the resolved keybinding) and returns an owned joined string. The caller
//   frees it.
// - The four upstream provider instances are file-scope constants.
const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("platform.zig");
const OperatingSystem = platform.OperatingSystem;

pub const ModifierLabels = struct {
    ctrl_key: []const u8,
    shift_key: []const u8,
    alt_key: []const u8,
    meta_key: []const u8,
    separator: []const u8,
};

/// A label provider over chords that carry modifier booleans (`KeyCodeChord`
/// and `ScanCodeChord`).
pub const ModifierLabelProvider = struct {
    mac: ModifierLabels,
    windows: ModifierLabels,
    linux: ModifierLabels,

    pub fn init(mac: ModifierLabels, windows: ModifierLabels, linux: ModifierLabels) ModifierLabelProvider {
        return .{ .mac = mac, .windows = windows, .linux = linux };
    }

    pub fn labelsFor(self: ModifierLabelProvider, os: OperatingSystem) ModifierLabels {
        return switch (os) {
            .Macintosh => self.mac,
            .Windows => self.windows,
            .Linux => self.linux,
        };
    }

    /// Returns `null` when any chord cannot be expressed. The caller owns the
    /// returned string.
    pub fn toLabel(
        self: ModifierLabelProvider,
        allocator: Allocator,
        os: OperatingSystem,
        chords: anytype,
        labels: []const ?[]u8,
    ) !?[]u8 {
        if (chords.len == 0) return null;

        const modifier_labels = self.labelsFor(os);
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();

        for (chords, labels, 0..) |chord, label, index| {
            const key_label = label orelse return null;
            if (index > 0) try result.append(' ');
            try simpleAsString(&result, chord, key_label, modifier_labels);
        }

        return try result.toOwnedSlice();
    }
};

fn simpleAsString(
    result: *std.array_list.Managed(u8),
    modifiers: anytype,
    key: []const u8,
    labels: ModifierLabels,
) !void {
    var first = true;
    const append = struct {
        fn part(list: *std.array_list.Managed(u8), value: []const u8, separator: []const u8, first_ptr: *bool) !void {
            if (!first_ptr.*) try list.appendSlice(separator);
            try list.appendSlice(value);
            first_ptr.* = false;
        }
    };

    if (modifiers.ctrl_key) try append.part(result, labels.ctrl_key, labels.separator, &first);
    if (modifiers.shift_key) try append.part(result, labels.shift_key, labels.separator, &first);
    if (modifiers.alt_key) try append.part(result, labels.alt_key, labels.separator, &first);
    if (modifiers.meta_key) try append.part(result, labels.meta_key, labels.separator, &first);
    if (key.len != 0) try append.part(result, key, labels.separator, &first);
}

/// A label provider that prints modifiers in a suitable format for the UI.
pub const UILabelProvider = ModifierLabelProvider.init(
    .{ .ctrl_key = "\u{2303}", .shift_key = "\u{21e7}", .alt_key = "\u{2325}", .meta_key = "\u{2318}", .separator = "" },
    .{ .ctrl_key = "Ctrl", .shift_key = "Shift", .alt_key = "Alt", .meta_key = "Windows", .separator = "+" },
    .{ .ctrl_key = "Ctrl", .shift_key = "Shift", .alt_key = "Alt", .meta_key = "Super", .separator = "+" },
);

/// A label provider that prints modifiers in a suitable format for ARIA.
pub const AriaLabelProvider = ModifierLabelProvider.init(
    .{ .ctrl_key = "Control", .shift_key = "Shift", .alt_key = "Option", .meta_key = "Command", .separator = "+" },
    .{ .ctrl_key = "Control", .shift_key = "Shift", .alt_key = "Alt", .meta_key = "Windows", .separator = "+" },
    .{ .ctrl_key = "Control", .shift_key = "Shift", .alt_key = "Alt", .meta_key = "Super", .separator = "+" },
);

/// A label provider that prints modifiers for Electron accelerators.
pub const ElectronAcceleratorLabelProvider = ModifierLabelProvider.init(
    .{ .ctrl_key = "Ctrl", .shift_key = "Shift", .alt_key = "Alt", .meta_key = "Cmd", .separator = "+" },
    .{ .ctrl_key = "Ctrl", .shift_key = "Shift", .alt_key = "Alt", .meta_key = "Super", .separator = "+" },
    .{ .ctrl_key = "Ctrl", .shift_key = "Shift", .alt_key = "Alt", .meta_key = "Super", .separator = "+" },
);

/// A label provider that prints modifiers in a suitable format for user
/// settings.
pub const UserSettingsLabelProvider = ModifierLabelProvider.init(
    .{ .ctrl_key = "ctrl", .shift_key = "shift", .alt_key = "alt", .meta_key = "cmd", .separator = "+" },
    .{ .ctrl_key = "ctrl", .shift_key = "shift", .alt_key = "alt", .meta_key = "win", .separator = "+" },
    .{ .ctrl_key = "ctrl", .shift_key = "shift", .alt_key = "alt", .meta_key = "meta", .separator = "+" },
);

test "simpleAsString skips an empty key and ends without the separator" {
    const allocator = std.testing.allocator;
    const labels = UILabelProvider.labelsFor(.Windows);
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    const modifiers = @import("keybindings.zig").KeyCodeChord.init(true, false, true, false, .Alt);
    try simpleAsString(&result, modifiers, "", labels);
    try std.testing.expectEqualStrings("Ctrl+Alt", result.items);
}

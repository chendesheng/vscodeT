// Port of `src/vs/platform/action/common/action.ts`.
//
// Terminal adaptation: `Icon` is a string (a theme icon id or a path) instead
// of a `URI`/`ThemeIcon` union; URLs and themables are not ported. Localized
// strings are plain structs with the English `value` and its `original`.
const std = @import("std");
const contextkey = @import("../../contextkey/common/contextkey.zig");

pub const ILocalizedString = struct {
    value: []const u8,
    original: []const u8,
};

pub fn isLocalizedString(value: anytype) bool {
    const T = @TypeOf(value);
    if (T != ILocalizedString) return false;
    return value.original.len > 0 and value.value.len > 0;
}

pub const ICommandActionTitle = struct {
    localized: ILocalizedString,
    /// Title with a mnemonic designation; `&&` precedes the mnemonic.
    mnemonic_title: ?[]const u8 = null,
};

/// A theme icon id or an icon path.
pub const Icon = []const u8;

pub const ICommandActionToggleInfo = struct {
    condition: *const contextkey.Expr,
    icon: ?Icon = null,
    tooltip: ?[]const u8 = null,
    title: ?[]const u8 = null,
    mnemonic_title: ?[]const u8 = null,
};

pub const ICommandActionSource = struct {
    id: []const u8,
    title: []const u8,
};

pub const ICommandAction = struct {
    id: []const u8,
    title: []const u8,
    short_title: ?[]const u8 = null,
    category: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    icon: ?Icon = null,
    source: ?ICommandActionSource = null,
    /// Precondition controls enablement (menu items render disabled).
    precondition: ?*const contextkey.Expr = null,
    toggled: ?*const contextkey.Expr = null,
    toggle_info: ?ICommandActionToggleInfo = null,
};

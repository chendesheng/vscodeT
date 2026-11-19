const std = @import("std");

/// Color scheme used by the OS and by color themes.
pub const ColorScheme = enum(u8) {
    DARK,
    LIGHT,
    HIGH_CONTRAST_DARK,
    HIGH_CONTRAST_LIGHT,

    pub fn toString(self: ColorScheme) []const u8 {
        return switch (self) {
            .DARK => "dark",
            .LIGHT => "light",
            .HIGH_CONTRAST_DARK => "hcDark",
            .HIGH_CONTRAST_LIGHT => "hcLight",
        };
    }
};

pub const ThemeTypeSelector = enum(u8) {
    VS,
    VS_DARK,
    HC_BLACK,
    HC_LIGHT,
};

/// Port of upstream `isHighContrast`.
pub fn isHighContrast(scheme: ColorScheme) bool {
    return scheme == .HIGH_CONTRAST_DARK or scheme == .HIGH_CONTRAST_LIGHT;
}

/// Port of upstream `isDark`.
pub fn isDark(scheme: ColorScheme) bool {
    return scheme == .DARK or scheme == .HIGH_CONTRAST_DARK;
}

test "theme: color scheme string values" {
    try std.testing.expectEqualStrings("dark", ColorScheme.DARK.toString());
    try std.testing.expectEqualStrings("light", ColorScheme.LIGHT.toString());
    try std.testing.expectEqualStrings("hcDark", ColorScheme.HIGH_CONTRAST_DARK.toString());
    try std.testing.expectEqualStrings("hcLight", ColorScheme.HIGH_CONTRAST_LIGHT.toString());
}

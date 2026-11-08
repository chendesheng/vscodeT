const std = @import("std");
const Color = @import("../../../base/common/color.zig").Color;
const theme = @import("./theme.zig");
const ColorScheme = theme.ColorScheme;
const ThemeTypeSelector = theme.ThemeTypeSelector;

pub const ColorIdentifier = []const u8;

pub const ITokenStyle = struct {
    foreground: ?u32 = null,
    bold: ?bool = null,
    underline: ?bool = null,
    strikethrough: ?bool = null,
    italic: ?bool = null,
};

pub const IFontTokenOptions = struct {
    fontFamily: ?[]const u8 = null,
    fontSizeMultiplier: ?f64 = null,
    lineHeightMultiplier: ?f64 = null,
};

/// A color theme.
///
/// The read-only data is stored inline; the methods are dispatched through a
/// vtable so that concrete themes (JSON themes, test themes, ...) can provide
/// their own backing storage.
pub const IColorTheme = struct {
    theme_type: ColorScheme,
    label: []const u8,
    tokenColorMap: []const []const u8 = &.{},
    tokenFontMap: []const IFontTokenOptions = &.{},
    semanticHighlighting: bool = false,

    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getColor: *const fn (context: *anyopaque, color: ColorIdentifier, useDefault: bool) ?Color,
        defines: *const fn (context: *anyopaque, color: ColorIdentifier) bool,
        getTokenStyleMetadata: *const fn (
            context: *anyopaque,
            token_type: []const u8,
            modifiers: []const []const u8,
            modelLanguage: []const u8,
        ) ?ITokenStyle,
    };

    pub fn init(
        theme_type: ColorScheme,
        label: []const u8,
        context: *anyopaque,
        vtable: *const VTable,
    ) IColorTheme {
        return .{
            .theme_type = theme_type,
            .label = label,
            .context = context,
            .vtable = vtable,
        };
    }

    pub fn getColor(self: *const IColorTheme, color: ColorIdentifier, useDefault: bool) ?Color {
        return self.vtable.getColor(self.context, color, useDefault);
    }

    pub fn defines(self: *const IColorTheme, color: ColorIdentifier) bool {
        return self.vtable.defines(self.context, color);
    }

    pub fn getTokenStyleMetadata(
        self: *const IColorTheme,
        token_type: []const u8,
        modifiers: []const []const u8,
        modelLanguage: []const u8,
    ) ?ITokenStyle {
        return self.vtable.getTokenStyleMetadata(self.context, token_type, modifiers, modelLanguage);
    }
};

pub const IFileIconTheme = struct {
    hasFileIcons: bool,
    hasFolderIcons: bool,
    hidesExplorerArrows: bool,
};

pub fn getThemeTypeSelector(theme_type: ColorScheme) ThemeTypeSelector {
    return switch (theme_type) {
        .DARK => .VS_DARK,
        .HIGH_CONTRAST_DARK => .HC_BLACK,
        .HIGH_CONTRAST_LIGHT => .HC_LIGHT,
        else => .VS,
    };
}

test "themeService: color theme vtable" {
    const TestTheme = struct {
        fn getColor(context: *anyopaque, color: ColorIdentifier, useDefault: bool) ?Color {
            _ = context;
            _ = useDefault;
            if (std.mem.eql(u8, color, "foreground")) {
                return .{ .r = 1, .g = 2, .b = 3, .a = 1 };
            }
            return null;
        }

        fn defines(context: *anyopaque, color: ColorIdentifier) bool {
            _ = context;
            return std.mem.eql(u8, color, "foreground");
        }

        fn getTokenStyleMetadata(
            context: *anyopaque,
            token_type: []const u8,
            modifiers: []const []const u8,
            modelLanguage: []const u8,
        ) ?ITokenStyle {
            _ = context;
            _ = modifiers;
            _ = modelLanguage;
            if (std.mem.eql(u8, token_type, "keyword")) {
                return .{ .foreground = 0x112233, .bold = true };
            }
            return null;
        }

        const vtable = IColorTheme.VTable{
            .getColor = getColor,
            .defines = defines,
            .getTokenStyleMetadata = getTokenStyleMetadata,
        };
    };

    var context: u8 = 0;
    var color_theme = IColorTheme.init(.DARK, "Test Theme", &context, &TestTheme.vtable);

    const color = color_theme.getColor("foreground", true).?;
    try std.testing.expectEqual(@as(u8, 1), color.r);
    try std.testing.expect(color_theme.defines("foreground"));
    try std.testing.expect(!color_theme.defines("background"));

    const style = color_theme.getTokenStyleMetadata("keyword", &.{}, "zig").?;
    try std.testing.expectEqual(@as(?u32, 0x112233), style.foreground);
    try std.testing.expectEqual(@as(?bool, true), style.bold);
}

test "themeService: theme type selector" {
    try std.testing.expectEqual(ThemeTypeSelector.VS_DARK, getThemeTypeSelector(.DARK));
    try std.testing.expectEqual(ThemeTypeSelector.VS, getThemeTypeSelector(.LIGHT));
    try std.testing.expectEqual(ThemeTypeSelector.HC_BLACK, getThemeTypeSelector(.HIGH_CONTRAST_DARK));
    try std.testing.expectEqual(ThemeTypeSelector.HC_LIGHT, getThemeTypeSelector(.HIGH_CONTRAST_LIGHT));
}

const std = @import("std");
const themeService = @import("../../platform/theme/common/themeService.zig");
const IColorTheme = themeService.IColorTheme;
const ITokenStyle = themeService.ITokenStyle;
const Color = @import("../../base/common/color.zig").Color;
const ColorScheme = @import("../../platform/theme/common/theme.zig").ColorScheme;

pub const EditorTheme = struct {
    _theme: IColorTheme,

    pub fn init(theme: IColorTheme) EditorTheme {
        return .{ ._theme = theme };
    }

    pub fn getType(self: *const EditorTheme) ColorScheme {
        return self._theme.theme_type;
    }

    pub fn value(self: *const EditorTheme) *const IColorTheme {
        return &self._theme;
    }

    pub fn update(self: *EditorTheme, theme: IColorTheme) void {
        self._theme = theme;
    }

    pub fn getColor(self: *const EditorTheme, color: []const u8) ?Color {
        return self._theme.getColor(color, true);
    }
};

test "editorTheme: updates and delegates to the color theme" {
    const TestTheme = struct {
        fn getColor(context: *anyopaque, color: []const u8, useDefault: bool) ?Color {
            _ = context;
            _ = useDefault;
            if (std.mem.eql(u8, color, "foreground")) {
                return .{ .r = 10, .g = 20, .b = 30, .a = 1 };
            }
            return null;
        }

        fn defines(context: *anyopaque, color: []const u8) bool {
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
            _ = token_type;
            _ = modifiers;
            _ = modelLanguage;
            return null;
        }

        const vtable = IColorTheme.VTable{
            .getColor = getColor,
            .defines = defines,
            .getTokenStyleMetadata = getTokenStyleMetadata,
        };
    };

    var context: u8 = 0;
    const dark = IColorTheme.init(.DARK, "Dark", &context, &TestTheme.vtable);
    var theme = EditorTheme.init(dark);

    try std.testing.expectEqual(ColorScheme.DARK, theme.getType());
    const color = theme.getColor("foreground").?;
    try std.testing.expectEqual(@as(u8, 10), color.r);

    const light = IColorTheme.init(.LIGHT, "Light", &context, &TestTheme.vtable);
    theme.update(light);
    try std.testing.expectEqual(ColorScheme.LIGHT, theme.getType());
    try std.testing.expectEqualStrings("Light", theme.value().label);
    try std.testing.expect(theme.getColor("missing") == null);
}

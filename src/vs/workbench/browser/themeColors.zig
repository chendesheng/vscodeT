//! Terminal palette bridge over the ported color-theme data.
//!
//! The `ui` library paints cells with direct `Style` values; VS Code paints
//! through CSS variables resolved from the active `ColorThemeData`. This module
//! resolves the color ids the terminal surfaces use and converts them to
//! `ui.Color`, compositing alpha over the theme's `editor.background` because
//! terminal cells have no alpha channel.
//!
//! Callers pass the palette their current literal as a fallback, so a theme
//! that does not define an id keeps the terminal's established look instead of
//! turning black. The fallback table is deliberately local to each surface;
//! the upstream color-id registrations for defaults are not ported yet.
const std = @import("std");
const ui = @import("ui");
const color_theme = @import("../services/themes/common/colorThemeData.zig");
const base_color = @import("../../base/common/color.zig");

pub const ThemeColors = struct {
    theme: *color_theme.ColorThemeData,
    background: ui.Color,
    foreground: ui.Color,

    pub fn init(theme: *color_theme.ColorThemeData) ThemeColors {
        const background: ui.Color = if (resolve(theme, "editor.background")) |c|
            .{ .r = c.r, .g = c.g, .b = c.b }
        else
            .{ .r = 30, .g = 30, .b = 33 };
        const foreground: ui.Color = if (resolve(theme, "editor.foreground")) |c|
            .{ .r = c.r, .g = c.g, .b = c.b }
        else
            .{ .r = 204, .g = 204, .b = 204 };
        return .{ .theme = theme, .background = background, .foreground = foreground };
    }

    /// Resolves `id`, falling back to the surface's current literal.
    pub fn color(self: ThemeColors, id: []const u8, fallback: [3]u8) ui.Color {
        const raw = resolve(self.theme, id) orelse return .{ .r = fallback[0], .g = fallback[1], .b = fallback[2] };
        return self.composite(raw);
    }

    /// Resolves `id`, falling back to an already-resolved color.
    pub fn colorOr(self: ThemeColors, id: []const u8, fallback: ui.Color) ui.Color {
        const raw = resolve(self.theme, id) orelse return fallback;
        return self.composite(raw);
    }

    /// Raw theme color, including its alpha. Surfaces that need to know
    /// whether a color was defined at all (for example the bracket-highlight
    /// pool, which skips transparent entries like upstream's `ColorProvider`)
    /// use this instead of `color`.
    pub fn rawColor(self: ThemeColors, id: []const u8) ?base_color.Color {
        return resolve(self.theme, id);
    }

    /// Composites an already-resolved color over the theme background.
    pub fn compositeColor(self: ThemeColors, value: base_color.Color) ui.Color {
        return self.composite(value);
    }

    /// Resolved foreground for plain text in the editor area.
    pub fn text(self: ThemeColors) ui.Color {
        return self.foreground;
    }

    pub fn paint(self: ThemeColors, id: []const u8, fallback: [3]u8) ui.cell.PaintStyle {
        return .{ .fg = ui.cell.packColor(self.color(id, fallback)) };
    }

    fn composite(self: ThemeColors, value: base_color.Color) ui.Color {
        const alpha: f32 = @floatCast(value.a);
        if (alpha >= 0.999) return .{ .r = value.r, .g = value.g, .b = value.b };
        if (alpha <= 0.001) return self.background;
        return .{
            .r = mix(self.background.r, value.r, alpha),
            .g = mix(self.background.g, value.g, alpha),
            .b = mix(self.background.b, value.b, alpha),
        };
    }

    fn mix(background: u8, foreground: u8, alpha: f32) u8 {
        const blended = @as(f32, @floatFromInt(foreground)) * alpha +
            @as(f32, @floatFromInt(background)) * (1 - alpha);
        return @intFromFloat(@round(std.math.clamp(blended, 0, 255)));
    }
};

fn resolve(theme: *color_theme.ColorThemeData, id: []const u8) ?base_color.Color {
    return theme.getColor(id, true);
}

test "ThemeColors: resolves theme colors, composits alpha and falls back" {
    const allocator = std.testing.allocator;
    const color_utils = @import("../../platform/theme/common/colorUtils.zig");
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    const theme = try color_theme.ColorThemeData.createUnloadedTheme(allocator, &registry, "test", &.{
        .{ "editor.background", "#101010" },
        .{ "editor.foreground", "#e0e0e0" },
        .{ "editor.selectionBackground", "#ff000080" }, // #RRGGBBAA: half-transparent red
    });
    defer theme.deinit();

    const palette = ThemeColors.init(theme);
    try std.testing.expectEqual(@as(u8, 0x10), palette.background.r);
    try std.testing.expectEqual(@as(u8, 0xe0), palette.foreground.g);

    const missing = palette.color("editor.findMatchBackground", .{ 1, 2, 3 });
    try std.testing.expectEqual(@as(u8, 1), missing.r);
    try std.testing.expectEqual(@as(u8, 2), missing.g);

    const selection = palette.color("editor.selectionBackground", .{ 0, 0, 0 });
    try std.testing.expect(selection.r > 0x80 and selection.g < 0x20);
}

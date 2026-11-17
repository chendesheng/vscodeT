// Port of `src/vs/platform/theme/common/colorUtils.ts` (color-value transforms).
//
// Terminal adaptations:
// - The global `ColorRegistry`, JSON-schema contribution and CSS variable
//   helpers are not ported (no settings-schema UI/CSS); transforms and
//   `resolveColorValue`/`executeTransform` are.
// - Nested transforms use a pointer operand (`ColorValue.transform`), because a
//   Zig tagged union cannot contain itself by value.
const std = @import("std");
const Color = @import("../../../base/common/color.zig").Color;
const theme_service = @import("./themeService.zig");
const IColorTheme = theme_service.IColorTheme;
const ColorIdentifier = theme_service.ColorIdentifier;

pub const ColorTransformType = enum(u8) {
    darken = 0,
    lighten = 1,
    transparent = 2,
    opacity = 3,
    mix = 4,
    opaque_color = 5,
    one_of = 6,
    if_defined_then_else = 7,
    less_prominent = 8,
};

pub const ColorValue = union(enum) {
    color: Color,
    /// A `#`-prefixed hex string or a theme color id.
    string: []const u8,
    transform: *const ColorTransform,
};

pub const ColorTransform = union(enum) {
    darken: struct { value: ColorValue, factor: f32 },
    lighten: struct { value: ColorValue, factor: f32 },
    transparent: struct { value: ColorValue, factor: f32 },
    opacity: struct { value: ColorValue, opacity: f32 },
    mix: struct { color: ColorValue, with: ColorValue, ratio: f32 },
    opaque_color: struct { value: ColorValue, background: ColorValue },
    one_of: struct { values: []const ColorValue },
    if_defined_then_else: struct { if_key: ColorIdentifier, then: ColorValue, otherwise: ColorValue },
    less_prominent: struct { value: ColorValue, background: ColorValue, factor: f32, transparency: f32 },
};

pub fn darken(value: ColorValue, factor: f32) ColorTransform {
    return .{ .darken = .{ .value = value, .factor = factor } };
}

pub fn lighten(value: ColorValue, factor: f32) ColorTransform {
    return .{ .lighten = .{ .value = value, .factor = factor } };
}

pub fn transparent(value: ColorValue, factor: f32) ColorTransform {
    return .{ .transparent = .{ .value = value, .factor = factor } };
}

/// Sets a color's opacity without scaling its existing alpha.
pub fn withOpacity(value: ColorValue, opacity: f32) ColorTransform {
    return .{ .opacity = .{ .value = value, .opacity = opacity } };
}

pub fn opaqueColor(value: ColorValue, background: ColorValue) ColorTransform {
    return .{ .opaque_color = .{ .value = value, .background = background } };
}

pub fn oneOf(values: []const ColorValue) ColorTransform {
    return .{ .one_of = .{ .values = values } };
}

pub fn ifDefinedThenElse(if_key: ColorIdentifier, then: ColorValue, otherwise: ColorValue) ColorTransform {
    return .{ .if_defined_then_else = .{ .if_key = if_key, .then = then, .otherwise = otherwise } };
}

pub fn lessProminent(value: ColorValue, background: ColorValue, factor: f32, transparency: f32) ColorTransform {
    return .{ .less_prominent = .{ .value = value, .background = background, .factor = factor, .transparency = transparency } };
}

pub fn executeTransform(transform: ColorTransform, theme: *const IColorTheme) ?Color {
    return switch (transform) {
        .darken => |op| if (resolveColorValue(op.value, theme)) |color| color.darken(op.factor) else null,
        .lighten => |op| if (resolveColorValue(op.value, theme)) |color| color.lighten(op.factor) else null,
        .transparent => |op| if (resolveColorValue(op.value, theme)) |color| color.transparent(op.factor) else null,
        .opacity => |op| if (resolveColorValue(op.value, theme)) |color| color.withAlpha(op.opacity) else null,
        .mix => |op| blk: {
            const primary = resolveColorValue(op.color, theme) orelse Color.transparent_color;
            const other = resolveColorValue(op.with, theme) orelse Color.transparent_color;
            break :blk primary.mix(other, op.ratio);
        },
        .opaque_color => |op| blk: {
            const background = resolveColorValue(op.background, theme) orelse
                break :blk resolveColorValue(op.value, theme);
            const value = resolveColorValue(op.value, theme) orelse break :blk null;
            break :blk value.makeOpaque(background);
        },
        .one_of => |op| blk: {
            for (op.values) |candidate| {
                if (resolveColorValue(candidate, theme)) |color| break :blk color;
            }
            break :blk null;
        },
        .if_defined_then_else => |op| resolveColorValue(
            if (theme.defines(op.if_key)) op.then else op.otherwise,
            theme,
        ),
        .less_prominent => |op| blk: {
            const from = resolveColorValue(op.value, theme) orelse break :blk null;
            const background = resolveColorValue(op.background, theme) orelse
                break :blk from.transparent(op.factor * op.transparency);
            break :blk if (from.isDarkerThan(background))
                Color.getLighterColor(from, background, op.factor).transparent(op.transparency)
            else
                Color.getDarkerColor(from, background, op.factor).transparent(op.transparency);
        },
    };
}

pub fn resolveColorValue(value: ColorValue, theme: *const IColorTheme) ?Color {
    return switch (value) {
        .color => |color| color,
        .string => |text| blk: {
            if (text.len > 0 and text[0] == '#') {
                break :blk Color.fromHex(text) catch null;
            }
            break :blk theme.getColor(text, true);
        },
        .transform => |transform| executeTransform(transform.*, theme),
    };
}

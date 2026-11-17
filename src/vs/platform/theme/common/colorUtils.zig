// Port of `src/vs/platform/theme/common/colorUtils.ts` (color-value transforms).
//
// Terminal adaptations:
// - The global `ColorRegistry`, JSON-schema contribution and CSS variable
//   helpers are not ported (no settings-schema UI/CSS); transforms and
//   `resolveColorValue`/`executeTransform` are.
// - Nested transforms use a pointer operand (`ColorValue.transform`), because a
//   Zig tagged union cannot contain itself by value.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const Color = @import("../../../base/common/color.zig").Color;
const theme_service = @import("./themeService.zig");
const IColorTheme = theme_service.IColorTheme;
const theme_mod = @import("./theme.zig");
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

pub const ColorDefaults = struct {
    light: ?ColorValue = null,
    dark: ?ColorValue = null,
    hc_dark: ?ColorValue = null,
    hc_light: ?ColorValue = null,

    fn forTheme(self: *const ColorDefaults, theme_type: theme_mod.ColorScheme) ?ColorValue {
        return switch (theme_type) {
            .LIGHT => self.light,
            .DARK => self.dark,
            .HIGH_CONTRAST_DARK => self.hc_dark,
            .HIGH_CONTRAST_LIGHT => self.hc_light,
        };
    }
};

pub const ColorContribution = struct {
    id: ColorIdentifier,
    description: []const u8,
    defaults: ?ColorDefaults = null,
    /// A single default value shared by all theme types.
    default_value: ?ColorValue = null,
    needs_transparency: bool = false,
    deprecation_message: ?[]const u8 = null,
};

/// Port of the `ColorRegistry` part of `colorUtils.ts`. The JSON schema
/// contribution is not ported (the terminal has no settings-schema UI); the
/// registry keeps the contributions and resolves theme defaults.
pub const ColorRegistry = struct {
    allocator: Allocator,
    colors: std.StringHashMap(ColorContribution),
    onDidChangeSchema: Emitter(void),

    pub fn init(allocator: Allocator) ColorRegistry {
        return .{
            .allocator = allocator,
            .colors = std.StringHashMap(ColorContribution).init(allocator),
            .onDidChangeSchema = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *ColorRegistry) void {
        self.colors.deinit();
        self.onDidChangeSchema.deinit();
    }

    pub fn registerColor(
        self: *ColorRegistry,
        id: ColorIdentifier,
        defaults: ?ColorDefaults,
        default_value: ?ColorValue,
        description: []const u8,
        needs_transparency: bool,
    ) !ColorIdentifier {
        try self.colors.put(id, .{
            .id = id,
            .description = description,
            .defaults = defaults,
            .default_value = default_value,
            .needs_transparency = needs_transparency,
        });
        try self.onDidChangeSchema.fire({});
        return id;
    }

    pub fn updateDefaultColor(self: *ColorRegistry, id: ColorIdentifier, defaults: ?ColorDefaults, default_value: ?ColorValue) void {
        if (self.colors.getPtr(id)) |contribution| {
            contribution.defaults = defaults;
            contribution.default_value = default_value;
        }
    }

    pub fn deregisterColor(self: *ColorRegistry, id: ColorIdentifier) void {
        _ = self.colors.remove(id);
        self.onDidChangeSchema.fire({}) catch {};
    }

    /// Contributions in insertion order; the returned slice is caller-owned.
    pub fn getColors(self: *ColorRegistry, allocator: Allocator) ![]const *const ColorContribution {
        var result = std.array_list.Managed(*const ColorContribution).init(allocator);
        errdefer result.deinit();
        var iterator = self.colors.valueIterator();
        while (iterator.next()) |contribution| try result.append(contribution);
        return result.toOwnedSlice();
    }

    pub fn getColor(self: *ColorRegistry, id: ColorIdentifier) ?ColorContribution {
        return self.colors.get(id);
    }

    pub fn resolveDefaultColor(self: *ColorRegistry, id: ColorIdentifier, theme: *const IColorTheme) ?Color {
        const contribution = self.colors.get(id) orelse return null;
        if (contribution.default_value) |value| return resolveColorValue(value, theme);
        if (contribution.defaults) |defaults| {
            const value = defaults.forTheme(theme.theme_type) orelse return null;
            return resolveColorValue(value, theme);
        }
        return null;
    }
};

const TestTheme = struct {
    theme_type: theme_mod.ColorScheme = .DARK,

    fn interface(self: *TestTheme) IColorTheme {
        return .{
            .theme_type = self.theme_type,
            .label = "test",
            .context = self,
            .vtable = &vtable,
        };
    }

    const vtable = IColorTheme.VTable{
        .getColor = getColor,
        .defines = defines,
        .getTokenStyleMetadata = getTokenStyleMetadata,
    };

    fn getColor(_: *anyopaque, _: []const u8, _: bool) ?Color {
        return null;
    }
    fn defines(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn getTokenStyleMetadata(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) ?theme_service.ITokenStyle {
        return null;
    }
};

test "color registry resolves per-theme defaults and updates" {
    const allocator = std.testing.allocator;
    var registry = ColorRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.registerColor("editor.background", .{
        .dark = .{ .string = "#000000" },
        .light = .{ .string = "#ffffff" },
    }, null, "Editor background", false);

    var dark = TestTheme{ .theme_type = .DARK };
    var light = TestTheme{ .theme_type = .LIGHT };
    const dark_color = registry.resolveDefaultColor("editor.background", &dark.interface()).?;
    try std.testing.expectEqual(@as(u8, 0), dark_color.r);
    const light_color = registry.resolveDefaultColor("editor.background", &light.interface()).?;
    try std.testing.expectEqual(@as(u8, 255), light_color.r);

    registry.updateDefaultColor("editor.background", null, .{ .string = "#ff0000" });
    const updated = registry.resolveDefaultColor("editor.background", &dark.interface()).?;
    try std.testing.expectEqual(@as(u8, 255), updated.r);
    try std.testing.expectEqual(@as(u8, 0), updated.g);

    const colors = try registry.getColors(allocator);
    defer allocator.free(colors);
    try std.testing.expectEqual(@as(usize, 1), colors.len);

    registry.deregisterColor("editor.background");
    try std.testing.expect(registry.resolveDefaultColor("editor.background", &dark.interface()) == null);
}

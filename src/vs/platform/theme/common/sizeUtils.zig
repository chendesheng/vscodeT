// Port of `src/vs/platform/theme/common/sizeUtils.ts` (data/registry core).
//
// Terminal adaptations: the registry is explicit instead of a platform-global
// singleton, there is no JSON-schema contribution registry (the schemas are
// kept as plain data where needed), and `notifyThemeUpdate` is not ported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const theme_mod = @import("./theme.zig");
const IColorTheme = @import("./themeService.zig").IColorTheme;
const ColorScheme = theme_mod.ColorScheme;

pub const SizeIdentifier = []const u8;

pub const SizeUnit = enum {
    px,
    rem,
    em,
    percent,
    unitless,

    pub fn suffix(self: SizeUnit) []const u8 {
        return switch (self) {
            .px => "px",
            .rem => "rem",
            .em => "em",
            .percent => "%",
            .unitless => "",
        };
    }
};

pub const SizeValue = struct {
    value: f64,
    unit: SizeUnit,
};

pub const SizeDefaults = struct {
    light: ?SizeValue = null,
    dark: ?SizeValue = null,
    hc_dark: ?SizeValue = null,
    hc_light: ?SizeValue = null,

    pub fn forTheme(self: *const SizeDefaults, theme_type: ColorScheme) ?SizeValue {
        return switch (theme_type) {
            .LIGHT => self.light,
            .DARK => self.dark,
            .HIGH_CONTRAST_DARK => self.hc_dark,
            .HIGH_CONTRAST_LIGHT => self.hc_light,
        };
    }
};

pub const SizeCustomization = struct {
    minimum: i64,
    maximum: i64,
};

pub const SizeDefaultsOrReference = union(enum) {
    defaults: SizeDefaults,
    value: SizeValue,
    reference: SizeIdentifier,
};

pub const SizeContribution = struct {
    id: SizeIdentifier,
    description: []const u8,
    defaults: ?SizeDefaultsOrReference = null,
    deprecation_message: ?[]const u8 = null,
    customization: ?SizeCustomization = null,
};

pub fn size(value: f64, unit: SizeUnit) SizeValue {
    return .{ .value = value, .unit = unit };
}

pub fn sizeForAllThemes(value: f64, unit: SizeUnit) SizeDefaults {
    const value_size = size(value, unit);
    return .{ .light = value_size, .dark = value_size, .hc_dark = value_size, .hc_light = value_size };
}

pub fn sizeValueToCss(allocator: Allocator, value: SizeValue) ![]u8 {
    if (value.unit == .unitless) return std.fmt.allocPrint(allocator, "{d}", .{value.value});
    return std.fmt.allocPrint(allocator, "{d}{s}", .{ value.value, value.unit.suffix() });
}

/// `--vscode-` + identifier with dots replaced by hyphens.
pub fn asCssVariableName(allocator: Allocator, id: SizeIdentifier) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("--vscode-");
    for (id) |character| {
        try out.writer.writeByte(if (character == '.') '-' else character);
    }
    return out.toOwnedSlice();
}

pub fn asCssVariable(allocator: Allocator, id: SizeIdentifier) ![]u8 {
    const name = try asCssVariableName(allocator, id);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "var({s})", .{name});
}

pub fn asCssVariableWithDefault(allocator: Allocator, id: SizeIdentifier, default_css: []const u8) ![]u8 {
    const name = try asCssVariableName(allocator, id);
    defer allocator.free(name);
    return std.fmt.allocPrint(allocator, "var({s}, {s})", .{ name, default_css });
}

pub const CustomizationProperty = struct {
    minimum: i64,
    maximum: i64,
};

pub const CustomizationSchema = struct {
    additional_properties: bool,
    properties: *const std.StringHashMap(CustomizationProperty),
};

pub const SizeRegistry = struct {
    allocator: Allocator,
    sizes: std.StringHashMap(SizeContribution),
    customization_properties: std.StringHashMap(CustomizationProperty),
    onDidChangeSchema: Emitter(void),

    pub fn init(allocator: Allocator) SizeRegistry {
        return .{
            .allocator = allocator,
            .sizes = std.StringHashMap(SizeContribution).init(allocator),
            .customization_properties = std.StringHashMap(CustomizationProperty).init(allocator),
            .onDidChangeSchema = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *SizeRegistry) void {
        self.sizes.deinit();
        self.customization_properties.deinit();
        self.onDidChangeSchema.deinit();
    }

    pub fn registerSize(
        self: *SizeRegistry,
        id: SizeIdentifier,
        defaults: ?SizeDefaultsOrReference,
        description: []const u8,
        deprecation_message: ?[]const u8,
        customization: ?SizeCustomization,
    ) !SizeIdentifier {
        try self.sizes.put(id, .{
            .id = id,
            .description = description,
            .defaults = defaults,
            .deprecation_message = deprecation_message,
            .customization = customization,
        });
        if (customization) |limits| {
            try self.customization_properties.put(id, .{ .minimum = limits.minimum, .maximum = limits.maximum });
        } else {
            _ = self.customization_properties.remove(id);
        }
        try self.onDidChangeSchema.fire({});
        return id;
    }

    pub fn deregisterSize(self: *SizeRegistry, id: SizeIdentifier) void {
        _ = self.sizes.remove(id);
        _ = self.customization_properties.remove(id);
        self.onDidChangeSchema.fire({}) catch {};
    }

    /// Contributions in insertion order; caller frees the returned slice.
    pub fn getSizes(self: *SizeRegistry, allocator: Allocator) ![]const *const SizeContribution {
        var result = std.array_list.Managed(*const SizeContribution).init(allocator);
        errdefer result.deinit();
        var iterator = self.sizes.valueIterator();
        while (iterator.next()) |contribution| try result.append(contribution);
        return result.toOwnedSlice();
    }

    pub fn getSizeCustomizationSchema(self: *SizeRegistry) CustomizationSchema {
        return .{ .additional_properties = false, .properties = &self.customization_properties };
    }

    pub fn getSize(self: *SizeRegistry, id: SizeIdentifier) ?SizeContribution {
        return self.sizes.get(id);
    }

    pub fn resolveDefaultSize(self: *SizeRegistry, id: SizeIdentifier, theme: *const IColorTheme) !?SizeValue {
        const empty = std.StringHashMap(i64).init(self.allocator);
        var customizations = empty;
        defer customizations.deinit();
        return self.resolveSize(id, theme, &customizations);
    }

    pub fn resolveSize(self: *SizeRegistry, id: SizeIdentifier, theme: *const IColorTheme, customizations: *const std.StringHashMap(i64)) !?SizeValue {
        var resolving = std.StringHashMap(void).init(self.allocator);
        defer resolving.deinit();
        return self.resolveSizeWithReferences(id, theme, customizations, &resolving);
    }

    fn resolveSizeWithReferences(
        self: *SizeRegistry,
        id: SizeIdentifier,
        theme: *const IColorTheme,
        customizations: *const std.StringHashMap(i64),
        resolving: *std.StringHashMap(void),
    ) !?SizeValue {
        if (resolving.contains(id)) return error.CircularSizeTokenReference;
        const contribution = self.sizes.get(id) orelse return null;
        if (contribution.customization) |limits| {
            if (customizations.get(id)) |customized| {
                if (customized >= limits.minimum and customized <= limits.maximum) {
                    return size(@floatFromInt(customized), .px);
                }
            }
        }
        const defaults = contribution.defaults orelse return null;
        switch (defaults) {
            .reference => |reference| {
                const key = try self.allocator.dupe(u8, id);
                try resolving.put(key, {});
                defer {
                    _ = resolving.remove(key);
                    self.allocator.free(key);
                }
                return self.resolveSizeWithReferences(reference, theme, customizations, resolving);
            },
            .value => |value| return value,
            .defaults => |values| return values.forTheme(theme.theme_type),
        }
    }
};

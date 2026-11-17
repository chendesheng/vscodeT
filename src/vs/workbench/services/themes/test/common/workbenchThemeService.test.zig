// Port of `src/vs/workbench/services/themes/test/common/workbenchThemeService.test.ts`.
//
// Terminal adaptation: the browser test's `TestConfigurationService` is
// replaced by a small in-memory service exposing the ported
// `IConfigurationService` interface; `TestHostColorSchemeService` keeps the
// mutable `dark`/`highContrast` fields the upstream test drives.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const configuration = @import("../../../../../platform/configuration/common/configuration.zig");
const configuration_registry = @import("../../../../../platform/configuration/common/configurationRegistry.zig");
const theme_mod = @import("../../../../../platform/theme/common/theme.zig");
const workbench_theme_service = @import("../../browser/workbenchThemeService.zig");
const host_color_scheme_service = @import("../../common/hostColorSchemeService.zig");
const theme_configuration = @import("../../common/themeConfiguration.zig");

const IConfigurationService = configuration.IConfigurationService;
const Value = configuration.Value;
const IHostColorSchemeService = host_color_scheme_service.IHostColorSchemeService;
const ThemeConfiguration = theme_configuration.ThemeConfiguration;
const ThemeSettings = workbench_theme_service.ThemeSettings;
const ThemeSettingDefaults = workbench_theme_service.ThemeSettingDefaults;
const ConfigurationScope = configuration.ConfigurationScope;

const TestHostColorSchemeService = struct {
    dark: bool = false,
    high_contrast: bool = false,

    fn isDark(context: *anyopaque) bool {
        return @as(*TestHostColorSchemeService, @ptrCast(@alignCast(context))).dark;
    }

    fn isHighContrast(context: *anyopaque) bool {
        return @as(*TestHostColorSchemeService, @ptrCast(@alignCast(context))).high_contrast;
    }

    fn interface(self: *TestHostColorSchemeService) IHostColorSchemeService {
        return .{
            .context = self,
            .is_dark = isDark,
            .is_high_contrast = isHighContrast,
        };
    }
};

const TestConfigurationService = struct {
    allocator: Allocator,
    values: std.StringHashMap(*Value),

    fn init(allocator: Allocator) TestConfigurationService {
        return .{ .allocator = allocator, .values = std.StringHashMap(*Value).init(allocator) };
    }

    fn deinit(self: *TestConfigurationService) void {
        var iterator = self.values.valueIterator();
        while (iterator.next()) |value| self.allocator.destroy(value.*);
        self.values.deinit();
    }

    fn setString(self: *TestConfigurationService, key: []const u8, value: []const u8) !void {
        if (self.values.get(key)) |existing| {
            existing.* = .{ .string = value };
            return;
        }
        const stored = try self.allocator.create(Value);
        stored.* = .{ .string = value };
        try self.values.put(key, stored);
    }

    fn setBool(self: *TestConfigurationService, key: []const u8, value: bool) !void {
        if (self.values.get(key)) |existing| {
            existing.* = .{ .bool = value };
            return;
        }
        const stored = try self.allocator.create(Value);
        stored.* = .{ .bool = value };
        try self.values.put(key, stored);
    }

    fn getValue(context: *anyopaque, key: []const u8) ?*const Value {
        const self: *TestConfigurationService = @ptrCast(@alignCast(context));
        return self.values.get(key);
    }

    fn interface(self: *TestConfigurationService) IConfigurationService {
        return .{ .context = self, .get_value = getValue };
    }
};

test "migrateThemeSettingsId: migrates Default-prefixed theme ids" {
    const expected = [_][]const u8{ "Dark Modern", "Light Modern", "Dark+", "Light+" };
    const input = [_][]const u8{ "Default Dark Modern", "Default Light Modern", "Default Dark+", "Default Light+" };
    for (input, expected) |settings_id, expected_id| {
        try testing.expectEqualStrings(expected_id, workbench_theme_service.migrateThemeSettingsId(settings_id));
    }
}

test "migrateThemeSettingsId: migrates Experimental theme ids to VS Code themes" {
    const expected = [_][]const u8{
        workbench_theme_service.ThemeSettingDefaults.COLOR_THEME_DARK,
        workbench_theme_service.ThemeSettingDefaults.COLOR_THEME_LIGHT,
        workbench_theme_service.ThemeSettingDefaults.COLOR_THEME_DARK,
        workbench_theme_service.ThemeSettingDefaults.COLOR_THEME_LIGHT,
    };
    const input = [_][]const u8{ "Experimental Dark", "Experimental Light", "VS Code Dark", "VS Code Light" };
    for (input, expected) |settings_id, expected_id| {
        try testing.expectEqualStrings(expected_id, workbench_theme_service.migrateThemeSettingsId(settings_id));
    }
}

test "migrateThemeSettingsId: returns unknown ids unchanged" {
    const ids = [_][]const u8{ "Dark Modern", "Dark 2026", "Some Custom Theme", "" };
    for (ids) |settings_id| {
        try testing.expectEqualStrings(settings_id, workbench_theme_service.migrateThemeSettingsId(settings_id));
    }
}

test "ThemeConfiguration: restores only for preferred color scheme changes" {
    var configuration_service = TestConfigurationService.init(testing.allocator);
    defer configuration_service.deinit();
    try configuration_service.setBool(ThemeSettings.DETECT_COLOR_SCHEME, false);
    try configuration_service.setBool(ThemeSettings.DETECT_HC, true);

    var host_color_service = TestHostColorSchemeService{};
    const configuration_model = ThemeConfiguration.init(
        configuration_service.interface(),
        host_color_service.interface(),
    );

    var results: [5]bool = undefined;
    host_color_service.dark = true;
    results[0] = configuration_model.isPreferredColorSchemeChange(.{ .dark = false, .highContrast = false });
    host_color_service.high_contrast = true;
    results[1] = configuration_model.isPreferredColorSchemeChange(.{ .dark = true, .highContrast = false });
    host_color_service.dark = false;
    results[2] = configuration_model.isPreferredColorSchemeChange(.{ .dark = true, .highContrast = true });
    host_color_service.high_contrast = false;
    results[3] = configuration_model.isPreferredColorSchemeChange(.{ .dark = false, .highContrast = true });

    try configuration_service.setBool(ThemeSettings.DETECT_COLOR_SCHEME, true);
    host_color_service.dark = true;
    results[4] = configuration_model.isPreferredColorSchemeChange(.{ .dark = false, .highContrast = false });

    try testing.expectEqual([5]bool{ false, true, true, true, true }, results);
}

test "ThemeConfiguration: registers the theme settings with upstream defaults" {
    var registry = try configuration_registry.ConfigurationRegistry.init(testing.allocator);
    defer registry.deinit();
    try theme_configuration.registerThemeConfigurationSchemas(registry);

    const properties = registry.getConfigurationProperties();

    const color_theme = properties.get(ThemeSettings.COLOR_THEME).?;
    try testing.expectEqualStrings("string", color_theme.value_type);
    try testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_DARK, color_theme.default.string);

    try testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_DARK, properties.get(ThemeSettings.PREFERRED_DARK_THEME).?.default.string);
    try testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_LIGHT, properties.get(ThemeSettings.PREFERRED_LIGHT_THEME).?.default.string);
    try testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_HC_DARK, properties.get(ThemeSettings.PREFERRED_HC_DARK_THEME).?.default.string);
    try testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_HC_LIGHT, properties.get(ThemeSettings.PREFERRED_HC_LIGHT_THEME).?.default.string);

    try testing.expect(properties.get(ThemeSettings.COLOR_CUSTOMIZATIONS).?.default == .object);
    try testing.expect(!properties.get(ThemeSettings.DETECT_COLOR_SCHEME).?.default.bool);
    try testing.expect(properties.get(ThemeSettings.DETECT_HC).?.default.bool);
    try testing.expectEqual(ConfigurationScope.APPLICATION, properties.get(ThemeSettings.DETECT_HC).?.scope);
    try testing.expectEqual(ConfigurationScope.WINDOW, properties.get(ThemeSettings.COLOR_THEME).?.scope);

    // The token customizations live in the editor configuration node.
    try testing.expect(properties.contains(ThemeSettings.TOKEN_COLOR_CUSTOMIZATIONS));
    try testing.expect(properties.contains(ThemeSettings.SEMANTIC_TOKEN_COLOR_CUSTOMIZATIONS));
    try testing.expect(properties.get(ThemeSettings.TOKEN_COLOR_CUSTOMIZATIONS).?.default == .object);
}

test "ThemeConfiguration: resolves the preferred color scheme and setting id" {
    var configuration_service = TestConfigurationService.init(testing.allocator);
    defer configuration_service.deinit();
    try configuration_service.setBool(ThemeSettings.DETECT_COLOR_SCHEME, false);
    try configuration_service.setBool(ThemeSettings.DETECT_HC, false);
    var host_color_service = TestHostColorSchemeService{ .dark = true };
    const theme_config = ThemeConfiguration.init(
        configuration_service.interface(),
        host_color_service.interface(),
    );

    try testing.expect(theme_config.getPreferredColorScheme() == null);
    try testing.expectEqualStrings(ThemeSettings.COLOR_THEME, theme_config.getColorThemeSettingId());

    try configuration_service.setBool(ThemeSettings.DETECT_COLOR_SCHEME, true);
    try testing.expectEqual(theme_mod.ColorScheme.DARK, theme_config.getPreferredColorScheme().?);
    try testing.expectEqualStrings(ThemeSettings.PREFERRED_DARK_THEME, theme_config.getColorThemeSettingId());

    try configuration_service.setBool(ThemeSettings.DETECT_HC, true);
    host_color_service.high_contrast = true;
    try testing.expectEqual(theme_mod.ColorScheme.HIGH_CONTRAST_DARK, theme_config.getPreferredColorScheme().?);
    try testing.expectEqualStrings(ThemeSettings.PREFERRED_HC_DARK_THEME, theme_config.getColorThemeSettingId());

    host_color_service.dark = false;
    try testing.expectEqual(theme_mod.ColorScheme.HIGH_CONTRAST_LIGHT, theme_config.getPreferredColorScheme().?);
    try testing.expectEqualStrings(ThemeSettings.PREFERRED_HC_LIGHT_THEME, theme_config.getColorThemeSettingId());

    try configuration_service.setBool(ThemeSettings.DETECT_HC, false);
    host_color_service.high_contrast = false;
    try testing.expectEqual(theme_mod.ColorScheme.LIGHT, theme_config.getPreferredColorScheme().?);
    try testing.expectEqualStrings(ThemeSettings.PREFERRED_LIGHT_THEME, theme_config.getColorThemeSettingId());
}

test "ThemeConfiguration: reads the color theme from the active preferred setting" {
    var configuration_service = TestConfigurationService.init(testing.allocator);
    defer configuration_service.deinit();
    try configuration_service.setBool(ThemeSettings.DETECT_COLOR_SCHEME, true);
    try configuration_service.setString(ThemeSettings.PREFERRED_DARK_THEME, "My Dark Theme");
    var host_color_service = TestHostColorSchemeService{ .dark = true };
    const theme_config = ThemeConfiguration.init(
        configuration_service.interface(),
        host_color_service.interface(),
    );

    try testing.expectEqualStrings("My Dark Theme", theme_config.getColorTheme().?);
}

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
const workbench_theme_service = @import("../../browser/workbenchThemeService.zig");
const host_color_scheme_service = @import("../../common/hostColorSchemeService.zig");
const theme_configuration = @import("../../common/themeConfiguration.zig");

const IConfigurationService = configuration.IConfigurationService;
const Value = configuration.Value;
const IHostColorSchemeService = host_color_scheme_service.IHostColorSchemeService;
const ThemeConfiguration = theme_configuration.ThemeConfiguration;
const ThemeSettings = workbench_theme_service.ThemeSettings;

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

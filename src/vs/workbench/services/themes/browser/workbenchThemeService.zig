// Port of the active-theme subset of
// `src/vs/workbench/services/themes/browser/workbenchThemeService.ts`.
//
// Terminal adaptations: themes are registered explicitly (no extension point),
// there are no file/product icon themes and no configuration watcher; the
// active color theme is persisted by id in the storage service.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const color_utils = @import("../../../../platform/theme/common/colorUtils.zig");
const theme_service = @import("../../../../platform/theme/common/themeService.zig");
const theme_mod = @import("../../../../platform/theme/common/theme.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");
const color_theme = @import("../common/colorThemeData.zig");

const ColorThemeData = color_theme.ColorThemeData;
const ResourceReader = color_theme.ResourceReader;
const IColorTheme = theme_service.IColorTheme;
const ColorScheme = theme_mod.ColorScheme;
const InMemoryStorageService = storage_mod.InMemoryStorageService;

pub const STORAGE_KEY = "workbench.theme.activeId";

pub const ThemeEntry = struct {
    label: []const u8,
    theme_type: ColorScheme,
};

pub const ThemeService = struct {
    allocator: Allocator,
    colors: *color_utils.ColorRegistry,
    storage: ?*InMemoryStorageService,
    themes: std.StringHashMap(ThemeEntry),
    active_id: []const u8,
    active: *ColorThemeData,
    onDidColorThemeChange: Emitter(void),

    pub fn init(allocator: Allocator, colors: *color_utils.ColorRegistry, storage: ?*InMemoryStorageService) !*ThemeService {
        const self = try allocator.create(ThemeService);
        errdefer allocator.destroy(self);
        const active = try ColorThemeData.createUnloadedTheme(allocator, colors, "vs-dark", &.{});
        self.* = .{
            .allocator = allocator,
            .colors = colors,
            .storage = storage,
            .themes = std.StringHashMap(ThemeEntry).init(allocator),
            .active_id = try allocator.dupe(u8, "vs-dark"),
            .active = active,
            .onDidColorThemeChange = Emitter(void).init(allocator),
        };
        try self.registerTheme("vs-dark", "Dark (Visual Studio)", .DARK);
        return self;
    }

    /// Restores the persisted active theme. Call after registering themes so
    /// the stored id can be resolved.
    pub fn restore(self: *ThemeService) !void {
        const storage = self.storage orelse return;
        const id = storage.get(STORAGE_KEY, .profile, null) orelse return;
        if (!self.themes.contains(id)) return;
        try self.applyThemeId(id);
    }

    pub fn deinit(self: *ThemeService) void {
        self.active.deinit();
        self.themes.deinit();
        self.allocator.free(self.active_id);
        self.onDidColorThemeChange.deinit();
        self.allocator.destroy(self);
    }

    pub fn registerTheme(self: *ThemeService, id: []const u8, label: []const u8, theme_type: ColorScheme) !void {
        try self.themes.put(id, .{ .label = label, .theme_type = theme_type });
    }

    pub fn getActiveTheme(self: *ThemeService) *ColorThemeData {
        return self.active;
    }

    pub fn getColorTheme(self: *ThemeService) IColorTheme {
        return self.active.interface();
    }

    pub fn getActiveThemeId(self: *const ThemeService) []const u8 {
        return self.active_id;
    }

    /// Applies a registered theme, optionally loading its file first.
    pub fn setTheme(self: *ThemeService, id: []const u8, reader: ?ResourceReader, path: ?[]const u8) !void {
        const entry = self.themes.get(id) orelse return error.UnknownTheme;
        const theme = try ColorThemeData.createUnloadedTheme(self.allocator, self.colors, id, &.{});
        errdefer theme.deinit();
        theme.theme_type = entry.theme_type;
        if (path) |location| theme.location = location;
        if (reader) |resource_reader| try theme.ensureLoaded(resource_reader);

        self.active.deinit();
        self.active = theme;
        try self.applyThemeId(id);
    }

    fn applyThemeId(self: *ThemeService, id: []const u8) !void {
        const entry = self.themes.get(id) orelse return error.UnknownTheme;
        self.allocator.free(self.active_id);
        self.active_id = try self.allocator.dupe(u8, id);
        self.active.theme_type = entry.theme_type;
        if (self.storage) |service| {
            try service.store(STORAGE_KEY, .{ .string = id }, .profile, .user);
        }
        try self.onDidColorThemeChange.fire({});
    }
};

test "theme service applies and restores the active theme" {
    const allocator = std.testing.allocator;
    var registry = color_utils.ColorRegistry.init(allocator);
    defer registry.deinit();
    var storage = InMemoryStorageService.init(allocator);
    defer storage.deinit();

    const service = try ThemeService.init(allocator, &registry, &storage);
    defer service.deinit();
    try std.testing.expectEqualStrings("vs-dark", service.getActiveThemeId());

    try service.registerTheme("vs-light", "Light (Visual Studio)", .LIGHT);
    try service.setTheme("vs-light", null, null);
    try std.testing.expectEqualStrings("vs-light", service.getActiveThemeId());
    try std.testing.expectEqual(ColorScheme.LIGHT, service.getActiveTheme().theme_type);
    try std.testing.expectEqualStrings("vs-light", storage.get(STORAGE_KEY, .profile, null).?);

    const restored = try ThemeService.init(allocator, &registry, &storage);
    defer restored.deinit();
    try restored.registerTheme("vs-light", "Light (Visual Studio)", .LIGHT);
    try restored.restore();
    try std.testing.expectEqualStrings("vs-light", restored.getActiveThemeId());
}

pub const ThemeSettingDefaults = struct {
    pub const COLOR_THEME_DARK = "Dark 2026";
    pub const COLOR_THEME_LIGHT = "Light 2026";
    pub const COLOR_THEME_HC_DARK = "Default High Contrast";
    pub const COLOR_THEME_HC_LIGHT = "Default High Contrast Light";
};

pub const ThemeSettings = struct {
    pub const COLOR_THEME = "workbench.colorTheme";
    pub const DETECT_COLOR_SCHEME = "window.autoDetectColorScheme";
    pub const DETECT_HC = "window.autoDetectHighContrast";
};

/// Migrates legacy theme setting ids to their current equivalents.
pub fn migrateThemeSettingsId(settings_id: []const u8) []const u8 {
    const mappings = [_][2][]const u8{
        .{ "Default Dark Modern", "Dark Modern" },
        .{ "Default Light Modern", "Light Modern" },
        .{ "Default Dark+", "Dark+" },
        .{ "Default Light+", "Light+" },
        .{ "Experimental Dark", ThemeSettingDefaults.COLOR_THEME_DARK },
        .{ "VS Code Dark", ThemeSettingDefaults.COLOR_THEME_DARK },
        .{ "Experimental Light", ThemeSettingDefaults.COLOR_THEME_LIGHT },
        .{ "VS Code Light", ThemeSettingDefaults.COLOR_THEME_LIGHT },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, settings_id, mapping[0])) return mapping[1];
    }
    return settings_id;
}

test "migrateThemeSettingsId migrates Default-prefixed ids" {
    try std.testing.expectEqualStrings("Dark Modern", migrateThemeSettingsId("Default Dark Modern"));
    try std.testing.expectEqualStrings("Light Modern", migrateThemeSettingsId("Default Light Modern"));
    try std.testing.expectEqualStrings("Dark+", migrateThemeSettingsId("Default Dark+"));
    try std.testing.expectEqualStrings("Light+", migrateThemeSettingsId("Default Light+"));
}

test "migrateThemeSettingsId migrates Experimental ids" {
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_DARK, migrateThemeSettingsId("Experimental Dark"));
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_LIGHT, migrateThemeSettingsId("Experimental Light"));
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_DARK, migrateThemeSettingsId("VS Code Dark"));
    try std.testing.expectEqualStrings(ThemeSettingDefaults.COLOR_THEME_LIGHT, migrateThemeSettingsId("VS Code Light"));
}

test "migrateThemeSettingsId returns unknown ids unchanged" {
    try std.testing.expectEqualStrings("Dark Modern", migrateThemeSettingsId("Dark Modern"));
    try std.testing.expectEqualStrings("Dark 2026", migrateThemeSettingsId("Dark 2026"));
    try std.testing.expectEqualStrings("Some Custom Theme", migrateThemeSettingsId("Some Custom Theme"));
    try std.testing.expectEqualStrings("", migrateThemeSettingsId(""));
}

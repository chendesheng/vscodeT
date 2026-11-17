// Port of the portable subset of
// `src/vs/workbench/services/themes/common/themeConfiguration.ts`.
//
// Terminal adaptations: the configuration-schema registration, the extension
// points that fill the theme enums and the file/product icon theme getters are
// not ported (the terminal has no icon themes and registers themes explicitly,
// see `browser/workbenchThemeService.zig`). The `fontSize` -> `lineHeight`
// compatibility rewrite of `tokenColorCustomizations` is not applied; the
// stored value is returned unchanged. The color theme selection, customizations
// and preferred-color-scheme logic keep the upstream behavior.
const std = @import("std");
const Allocator = std.mem.Allocator;

const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const theme_mod = @import("../../../../platform/theme/common/theme.zig");
const window_mod = @import("../../../../platform/window/common/window.zig");
const workbench_theme_service = @import("../browser/workbenchThemeService.zig");
const host_color_scheme_service = @import("./hostColorSchemeService.zig");

const IConfigurationService = configuration.IConfigurationService;
const Value = configuration.Value;
const ColorScheme = theme_mod.ColorScheme;
const IColorScheme = window_mod.IColorScheme;
const IHostColorSchemeService = host_color_scheme_service.IHostColorSchemeService;
const ThemeSettings = workbench_theme_service.ThemeSettings;

pub const ThemeConfiguration = struct {
    configuration_service: IConfigurationService,
    host_color_service: IHostColorSchemeService,

    pub fn init(
        configuration_service: IConfigurationService,
        host_color_service: IHostColorSchemeService,
    ) ThemeConfiguration {
        return .{
            .configuration_service = configuration_service,
            .host_color_service = host_color_service,
        };
    }

    pub fn getColorTheme(self: ThemeConfiguration) ?[]const u8 {
        return self.configuration_service.getString(self.getColorThemeSettingId());
    }

    pub fn getColorCustomizations(self: ThemeConfiguration) ?*const Value {
        return self.configuration_service.getValue(ThemeSettings.COLOR_CUSTOMIZATIONS);
    }

    pub fn getSemanticTokenColorCustomizations(self: ThemeConfiguration) ?*const Value {
        return self.configuration_service.getValue(ThemeSettings.SEMANTIC_TOKEN_COLOR_CUSTOMIZATIONS);
    }

    pub fn getPreferredColorScheme(self: ThemeConfiguration) ?ColorScheme {
        if (self.isDetectingHighContrast() and self.host_color_service.highContrast()) {
            return if (self.host_color_service.dark()) .HIGH_CONTRAST_DARK else .HIGH_CONTRAST_LIGHT;
        }
        if (self.isDetectingColorScheme()) {
            return if (self.host_color_service.dark()) .DARK else .LIGHT;
        }
        return null;
    }

    pub fn isDetectingHighContrast(self: ThemeConfiguration) bool {
        return self.configuration_service.getBool(ThemeSettings.DETECT_HC, false);
    }

    pub fn isDetectingColorScheme(self: ThemeConfiguration) bool {
        return self.configuration_service.getBool(ThemeSettings.DETECT_COLOR_SCHEME, false);
    }

    pub fn isPreferredColorSchemeChange(self: ThemeConfiguration, previous: IColorScheme) bool {
        const dark_changed = previous.dark != self.host_color_service.dark();
        if (self.isDetectingColorScheme() and dark_changed) {
            return true;
        }
        if (self.isDetectingHighContrast()) {
            return previous.highContrast != self.host_color_service.highContrast() or
                (self.host_color_service.highContrast() and dark_changed);
        }
        return false;
    }

    /// The setting id the active color theme is read from / written to.
    pub fn getColorThemeSettingId(self: ThemeConfiguration) []const u8 {
        const preferred_scheme = self.getPreferredColorScheme() orelse return ThemeSettings.COLOR_THEME;
        return switch (preferred_scheme) {
            .DARK => ThemeSettings.PREFERRED_DARK_THEME,
            .LIGHT => ThemeSettings.PREFERRED_LIGHT_THEME,
            .HIGH_CONTRAST_DARK => ThemeSettings.PREFERRED_HC_DARK_THEME,
            .HIGH_CONTRAST_LIGHT => ThemeSettings.PREFERRED_HC_LIGHT_THEME,
        };
    }
};

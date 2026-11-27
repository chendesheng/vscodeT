// Port of `src/vs/editor/contrib/semanticTokens/common/semanticTokensConfig.ts`.
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const resource_config = @import("../../../common/services/textResourceConfiguration.zig");
const theme = @import("../../../../platform/theme/common/themeService.zig");
pub const SETTING_ID = "editor.semanticHighlighting";
pub fn isSemanticColoringEnabled(model: *TextModel, current_theme: ?theme.IColorTheme, configuration: ?resource_config.ITextResourceConfigurationService) bool {
    if (configuration) |cfg| {
        if (cfg.getValue(model, "editor.semanticHighlighting.enabled")) |enabled| if (enabled.* == .bool) return enabled.bool;
        if (cfg.getValue(model, SETTING_ID)) |setting| if (setting.* == .object) if (setting.object.get("enabled")) |enabled| if (enabled == .bool) return enabled.bool;
    }
    return if (current_theme) |value| value.semanticHighlighting else false;
}

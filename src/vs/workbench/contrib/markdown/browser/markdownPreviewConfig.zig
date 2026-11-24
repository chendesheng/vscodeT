//! Terminal subset of
//! `vscode/extensions/markdown-language-features/src/preview/previewConfig.ts`.
//!
//! Font, line-height and CSS style settings have no terminal counterpart and
//! are intentionally absent. The booleans below drive the ported preview and
//! scroll-sync behavior.

const std = @import("std");
const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;

pub const MarkdownPreviewConfig = struct {
    scroll_preview_with_editor: bool = true,
    scroll_editor_with_preview: bool = true,
    mark_editor_selection: bool = true,
    preview_breaks: bool = false,
    math_enabled: bool = true,
    double_click_to_switch_to_editor: bool = true,

    pub fn load(configuration: ?*ConfigurationService) MarkdownPreviewConfig {
        const service = configuration orelse return .{};
        return .{
            .scroll_preview_with_editor = service.getBool("markdown.preview.scrollPreviewWithEditor", true),
            .scroll_editor_with_preview = service.getBool("markdown.preview.scrollEditorWithPreview", true),
            .mark_editor_selection = service.getBool("markdown.preview.markEditorSelection", true),
            .math_enabled = service.getBool("markdown.math.enabled", true),
            .preview_breaks = service.getBool("markdown.preview.breaks", false),
            .double_click_to_switch_to_editor = service.getBool("markdown.preview.doubleClickToSwitchToEditor", true),
        };
    }

    pub fn eql(a: MarkdownPreviewConfig, b: MarkdownPreviewConfig) bool {
        return a.scroll_preview_with_editor == b.scroll_preview_with_editor and
            a.scroll_editor_with_preview == b.scroll_editor_with_preview and
            a.mark_editor_selection == b.mark_editor_selection and
            a.preview_breaks == b.preview_breaks and
            a.math_enabled == b.math_enabled and
            a.double_click_to_switch_to_editor == b.double_click_to_switch_to_editor;
    }
};

test "markdownPreviewConfig: defaults match VS Code" {
    const config = MarkdownPreviewConfig.load(null);
    try std.testing.expect(config.scroll_preview_with_editor);
    try std.testing.expect(config.scroll_editor_with_preview);
    try std.testing.expect(config.mark_editor_selection);
    try std.testing.expect(!config.preview_breaks);
    try std.testing.expect(config.double_click_to_switch_to_editor);
    try std.testing.expect(config.eql(.{}));
}

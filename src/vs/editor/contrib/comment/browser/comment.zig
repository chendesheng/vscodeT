// Port of the portable comment actions and helpers from `src/vs/editor/contrib/comment/browser/comment.ts`.
const language_configuration_registry = @import("../../../common/languages/languageConfigurationRegistry.zig");
const ICommentsConfiguration = language_configuration_registry.ICommentsConfiguration;
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;

/// Resolves the comment configuration for `languageId` from the model language
/// service. The full upstream `ILanguageConfigurationService` is not ported;
/// this is the portable subset the comment commands need.
pub fn commentsFor(language_service: *LanguageService, language_id: []const u8) ?ICommentsConfiguration {
    const config = language_service.getLanguageConfiguration(language_id) orelse return null;
    return language_configuration_registry.ResolvedLanguageConfiguration._handleComments(config);
}

const ActionEditor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ActionCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const action_registry = @import("../../../../platform/actions/common/actions.zig");

pub const editor_actions = [_]action_registry.Action2{
    ActionCommand.action(.{ .id = "editor.action.commentLine", .title = "Toggle Line Comment", .category = "Editor", .precondition = &ActionCommand.writable }, true, ActionEditor.toggleLineComment),
    ActionCommand.action(.{ .id = "editor.action.blockComment", .title = "Toggle Block Comment", .category = "Editor", .precondition = &ActionCommand.writable }, true, ActionEditor.toggleBlockComment),
};

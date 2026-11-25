// Port of the action registration from `src/vs/editor/contrib/format/browser/formatActions.ts`.

const ActionEditor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ActionCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const action_registry = @import("../../../../platform/actions/common/actions.zig");

pub const editor_actions = [_]action_registry.Action2{
    ActionCommand.action(.{ .id = "editor.action.formatSelection", .title = "Format Selection", .category = "Editor", .precondition = &ActionCommand.writable }, true, ActionEditor.formatSelection),
};

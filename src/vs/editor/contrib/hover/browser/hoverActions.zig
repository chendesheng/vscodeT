// Port of ShowOrFocusHoverAction in
// src/vs/editor/contrib/hover/browser/hoverActions.ts.
// The terminal has no browser accessibility auto-focus mode or JSON
// command arguments. Keep the default FocusIfVisible behavior.
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const EditorCommand = @import("../../../browser/editorExtensions.zig").EditorCommand;
const ContentHoverController = @import("contentHoverController.zig").ContentHoverController;
const Range = @import("../../../common/core/range.zig").Range;
const HoverStartMode = @import("hoverOperation.zig").HoverStartMode;
const HoverStartSource = @import("hoverTypes.zig").HoverStartSource;

pub const HoverFocusBehavior = enum { NoAutoFocus, FocusIfVisible, AutoFocusImmediately };

pub const show_or_focus_hover_action = EditorCommand.action(.{
    .id = "editor.action.showHover",
    .title = "Show or Focus Hover",
    .tooltip = "Show or focus the editor hover at the cursor.",
    .category = "Editor",
}, false, run);

pub fn showOrFocusHover(editor: *Editor, focus: HoverFocusBehavior) bool {
    const controller = editor.getContribution(ContentHoverController) orelse return false;
    if (controller.isVisible() and focus != .NoAutoFocus) {
        controller.widget().focus();
    } else {
        const position = editor.modelCursorPosition();
        controller.showContentHover(
            Range.init(position.lineNumber, position.column, position.lineNumber, position.column),
            HoverStartMode.immediate,
            HoverStartSource.keyboard,
            focus == .AutoFocusImmediately,
        );
    }
    return true;
}

fn run(editor: *Editor) !void {
    _ = showOrFocusHover(editor, .FocusIfVisible);
}

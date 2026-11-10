// Port of the action metadata from
// `src/vs/editor/contrib/caretOperations/browser/caretOperations.ts`.
const editor_extensions = @import("../../../browser/editorExtensions.zig");
const EditorAction = editor_extensions.EditorAction;

pub const MoveCaretLeftAction = struct {
    pub const id = "editor.action.moveCarretLeftAction";
    pub const label = "Move Selected Text Left";
    pub const description = "Move Selected Text Left";

    pub fn action(context: *anyopaque, run: *const fn (*anyopaque) anyerror!void) EditorAction {
        return EditorAction.init(.{ .id = id, .label = label, .description = description, .context = context, .run = run });
    }
};

pub const MoveCaretRightAction = struct {
    pub const id = "editor.action.moveCarretRightAction";
    pub const label = "Move Selected Text Right";
    pub const description = "Move Selected Text Right";

    pub fn action(context: *anyopaque, run: *const fn (*anyopaque) anyerror!void) EditorAction {
        return EditorAction.init(.{ .id = id, .label = label, .description = description, .context = context, .run = run });
    }
};

// Port of `src/vs/editor/browser/widget/diffEditor/delegatingEditorImpl.ts`.
// Zig has no abstract base class or IEditor method inheritance. Expose the
// same target CodeEditorWidget directly to generic editor consumers; its
// position, selection, reveal, decoration and command APIs are not copied.
// Composite model, view state, layout, focus and disposal stay on the owner.
const Editor = @import("../codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const DelegatingEditor = struct {
    context: *anyopaque,
    get_target_editor: *const fn (*anyopaque) ?*Editor,

    pub fn targetEditor(self: DelegatingEditor) ?*Editor {
        return self.get_target_editor(self.context);
    }
};

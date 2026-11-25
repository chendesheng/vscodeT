// Port of the focused and active editor contracts in src/vs/editor/browser/services/codeEditorService.ts.
const Editor = @import("../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const ServiceIdentifier = @import("../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier;

pub const ICodeEditorService = struct {
    context: *anyopaque,
    focused: *const fn (*anyopaque) ?*Editor,
    active: *const fn (*anyopaque) ?*Editor,

    pub fn getFocusedCodeEditor(self: ICodeEditorService) ?*Editor {
        return self.focused(self.context);
    }

    pub fn getActiveCodeEditor(self: ICodeEditorService) ?*Editor {
        return self.active(self.context);
    }
};
pub const code_editor_service_id = ServiceIdentifier(ICodeEditorService, "codeEditorService");

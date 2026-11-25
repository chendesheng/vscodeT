// Port of the active and visible editor contract from
// `src/vs/workbench/services/editor/common/editorService.ts`.
// Opening, replacing and closing resource inputs are still being moved from
// the terminal composition root; the mounted-pane events are already real.
const editor = @import("../../../common/editor.zig");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const editor_service_id = instantiation.ServiceIdentifier(IEditorService, "editorService");

pub const IEditorService = struct {
    context: *anyopaque,
    active_editor_pane_fn: *const fn (*anyopaque) ?editor.IVisibleEditorPane,
    active_editor_fn: *const fn (*anyopaque) ?*EditorInput,
    on_did_active_editor_change: *Emitter(?*EditorInput),
    on_did_visible_editors_change: *Emitter(void),

    pub fn activeEditorPane(self: IEditorService) ?editor.IVisibleEditorPane {
        return self.active_editor_pane_fn(self.context);
    }

    pub fn activeEditor(self: IEditorService) ?*EditorInput {
        return self.active_editor_fn(self.context);
    }
};

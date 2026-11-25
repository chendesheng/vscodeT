// Port of the active and visible editor contract from
// `src/vs/workbench/services/editor/common/editorService.ts`.
// Mounted-editor events and resource opening are portable; text-file and
// native pane creation are supplied by the browser EditorService.
const editor = @import("../../../common/editor.zig");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const editor_service_id = instantiation.ServiceIdentifier(IEditorService, "editorService");

pub const OpenOptions = struct {
    /// Preview editors are replaced by the next preview in the group.
    pinned: bool = true,
    preserve_focus: bool = false,
    /// Explicit text editor override for image files.
    force_text: bool = false,
};

pub const IEditorService = struct {
    context: *anyopaque,
    active_editor_pane_fn: *const fn (*anyopaque) ?editor.IVisibleEditorPane,
    active_editor_fn: *const fn (*anyopaque) ?*EditorInput,
    open_editor_fn: *const fn (*anyopaque, []const u8, OpenOptions) anyerror!void,
    on_did_active_editor_change: *Emitter(?*EditorInput),
    on_did_visible_editors_change: *Emitter(void),

    pub fn openEditor(self: IEditorService, resource: []const u8, options: OpenOptions) !void {
        try self.open_editor_fn(self.context, resource, options);
    }

    pub fn activeEditorPane(self: IEditorService) ?editor.IVisibleEditorPane {
        return self.active_editor_pane_fn(self.context);
    }

    pub fn activeEditor(self: IEditorService) ?*EditorInput {
        return self.active_editor_fn(self.context);
    }
};

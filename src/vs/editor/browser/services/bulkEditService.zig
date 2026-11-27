// Port of `src/vs/editor/browser/services/bulkEditService.ts`.
// Native completion callbacks replace the Promise return value. The resource
// DTO itself is portable and independent of workbench/host implementation.
const languages = @import("../../common/languages.zig");
const cancellation = @import("../../../base/common/cancellation.zig");
const instantiation = @import("../../../platform/instantiation/common/instantiation.zig");
const Editor = @import("../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const ResourceTextEdit = languages.WorkspaceTextEdit;
pub const ResourceFileEdit = languages.WorkspaceFileEdit;
pub const ResourceEdit = languages.WorkspaceResourceEdit;
pub const IBulkEditOptions = struct {
    editor: ?*Editor = null,
    token: cancellation.CancellationToken = .None,
    show_preview: bool = false,
    label: ?[]const u8 = null,
    code: ?[]const u8 = null,
    quotable_label: ?[]const u8 = null,
    respect_auto_save_config: bool = false,
};
pub const IBulkEditResult = struct { is_applied: bool, edited_resources: usize = 0, edit_count: usize = 0 };
pub const EditListener = struct { context: *anyopaque, complete: *const fn (*anyopaque, anyerror!IBulkEditResult) void };
pub const IBulkEditService = struct {
    context: *anyopaque,
    apply_fn: *const fn (*anyopaque, languages.WorkspaceEdit, IBulkEditOptions, EditListener) anyerror!?cancellation.IDisposable,
    has_preview_handler_fn: *const fn (*anyopaque) bool,

    pub fn apply(self: IBulkEditService, edit: languages.WorkspaceEdit, options: IBulkEditOptions, listener: EditListener) !?cancellation.IDisposable {
        return self.apply_fn(self.context, edit, options, listener);
    }
    pub fn hasPreviewHandler(self: IBulkEditService) bool {
        return self.has_preview_handler_fn(self.context);
    }
};

pub const bulk_edit_service_id = instantiation.ServiceIdentifier(IBulkEditService, "IWorkspaceEditService");

// Port of the active-editor subset of src/vs/workbench/contrib/files/browser/fileCommands.ts.
// Multi-selected editors and save-as dialogs are not ported here. Native
// file inputs own their text-file save and revert implementations.
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const editor_service = @import("../../../services/editor/common/editorService.zig");
const editor_groups = @import("../../../services/editor/common/editorGroupsService.zig");

pub const editor_actions = [_]actions.Action2{
    .{ .command = .{ .id = "workbench.action.files.save", .title = "Save", .category = "File" }, .f1 = true, .context = @constCast(&{}), .run_fn = save },
    .{ .command = .{ .id = "workbench.action.files.revert", .title = "Revert File", .category = "File" }, .f1 = true, .context = @constCast(&{}), .run_fn = revert },
};

fn save(_: *anyopaque, accessor: ServicesAccessor) !void {
    const editors = try accessor.get(editor_service.editor_service_id);
    const groups = try accessor.get(editor_groups.editor_groups_service_id);
    const input = editors.activeEditor() orelse return error.NoActiveEditor;
    const group = groups.activeGroup() orelse return error.NoActiveEditor;
    try input.requestSave(group.id, null);
}

fn revert(_: *anyopaque, accessor: ServicesAccessor) !void {
    const editors = try accessor.get(editor_service.editor_service_id);
    const groups = try accessor.get(editor_groups.editor_groups_service_id);
    const input = editors.activeEditor() orelse return error.NoActiveEditor;
    const group = groups.activeGroup() orelse return error.NoActiveEditor;
    try input.revert(group.id);
}

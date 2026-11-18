// Terminal adapter exposing a TUI `Editor` as a workbench `IWorkingCopy`.
const std = @import("std");
const editor_mod = @import("editor.zig");
const working_copy = @import("../vs/workbench/services/workingCopy/common/workingCopy.zig");
const Editor = editor_mod.Editor;
const IWorkingCopy = working_copy.IWorkingCopy;
const WorkingCopyListener = working_copy.WorkingCopyListener;

pub const TYPE_ID = "workbench.editors.files.textFileEditor";

fn resource(context: *anyopaque) []const u8 {
    const editor: *Editor = @ptrCast(@alignCast(context));
    return editor.path;
}
fn typeId(_: *anyopaque) []const u8 {
    return TYPE_ID;
}
fn name(context: *anyopaque) []const u8 {
    const editor: *Editor = @ptrCast(@alignCast(context));
    return std.fs.path.basename(editor.path);
}
fn isDirty(context: *anyopaque) bool {
    const editor: *Editor = @ptrCast(@alignCast(context));
    return editor.isDirty();
}
fn isModified(context: *anyopaque) bool {
    return isDirty(context);
}

fn addDirty(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.addWorkingCopyDirtyListener(.{ .context = listener.context, .callback = listener.callback });
}
fn removeDirty(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.removeWorkingCopyDirtyListener(.{ .context = listener.context, .callback = listener.callback });
}
fn addContent(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.addWorkingCopyContentListener(.{ .context = listener.context, .callback = listener.callback });
}
fn removeContent(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.removeWorkingCopyContentListener(.{ .context = listener.context, .callback = listener.callback });
}
fn addSave(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.addWorkingCopySaveListener(.{ .context = listener.context, .callback = listener.callback });
}
fn removeSave(context: *anyopaque, listener: WorkingCopyListener) void {
    const editor: *Editor = @ptrCast(@alignCast(context));
    editor.removeWorkingCopySaveListener(.{ .context = listener.context, .callback = listener.callback });
}

pub fn interface(editor: *Editor) IWorkingCopy {
    return .{
        .context = editor,
        .resource = resource,
        .type_id = typeId,
        .name = name,
        .is_dirty = isDirty,
        .is_modified = isModified,
        .add_dirty_listener = addDirty,
        .remove_dirty_listener = removeDirty,
        .add_content_listener = addContent,
        .remove_content_listener = removeContent,
        .add_save_listener = addSave,
        .remove_save_listener = removeSave,
    };
}

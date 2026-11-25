// Port of the active and visible editor contract from
// `src/vs/workbench/services/editor/common/editorService.ts`.
// Mounted-editor events and resource opening are portable; text-file and
// native pane creation are supplied by the browser EditorService.
const std = @import("std");
const editor = @import("../../../common/editor.zig");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const editor_service_id = instantiation.ServiceIdentifier(IEditorService, "editorService");

pub const EditorTarget = enum { active, side };

pub const OpenOptions = struct {
    /// Preview editors are replaced by the next preview in the group.
    pinned: bool = true,
    preserve_focus: bool = false,
    /// Explicit text editor override for image files.
    force_text: bool = false,
};

/// Upstream IEditorCloseEvent, with the native pinned state retained for
/// reopening a terminal editor tab at its previous sequential index.
pub const IEditorCloseEvent = struct {
    editor: *EditorInput,
    group_id: @import("../../../common/editor.zig").GroupIdentifier,
    index: usize,
    sticky: bool,
    pinned: bool,
    context: @import("../../../common/editor.zig").EditorCloseContext,
};

pub const IEditorIdentifier = struct { editor: *EditorInput, group_id: editor.GroupIdentifier };
pub const EditorReplacement = struct { editor: *EditorInput, resource: []const u8, options: OpenOptions };

pub const IEditorService = struct {
    context: *anyopaque,
    active_editor_pane_fn: *const fn (*anyopaque) ?editor.IVisibleEditorPane,
    active_editor_fn: *const fn (*anyopaque) ?*EditorInput,
    open_editor_fn: *const fn (*anyopaque, []const u8, OpenOptions) anyerror!void,
    request_open_editor: *const fn (*anyopaque, []const u8, OpenOptions, EditorTarget) anyerror!void,
    get_editors: *const fn (*anyopaque, std.mem.Allocator) anyerror![]IEditorIdentifier,
    replace_editors: *const fn (*anyopaque, []const EditorReplacement, editor.GroupIdentifier) anyerror!void,
    on_did_active_editor_change: *Emitter(?*EditorInput),
    on_did_visible_editors_change: *Emitter(void),
    on_did_close_editor: *Emitter(IEditorCloseEvent),

    pub fn openEditor(self: IEditorService, resource: []const u8, options: OpenOptions) !void {
        try self.open_editor_fn(self.context, resource, options);
    }

    pub fn requestOpenEditor(self: IEditorService, resource: []const u8, options: OpenOptions, target: EditorTarget) !void {
        try self.request_open_editor(self.context, resource, options, target);
    }

    /// Sequential editors in grid appearance order. Caller owns the slice.
    pub fn getEditors(self: IEditorService, allocator: std.mem.Allocator) ![]IEditorIdentifier {
        return self.get_editors(self.context, allocator);
    }

    pub fn replaceEditors(self: IEditorService, replacements: []const EditorReplacement, group_id: editor.GroupIdentifier) !void {
        try self.replace_editors(self.context, replacements, group_id);
    }

    pub fn activeEditorPane(self: IEditorService) ?editor.IVisibleEditorPane {
        return self.active_editor_pane_fn(self.context);
    }

    pub fn activeEditor(self: IEditorService) ?*EditorInput {
        return self.active_editor_fn(self.context);
    }
};

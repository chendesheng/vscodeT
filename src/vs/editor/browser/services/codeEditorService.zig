// Port of the editor registration, focused and active editor contracts in
// src/vs/editor/browser/services/codeEditorService.ts.
const Editor = @import("../widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const IDiffEditor = @import("../editorBrowser.zig").IDiffEditor;
const ServiceIdentifier = @import("../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier;

pub const ICodeEditorService = struct {
    context: *anyopaque,
    focused: *const fn (*anyopaque) ?*Editor,
    active: *const fn (*anyopaque) ?*Editor,
    focused_diff: ?*const fn (*anyopaque) ?IDiffEditor = null,
    add_code_editor: ?*const fn (*anyopaque, *Editor) anyerror!void = null,
    remove_code_editor: ?*const fn (*anyopaque, *Editor) void = null,
    list_code_editors: ?*const fn (*anyopaque) []const *Editor = null,

    pub fn addCodeEditor(self: ICodeEditorService, editor: *Editor) !void {
        if (self.add_code_editor) |add| try add(self.context, editor);
    }

    pub fn removeCodeEditor(self: ICodeEditorService, editor: *Editor) void {
        if (self.remove_code_editor) |remove| remove(self.context, editor);
    }

    pub fn listCodeEditors(self: ICodeEditorService) []const *Editor {
        if (self.list_code_editors) |list| return list(self.context);
        return &.{};
    }

    pub fn getFocusedCodeEditor(self: ICodeEditorService) ?*Editor {
        return self.focused(self.context);
    }

    pub fn getFocusedDiffEditor(self: ICodeEditorService) ?IDiffEditor {
        const find = self.focused_diff orelse return null;
        return find(self.context);
    }

    pub fn getActiveCodeEditor(self: ICodeEditorService) ?*Editor {
        return self.active(self.context);
    }
};
pub const code_editor_service_id = ServiceIdentifier(ICodeEditorService, "codeEditorService");

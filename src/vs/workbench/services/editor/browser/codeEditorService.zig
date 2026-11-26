// Port of getActiveCodeEditor in src/vs/workbench/services/editor/browser/codeEditorService.ts
// and the focus lookup in src/vs/editor/browser/services/abstractCodeEditorService.ts.
// Terminal group views expose the mounted code editors and their focus state.
const service = @import("../../../../editor/browser/services/codeEditorService.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);

pub const CodeEditorService = struct {
    part: *EditorPart,

    pub fn interface(self: *CodeEditorService) service.ICodeEditorService {
        return .{ .context = self, .focused = focusedEditor, .active = activeEditor };
    }

    fn hasTextControl(tab: *const Tab) bool {
        return !tab.isImage() and tab.terminal_input == null and tab.markdown_preview == null;
    }

    fn focusedEditor(context: *anyopaque) ?*Editor {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        for (self.part.group_views.items) |group| {
            const tab = group.activeTab() orelse continue;
            if (!hasTextControl(tab)) continue;
            if (tab.diff) |diff| {
                if (diff.widget.focusedView().isFocused()) return diff.widget.focusedEditor();
            } else if (tab.view.isFocused()) return tab.editor;
        }
        return null;
    }

    fn activeEditor(context: *anyopaque) ?*Editor {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        const group = self.part.activeView() orelse return null;
        const tab = group.activeTab() orelse return null;
        if (!hasTextControl(tab)) return null;
        if (tab.diff) |diff| return diff.widget.modified_editor;
        return tab.editor;
    }
};

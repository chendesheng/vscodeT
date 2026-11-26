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
        return .{ .context = self, .focused = focusedEditor, .active = activeEditor, .focused_diff = focusedDiffEditor };
    }

    fn hasTextControl(tab: *const Tab) bool {
        return !tab.isImage() and tab.terminal_input == null and tab.markdown_preview == null;
    }

    fn focusedEditor(context: *anyopaque) ?*Editor {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        for (self.part.group_views.items) |group| {
            const tab = group.activeTab() orelse continue;
            if (!hasTextControl(tab)) continue;
            if (tab.activeDiffWidget()) |widget| {
                if (widget.focusedView().isFocused()) return widget.focusedEditor();
            } else if (!tab.isMultiDiff() and tab.view.isFocused()) {
                if (tab.editor.focused_embedded) |child| return child.view.editor;
                return tab.editor;
            }
        }
        return null;
    }

    fn focusedDiffEditor(context: *anyopaque) ?@import("../../../../editor/browser/editorBrowser.zig").IDiffEditor {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        for (self.part.group_views.items) |group| {
            const tab = group.activeTab() orelse continue;
            if (tab.activeDiffWidget()) |widget| {
                if (widget.focusedView().isFocused()) return widget.interface();
            } else if (!tab.isMultiDiff() and tab.view.isFocused()) {
                if (tab.editor.focused_embedded) |child| return child.diff;
            }
        }
        // The accessible review surface is not a code-editor widget. The
        // active diff pane is also the action target from the command palette.
        const group = self.part.activeView() orelse return null;
        const tab = group.activeTab() orelse return null;
        const widget = tab.activeDiffWidget() orelse return null;
        return widget.interface();
    }

    fn activeEditor(context: *anyopaque) ?*Editor {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        const group = self.part.activeView() orelse return null;
        const tab = group.activeTab() orelse return null;
        if (!hasTextControl(tab)) return null;
        return tab.codeEditorControl();
    }
};

// Port of getActiveCodeEditor in src/vs/workbench/services/editor/browser/codeEditorService.ts
// and the focus lookup in src/vs/editor/browser/services/abstractCodeEditorService.ts.
// Terminal group views expose the mounted code editors and their focus state.
const std = @import("std");
const service = @import("../../../../editor/browser/services/codeEditorService.zig");
const IDiffEditor = @import("../../../../editor/browser/editorBrowser.zig").IDiffEditor;
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);

pub const CodeEditorService = struct {
    part: *EditorPart,
    allocator: std.mem.Allocator,
    editors: std.ArrayList(*Editor) = .empty,
    diff_editors: std.ArrayList(IDiffEditor) = .empty,
    opening: ?struct { context: *anyopaque, open: *const fn (*anyopaque, service.OpenCodeEditorOptions) anyerror!void } = null,

    pub fn init(allocator: std.mem.Allocator, part: *EditorPart) CodeEditorService {
        return .{ .allocator = allocator, .part = part };
    }

    pub fn deinit(self: *CodeEditorService) void {
        self.diff_editors.deinit(self.allocator);
        self.editors.deinit(self.allocator);
    }

    pub fn interface(self: *CodeEditorService) service.ICodeEditorService {
        return .{ .context = self, .focused = focusedEditor, .active = activeEditor, .focused_diff = focusedDiffEditor, .add_diff_editor = addDiffEditor, .remove_diff_editor = removeDiffEditor, .list_diff_editors = listDiffEditors, .add_code_editor = addCodeEditor, .remove_code_editor = removeCodeEditor, .list_code_editors = listCodeEditors, .open_code_editor = openCodeEditor };
    }

    fn openCodeEditor(context: *anyopaque, options: service.OpenCodeEditorOptions) !void {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        const opening = self.opening orelse return error.EditorOpeningUnavailable;
        try opening.open(opening.context, options);
    }

    fn addCodeEditor(context: *anyopaque, editor: *Editor) !void {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        for (self.editors.items) |existing| if (existing == editor) return;
        try self.editors.append(self.allocator, editor);
    }

    fn removeCodeEditor(context: *anyopaque, editor: *Editor) void {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        for (self.editors.items, 0..) |existing, index| {
            if (existing != editor) continue;
            _ = self.editors.orderedRemove(index);
            return;
        }
    }

    fn listCodeEditors(context: *anyopaque) []const *Editor {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        return self.editors.items;
    }

    fn addDiffEditor(context: *anyopaque, editor: IDiffEditor) !void {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        for (self.diff_editors.items) |existing| if (existing.context == editor.context) return;
        try self.diff_editors.append(self.allocator, editor);
    }

    fn removeDiffEditor(context: *anyopaque, editor: IDiffEditor) void {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        for (self.diff_editors.items, 0..) |existing, index| {
            if (existing.context != editor.context) continue;
            _ = self.diff_editors.orderedRemove(index);
            return;
        }
    }

    fn listDiffEditors(context: *anyopaque) []const IDiffEditor {
        const self: *CodeEditorService = @ptrCast(@alignCast(context));
        return self.diff_editors.items;
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

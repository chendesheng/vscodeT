// Port of the single-window editor service, editor opening, visibleEditorPanes
// and onDidVisibleEditorsChange in
// src/vs/workbench/services/editor/browser/editorService.ts.
// Terminal groups retain one pane per tab and expose their mounted pane.
const std = @import("std");
const ui = @import("ui");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const FileEditorInput = @import("../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const ImagePreviewEditorInput = @import("../../../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;
const text_files = @import("../../textfile/common/textFileService.zig");
const Tab = @import("../../../browser/parts/editor/editorPane.zig").Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Event = @import("../../../../base/common/event.zig").Emitter(void);

pub const OpenOptions = struct {
    /// Preview editors are replaced by the next preview in the group.
    pinned: bool = true,
    preserve_focus: bool = false,
    /// Explicit text editor override for image files.
    force_text: bool = false,
};

pub const OpenedTextEditor = struct {
    pane: *GroupView,
    tab: ?*Tab,
    is_new: bool,
};

pub const EditorService = struct {
    part: *EditorPart,

    /// Resolves an already-open input from the groups before opening a second
    /// model or reading the resource. The URI identity boundary is shared.
    pub fn findOpenFileInput(self: EditorService, io: std.Io, path: []const u8) ?*FileEditorInput {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const input = tab.file_input orelse continue;
                if (!text_files.samePath(self.part.allocator, io, input.editor.path, path)) continue;
                if (!pane.group.model.contains(.{ .input = &input.base }, .{})) continue;
                return input;
            }
        }
        return null;
    }

    pub fn findOpenImageInput(self: EditorService, io: std.Io, path: []const u8) ?*ImagePreviewEditorInput {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const input = tab.image_input orelse continue;
                if (!text_files.samePath(self.part.allocator, io, input.path, path)) continue;
                if (!pane.group.model.contains(.{ .input = &input.base }, .{})) continue;
                return input;
            }
        }
        return null;
    }

    pub fn openExistingFileInput(self: EditorService, input: *FileEditorInput, options: OpenOptions) !OpenedTextEditor {
        const opened = try self.part.service.openEditor(&input.base, null, .{ .open = .{ .pinned = options.pinned, .active = true } });
        const pane = self.part.viewForGroup(opened.group) orelse return error.GroupPaneMissing;
        const tab = pane.tabForInput(opened.result.editor);
        if (tab) |value| try pane.activateTab(value);
        return .{ .pane = pane, .tab = tab, .is_new = false };
    }

    /// Shared openEditor path for both a synchronously resolved text model and
    /// an asynchronous TextFileService read. Consumes the new editor on all
    /// outcomes. Input/pane ownership changes exactly once.
    pub fn openTextEditor(self: EditorService, editor: *Editor, options: OpenOptions, images: *ui.image.Runtime) !OpenedTextEditor {
        const allocator = self.part.allocator;
        const input = FileEditorInput.init(allocator, editor) catch |err| {
            editor.deinit();
            allocator.destroy(editor);
            return err;
        };
        var input_owned = true;
        defer if (input_owned) input.deinit();
        const opened = try self.part.service.openEditor(&input.base, null, .{ .open = .{ .pinned = options.pinned, .active = true } });
        if (!opened.result.is_new) {
            const pane = self.part.viewForGroup(opened.group) orelse return error.GroupPaneMissing;
            const tab = pane.tabForInput(opened.result.editor);
            if (tab) |value| try pane.activateTab(value);
            return .{ .pane = pane, .tab = tab, .is_new = false };
        }

        var owned_tab: ?*Tab = null;
        errdefer {
            _ = opened.group.model.closeEditor(&input.base, .UNKNOWN, true) catch null;
            if (owned_tab) |tab| tab.deinit();
        }
        const pane = self.part.viewForGroup(opened.group) orelse return error.GroupPaneMissing;
        const tab = try Tab.initFromInput(allocator, input);
        input_owned = false;
        owned_tab = tab;
        tab.setImageRuntime(images);
        try tab.view.setStatusBarVisible(false);
        try pane.addTab(tab);
        owned_tab = null;
        return .{ .pane = pane, .tab = tab, .is_new = true };
    }

    pub fn activeEditorPane(self: EditorService) ?*Tab {
        const group = self.part.activeView() orelse return null;
        return group.panes.activePane();
    }

    pub fn onDidActiveEditorChange(self: EditorService) *@import("../../../../base/common/event.zig").Emitter(?*EditorInput) {
        return &self.part.service.on_did_active_editor_change;
    }

    pub fn onDidVisibleEditorsChange(self: EditorService) *Event {
        return &self.part.service.on_did_visible_editors_change;
    }

    pub fn visibleEditorPanes(self: EditorService) VisibleEditorPanes {
        return .{ .groups = self.part.group_views.items };
    }

    pub const VisibleEditorPanes = struct {
        groups: []const *GroupView,

        pub fn next(self: *VisibleEditorPanes) ?*Tab {
            while (self.groups.len > 0) {
                const group = self.groups[0];
                self.groups = self.groups[1..];
                if (group.panes.activePane()) |pane| return pane;
            }
            return null;
        }
    };
};

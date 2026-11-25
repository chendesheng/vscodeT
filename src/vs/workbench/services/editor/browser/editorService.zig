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
const text_diff_editor_mod = @import("../../../browser/parts/editor/textDiffEditor.zig");
const IConfigurationService = @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const IEditorService = @import("../common/editorService.zig").IEditorService;
const IVisibleEditorPane = @import("../../../common/editor.zig").IVisibleEditorPane;
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

    pub fn openSnapshotDiff(
        self: EditorService,
        io: std.Io,
        configuration: ?IConfigurationService,
        path: []const u8,
        original_text: []const u8,
        modified_text: []const u8,
        left_label: []const u8,
        right_label: []const u8,
    ) !void {
        if (self.findDiffTab(path, left_label, right_label)) |existing| {
            const tab = existing.tab;
            const dims = existing.pane.contentDimensions();
            try tab.diff.?.replace(original_text, modified_text, dims.width, dims.height, text_diff_editor_mod.computeConfiguration(configuration));
            tab.syncDiffViews();
            try existing.pane.activateTab(tab);
            self.part.service.activateGroup(existing.pane.group);
            tab.layoutCells(dims.width, dims.height);
            tab.focusEditor();
            return;
        }

        const pane = self.part.activeView() orelse return error.GroupPaneMissing;
        const dims = pane.contentDimensions();
        const tab = blk: {
            const view = try text_diff_editor_mod.DiffView.create(
                self.part.allocator,
                io,
                .{
                    .original_path = path,
                    .modified_path = path,
                    .original_label = left_label,
                    .modified_label = right_label,
                },
                original_text,
                modified_text,
                dims.width,
                dims.height,
                text_diff_editor_mod.computeConfiguration(configuration),
            );
            errdefer view.destroy();
            break :blk try Tab.initDiff(self.part.allocator, view);
        };
        var registered = false;
        defer if (!registered) tab.deinit();

        try pane.tabs.ensureUnusedCapacity(1);
        errdefer if (pane.group.model.indexOfExact(tab.input) != null) {
            _ = pane.group.model.closeEditor(tab.input, .UNKNOWN, true) catch {};
            pane.syncActivePane();
        };
        const opened = try self.part.service.openEditor(
            tab.input,
            pane.group,
            .{ .open = .{ .pinned = true, .active = true } },
        );
        if (!opened.result.is_new) {
            pane.syncActivePane();
            if (pane.tabForInput(opened.result.editor)) |existing| existing.focusEditor();
            return;
        }

        try pane.addTab(tab);
        registered = true;
        tab.layoutCells(dims.width, dims.height);
        tab.focusEditor();
    }

    pub fn findDiffTab(self: EditorService, path: []const u8, left_label: []const u8, right_label: []const u8) ?struct { pane: *GroupView, tab: *Tab } {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const diff = tab.diff orelse continue;
                if (diff.matches(path, left_label, right_label)) return .{ .pane = pane, .tab = tab };
            }
        }
        return null;
    }

    pub fn interface(self: *EditorService) IEditorService {
        return .{
            .context = self,
            .active_editor_pane_fn = struct {
                fn get(context: *anyopaque) ?IVisibleEditorPane {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const pane = service.activeEditorPane() orelse return null;
                    return pane.interface();
                }
            }.get,
            .active_editor_fn = struct {
                fn get(context: *anyopaque) ?*EditorInput {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    return service.part.service.activeGroup().model.activeEditor();
                }
            }.get,
            .on_did_active_editor_change = self.onDidActiveEditorChange(),
            .on_did_visible_editors_change = self.onDidVisibleEditorsChange(),
        };
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

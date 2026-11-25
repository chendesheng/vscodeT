// Port of the dynamic and static preview lifecycle from
// extensions/markdown-language-features/src/preview/previewManager.ts.
// The native preview store uses the registered editor-group panes rather
// than VS Code webview panels. The pane owns the source document and scroll
// monitor; this manager owns reveal/reuse, refresh, source navigation and
// active-document/configuration events. Browser webview serialization and
// locked preview settings are not implemented by this terminal adapter.
const std = @import("std");
const editor_pane = @import("../../../../vs/workbench/browser/parts/editor/editorPane.zig");
const Tab = editor_pane.Tab;
const GroupPane = @import("../../../../vs/workbench/browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../../vs/workbench/browser/parts/editor/editorPart.zig").EditorPart(GroupPane);
const groups = @import("../../../../vs/workbench/services/editor/common/editorGroupsService.zig");
const EditorInput = @import("../../../../vs/workbench/common/editor/editorInput.zig").EditorInput;
const FileEditorInput = @import("../../../../vs/workbench/contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const ConfigurationService = @import("../../../../vs/workbench/services/configuration/browser/configurationService.zig").ConfigurationService;
const ThemeColors = @import("../../../../vs/workbench/browser/themeColors.zig").ThemeColors;
const MarkdownPreviewConfig = @import("../../../../vs/workbench/contrib/markdown/browser/markdownPreviewConfig.zig").MarkdownPreviewConfig;
const commands_mod = @import("../../../../vs/workbench/browser/commands.zig");

pub const MarkdownPreviewManager = struct {
    allocator: std.mem.Allocator,
    part: *EditorPart,
    configuration: *const ?*ConfigurationService,
    theme_palette: *const ?*ThemeColors,
    copy_host: GroupPane.CopyEditorHost,
    layout: *const fn (*anyopaque) void,
    focus_editor: *const fn (*anyopaque) void,
    active_editor_listener: ?usize = null,
    configuration_listener: ?struct { service: *ConfigurationService, id: usize } = null,

    pub fn attachConfiguration(self: *MarkdownPreviewManager, service: *ConfigurationService) !void {
        self.detachConfiguration();
        self.configuration_listener = .{ .service = service, .id = try service.listenConfigurationChange(self, onConfigurationChanged) };
        self.updateConfiguration();
    }

    pub fn detachConfiguration(self: *MarkdownPreviewManager) void {
        if (self.configuration_listener) |listener| listener.service.unlistenConfigurationChange(listener.id);
        self.configuration_listener = null;
    }

    fn onConfigurationChanged(change: @import("../../../../vs/platform/configuration/common/configuration.zig").Change, self: *MarkdownPreviewManager) !void {
        const config = @import("../../../../vs/platform/configuration/common/configuration.zig");
        if (config.affectsConfiguration(change, "markdown")) self.updateConfiguration();
    }

    pub fn registerListeners(self: *MarkdownPreviewManager) !void {
        self.active_editor_listener = try self.part.service.on_did_active_editor_change.listen(self, onDidChangeActiveTextEditor);
    }

    pub fn deinit(self: *MarkdownPreviewManager) void {
        self.detachConfiguration();
        if (self.active_editor_listener) |listener| self.part.service.on_did_active_editor_change.unlisten(listener);
        self.active_editor_listener = null;
    }

    pub fn registerCommands(self: *MarkdownPreviewManager, commands: *commands_mod.CommandRegistry) !void {
        const descriptors = [_]commands_mod.CommandInfo{
            .{ .id = "markdown.showSource", .label = "Show Source", .category = "Markdown", .requires_editor = true, .context = self, .run = commandShowMarkdownSource },
            .{ .id = "markdown.showPreview", .label = "Open Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandOpenMarkdownPreview },
            .{ .id = "markdown.showPreviewToSide", .label = "Open Preview to the Side", .category = "Markdown", .requires_editor = true, .context = self, .run = commandShowMarkdownPreview },
            .{ .id = "markdown.togglePreview", .label = "Toggle Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandToggleMarkdownPreview },
            .{ .id = "markdown.preview.refresh", .label = "Refresh Preview", .category = "Markdown", .requires_editor = true, .context = self, .run = commandRefreshMarkdownPreview },
        };
        for (descriptors) |command| try commands.register(command);
    }

    fn focusPane(pane: *GroupPane) !void {
        if (pane.activeTab()) |tab| try tab.ensureControllers();
        pane.focus();
    }

    pub fn getConfiguration(self: *MarkdownPreviewManager) MarkdownPreviewConfig {
        return MarkdownPreviewConfig.load(self.configuration.*);
    }

    pub fn updateConfiguration(self: *MarkdownPreviewManager) void {
        const config = self.getConfiguration();
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.markdown_preview == null) continue;
                const previous = tab.markdown_preview.?.options;
                tab.setMarkdownPreviewConfig(config);
                if (!MarkdownPreviewConfig.eql(previous, config)) {
                    tab.refreshMarkdownPreview(true);
                }
            }
        }
    }

    pub fn togglePreview(self: *MarkdownPreviewManager, pane: *GroupPane) !void {
        const tab = pane.activeTab() orelse return;
        if (tab.markdown_panel != null) return;
        if (!tab.isMarkdown()) {
            tab.editor.setMessage("Markdown preview is available for Markdown files only.", .{});
            return;
        }
        tab.setImageRuntime(self.copy_host.images);
        tab.setAsyncIo(self.copy_host.async_io);
        try tab.toggleMarkdownEditor(self.getConfiguration(), self.theme_palette.*);
        pane.layout();
        self.focus_editor(self.copy_host.context);
    }

    fn onDidChangeActiveTextEditor(active_input: ?*EditorInput, self: *MarkdownPreviewManager) anyerror!void {
        const input = active_input orelse return;
        if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) return;
        const source: *FileEditorInput = @ptrCast(@alignCast(input.impl orelse return));
        if (!Tab.isMarkdownLanguage(source.editor.languageId())) return;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.markdown_panel != null) try tab.updateMarkdownPanel(source);
            }
        }
    }

    pub fn openDynamicPreview(self: *MarkdownPreviewManager, beside: bool) !void {
        const pane = self.part.activeView() orelse return;
        const tab = pane.activeTab() orelse return;
        if (!tab.isMarkdown() or tab.markdown_preview != null) return;
        const source = tab.file_input orelse return;
        const direction = groups.preferredSideBySideGroupDirection(if (self.configuration.*) |configuration| configuration.interface() else null);
        self.part.setMaximizedGroup(null);
        if (beside) self.layout(self.copy_host.context);
        const adjacent = if (beside) try self.part.findGroup(.{ .direction = direction }, pane, false) else pane;
        const target = adjacent orelse try self.part.splitGroup(pane, if (direction == .DOWN) .vertical else .horizontal, false);
        errdefer if (adjacent == null and target.isEmpty()) {
            _ = self.part.collapseView(target);
        };
        // An unlocked dynamic preview matches by destination group. Repeated
        // opens reveal the same panel even when the Markdown resource changes.
        for (target.tabs.items) |existing| {
            if (existing.markdown_panel == null) continue;
            try existing.updateMarkdownPanel(source);
            try target.activateTab(existing);
            try focusPane(target);
            return;
        }
        const preview = try Tab.initMarkdownPanel(self.copy_host.view_factory, self.allocator, source, pane.group, self.getConfiguration(), self.theme_palette.*, self.copy_host.images, self.copy_host.async_io, self.copy_host.window);
        {
            errdefer preview.deinit();
            try target.tabs.ensureUnusedCapacity(1);
            _ = try target.group.model.openEditor(preview.input, .{ .pinned = true, .active = true });
            try target.addTab(preview);
        }
        try focusPane(target);
    }

    pub fn showSource(self: *MarkdownPreviewManager) !void {
        const pane = self.part.activeView() orelse return;
        const active = pane.activeTab() orelse return;
        const panel = active.markdown_panel orelse {
            if (active.markdown_preview != null) try self.togglePreview(pane);
            return;
        };
        const target = if (self.part.service.getGroup(panel.source_group)) |group| self.part.viewForGroup(group).? else pane;
        if (target.group.model.findEditor(&panel.source.base, .{})) |match| {
            const source = target.tabForInput(match.editor) orelse return error.EditorNotFound;
            try target.activateTab(source);
            if (source.markdown_preview != null) try self.togglePreview(target);
        } else {
            // showTextDocument may reopen a source whose tab was closed.
            // Reuse the live document, including its unsaved text and undo.
            const input = try panel.source.copyInput();
            const source = Tab.initFromInput(self.copy_host.view_factory, self.allocator, input) catch |err| {
                input.deinit();
                return err;
            };
            errdefer source.deinit();
            try target.tabs.ensureUnusedCapacity(1);
            _ = try target.group.model.openEditor(&input.base, .{ .active = true, .pinned = true });
            errdefer _ = target.group.model.closeEditor(&input.base, .UNKNOWN, true) catch {};
            try target.finishCopiedEditor(source, self.copy_host);
        }
        try focusPane(target);
    }

    pub fn refresh(self: *MarkdownPreviewManager) void {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| tab.refreshMarkdownPreview(true);
        }
    }

    fn commandShowMarkdownSource(context: *anyopaque) anyerror!void {
        const self: *MarkdownPreviewManager = @ptrCast(@alignCast(context));
        try self.showSource();
    }

    fn commandOpenMarkdownPreview(context: *anyopaque) anyerror!void {
        const self: *MarkdownPreviewManager = @ptrCast(@alignCast(context));
        try self.openDynamicPreview(false);
    }

    fn commandShowMarkdownPreview(context: *anyopaque) anyerror!void {
        const self: *MarkdownPreviewManager = @ptrCast(@alignCast(context));
        try self.openDynamicPreview(true);
    }

    fn commandToggleMarkdownPreview(context: *anyopaque) anyerror!void {
        const self: *MarkdownPreviewManager = @ptrCast(@alignCast(context));
        const pane = self.part.activeView() orelse return;
        try self.togglePreview(pane);
    }

    fn commandRefreshMarkdownPreview(context: *anyopaque) anyerror!void {
        const self: *MarkdownPreviewManager = @ptrCast(@alignCast(context));
        self.refresh();
    }
};

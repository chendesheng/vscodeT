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
const editor_pane = @import("../../../browser/parts/editor/editorPane.zig");
const Tab = editor_pane.Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const text_diff_editor_mod = @import("../../../browser/parts/editor/textDiffEditor.zig");
const IConfigurationService = @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const IEditorService = @import("../common/editorService.zig").IEditorService;
const IVisibleEditorPane = @import("../../../common/editor.zig").IVisibleEditorPane;
const Event = @import("../../../../base/common/event.zig").Emitter(void);

pub const OpenOptions = @import("../common/editorService.zig").OpenOptions;
const EditorTarget = @import("../common/editorService.zig").EditorTarget;
const GroupActions = @import("../../../browser/parts/editor/editorActions.zig").GroupActions;

pub const OpenedTextEditor = struct {
    pane: *GroupView,
    tab: ?*Tab,
    is_new: bool,
};

pub const EditorService = struct {
    part: *EditorPart,
    opening: ?*EditorOpening = null,

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
    pub fn openTextEditor(self: EditorService, factory: editor_pane.EditorViewFactory, editor: *Editor, options: OpenOptions, images: *ui.image.Runtime) !OpenedTextEditor {
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
        const tab = try Tab.initFromInput(factory, allocator, input);
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
        factory: editor_pane.EditorViewFactory,
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
            const view = try editor_pane.DiffView.create(
                factory,
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
            .open_editor_fn = struct {
                fn open(context: *anyopaque, resource: []const u8, options: OpenOptions) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    try opening.openPathWithOptions(resource, options);
                }
            }.open,
            .request_open_editor = struct {
                fn open(context: *anyopaque, resource: []const u8, options: OpenOptions, target: EditorTarget) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    try opening.requestOpenEditor(resource, options, target);
                }
            }.open,
            .on_did_active_editor_change = self.onDidActiveEditorChange(),
            .on_did_visible_editors_change = self.onDidVisibleEditorsChange(),
            .on_did_close_editor = &self.part.on_did_close_editor,
        };
    }

    pub fn tabCount(self: EditorService) usize {
        var count: usize = 0;
        for (self.part.group_views.items) |pane| count += pane.tabs.items.len;
        return count;
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

const Allocator = std.mem.Allocator;
const TextFileRead = text_files.TextFileRead;
const media_preview = @import("../../../contrib/mediaPreview/common/mediaPreview.zig");
const extensions_registry = @import("../../extensions/common/extensionsRegistry.zig");
const json_language = @import("../../language/common/jsonLanguageClient.zig");
const LanguageFeaturesService = @import("../../../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const HistoryService = @import("../../history/browser/historyService.zig").HistoryService;

/// Native asynchronous editor opening adapter. EditorService owns editor
/// model/view construction and this companion owns the outstanding file
/// resolve/reload jobs. The window provides the document surface and
/// notification callbacks; completions are posted to its input/event queue.
pub const EditorOpening = struct {
    pub const ImageDimensions = struct { width: usize, height: usize };

    allocator: Allocator,
    part: *EditorPart,
    group_actions: *GroupActions,
    io: std.Io,
    view_factory: editor_pane.EditorViewFactory,
    images: *ui.image.Runtime,
    window_events: *@import("../../../../base/common/windowDispatch.zig").Queue,
    text_file_service: *text_files.TextFileService,
    history: *HistoryService,
    declarative: *const ?*const extensions_registry.Registry,
    json_client: *const ?*json_language.Client,
    language_features: *const ?*LanguageFeaturesService,
    host: struct {
        context: *anyopaque,
        reveal: *const fn (*anyopaque, []const u8) void,
        configure_editor: *const fn (*anyopaque, *Editor) void,
        configure_tab: *const fn (*anyopaque, *Tab) void,
        register_working_copy: *const fn (*anyopaque, *Tab) void,
        discard_tab: *const fn (*anyopaque, *Tab) void,
        focus_editor: *const fn (*anyopaque) void,
        request_frame: *const fn (*anyopaque) void,
        show_status: *const fn (*anyopaque, []const u8) void,
        image_dimensions: *const fn (*anyopaque) ImageDimensions,
    },
    pending_open: ?struct { read: *TextFileRead, options: OpenOptions } = null,
    reload_jobs: std.array_list.Managed(*TextFileRead),

    pub fn cancel(self: *EditorOpening) void {
        self.cancelPendingOpen();
        self.cancelReloadJobs();
    }

    pub fn deinit(self: *EditorOpening) void {
        self.cancel();
        self.reload_jobs.deinit();
    }

    fn samePath(self: *EditorOpening, left: []const u8, right: []const u8) bool {
        return text_files.samePath(self.allocator, self.io, left, right);
    }

    fn findOpenInput(self: *EditorOpening, path: []const u8) ?*FileEditorInput {
        return (EditorService{ .part = self.part }).findOpenFileInput(self.io, path);
    }

    fn findOpenImageInput(self: *EditorOpening, path: []const u8) ?*ImagePreviewEditorInput {
        return (EditorService{ .part = self.part }).findOpenImageInput(self.io, path);
    }

    fn setStatusHint(self: *EditorOpening, comptime fmt: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, fmt, args) catch return;
        self.host.show_status(self.host.context, message);
    }

    fn clearStatusHint(self: *EditorOpening) void {
        self.host.show_status(self.host.context, "");
    }

    fn openExistingImageInput(
        self: *EditorOpening,
        path: []const u8,
        existing: *ImagePreviewEditorInput,
        options: OpenOptions,
    ) !void {
        const opened = try self.part.service.openEditor(
            &existing.base,
            null,
            .{ .open = .{ .pinned = options.pinned, .active = true } },
        );
        const pane = self.part.viewForGroup(opened.group) orelse return error.GroupPaneMissing;
        self.host.reveal(self.host.context, path);
        if (pane.tabForInput(opened.result.editor)) |tab| {
            try pane.activateTab(tab);
            tab.setImageRuntime(self.images);
            if (!options.preserve_focus) tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    fn openImagePath(self: *EditorOpening, path: []const u8, options: OpenOptions, window: ?*@import("../../../../base/common/windowDispatch.zig").Queue) !void {
        const input = try ImagePreviewEditorInput.init(self.allocator, path);
        var input_owned = true;
        defer if (input_owned) input.deinit();

        const opened = try self.part.service.openEditor(
            &input.base,
            null,
            .{ .open = .{ .pinned = options.pinned, .active = true } },
        );
        const pane = self.part.viewForGroup(opened.group) orelse return error.GroupPaneMissing;
        self.host.reveal(self.host.context, path);
        if (!opened.result.is_new) {
            if (pane.tabForInput(opened.result.editor)) |tab| {
                try pane.activateTab(tab);
                tab.setImageRuntime(self.images);
                if (!options.preserve_focus) tab.focusEditor();
            }
            try self.history.add(path);
            self.pruneTabs(pane);
            return;
        }

        var owned_tab: ?*Tab = null;
        var mounted = false;
        errdefer if (!mounted) {
            _ = opened.group.model.closeEditor(&input.base, .UNKNOWN, true) catch {};
            if (owned_tab) |tab| tab.deinit();
        };
        const dimensions = self.host.image_dimensions(self.host.context);
        const tab = try Tab.initImageFromInput(self.view_factory, self.allocator, self.io, input, dimensions.width, dimensions.height, self.images, window);
        input_owned = false;
        owned_tab = tab;
        try tab.view.setStatusBarVisible(false);
        try pane.addTab(tab);
        owned_tab = null;
        mounted = true;
        self.host.configure_tab(self.host.context, tab);
        try pane.activateTab(tab);
        if (!options.preserve_focus) {
            self.host.focus_editor(self.host.context);
            tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(pane);
    }

    fn openExistingInput(self: *EditorOpening, path: []const u8, existing: *FileEditorInput, options: OpenOptions) !void {
        const service = EditorService{ .part = self.part };
        try self.finishTextEditorOpen(path, try service.openExistingFileInput(existing, options), options);
    }

    fn openCreatedTextEditor(self: *EditorOpening, path: []const u8, editor: *Editor, options: OpenOptions) !void {
        self.host.configure_editor(self.host.context, editor);
        const service = EditorService{ .part = self.part };
        try self.finishTextEditorOpen(path, try service.openTextEditor(self.view_factory, editor, options, self.images), options);
    }

    fn finishTextEditorOpen(self: *EditorOpening, path: []const u8, opened: OpenedTextEditor, options: OpenOptions) !void {
        self.host.reveal(self.host.context, path);
        if (opened.tab) |tab| {
            tab.setImageRuntime(self.images);
            if (opened.is_new) {
                self.host.configure_tab(self.host.context, tab);
                self.host.register_working_copy(self.host.context, tab);
            }
            if (self.language_features.*) |features| tab.attachLanguageRegistry(features);
            try tab.ensureControllers();
            if (!opened.is_new and !options.preserve_focus) tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(opened.pane);
    }

    pub fn openPathWithOptions(self: *EditorOpening, path: []const u8, options: OpenOptions) !void {
        self.history.recordActiveNavigation(.USER);
        if (!options.force_text and media_preview.opensInImagePreview(path)) {
            if (self.findOpenImageInput(path)) |existing| {
                return self.openExistingImageInput(path, existing, options);
            }
            return self.openImagePath(path, options, null);
        }
        if (self.findOpenInput(path)) |existing| {
            return self.openExistingInput(path, existing, options);
        }
        const size = (self.part.activeView() orelse return error.GroupPaneMissing).contentDimensions();
        const editor = try Editor.createWithExtensionsOptions(self.allocator, self.io, path, size.width, size.height, self.declarative.*, self.json_client.*, .{ .reserve_scrollbar = true });
        try self.openCreatedTextEditor(path, editor, options);
    }

    /// The quick access SIDE_GROUP target uses the configured split direction,
    /// reuses an existing group when available, then opens there. An already
    /// resolved input shares its model via EditorGroupView.copyEditor.
    pub fn requestOpenEditor(self: *EditorOpening, path: []const u8, options: OpenOptions, target: EditorTarget) !void {
        if (target == .side) {
            self.group_actions.transfer.layout(self.group_actions.transfer.copy.context);
            const source = self.part.activeView() orelse return;
            const direction = self.group_actions.preferredSideBySideDirection();
            const destination = try self.part.findGroup(.{ .direction = direction }, source, false) orelse try self.group_actions.newEmptyGroup(direction);
            for (self.part.group_views.items) |pane| {
                for (pane.tabs.items) |tab| {
                    const resource = if (tab.file_input) |input| input.editor.path else tab.imagePath() orelse continue;
                    if (!self.samePath(resource, path)) continue;
                    const copy = if (pane == destination) tab else try destination.copyEditor(tab, .{ .pinned = options.pinned, .active = true }, self.group_actions.transfer.copy);
                    try destination.activateTab(copy);
                    if (destination.activeTab()) |active| try active.ensureControllers();
                    destination.focus();
                    try self.history.add(path);
                    return;
                }
            }
            if (destination.activeTab()) |active| try active.ensureControllers();
            destination.focus();
        }
        self.requestOpenPathWithOptions(path, options);
    }

    pub fn requestOpenPathWithOptions(self: *EditorOpening, path: []const u8, options: OpenOptions) void {
        self.cancelPendingOpen();
        self.clearStatusHint();
        // Image tabs load their payload through `ImagePreviewPane.initAsync`;
        // constructing the tab itself does no file I/O.
        if (!options.force_text and media_preview.opensInImagePreview(path)) {
            if (self.findOpenImageInput(path)) |existing| {
                self.history.recordActiveNavigation(.USER);
                self.openExistingImageInput(path, existing, options) catch |err| {
                    self.setStatusHint("Open failed: {s}", .{@errorName(err)});
                };
                return;
            }
            self.history.recordActiveNavigation(.USER);
            self.openImagePath(path, options, self.window_events) catch |err| {
                self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            };
            return;
        }
        if (self.findOpenInput(path)) |existing| {
            self.history.recordActiveNavigation(.USER);
            self.openExistingInput(path, existing, options) catch |err| {
                self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            };
            return;
        }

        const read = TextFileRead.startWithListener(self.text_file_service, path, true, .{ .context = self, .queue = self.window_events, .run = openReadCompleted }) catch |err| {
            self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            return;
        };
        self.pending_open = .{ .read = read, .options = options };
        self.setStatusHint("Opening {s}...", .{std.fs.path.basename(path)});
    }

    fn cancelPendingOpen(self: *EditorOpening) void {
        const job = self.pending_open orelse return;
        self.pending_open = null;
        job.read.cancel();
    }

    /// Starts one external-change reload per path. Results are applied by
    /// the completion handler after resolving the tab again.
    fn requestFileReload(self: *EditorOpening, path: []const u8) void {
        for (self.reload_jobs.items) |job| {
            if (self.samePath(job.path, path)) return;
        }
        const read = TextFileRead.startWithListener(self.text_file_service, path, false, .{ .context = self, .queue = self.window_events, .run = reloadCompleted }) catch return;
        self.reload_jobs.append(read) catch read.cancel();
    }

    fn reloadCompleted(context: *anyopaque, job: *TextFileRead) bool {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        const index = std.mem.indexOfScalar(*TextFileRead, self.reload_jobs.items, job).?;
        _ = self.reload_jobs.swapRemove(index);
        defer job.destroy();
        var content = job.awaitResult() catch return false;
        defer content.deinit(self.allocator);
        const input = self.findOpenInput(job.path) orelse return false;
        if (input.editor.isDirty()) input.editor.markConflict() else input.editor.applyReloadedContent(content.text, content.encoding) catch {};
        return true;
    }

    fn cancelReloadJobs(self: *EditorOpening) void {
        for (self.reload_jobs.items) |job| job.cancel();
        self.reload_jobs.clearRetainingCapacity();
    }

    fn openLoadedTextEditor(self: *EditorOpening, path: []const u8, loaded: *const text_files.ResolvedTextFile, options: OpenOptions) !void {
        const size = (self.part.activeView() orelse return error.GroupPaneMissing).contentDimensions();
        const editor = try Editor.createWithExtensionsFromLoadedText(
            self.allocator,
            self.io,
            loaded,
            path,
            size.width,
            size.height,
            self.declarative.*,
            self.json_client.*,
            .{ .reserve_scrollbar = true },
        );
        try self.openCreatedTextEditor(path, editor, options);
    }

    /// Drains completed async reads on the TUI thread. Returns true when a
    /// result was applied and a repaint is needed.
    fn openReadCompleted(context: *anyopaque, read: *TextFileRead) bool {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        const job = self.pending_open.?;
        std.debug.assert(job.read == read);
        self.pending_open = null;
        defer read.destroy();
        var loaded = read.awaitResult() catch |err| {
            self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            return true;
        };
        defer loaded.deinit(self.allocator);
        self.history.recordActiveNavigation(.USER);
        self.openLoadedTextEditor(read.path, &loaded, job.options) catch |err| {
            self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            return true;
        };
        self.clearStatusHint();
        return true;
    }

    /// Handles external file changes: clean open editors are reloaded, dirty
    /// ones keep the user's in-memory content (upstream marks the conflict).
    pub fn handleFileChanges(self: *EditorOpening, changes: []const @import("../../../../platform/files/common/files.zig").FileChange) void {
        for (changes) |change| {
            if (change.type == .DELETED) continue;
            // FSEvents can report a pre-existing path as ADDED on its first
            // event because it has no initial directory snapshot. For an open
            // editor that is a content change just like UPDATED.
            self.host.request_frame(self.host.context);
            for (self.part.group_views.items) |pane| {
                for (pane.tabs.items) |tab| {
                    if (tab.isImage()) {
                        const image_path = tab.imagePath() orelse continue;
                        if (self.samePath(image_path, change.resource)) tab.reloadImage();
                        continue;
                    }
                    if (tab.markdown_preview) |preview| {
                        if (preview.usesImagePath(change.resource)) preview.refresh(false);
                    }
                    if (tab.isDiff()) continue;
                    if (!self.samePath(tab.editor.path, change.resource)) continue;
                    if (tab.editor.isDirty()) {
                        tab.editor.markConflict();
                        continue;
                    }
                    self.requestFileReload(change.resource);
                }
            }
        }
    }

    /// Removes tab views whose input the group model no longer contains. This
    /// is needed when a preview editor is replaced by the next preview.
    fn pruneTabs(self: *EditorOpening, pane: *GroupView) void {
        var index = pane.tabs.items.len;
        var removed_active = false;
        while (index > 0) {
            index -= 1;
            const tab = pane.tabs.items[index];
            if (pane.group.model.contains(.{ .input = tab.input }, .{})) continue;
            if (pane.activeTab() == tab) removed_active = true;
            _ = pane.removeTab(tab);

            self.host.discard_tab(self.host.context, tab);
        }
        if (removed_active) pane.syncActivePane();
    }
};

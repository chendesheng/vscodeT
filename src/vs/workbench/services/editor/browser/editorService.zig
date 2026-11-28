// Port of the single-window editor service, editor opening, visibleEditorPanes
// and onDidVisibleEditorsChange in
// src/vs/workbench/services/editor/browser/editorService.ts.
// Terminal groups retain one pane per tab and expose their mounted pane.
const std = @import("std");
const resource_uri = @import("../../../../base/common/stdUri.zig");
const ui = @import("ui");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const FileEditorInput = @import("../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const ImagePreviewEditorInput = @import("../../../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;
const text_files = @import("../../textfile/common/textFileService.zig");
const TextModelResolverService = @import("../../textmodelResolver/common/textModelResolverService.zig").TextModelResolverService;
const editor_pane = @import("../../../browser/parts/editor/editorPane.zig");
const Tab = editor_pane.Tab;
const GroupView = @import("../../../browser/parts/editor/editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("../../../browser/parts/editor/editorPart.zig").EditorPart(GroupView);
const text_diff_editor_mod = @import("../../../browser/parts/editor/textDiffEditor.zig");
const multi_diff_input = @import("../../../contrib/multiDiffEditor/browser/multiDiffEditorInput.zig");
const multi_source = @import("../../../contrib/multiDiffEditor/browser/multiDiffSourceResolverService.zig");
const IConfigurationService = @import("../../../../platform/configuration/common/configuration.zig").IConfigurationService;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const IEditorService = @import("../common/editorService.zig").IEditorService;
const IVisibleEditorPane = @import("../../../common/editor.zig").IVisibleEditorPane;
const Event = @import("../../../../base/common/event.zig").Emitter(void);

pub const OpenOptions = @import("../common/editorService.zig").OpenOptions;
const EditorTarget = @import("../common/editorService.zig").EditorTarget;
const EditorReplacement = @import("../common/editorService.zig").EditorReplacement;
const IEditorIdentifier = @import("../common/editorService.zig").IEditorIdentifier;
const GroupIdentifier = @import("../../../common/editor.zig").GroupIdentifier;
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

    /// Resolve a file input already held by a normal pane or by either side
    /// of an open comparison. Both use the same working document.
    pub fn findResolvedFileInput(self: EditorService, io: std.Io, path: []const u8) ?*FileEditorInput {
        if (self.findOpenFileInput(io, path)) |input| return input;
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.multi_diff) |multi| {
                    for (multi.input.entries) |entry| {
                        for ([_]?text_diff_editor_mod.SideInput{ entry.original, entry.modified }) |maybe_side| {
                            const side = maybe_side orelse continue;
                            const input = side.fileInput() orelse continue;
                            if (text_files.samePath(self.part.allocator, io, input.editor.path, path)) return input;
                        }
                    }
                } else if (tab.diff) |diff| {
                    for ([_]text_diff_editor_mod.SideInput{ diff.original_input, diff.modified_input }) |side| {
                        const input = side.fileInput() orelse continue;
                        if (text_files.samePath(self.part.allocator, io, input.editor.path, path)) return input;
                    }
                }
            }
        }
        return null;
    }

    const DiffResources = struct {
        original: ?diff_provider.SnapshotSource.Resource = null,
        modified: ?diff_provider.SnapshotSource.Resource = null,
    };

    fn matchesResolvedSide(self: EditorService, io: std.Io, side: text_diff_editor_mod.SideInput, resource: ?diff_provider.SnapshotSource.Resource) bool {
        const resolved = resource orelse return true;
        if (resolved.is_working_file) {
            const file = side.fileInput() orelse return false;
            return text_files.samePath(self.part.allocator, io, file.editor.path, resolved.path);
        }
        if (side.fileInput() != null) return false;
        const key = @import("../../../../base/common/stdUri.zig").resourceKey(self.part.allocator, resolved.uri) catch return false;
        defer self.part.allocator.free(key);
        return std.mem.eql(u8, side.interface().resource orelse return false, key);
    }

    fn findResolvedDiffTab(self: EditorService, io: std.Io, path: []const u8, left: []const u8, right: []const u8, resources: DiffResources) ?struct { pane: *GroupView, tab: *Tab } {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const diff = tab.diff orelse continue;
                if (!diff.matches(path, left, right)) continue;
                if (!self.matchesResolvedSide(io, diff.original_input, resources.original)) continue;
                if (!self.matchesResolvedSide(io, diff.modified_input, resources.modified)) continue;
                return .{ .pane = pane, .tab = tab };
            }
        }
        return null;
    }

    fn resolveDiffSide(self: EditorService, io: std.Io, resource: ?diff_provider.SnapshotSource.Resource, text: []const u8, width: usize, height: usize, created: *?*FileEditorInput) !text_diff_editor_mod.SideSource {
        const resolver = if (self.opening) |opening| opening.text_model_resolver else null;
        const resolved = resource orelse return .{ .resolver = resolver };
        if (!resolved.is_working_file) return .{ .resource = resolved.uri, .encoding = resolved.encoding, .resolver = resolver };
        if (self.findResolvedFileInput(io, resolved.path)) |input| return .{ .file = input, .resolver = resolver };
        const editor = if (self.opening) |opening| try opening.createResolvedFileEditor(resolved, text, width, height) else try Editor.createFromTextWithOptions(self.part.allocator, io, text, resolved.path, width, height, .{ .reserve_scrollbar = true });
        errdefer {
            editor.deinit();
            self.part.allocator.destroy(editor);
        }
        if (self.opening) |opening| opening.host.configure_editor(opening.host.context, editor);
        const input = try FileEditorInput.init(self.part.allocator, editor);
        created.* = input;
        return .{ .file = input, .resolver = resolver };
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

    pub fn openDiffSide(self: EditorService, input: text_diff_editor_mod.SideInput) !void {
        const opening = self.opening orelse return error.EditorOpeningUnavailable;
        switch (input) {
            .file => |file| try opening.openPathWithOptions(file.editor.path, .{ .force_text = true }),
            .resource => |resource| try opening.openTextResourceInput(resource),
        }
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
        try self.openSnapshotDiffWithDiff(factory, io, path, original_text, modified_text, left_label, right_label, text_diff_editor_mod.computeConfigurationForResource(configuration, .{ .resource = path }), null, null, .{});
    }

    fn openSnapshotDiffWithDiff(
        self: EditorService,
        factory: editor_pane.EditorViewFactory,
        io: std.Io,
        path: []const u8,
        original_text: []const u8,
        modified_text: []const u8,
        left_label: []const u8,
        right_label: []const u8,
        options: text_diff_editor_mod.Options,
        computed: ?text_diff_editor_mod.IDocumentDiff,
        target: ?GroupIdentifier,
        resources: DiffResources,
    ) !void {
        if (self.findResolvedDiffTab(io, path, left_label, right_label, resources)) |existing| {
            const tab = existing.tab;
            const dims = existing.pane.contentDimensions();
            if (!tab.diff.?.matchesSnapshot(original_text, modified_text, options) or !tab.diff.?.widget.view_model.is_diff_up_to_date) {
                try tab.diff.?.replaceWithDiff(original_text, modified_text, dims.width, dims.height, options, computed);
            }
            if (resources.original) |resource| if (!resource.is_working_file) if (resource.encoding) |encoding| tab.diff.?.original_input.resolve().setEncoding(encoding);
            if (resources.modified) |resource| if (!resource.is_working_file) if (resource.encoding) |encoding| tab.diff.?.modified_input.resolve().setEncoding(encoding);
            if (self.opening) |opening| {
                try opening.configureSingleDiff(tab.diff.?.widget);
                opening.host.configure_tab(opening.host.context, tab);
            }
            tab.syncDiffViews();
            try existing.pane.activateTab(tab);
            self.part.service.activateGroup(existing.pane.group);
            tab.layoutCells(dims.width, dims.height);
            tab.focusEditor();
            return;
        }

        const pane = if (target) |id| self.part.viewForGroup(self.part.service.getGroup(id) orelse return error.GroupPaneMissing) orelse return error.GroupPaneMissing else self.part.activeView() orelse return error.GroupPaneMissing;
        const dims = pane.contentDimensions();
        const tab = blk: {
            var created_original: ?*FileEditorInput = null;
            defer if (created_original) |input| input.deinit();
            var created_modified: ?*FileEditorInput = null;
            defer if (created_modified) |input| input.deinit();
            const original = try self.resolveDiffSide(io, resources.original, original_text, dims.width, dims.height, &created_original);
            const modified = if (original.file) |file| blk_side: {
                if (resources.modified) |resolved| {
                    if (resolved.is_working_file and text_files.samePath(self.part.allocator, io, file.editor.path, resolved.path)) break :blk_side text_diff_editor_mod.SideSource{ .file = file, .resolver = original.resolver };
                }
                break :blk_side try self.resolveDiffSide(io, resources.modified, modified_text, dims.width, dims.height, &created_modified);
            } else try self.resolveDiffSide(io, resources.modified, modified_text, dims.width, dims.height, &created_modified);
            const view = try editor_pane.DiffView.createWithSources(
                factory,
                self.part.allocator,
                io,
                .{
                    .original_path = if (resources.original) |resource| resource.path else path,
                    .modified_path = if (resources.modified) |resource| resource.path else path,
                    .original_label = left_label,
                    .modified_label = right_label,
                },
                original_text,
                modified_text,
                dims.width,
                dims.height,
                options,
                .{ .original = original, .modified = modified },
                computed,
            );
            errdefer view.destroy();
            break :blk try Tab.initDiff(self.part.allocator, view);
        };
        var registered = false;
        defer if (!registered) tab.deinit();
        if (self.opening) |opening| try opening.configureSingleDiff(tab.diff.?.widget);

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
        if (self.opening) |opening| {
            opening.host.configure_tab(opening.host.context, tab);
            opening.host.register_working_copy(opening.host.context, tab);
        }
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
            .request_open_resource_uri_fn = struct {
                fn open(context: *anyopaque, resource: std.Uri, label: []const u8) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    try opening.requestOpenResourceUri(resource, label);
                }
            }.open,
            .open_text_resource_fn = struct {
                fn open(context: *anyopaque, input: *text_diff_editor_mod.TextResourceEditorInput, target: EditorTarget) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    if (target == .auxiliary_window) return error.AuxiliaryWindowUnavailable;
                    if (target == .side) {
                        opening.group_actions.transfer.layout(opening.group_actions.transfer.copy.context);
                        const source = opening.part.activeView() orelse return error.GroupPaneMissing;
                        const direction = opening.group_actions.preferredSideBySideDirection();
                        const destination = try opening.part.findGroup(.{ .direction = direction }, source, false) orelse try opening.group_actions.newEmptyGroup(direction);
                        destination.focus();
                    }
                    try opening.openTextResourceInput(input);
                }
            }.open,
            .open_multi_diff_source_fn = struct {
                fn open(context: *anyopaque, source_uri: []const u8, label: []const u8) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    const sources = opening.multi_diff_source_services orelse return error.MultiDiffUnavailable;
                    try opening.openMultiDiffSource(if (sources.configuration) |configuration| configuration.* else null, sources.resolver, source_uri, label);
                }
            }.open,
            .open_multi_diff_resources_fn = struct {
                fn open(context: *anyopaque, input: @import("../../../common/editor.zig").IResourceMultiDiffEditorInput) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    try opening.openMultiDiffResources(input);
                }
            }.open,
            .request_close_editor = struct {
                fn close(context: *anyopaque, group: GroupIdentifier, input: *EditorInput, preserve_focus: bool) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorClosingUnavailable;
                    const close_editor = opening.host.request_close_editor orelse return error.EditorClosingUnavailable;
                    try close_editor(opening.host.context, group, input, preserve_focus);
                }
            }.close,
            .request_open_editor = struct {
                fn open(context: *anyopaque, resource: []const u8, options: OpenOptions, target: EditorTarget) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    try opening.requestOpenEditor(resource, options, target);
                }
            }.open,
            .get_editors = struct {
                fn get(context: *anyopaque, allocator: std.mem.Allocator) ![]IEditorIdentifier {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    return service.getEditors(allocator);
                }
            }.get,
            .get_visible_text_resources = struct {
                fn get(context: *anyopaque, allocator: std.mem.Allocator) ![]std.Uri {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    return service.getVisibleTextResources(allocator);
                }
            }.get,
            .replace_editors = struct {
                fn replace(context: *anyopaque, replacements: []const EditorReplacement, group_id: GroupIdentifier) !void {
                    const service: *EditorService = @ptrCast(@alignCast(context));
                    const opening = service.opening orelse return error.EditorOpeningUnavailable;
                    try opening.replaceEditors(replacements, group_id);
                }
            }.replace,
            .on_did_active_editor_change = self.onDidActiveEditorChange(),
            .on_did_visible_editors_change = self.onDidVisibleEditorsChange(),
            .on_did_close_editor = &self.part.on_did_close_editor,
        };
    }

    pub fn getEditors(self: EditorService, allocator: std.mem.Allocator) ![]IEditorIdentifier {
        const views = try self.part.orderedViews(allocator);
        defer allocator.free(views);
        var result: std.ArrayList(IEditorIdentifier) = .empty;
        errdefer result.deinit(allocator);
        for (views) |pane| {
            for (0..pane.group.model.count()) |index| {
                try result.append(allocator, .{ .editor = pane.group.model.getEditorByIndex(index).?, .group_id = pane.group.id });
            }
        }
        return result.toOwnedSlice(allocator);
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

    pub fn getVisibleTextResources(self: EditorService, allocator: std.mem.Allocator) ![]std.Uri {
        var result: std.ArrayList(std.Uri) = .empty;
        errdefer result.deinit(allocator);
        var panes = self.visibleEditorPanes();
        while (panes.next()) |tab| {
            if (tab.image_preview != null or tab.markdown_preview != null or tab.terminalInstance() != null) continue;
            if (tab.multi_diff) |multi| {
                try multi.widget.collectVisibleTextResources(allocator, &result);
            } else if (tab.diff) |diff| {
                try result.append(allocator, diff.widget.original_editor.model.uri());
                try result.append(allocator, diff.widget.modified_editor.model.uri());
            } else {
                try result.append(allocator, tab.editor.model.uri());
            }
        }
        return result.toOwnedSlice(allocator);
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
const diff_provider = @import("../../../../editor/browser/widget/diffEditor/diffProviderFactoryService.zig");
const DiffProvider = diff_provider.WorkerBasedDocumentDiffProvider;
const DiffWorker = @import("../../../../editor/browser/services/editorWorkerService.zig").EditorWorkerService;
const WindowTask = @import("../../../../base/common/windowDispatch.zig").Task;

pub const EditorOpening = struct {
    pub const ImageDimensions = struct { width: usize, height: usize };

    allocator: Allocator,
    part: *EditorPart,
    group_actions: *GroupActions,
    io: std.Io,
    external_opener: ?*@import("../../../../platform/opener/common/opener.zig").ExternalOpener = null,
    view_factory: editor_pane.EditorViewFactory,
    images: *ui.image.Runtime,
    window_events: *@import("../../../../base/common/windowDispatch.zig").Queue,
    text_file_service: *text_files.TextFileService,
    text_model_resolver: *TextModelResolverService,
    history: *HistoryService,
    declarative: *const ?*const extensions_registry.Registry,
    json_client: *const ?*json_language.Client,
    language_features: *const ?*LanguageFeaturesService,
    host: struct {
        context: *anyopaque,
        configure_editor: *const fn (*anyopaque, *Editor) void,
        configure_tab: *const fn (*anyopaque, *Tab) void,
        configure_diff_widget: ?*const fn (*anyopaque, *editor_pane.DiffWidget) anyerror!void = null,
        dispose_diff_widget: ?*const fn (*anyopaque, *editor_pane.DiffWidget) void = null,
        register_working_copy: *const fn (*anyopaque, *Tab) void,
        change_working_copy: ?*const fn (*anyopaque, *Editor, bool) void = null,
        discard_tab: *const fn (*anyopaque, *Tab) void,
        request_close_editor: ?*const fn (*anyopaque, GroupIdentifier, *EditorInput, bool) anyerror!void = null,
        focus_editor: *const fn (*anyopaque) void,
        request_frame: *const fn (*anyopaque) void,
        show_status: *const fn (*anyopaque, []const u8) void,
        image_dimensions: *const fn (*anyopaque) ImageDimensions,
    },
    next_multi_diff_source: usize = 0,
    multi_diff_source_services: ?struct {
        configuration: ?*const IConfigurationService,
        resolver: multi_source.IMultiDiffSourceResolverService,
        storage: ?*const @import("../../../../platform/storage/common/storage.zig").IStorageService = null,
        workspace: ?*@import("../../workspaces/common/workspaceContextService.zig").WorkspaceContextService = null,
        lists: ?*@import("../../../../platform/list/browser/listService.zig").ListService = null,
        menus: ?*@import("../../../../platform/actions/common/menuService.zig").MenuService = null,
        context_keys: ?*const @import("../../../../platform/contextkey/common/contextkey.zig").IContextKeyService = null,
        context_menu: ?*const @import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService = null,
    } = null,
    pending_open: ?struct { read: *TextFileRead, options: OpenOptions } = null,
    pending_resource_open: ?struct {
        request: @import("../../../../editor/common/services/resolverService.zig").ModelReferenceRequest,
        label: []u8,
        options: OpenOptions = .{},
    } = null,
    pending_link_open: ?struct {
        encoded_uri: []u8,
        selection_utf16: ?@import("../../../../editor/common/core/position.zig").Position,
    } = null,
    link_open_task: WindowTask = .{},
    diff_worker: ?*DiffWorker = null,
    diff_cache: diff_provider.Cache = .{},
    pending_diff: ?struct {
        request: *DiffProvider.Request,
        path: []u8,
        left: []u8,
        right: []u8,
        group: GroupIdentifier,
    } = null,
    diff_progress: WindowTask = .{},
    reload_jobs: std.array_list.Managed(*TextFileRead),
    working_copy_file_listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,
    file_operation_service: ?@import("../../../../platform/files/common/files.zig").IFileService = null,
    pending_file_operations: std.ArrayList(*PendingFileOperation) = .empty,

    const PendingFileOperation = struct {
        owner: *EditorOpening,
        arena: std.heap.ArenaAllocator,
        operation: @import("../../../../platform/files/common/files.zig").FileOperation,
        pairs: []const @import("../../workingCopy/common/workingCopyFileService.zig").SourceTargetPair,
        leases: std.ArrayList(@import("../../../../editor/common/services/resolverService.zig").ModelReference) = .empty,
        task: WindowTask = .{},

        fn dispose(self: *PendingFileOperation) void {
            self.task.schedule(null);
            for (self.leases.items) |*reference| reference.dispose();
            const owner = self.owner;
            for (owner.pending_file_operations.items, 0..) |item, i| if (item == self) {
                _ = owner.pending_file_operations.orderedRemove(i);
                break;
            };
            self.arena.deinit();
            owner.allocator.destroy(self);
        }
        fn run(context: *anyopaque, _: i64, _: bool) bool {
            const self: *PendingFileOperation = @ptrCast(@alignCast(context));
            const owner = self.owner;
            defer self.dispose();
            for (self.pairs) |pair| {
                if (self.operation == .MOVE) {
                    if (pair.source) |source| {
                        owner.handleMovedFile(source, pair.target) catch {};
                        owner.handleDeletedFile(source, pair.target) catch {};
                    }
                } else owner.handleDeletedFile(pair.target, null) catch {};
            }
            owner.host.request_frame(owner.host.context);
            return true;
        }
    };

    pub fn bindWorkingCopyFileService(self: *EditorOpening, service: @import("../../workingCopy/common/workingCopyFileService.zig").IWorkingCopyFileService, files: @import("../../../../platform/files/common/files.zig").IFileService) !void {
        self.unbindWorkingCopyFileService();
        self.file_operation_service = files;
        self.working_copy_file_listener = try service.on_did_run.listenDisposable(self, onDidRunFileOperation);
    }
    pub fn unbindWorkingCopyFileService(self: *EditorOpening) void {
        if (self.working_copy_file_listener) |listener| listener.dispose();
        self.working_copy_file_listener = null;
        self.file_operation_service = null;
        while (self.pending_file_operations.items.len > 0) self.pending_file_operations.items[0].dispose();
        self.pending_file_operations.clearAndFree(self.allocator);
    }
    fn onDidRunFileOperation(event: @import("../../workingCopy/common/workingCopyFileService.zig").WorkingCopyFileEvent, self: *EditorOpening) !void {
        if (event.operation != .MOVE and event.operation != .DELETE) return;
        // The upstream listener awaits replacement; native provider mutations
        // complete synchronously. Deliver the immutable operation at the next
        // window turn, so a file undo cannot destroy its initiating editor
        // while that editor's undo/redo or code-action call is on the stack.
        const pending = try self.allocator.create(PendingFileOperation);
        errdefer self.allocator.destroy(pending);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const pairs = try a.alloc(@import("../../workingCopy/common/workingCopyFileService.zig").SourceTargetPair, event.files.len);
        for (event.files, pairs) |pair, *owned| owned.* = .{ .source = if (pair.source) |source| try resource_uri.clone(a, source) else null, .target = try resource_uri.clone(a, pair.target) };
        pending.* = .{ .owner = self, .arena = arena, .operation = event.operation, .pairs = pairs };
        errdefer for (pending.leases.items) |*reference| reference.dispose();
        // Keep restored target models alive through the deferred editor
        // replacement, including clean copies otherwise eligible for disposal.
        if (event.operation == .MOVE) for (self.part.group_views.items) |pane| for (pane.tabs.items) |tab| {
            if (tab.file_input == null) continue;
            const resource = tab.editor.model.uri();
            for (pairs) |pair| if (pair.source) |source| {
                const moved = (try resource_uri.mapMovedResource(a, resource, source, pair.target, self.ignoresFilePathCasing(resource))) orelse continue;
                if (try self.text_model_resolver.acquireExisting(moved)) |reference| {
                    var owned = reference;
                    errdefer owned.dispose();
                    try pending.leases.append(a, owned);
                }
            };
        };
        // ArrayList allocations above belong to the local arena which is
        // transferred together with the pending operation.
        pending.arena = arena;
        try self.pending_file_operations.append(self.allocator, pending);
        pending.task = .{ .queue = self.window_events, .context = pending, .run = PendingFileOperation.run, .progress = true };
        pending.task.post();
    }

    fn ignoresFilePathCasing(self: *const EditorOpening, resource: std.Uri) bool {
        const files = self.file_operation_service orelse return false;
        return !files.hasCapability(resource, @import("../../../../platform/files/common/files.zig").FileSystemProviderCapabilities.PathCaseSensitive);
    }

    fn handleMovedFile(self: *EditorOpening, source: std.Uri, target: std.Uri) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const active_group_id = self.part.service.activeGroup().id;
        defer if (self.part.service.getGroup(active_group_id)) |restored| self.part.service.activateGroup(restored);
        const group_ids = try a.alloc(GroupIdentifier, self.part.group_views.items.len);
        for (self.part.group_views.items, group_ids) |pane, *id| id.* = pane.group.id;
        const Item = struct { replacement: EditorReplacement, view_state: @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").ICodeEditorViewState };
        for (group_ids) |id| {
            const group = self.part.service.getGroup(id) orelse continue;
            const pane = self.part.viewForGroup(group) orelse continue;
            const active = group.model.activeEditor();
            var active_replacement: ?[]const u8 = null;
            var replacements: std.ArrayList(Item) = .empty;
            for (pane.tabs.items) |tab| {
                if (tab.file_input == null) continue;
                const resource = tab.editor.model.uri();
                const moved = (try resource_uri.mapMovedResource(a, resource, source, target, self.ignoresFilePathCasing(resource))) orelse continue;
                const result = (try tab.input.rename(group.id, moved)) orelse continue;
                const path = try resource_uri.fsPath(result.resource, a);
                try replacements.append(a, .{ .replacement = .{ .editor = tab.input, .resource = path, .options = .{ .force_text = true, .pinned = group.model.isPinned(.{ .editor = tab.input }), .preserve_focus = true } }, .view_state = try tab.editor.saveViewState(a) });
                if (active == tab.input) active_replacement = path;
            }
            for (replacements.items) |item| {
                try self.replaceEditors(&.{item.replacement}, id);
                for (pane.tabs.items) |tab| if (tab.file_input != null and self.samePath(tab.editor.path, item.replacement.resource)) {
                    try tab.editor.restoreViewState(item.view_state);
                    break;
                };
            }
            // Rename of an inactive tab must not make it active, and moving
            // the active tab restores the same group-specific selection.
            if (active_replacement) |path| {
                for (pane.tabs.items) |tab| if (tab.file_input != null and self.samePath(tab.editor.path, path)) {
                    try pane.activateTab(tab);
                    break;
                };
            } else if (active) |input| if (pane.tabForInput(input)) |tab| try pane.activateTab(tab);
        }
    }

    fn deletedResourceMatches(self: *EditorOpening, a: Allocator, resource: std.Uri, source: std.Uri, moved_to: ?std.Uri) !bool {
        const ignore_case = self.ignoresFilePathCasing(resource);
        if (moved_to) |target| if (try resource_uri.isEqualOrParent(resource, target, a, ignore_case)) return false;
        return resource_uri.isEqualOrParent(resource, source, a, ignore_case);
    }
    fn handleDeletedFile(self: *EditorOpening, source: std.Uri, moved_to: ?std.Uri) !void {
        const close = self.host.request_close_editor orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var to_close: std.ArrayList(struct { group: GroupIdentifier, input: *EditorInput }) = .empty;
        for (self.part.group_views.items) |pane| for (pane.tabs.items) |tab| {
            if (tab.input.isDirty()) continue;
            var matches = false;
            if (tab.file_input != null) matches = try self.deletedResourceMatches(a, tab.editor.model.uri(), source, moved_to) else if (tab.diff) |diff| {
                for ([_]text_diff_editor_mod.SideInput{ diff.original_input, diff.modified_input }) |side| {
                    if (side != .file) continue;
                    if (try self.deletedResourceMatches(a, side.resolve().model.uri(), source, moved_to)) matches = true;
                }
            }
            if (matches) try to_close.append(a, .{ .group = pane.group.id, .input = tab.input });
        };
        for (to_close.items) |item| try close(self.host.context, item.group, item.input, true);
    }

    pub fn cancel(self: *EditorOpening) void {
        self.link_open_task.schedule(null);
        if (self.pending_link_open) |pending| self.allocator.free(pending.encoded_uri);
        self.pending_link_open = null;
        self.cancelPendingOpen();
        self.cancelPendingDiff();
        self.cancelReloadJobs();
    }

    pub fn deinit(self: *EditorOpening) void {
        self.unbindWorkingCopyFileService();
        self.cancel();
        if (self.diff_worker) |worker| {
            worker.deinit();
            self.allocator.destroy(worker);
        }
        self.diff_cache.deinit();
        self.reload_jobs.deinit();
    }

    fn ensureDiffWorker(self: *EditorOpening) !*DiffWorker {
        if (self.diff_worker) |worker| return worker;
        const instance = try self.allocator.create(DiffWorker);
        instance.* = DiffWorker.init();
        instance.attachWindow(self.window_events);
        self.diff_worker = instance;
        return instance;
    }

    /// Restored panes take the same configuration, language, worker and
    /// working-copy registration path as fresh panes after mounting.
    pub fn configureRestoredTab(self: *EditorOpening, tab: *Tab) !void {
        if (tab.multi_diff) |multi| {
            const services = self.multi_diff_source_services orelse return error.MultiDiffUnavailable;
            try self.bindMultiDiffInput(multi.input, if (services.configuration) |configuration| configuration.* else null, services.resolver);
        } else if (tab.diff) |diff| {
            for ([_]text_diff_editor_mod.SideInput{ diff.original_input, diff.modified_input }) |side| try self.text_model_resolver.registerDocument(side.resolve(), side.interface().isReadonly());
            try self.configureSingleDiff(diff.widget);
        } else {
            self.host.configure_editor(self.host.context, tab.editor);
            if (tab.file_input != null) try self.text_model_resolver.registerDocument(tab.editor.document, false);
        }
        self.host.configure_tab(self.host.context, tab);
        self.host.register_working_copy(self.host.context, tab);
    }

    /// Fresh, restored and refreshed diff panes configure both actual
    /// sub-editors through the ordinary code-editor service binding.
    fn configureSingleDiff(self: *EditorOpening, widget: *editor_pane.DiffWidget) !void {
        self.host.configure_editor(self.host.context, widget.original_editor);
        self.host.configure_editor(self.host.context, widget.modified_editor);
        try self.attachDiffModel(widget.view_model);
    }

    fn attachDiffModel(self: *EditorOpening, model: *@import("../../../../editor/browser/widget/diffEditor/diffEditorViewModel.zig").DiffEditorViewModel) !void {
        model.attachWorker(try self.ensureDiffWorker(), &self.diff_cache, self.window_events);
    }

    pub fn findMultiDiffTab(self: *EditorOpening, source_uri: []const u8) ?struct { pane: *GroupView, tab: *Tab } {
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                const multi = tab.multi_diff orelse continue;
                if (std.mem.eql(u8, multi.input.source_uri, source_uri)) return .{ .pane = pane, .tab = tab };
            }
        }
        return null;
    }

    /// Opens the registered composite input through the normal group model.
    /// The input retains its document references for the pane's lifetime.
    pub fn openMultiDiffInput(self: *EditorOpening, input: *multi_diff_input.MultiDiffEditorInput, target: ?GroupIdentifier, preserve_focus: bool) !void {
        if (self.findMultiDiffTab(input.source_uri)) |existing| {
            try existing.pane.activateTab(existing.tab);
            self.part.service.activateGroup(existing.pane.group);
            if (!preserve_focus) {
                existing.tab.focusEditor();
                self.host.focus_editor(self.host.context);
            }
            return;
        }
        const group = if (target) |id| self.part.service.getGroup(id) orelse return error.GroupPaneMissing else self.part.service.activeGroup();
        const pane = self.part.viewForGroup(group) orelse return error.GroupPaneMissing;
        const dims = pane.contentDimensions();
        const tab = try self.createMultiDiffTab(input, dims.width, dims.height, preserve_focus);
        var tab_owned = true;
        errdefer if (tab_owned) tab.deinit();
        try pane.tabs.ensureUnusedCapacity(1);
        var added_model = false;
        errdefer if (added_model) {
            _ = pane.group.model.closeEditor(tab.input, .UNKNOWN, true) catch {};
            pane.syncActivePane();
        };
        const opened = try self.part.service.openEditor(tab.input, group, .{ .open = .{ .pinned = true, .active = true } });
        if (!opened.result.is_new) {
            tab.deinit();
            tab_owned = false;
            if (pane.tabForInput(opened.result.editor)) |existing| try pane.activateTab(existing);
            return;
        }
        added_model = true;
        try pane.addTab(tab);
        tab_owned = false;
        added_model = false;
        self.host.configure_tab(self.host.context, tab);
        self.host.register_working_copy(self.host.context, tab);
        tab.layoutCells(dims.width, dims.height);
        if (!preserve_focus) {
            tab.focusEditor();
            self.host.focus_editor(self.host.context);
        }
        self.host.request_frame(self.host.context);
    }

    pub fn setMultiDiffWorkspace(self: *EditorOpening, workspace: *@import("../../workspaces/common/workspaceContextService.zig").WorkspaceContextService) void {
        if (self.multi_diff_source_services) |*services| services.workspace = workspace;
        for (self.part.group_views.items) |pane| for (pane.tabs.items) |tab| {
            if (tab.multi_diff) |multi| multi.setWorkspace(workspace) catch {};
        };
    }

    /// Fresh and restored multi-diff inputs mount the same pane and worker.
    pub fn createMultiDiffTab(self: *EditorOpening, input: *multi_diff_input.MultiDiffEditorInput, width: usize, height: usize, preserve_focus: bool) !*Tab {
        const multi = try editor_pane.MultiDiffPane.create(self.allocator, self.io, input, self.window_events, .{
            .context = self,
            .view_factory = self.view_factory,
            .configure_diff = configureMultiDiffWidget,
            .dispose_diff = disposeMultiDiffWidget,
            .open_file = openMultiDiffFile,
            .open_binary_diff = openMultiDiffBinary,
            .file_toolbar = if (self.multi_diff_source_services) |services| blk: {
                const menus = services.menus orelse break :blk null;
                const keys = services.context_keys orelse break :blk null;
                break :blk .{ .menus = menus, .parent_context = keys, .context_menu_service = if (services.context_menu) |menu| menu.* else null };
            } else null,
        }, .{ .worker = try self.ensureDiffWorker(), .cache = &self.diff_cache }, width, height, preserve_focus, if (self.multi_diff_source_services) |services| blk: {
            const config = services.configuration orelse break :blk null;
            const store = services.storage orelse break :blk null;
            break :blk .{ .configuration_service = config.*, .storage_service = store.*, .workspace = services.workspace, .lists = services.lists };
        } else null);
        errdefer multi.destroy();
        return Tab.initMultiDiff(self.view_factory, self.allocator, self.io, multi);
    }

    fn configureMultiDiffWidget(context: *anyopaque, widget: *editor_pane.DiffWidget) !void {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        self.host.configure_editor(self.host.context, widget.original_editor);
        self.host.configure_editor(self.host.context, widget.modified_editor);
        if (self.host.configure_diff_widget) |configure| try configure(self.host.context, widget);
    }

    fn disposeMultiDiffWidget(context: *anyopaque, widget: *editor_pane.DiffWidget) void {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        if (self.host.dispose_diff_widget) |dispose| dispose(self.host.context, widget);
    }

    fn openMultiDiffFile(context: *anyopaque, uri: std.Uri) !void {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var target = uri;
        var label: ?[]const u8 = null;
        var selection: ?@import("../../../../editor/common/core/selection.zig").Selection = null;
        const current = (EditorService{ .part = self.part }).activeEditorPane();
        if (current) |tab| if (tab.multi_diff) |multi| {
            if (try multi.input.findDocumentDiffItem(uri)) |found| {
                if (found.entry.go_to_file_uri) |encoded| target = try std.Uri.parse(try a.dupe(u8, encoded));
                if (found.entry.go_to_file_title) |title| label = try a.dupe(u8, title);
                if (multi.widget.getViewModel()) |vm| for (vm.items) |item| {
                    if (item.documentDiffItem != found.entry.item) continue;
                    if (multi.widget.impl.bindingFor(item)) |binding| if (binding.editor) |widget| {
                        const editor = if (found.is_original) widget.original_editor else widget.modified_editor;
                        const selections = try editor.getSelections();
                        defer editor.allocator.free(selections);
                        if (selections.len != 0) selection = selections[0];
                    };
                    break;
                };
            }
        };
        try self.openMultiDiffTarget(target, label);
        if (selection) |value| {
            const tab = (EditorService{ .part = self.part }).activeEditorPane() orelse return;
            try tab.editor.setSelections(&.{value});
            _ = tab.editor.revealRange(.init(value.startLineNumber, value.startColumn, value.endLineNumber, value.endColumn), .CenterIfOutsideViewport);
        }
    }

    fn openMultiDiffTarget(self: *EditorOpening, uri: std.Uri, label: ?[]const u8) !void {
        const std_uri = @import("../../../../base/common/stdUri.zig");
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (std.mem.eql(u8, uri.scheme, "file")) return self.openPathWithOptions(try std_uri.fsPath(uri, arena.allocator()), .{});
        const key = try std_uri.resourceKey(arena.allocator(), uri);
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.multi_diff) |multi| for (multi.input.entries) |entry| {
                    for ([_]?text_diff_editor_mod.SideInput{ entry.original, entry.modified }) |side| {
                        if (side) |source| {
                            if (source == .resource and std.mem.eql(u8, source.resource.key, key)) {
                                if (label) |name| try source.resource.setPreferredName(name);
                                return self.openTextResourceInput(source.resource);
                            }
                        }
                    }
                };
            }
        }
        return error.DiffResourceUnavailable;
    }

    fn openMultiDiffBinary(context: *anyopaque, original: std.Uri, modified: std.Uri) !void {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, modified.scheme, "file")) return openMultiDiffFile(context, modified);
        if (std.mem.eql(u8, original.scheme, "file")) return openMultiDiffFile(context, original);
        self.setStatusHint("No binary comparison editor for this resource", .{});
    }

    /// Source resolution belongs to the input, not the transient open-editor
    /// request. A late SCM provider or a changed group can update the same
    /// pane even after another editor is opened.
    pub fn openMultiDiffSource(self: *EditorOpening, configuration: ?IConfigurationService, resolver: multi_source.IMultiDiffSourceResolverService, source_uri: []const u8, label: []const u8) !void {
        self.cancelPendingOpen();
        self.cancelPendingDiff();
        if (self.findMultiDiffTab(source_uri)) |existing| {
            try self.openMultiDiffInput(existing.tab.multi_diff.?.input, existing.pane.group.id, false);
            return;
        }
        const input = try multi_diff_input.MultiDiffEditorInput.create(self.allocator, source_uri, label, false);
        defer input.destroy();
        try self.bindMultiDiffInput(input, configuration, resolver);
        try self.openMultiDiffInput(input, null, false);
    }

    pub fn openMultiDiffResources(self: *EditorOpening, options: @import("../../../common/editor.zig").IResourceMultiDiffEditorInput) !void {
        if (options.multiDiffSource == null and options.resources == null) return error.InvalidMultiDiffSource;
        const services = self.multi_diff_source_services orelse return error.MultiDiffUnavailable;
        self.cancelPendingOpen();
        self.cancelPendingDiff();
        const uri = if (options.multiDiffSource) |source|
            try std.fmt.allocPrint(self.allocator, "{f}", .{source})
        else blk: {
            self.next_multi_diff_source += 1;
            // Unique within this window, including inputs restored from an
            // earlier native session.
            const now = @import("../../../../base/common/timeCompat.zig").milliTimestamp(self.window_events.io);
            break :blk try std.fmt.allocPrint(self.allocator, "multi-diff-editor:{d}-{d}", .{ now, self.next_multi_diff_source });
        };
        defer self.allocator.free(uri);
        if (self.findMultiDiffTab(uri)) |existing| {
            try self.openMultiDiffInput(existing.tab.multi_diff.?.input, existing.pane.group.id, options.options.preserveFocus);
            try existing.tab.multi_diff.?.setOptions(options.options);
            return;
        }
        const input = try multi_diff_input.MultiDiffEditorInput.create(self.allocator, uri, options.label, options.isTransient);
        defer input.destroy();
        if (options.resources) |resources| {
            const items = try self.allocator.alloc(multi_source.MultiDiffEditorItem, resources.len);
            defer self.allocator.free(items);
            for (resources, items) |resource, *item| item.* = .{
                .originalUri = resource.original,
                .modifiedUri = resource.modified,
                .goToFileUri = resource.goToFileResource,
            };
            try input.setInitialResources(items);
        }
        try self.bindMultiDiffInput(input, if (services.configuration) |configuration| configuration.* else null, services.resolver);
        try self.openMultiDiffInput(input, null, options.options.preserveFocus);
        if (self.findMultiDiffTab(uri)) |opened| try opened.tab.multi_diff.?.setOptions(options.options);
    }

    fn bindMultiDiffInput(self: *EditorOpening, input: *multi_diff_input.MultiDiffEditorInput, configuration: ?IConfigurationService, resolver: multi_source.IMultiDiffSourceResolverService) !void {
        if (input.source_binding != null) return;
        const source = try input.resolveSource(resolver);
        _ = try SourceBinding.create(self, input, source, configuration);
    }

    const SourceBinding = struct {
        opening: *EditorOpening,
        input: *multi_diff_input.MultiDiffEditorInput,
        configuration: ?IConfigurationService,

        fn create(opening: *EditorOpening, input: *multi_diff_input.MultiDiffEditorInput, source: multi_source.IResolvedMultiDiffSource, configuration: ?IConfigurationService) !*SourceBinding {
            const binding = opening.allocator.create(SourceBinding) catch |err| {
                source.dispose(source.context);
                return err;
            };
            binding.* = .{ .opening = opening, .input = input, .configuration = configuration };
            try input.attachResolvedSource(source, .{ .context = binding, .resolve_resources = refresh, .report_failure = reportFailure, .dispose = dispose });
            return binding;
        }
        fn reportFailure(context: *anyopaque, err: anyerror) void {
            const self: *SourceBinding = @ptrCast(@alignCast(context));
            self.opening.setStatusHint("Open changes failed: {s}", .{@errorName(err)});
        }
        fn refresh(context: *anyopaque, resources: []const multi_source.MultiDiffEditorItem) !void {
            const self: *SourceBinding = @ptrCast(@alignCast(context));
            try self.input.resolveResourceModels(self.opening.text_model_resolver.interface(), resources, .{ .context = self, .run = resolved });
        }
        fn resolved(context: *anyopaque, resources: []const multi_diff_input.ResolvedResourceItem) !void {
            const self: *SourceBinding = @ptrCast(@alignCast(context));
            const opening = self.opening;
            const input = self.input;
            try self.applyResolved(resources);
            if (input.last_resolution_failure) |failure| opening.setStatusHint("Some changed files could not be resolved: {s}", .{@errorName(failure)}) else opening.clearStatusHint();
            opening.host.request_frame(opening.host.context);
        }
        fn applyResolved(self: *SourceBinding, resources: []const multi_diff_input.ResolvedResourceItem) !void {
            const opening = self.opening;
            const change = opening.host.change_working_copy orelse return self.input.publishResolvedResources(resources, self.resourceModelAdapter());
            // Retain the old file inputs until their registration delta is
            // applied. Unchanged file identities do not unregister/re-register.
            var previous: std.ArrayList(*FileEditorInput) = .empty;
            defer {
                for (previous.items) |file| file.deinit();
                previous.deinit(opening.allocator);
            }
            for (self.input.entries) |entry| for ([_]?text_diff_editor_mod.SideInput{ entry.original, entry.modified }) |side| {
                if (side) |value| if (value.fileInput()) |file| {
                    try previous.append(opening.allocator, file);
                    _ = file.retain();
                };
            };
            var delta: std.AutoHashMap(*Editor, isize) = .init(opening.allocator);
            defer delta.deinit();
            for (previous.items) |file| {
                const entry = try delta.getOrPut(file.editor);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* -= 1;
            }
            const result = self.input.publishResolvedResources(resources, self.resourceModelAdapter());
            for (self.input.entries) |entry| for ([_]?text_diff_editor_mod.SideInput{ entry.original, entry.modified }) |side| {
                if (side) |value| if (value.fileInput()) |file| {
                    const counter = try delta.getOrPut(file.editor);
                    if (!counter.found_existing) counter.value_ptr.* = 0;
                    counter.value_ptr.* += 1;
                };
            };
            var iterator = delta.iterator();
            while (iterator.next()) |entry| {
                const count = entry.value_ptr.*;
                for (0..@abs(count)) |_| change(opening.host.context, entry.key_ptr.*, count > 0);
            }
            try result;
        }
        fn resourceModelAdapter(self: *SourceBinding) multi_diff_input.ResourceModelAdapter {
            return .{ .context = self, .create_side = createSide, .compute_options = computeOptions };
        }
        fn createSide(context: *anyopaque, side: multi_diff_input.ResolvedResourceSide, existing: ?text_diff_editor_mod.SideInput, label: []const u8) !multi_diff_input.ResolvedSide {
            const self: *SourceBinding = @ptrCast(@alignCast(context));
            const opening = self.opening;
            const uri = side.uri.?;
            const reference = side.reference() orelse return error.UnableToResolveResource;
            const document = TextModelResolverService.documentOf(reference);
            if (existing) |input| {
                if (input.resolve() == document) return .{ .uri = uri, .input = switch (input) {
                    .file => |file| .{ .file = file.retain() },
                    .resource => |resource| .{ .resource = resource.retain() },
                } };
            }
            if (std.mem.eql(u8, uri.scheme, "file")) {
                const service = EditorService{ .part = opening.part };
                if (service.findOpenFileInput(opening.io, document.path)) |file| {
                    if (file.editor.document != document) return error.ModelAlreadyRegistered;
                    return .{ .uri = uri, .input = .{ .file = file.retain() } };
                }
                const editor = try Editor.createViewFromDocument(document, 80, 20, .{ .reserve_scrollbar = true });
                errdefer {
                    editor.deinit();
                    opening.allocator.destroy(editor);
                }
                opening.host.configure_editor(opening.host.context, editor);
                const input = try FileEditorInput.init(opening.allocator, editor);
                return .{ .uri = uri, .input = .{ .file = input } };
            }
            const owned_reference = try opening.text_model_resolver.acquireModelReference(uri);
            const input = try text_diff_editor_mod.TextResourceEditorInput.initFromReference(opening.allocator, owned_reference, label);
            return .{ .uri = uri, .input = .{ .resource = input } };
        }
        fn computeOptions(context: *anyopaque, uri: std.Uri, original: ?multi_diff_input.ResolvedSide, modified: ?multi_diff_input.ResolvedSide) !text_diff_editor_mod.Options {
            const self: *SourceBinding = @ptrCast(@alignCast(context));
            var scratch = std.heap.ArenaAllocator.init(self.opening.allocator);
            defer scratch.deinit();
            const language = if (modified) |side| if (side.input) |input| input.resolve().model.getLanguageId() else null else null;
            const side = modified orelse original.?;
            const path = if (side.input) |input| input.resolve().path else try @import("../../../../base/common/stdUri.zig").fsPath(uri, scratch.allocator());
            return text_diff_editor_mod.computeConfigurationForResource(self.configuration, .{ .resource = path, .override_identifier = language });
        }
        fn dispose(context: *anyopaque) void {
            const self: *SourceBinding = @ptrCast(@alignCast(context));
            self.opening.allocator.destroy(self);
        }
    };

    fn createResolvedFileEditor(self: *EditorOpening, resource: diff_provider.SnapshotSource.Resource, text: []const u8, width: usize, height: usize) !*Editor {
        if (try self.text_model_resolver.acquireExisting(resource.uri)) |value| {
            var reference = value;
            defer reference.dispose();
            return Editor.createViewFromDocument(TextModelResolverService.documentOf(reference), width, height, .{ .reserve_scrollbar = true });
        }
        var reference = try self.text_model_resolver.createResolvedModelReference(resource.uri, resource.path, text, false);
        defer reference.dispose();
        const editor = try Editor.createViewFromDocument(TextModelResolverService.documentOf(reference), width, height, .{ .reserve_scrollbar = true });
        if (resource.encoding) |encoding| editor.setEncoding(encoding);
        return editor;
    }

    /// Consumes the provider's virtual document source on all outcomes.
    pub fn requestOpenSnapshotDiff(self: *EditorOpening, configuration: ?IConfigurationService, path: []const u8, source: diff_provider.SnapshotSource, left: []const u8, right: []const u8) !void {
        var source_owned = true;
        errdefer if (source_owned) source.destroy(source.context);
        self.cancelPendingOpen();
        self.cancelPendingDiff();
        const options = text_diff_editor_mod.computeConfigurationForResource(configuration, .{ .resource = path });
        const worker = try self.ensureDiffWorker();
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const left_copy = try self.allocator.dupe(u8, left);
        errdefer self.allocator.free(left_copy);
        const right_copy = try self.allocator.dupe(u8, right);
        errdefer self.allocator.free(right_copy);
        const now = @import("../../../../base/common/timeCompat.zig").milliTimestamp(self.window_events.io);
        source_owned = false;
        const request = try DiffProvider.computeResolvedDiff(worker, &self.diff_cache, source, options, .{
            .context = self,
            .run = diffCompleted,
        }, now);
        self.pending_diff = .{
            .request = request,
            .path = path_copy,
            .left = left_copy,
            .right = right_copy,
            .group = self.part.service.activeGroup().id,
        };
        self.diff_progress = .{ .queue = self.window_events, .context = self, .run = showDiffProgress };
        self.diff_progress.schedule(now + 1000);
    }

    fn showDiffProgress(context: *anyopaque, _: i64, _: bool) bool {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        const pending = self.pending_diff orelse return false;
        self.setStatusHint("Computing diff for {s}...", .{std.fs.path.basename(pending.path)});
        return true;
    }

    fn cancelPendingDiff(self: *EditorOpening) void {
        const pending = self.pending_diff orelse return;
        self.pending_diff = null;
        pending.request.cancel();
        self.diff_progress.schedule(null);
        self.allocator.free(pending.path);
        self.allocator.free(pending.left);
        self.allocator.free(pending.right);
    }

    fn diffCompleted(context: *anyopaque, request: *DiffProvider.Request, result: ?text_diff_editor_mod.IDocumentDiff) bool {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        const pending = self.pending_diff orelse return false;
        if (pending.request != request) return false;
        self.pending_diff = null;
        self.diff_progress.schedule(null);
        defer {
            self.allocator.free(pending.path);
            self.allocator.free(pending.left);
            self.allocator.free(pending.right);
        }
        const computed = result orelse {
            if (request.failure) |err| self.setStatusHint("Open diff failed: {s}", .{@errorName(err)}) else self.setStatusHint("Diff computation failed", .{});
            return true;
        };
        if (self.part.service.getGroup(pending.group) == null) return false;
        const editors = EditorService{ .part = self.part, .opening = self };
        editors.openSnapshotDiffWithDiff(self.view_factory, self.io, pending.path, request.original, request.modified, pending.left, pending.right, request.options, computed, pending.group, .{ .original = request.original_resource, .modified = request.modified_resource }) catch |err| {
            self.setStatusHint("Open diff failed: {s}", .{@errorName(err)});
            return true;
        };
        self.clearStatusHint();
        self.host.focus_editor(self.host.context);
        return true;
    }

    fn samePath(self: *EditorOpening, left: []const u8, right: []const u8) bool {
        return text_files.samePath(self.allocator, self.io, left, right);
    }

    fn findOpenInput(self: *EditorOpening, path: []const u8) ?*FileEditorInput {
        return (EditorService{ .part = self.part }).findResolvedFileInput(self.io, path);
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

    fn openTextResourceInput(self: *EditorOpening, input: *text_diff_editor_mod.TextResourceEditorInput) !void {
        try self.text_model_resolver.registerDocument(input.document, true);
        self.cancelPendingOpen();
        self.cancelPendingDiff();
        const opened = try self.part.service.openEditor(input.interface(), null, .{ .open = .{ .pinned = true, .active = true } });
        const pane = self.part.viewForGroup(opened.group) orelse return error.GroupPaneMissing;
        if (!opened.result.is_new) {
            if (pane.tabForInput(opened.result.editor)) |tab| {
                try pane.activateTab(tab);
                tab.focusEditor();
                self.host.focus_editor(self.host.context);
            }
            return;
        }
        var mounted = false;
        errdefer if (!mounted) {
            _ = opened.group.model.closeEditor(input.interface(), .UNKNOWN, true) catch null;
            pane.syncActivePane();
        };
        const dimensions = pane.contentDimensions();
        const tab = try Tab.initResourceFromInput(self.view_factory, self.allocator, input, dimensions.width, dimensions.height);
        var tab_owned = true;
        errdefer if (tab_owned) tab.deinit();
        self.host.configure_editor(self.host.context, tab.editor);
        try tab.view.setStatusBarVisible(false);
        tab.setImageRuntime(self.images);
        try pane.addTab(tab);
        tab_owned = false;
        mounted = true;
        self.host.configure_tab(self.host.context, tab);
        if (self.language_features.*) |features| tab.attachLanguageRegistry(features);
        tab.ensureControllers() catch {};
        tab.focusEditor();
        self.host.focus_editor(self.host.context);
    }

    fn openExistingInput(self: *EditorOpening, path: []const u8, existing: *FileEditorInput, options: OpenOptions) !void {
        const service = EditorService{ .part = self.part };
        if (service.findOpenFileInput(self.io, path)) |mounted| {
            try self.finishTextEditorOpen(path, try service.openExistingFileInput(mounted, options), options);
        } else {
            const size = (self.part.activeView() orelse return error.GroupPaneMissing).contentDimensions();
            const editor = try Editor.createViewFromEditorWithOptions(existing.editor, size.width, size.height, .{ .reserve_scrollbar = true });
            try self.openCreatedTextEditor(path, editor, options);
        }
    }

    fn openCreatedTextEditor(self: *EditorOpening, path: []const u8, editor: *Editor, options: OpenOptions) !void {
        var actual = editor;
        var owned = true;
        defer if (owned) {
            actual.deinit();
            self.allocator.destroy(actual);
        };
        if (try self.text_model_resolver.acquireExisting(editor.model.uri())) |value| {
            var reference = value;
            defer reference.dispose();
            const document = TextModelResolverService.documentOf(reference);
            if (document != editor.document) {
                const size = (self.part.activeView() orelse return error.GroupPaneMissing).contentDimensions();
                actual = try Editor.createViewFromDocument(document, size.width, size.height, .{ .reserve_scrollbar = true });
                editor.deinit();
                self.allocator.destroy(editor);
            }
        } else try self.text_model_resolver.registerDocument(editor.document, false);
        self.host.configure_editor(self.host.context, actual);
        const service = EditorService{ .part = self.part };
        owned = false; // openTextEditor consumes the editor on all outcomes
        try self.finishTextEditorOpen(path, try service.openTextEditor(self.view_factory, actual, options, self.images), options);
    }

    fn finishTextEditorOpen(self: *EditorOpening, path: []const u8, opened: OpenedTextEditor, options: OpenOptions) !void {
        if (opened.tab) |tab| {
            tab.setImageRuntime(self.images);
            if (opened.is_new) {
                self.host.configure_tab(self.host.context, tab);
                self.host.register_working_copy(self.host.context, tab);
            }
            if (self.language_features.*) |features| tab.attachLanguageRegistry(features);
            try tab.ensureControllers();
            if (options.selection_utf16) |position| try revealUtf16Position(tab.editor, position);
            if (options.selection_model) |selection| try tab.editor.setSelection(selection);
            if (!opened.is_new and !options.preserve_focus) tab.focusEditor();
        }
        try self.history.add(path);
        self.pruneTabs(opened.pane);
        if (opened.tab) |tab| if (options.on_text_editor_opened) |callback| callback(tab.editor);
    }

    fn revealUtf16Position(editor: *Editor, position: @import("../../../../editor/common/core/position.zig").Position) !void {
        const line_number = std.math.clamp(position.lineNumber, 1, editor.model.getLineCount());
        var line = try editor.model.getLineContent(line_number);
        defer line.deinit();
        const column = @import("../../../api/common/positionConverter.zig").columnForUtf16Offset(line.items, position.column);
        try editor.setCursorPosition(.init(line_number, column));
    }

    pub fn openPathWithOptions(self: *EditorOpening, path: []const u8, options: OpenOptions) !void {
        self.cancelPendingDiff();
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
        const resource: std.Uri = .{ .scheme = "file", .path = .{ .raw = path } };
        if (try self.text_model_resolver.acquireExisting(resource)) |reference| {
            var held = reference;
            defer held.dispose();
            const editor = try Editor.createViewFromDocument(TextModelResolverService.documentOf(held), size.width, size.height, .{ .reserve_scrollbar = true });
            return self.openCreatedTextEditor(path, editor, options);
        }
        const editor = try Editor.createWithExtensionsOptions(self.allocator, self.io, path, size.width, size.height, self.declarative.*, self.json_client.*, .{ .reserve_scrollbar = true, .undo_store = try self.text_model_resolver.undoRedoStore() });
        try self.openCreatedTextEditor(path, editor, options);
    }

    /// Portable resource replacement for the default text-editor override.
    /// Open the replacement in the nominated group before closing the old
    /// input, preserving its sequential index and REPLACE close context.
    pub fn replaceEditors(self: *EditorOpening, replacements: []const EditorReplacement, group_id: GroupIdentifier) !void {
        const group = self.part.service.getGroup(group_id) orelse return;
        const destination = self.part.viewForGroup(group) orelse return;
        for (replacements) |item| {
            if (!item.options.force_text) return error.ReplacementNotSupported;
            const old = destination.tabForInput(item.editor) orelse continue;
            const index = group.model.indexOf(.{ .input = item.editor }) orelse continue;
            const sticky = group.model.isSticky(.{ .editor = item.editor });
            self.part.service.activateGroup(group);
            var replacement: ?*Tab = null;
            // A resolved text input may already be open in another group.
            // Copy its mounted view, not the input pointer without a pane.
            outer: for (self.part.group_views.items) |pane| {
                for (pane.tabs.items) |tab| {
                    const input = tab.file_input orelse continue;
                    if (!self.samePath(input.editor.path, item.resource)) continue;
                    replacement = if (pane == destination) tab else try destination.copyEditor(tab, .{ .pinned = item.options.pinned, .active = true }, self.group_actions.transfer.copy);
                    break :outer;
                }
            }
            const already_open = replacement != null;
            if (replacement) |tab| {
                try destination.activateTab(tab);
                if (item.options.pinned) _ = try group.model.pin(tab.input);
                try self.history.add(item.resource);
            } else {
                // Keep the source preview alive until its explicit REPLACE
                // close. Opening another unpinned preview would otherwise
                // dispose the source before this transaction can use it.
                var open_options = item.options;
                open_options.pinned = true;
                try self.openPathWithOptions(item.resource, open_options);
                replacement = destination.activeTab();
            }
            const tab = replacement orelse return error.EditorOpeningUnavailable;
            if (tab == old or tab.file_input == null) return error.ReplacementNotSupported;
            self.group_actions.transfer.move.will_move(self.group_actions.transfer.move.context, destination, old);
            try self.part.closeEditorWithContext(destination, old, .REPLACE, self.group_actions.transfer);
            if (sticky) _ = try group.model.stick(tab.input) else if (!item.options.pinned and !already_open and !tab.input.isDirty()) _ = try group.model.unpin(tab.input);
            _ = try group.model.moveEditor(tab.input, @intCast(index));
            destination.syncActivePane();
            if (!item.options.preserve_focus) destination.focus();
        }
    }

    /// The quick access SIDE_GROUP target uses the configured split direction,
    /// reuses an existing group when available, then opens there. An already
    /// resolved input shares its model via EditorGroupView.copyEditor.
    pub fn requestOpenEditor(self: *EditorOpening, path: []const u8, options: OpenOptions, target: EditorTarget) !void {
        if (target == .auxiliary_window) return error.AuxiliaryWindowUnavailable;
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
        self.cancelPendingDiff();
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

    pub fn requestOpenResourceUri(self: *EditorOpening, resource: std.Uri, label: []const u8) !void {
        try self.requestOpenResourceUriAt(resource, label, null);
    }

    /// IOpenerService adapter. Defer the actual editor activation until the
    /// current DOM event has returned, since opening a preview can dispose
    /// the code editor and hover that initiated it.
    pub const OpenerAdapter = struct {
        opening: *EditorOpening,
        pub fn interface(self: OpenerAdapter) @import("../../../../platform/opener/common/opener.zig").IOpenerService {
            return .{ .context = self.opening, .open_resource = open };
        }
        fn open(context: *anyopaque, resource: resource_uri.Components, selection: ?@import("../../../../editor/common/core/position.zig").Position) void {
            const self: *EditorOpening = @ptrCast(@alignCast(context));
            var uri = @import("../../../../base/common/uri.zig").URI.from(self.allocator, .{ .scheme = resource.scheme, .authority = resource.authority, .path = resource.path, .query = resource.query, .fragment = resource.fragment }, false) catch return;
            defer uri.deinit();
            const encoded = uri.toStringEncoded(self.allocator) catch return;
            if (self.pending_link_open) |pending| self.allocator.free(pending.encoded_uri);
            self.pending_link_open = .{ .encoded_uri = encoded, .selection_utf16 = selection };
            if (self.link_open_task.queue == null) self.link_open_task = .{ .queue = self.window_events, .context = self, .run = run, .progress = true };
            self.link_open_task.post();
        }
        fn run(context: *anyopaque, _: i64, _: bool) bool {
            const self: *EditorOpening = @ptrCast(@alignCast(context));
            const pending = self.pending_link_open orelse return false;
            self.pending_link_open = null;
            defer self.allocator.free(pending.encoded_uri);
            const resource = std.Uri.parse(pending.encoded_uri) catch return false;
            if (std.mem.eql(u8, resource.scheme, "http") or std.mem.eql(u8, resource.scheme, "https")) {
                if (self.external_opener) |opener| {
                    opener.requestOpen(pending.encoded_uri) catch {};
                } else _ = @import("../../../../platform/opener/common/opener.zig").openExternal(self.allocator, self.io, pending.encoded_uri) catch false;
            } else if (!std.mem.eql(u8, resource.scheme, "command")) {
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                const path = resource_uri.path(resource, scratch.allocator()) catch return false;
                self.requestOpenResourceUriAt(resource, std.fs.path.basename(path), pending.selection_utf16) catch |err| self.setStatusHint("Open failed: {s}", .{@errorName(err)});
            }
            self.host.request_frame(self.host.context);
            return true;
        }
    };

    /// Shared opener path: files use their normal editable input, while
    /// virtual resources resolve through ITextModelService in the same way
    /// as opening the original side of a diff.
    pub fn requestOpenResourceUriAt(self: *EditorOpening, resource: std.Uri, label: []const u8, selection: ?@import("../../../../editor/common/core/position.zig").Position) !void {
        try self.requestOpenResourceUriWithOptions(resource, label, .{ .force_text = selection != null, .selection_utf16 = selection });
    }

    pub fn requestOpenCodeEditor(context: *anyopaque, request: @import("../../../../editor/browser/services/codeEditorService.zig").OpenCodeEditorOptions) !void {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const path = try resource_uri.path(request.resource, arena.allocator());
        try self.requestOpenResourceUriWithOptions(request.resource, std.fs.path.basename(path), .{ .pinned = request.pinned, .force_text = true, .selection_model = request.selection, .on_text_editor_opened = request.on_opened });
    }

    fn requestOpenResourceUriWithOptions(self: *EditorOpening, resource: std.Uri, label: []const u8, options: OpenOptions) !void {
        self.cancelPendingOpen();
        self.cancelPendingDiff();
        if (std.mem.eql(u8, resource.scheme, "file")) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const path = try @import("../../../../base/common/stdUri.zig").fsPath(resource, arena.allocator());
            self.requestOpenPathWithOptions(path, options);
            return;
        }
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const request = try self.text_model_resolver.createModelReference(resource, .{ .context = self, .complete = resourceOpenCompleted });
        self.pending_resource_open = .{ .request = request, .label = owned_label, .options = options };
        self.setStatusHint("Opening {s}...", .{label});
    }

    fn resourceOpenCompleted(context: *anyopaque, result: @import("../../../../editor/common/services/resolverService.zig").ModelReferenceResult) void {
        const self: *EditorOpening = @ptrCast(@alignCast(context));
        const pending = self.pending_resource_open orelse {
            if (result == .resolved) {
                var reference = result.resolved;
                reference.dispose();
            }
            return;
        };
        self.pending_resource_open = null;
        defer self.allocator.free(pending.label);
        self.clearStatusHint();
        self.finishResourceOpen(result, pending.label, pending.options) catch |err| self.setStatusHint("Open failed: {s}", .{@errorName(err)});
        self.host.request_frame(self.host.context);
    }

    fn finishResourceOpen(self: *EditorOpening, result: @import("../../../../editor/common/services/resolverService.zig").ModelReferenceResult, label: []const u8, options: OpenOptions) !void {
        const reference = switch (result) {
            .resolved => |value| value,
            .failure => |err| return err,
        };
        const input = try text_diff_editor_mod.TextResourceEditorInput.initFromReference(self.allocator, reference, label);
        defer input.destroy();
        try self.openTextResourceInput(input);
        if (self.part.activeView()) |pane| if (pane.activeTab()) |tab| {
            if (options.selection_utf16) |position| try revealUtf16Position(tab.editor, position);
            if (options.selection_model) |selection| try tab.editor.setSelection(selection);
            if (options.on_text_editor_opened) |callback| callback(tab.editor);
        };
    }

    fn cancelPendingOpen(self: *EditorOpening) void {
        if (self.pending_resource_open) |pending| {
            self.pending_resource_open = null;
            pending.request.cancel();
            self.allocator.free(pending.label);
        }
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
            .{ .reserve_scrollbar = true, .undo_store = try self.text_model_resolver.undoRedoStore() },
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
                }
            }
            if (self.findOpenInput(change.resource)) |input| {
                if (input.editor.isDirty()) {
                    input.editor.markConflict();
                } else {
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

// One terminal editor tab: an `Editor`, its `View`, the `FileEditorInput`
// that represents it in the ported `EditorGroupModel`, and the editor
// contributions that live on that view.
//
// Controllers are created lazily when a tab is first activated. That keeps
// opening N files cheap and avoids constructing hover/suggest/find widgets for
// tabs that were never shown, while the view/widget instances stay stable for
// the lifetime of the tab (unlike re-creating them on every switch).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const editor_view = @import("../../../../editor/browser/widget/codeEditor/terminalEditorView.zig");
const View = editor_view.IEditorView;
const Cell = editor_view.Cell;
pub const EditorViewFactory = editor_view.EditorViewFactory;
const ModelDecorationSink = @import("../../../../editor/browser/widget/codeEditor/terminalModelDecorations.zig").ModelDecorationSink;
const editor_input_dispatch = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminalInput.zig");
const FileEditorInput = @import("../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const TextResourceEditorInput = @import("../../../common/editor/textResourceEditorInput.zig").TextResourceEditorInput;
pub const DiffView = @import("./textDiffEditor.zig").DiffView(View);
pub const MultiDiffPane = @import("../../../contrib/multiDiffEditor/browser/multiDiffEditor.zig").MultiDiffEditor(View);
pub const DiffWidget = @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig").DiffEditorWidget(View);
const FindController = @import("../../../../editor/contrib/find/browser/findController.zig").FindController;
const word_character_classifier = @import("../../../../editor/common/core/wordCharacterClassifier.zig");
const editorBrowser = @import("../../../../editor/browser/editorBrowser.zig");
const Position = @import("../../../../editor/common/core/position.zig").Position;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const Selection = @import("../../../../editor/common/core/selection.zig").Selection;
const editor_common = @import("../../../common/editor.zig");
const ViewEventHandler = @import("../../../../editor/common/viewEventHandler.zig").ViewEventHandler;
const view_events = @import("../../../../editor/common/viewEvents.zig");
const cursor_events = @import("../../../../editor/common/cursorEvents.zig");
const text_editor_selection = @import("./textEditor.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const theme_colors_mod = @import("../../themeColors.zig");
const languages = @import("../../../../editor/common/languages.zig");
const hoverTypes = @import("../../../../editor/contrib/hover/browser/hoverTypes.zig");
const ContentHoverController = @import("../../../../editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
const MarkdownHoverParticipant = @import("../../../../editor/contrib/hover/browser/markdownHoverParticipant.zig").MarkdownHoverParticipant;
const MarkerHoverParticipant = @import("../../../../editor/contrib/hover/browser/markerHoverParticipant.zig").MarkerHoverParticipant;
const WordHighlighterContribution = @import("../../../../editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
const SuggestController = @import("../../../../editor/contrib/suggest/browser/suggestController.zig").SuggestController;
const WordBasedCompletionProvider = @import("../../../../editor/contrib/suggest/browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;
const TuiHoverProvider = @import("../../../../editor/contrib/hover/browser/terminalHoverProvider.zig").TuiHoverProvider;
const completion = @import("../../../../editor/common/languages/completion.zig");
const LanguageFeaturesService = @import("../../../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const WebviewInput = @import("../../../contrib/webviewPanel/browser/webviewEditorInput.zig").WebviewInput;
const groups = @import("../../../services/editor/common/editorGroupsService.zig");
const topmost = @import("../../../contrib/markdown/browser/topmostLineMonitor.zig");
const MarkdownPreview = @import("../../../contrib/markdown/browser/markdownPreview.zig").MarkdownPreview;
const MarkdownPreviewConfig = @import("../../../contrib/markdown/browser/markdownPreviewConfig.zig").MarkdownPreviewConfig;
const StickyScrollHost = @import("../../../../editor/contrib/stickyScroll/browser/stickyScrollHost.zig").StickyScrollHost;
const StickyScrollController = @import("../../../../editor/contrib/stickyScroll/browser/stickyScrollController.zig").StickyScrollController;
const ImagePreviewPane = @import("../../../contrib/mediaPreview/browser/imagePreviewPane.zig").ImagePreviewPane;
const ImagePreviewEditorInput = @import("../../../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;

const SearchEditorInput = @import("../../../contrib/searchEditor/browser/searchEditorInput.zig").SearchEditorInput;
const TerminalEditorInput = @import("../../../contrib/terminal/browser/terminalEditorInput.zig").TerminalEditorInput;
const TerminalInstance = @import("../../../contrib/terminal/browser/terminalInstance.zig").TerminalInstance;
const terminal_editor = @import("../../../contrib/terminal/browser/terminalEditor.zig");

/// EditorMemento from editorPane.ts. The terminal keeps open pane controls
/// alive until close; shutdown captures their view state into a bounded
/// group/resource map. Session storage is an explicit host file rather than
/// the browser's workspace storage database.
pub const EditorMemento = struct {
    allocator: Allocator,
    entries: std.ArrayList(groups.SerializedEditorViewState) = .empty,
    const limit = 100;

    pub fn deinit(self: *EditorMemento) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Takes ownership of resource/state on success.
    pub fn saveEditorState(self: *EditorMemento, entry: groups.SerializedEditorViewState) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        var i: usize = 0;
        // Touch every state of the resource as one LRU key, preserving the
        // relative order of its other groups.
        var end = self.entries.items.len;
        while (i < end) {
            const old = self.entries.items[i];
            if (!std.mem.eql(u8, old.resource, entry.resource)) {
                i += 1;
                continue;
            }
            _ = self.entries.orderedRemove(i);
            end -= 1;
            if (old.group == entry.group) old.deinit(self.allocator) else self.entries.appendAssumeCapacity(old);
        }
        self.entries.appendAssumeCapacity(entry);
        // Upstream bounds the number of resource keys, not the number of
        // groups within a key. Dispose the oldest complete key when needed.
        var resources: usize = 0;
        for (self.entries.items, 0..) |candidate, index| {
            for (self.entries.items[0..index]) |previous| {
                if (std.mem.eql(u8, candidate.resource, previous.resource)) break;
            } else resources += 1;
        }
        if (resources > limit) {
            const oldest = self.entries.orderedRemove(0);
            defer oldest.deinit(self.allocator);
            i = 0;
            while (i < self.entries.items.len) {
                if (std.mem.eql(u8, oldest.resource, self.entries.items[i].resource)) self.entries.orderedRemove(i).deinit(self.allocator) else i += 1;
            }
        }
    }

    pub fn loadEditorState(entries: []const groups.SerializedEditorViewState, group: u32, resource: []const u8, shared: bool) ?[]const u8 {
        var fallback: ?[]const u8 = null;
        for (entries) |entry| {
            if (!std.mem.eql(u8, resource, entry.resource)) continue;
            if (entry.group == group) return entry.state;
            if (shared) fallback = entry.state;
        }
        return fallback;
    }
};

/// Restores the terminal view for an input already deserialized by its group.
/// The group owns the view from addTab onward. The model keeps its original
/// active, pinned, sticky and preview selections.
pub const RestoredEditorPanes = struct {
    view_factory: EditorViewFactory,
    io: Io,
    width: usize,
    height: usize,
    images: *ui.image.Runtime,
    history: *@import("../../../services/history/browser/historyService.zig").HistoryService,
    working_copies: *@import("../../../services/workingCopy/common/workingCopyService.zig").WorkingCopyService,
    diff_options: @import("textDiffEditor.zig").Options = .{},
    editor_view_states: []const groups.SerializedEditorViewState = &.{},
    share_view_state: bool = false,
    create_multi_diff: ?struct {
        context: *anyopaque,
        run: *const fn (*anyopaque, *@import("../../../contrib/multiDiffEditor/browser/multiDiffEditorInput.zig").MultiDiffEditorInput, usize, usize) anyerror!*Tab,
    } = null,
    on_restore: ?struct { context: *anyopaque, run: *const fn (*anyopaque, *Tab) anyerror!void } = null,

    pub fn createPane(self: RestoredEditorPanes, allocator: Allocator, input: *EditorInput) !?*Tab {
        if (std.mem.eql(u8, input.type_id, ImagePreviewEditorInput.ID)) {
            return try Tab.initImageFromInput(self.view_factory, allocator, self.io, @ptrCast(@alignCast(input.impl.?)), self.width, self.height, self.images, null);
        }
        if (@import("../../../common/editor/diffEditorInput.zig").is(input)) |diff_input| {
            const diff = try DiffView.createFromInput(self.view_factory, allocator, self.io, diff_input, self.width, self.height, self.diff_options);
            return try Tab.initDiff(allocator, diff);
        }
        if (@import("../../../contrib/multiDiffEditor/browser/multiDiffEditorInput.zig").MultiDiffEditorInput.is(input)) |multi| {
            const callback = self.create_multi_diff orelse return null;
            const tab = try callback.run(callback.context, multi, self.width, self.height);
            // The new pane retained the deserialized input.
            multi.destroy();
            return tab;
        }
        if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) return null;
        const tab = try Tab.initFromInput(self.view_factory, allocator, @ptrCast(@alignCast(input.impl.?)));
        tab.setImageRuntime(self.images);
        return tab;
    }

    pub fn didRestore(self: RestoredEditorPanes, tab: *Tab, group: u32) !void {
        try tab.view.setStatusBarVisible(false);
        if (self.on_restore) |callback| {
            try callback.run(callback.context, tab);
        } else {
            const widget = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
            for (0..tab.workingCopyCount()) |index| if (tab.workingCopyAt(index)) |editor| {
                self.working_copies.acquireWorkingCopy(widget.workingCopyInterface(editor)) catch |err| switch (err) {
                    error.AlreadyRegistered => {},
                    else => return err,
                };
            };
        }
        if (tab.diff) |diff| {
            const resource = try diff.viewStateResource(tab.allocator);
            defer tab.allocator.free(resource);
            if (EditorMemento.loadEditorState(self.editor_view_states, group, resource, self.share_view_state)) |state| try diff.restoreEditorViewState(state);
        }
        if (tab.multi_diff) |multi| {
            const resource = try multi.viewStateResource(tab.allocator);
            defer tab.allocator.free(resource);
            if (EditorMemento.loadEditorState(self.editor_view_states, group, resource, self.share_view_state)) |state| try multi.restoreEditorViewState(state);
        } else try self.history.add(tab.editor.path);
    }
};

pub const Tab = struct {
    allocator: Allocator,
    /// Modified/first editor. For a diff tab this is the modified pane.
    editor: *Editor,
    /// Modified/first view. For a diff tab this is the modified pane.
    view: *View,
    element: ?*ui.Node = null,
    /// File input for a normal tab; null for a diff tab.
    file_input: ?*FileEditorInput,
    text_resource_input: ?*TextResourceEditorInput = null,
    /// The group-model input (a `FileEditorInput` or a `DiffEditorInput`).
    input: *EditorInput,
    controllers: ?*Controllers = null,
    original_controllers: ?*Controllers = null,
    code_lens_services: ?CodeLensServices = null,
    code_action_services: ?CodeActionServices = null,
    hover_opener: ?MarkerHoverParticipantOpener = null,
    hover_menus: ?MarkerHoverMenuServices = null,
    marker_navigation_services: ?MarkerNavigationServices = null,
    diff: ?*DiffView = null,
    multi_diff: ?*MultiDiffPane = null,
    multi_diff_listener: ?usize = null,
    multi_diff_resources_listener: ?usize = null,
    multi_diff_documents_listener: ?usize = null,
    control_change_service: ?*groups.EditorGroupsService = null,
    markdown_preview: ?*MarkdownPreview = null,
    window: ?*@import("../../../../base/common/windowDispatch.zig").Queue = null,
    // Dynamic previews are singleton webview inputs. In-place previews keep
    // the file input so edits, dirty state and undo survive switching back.
    markdown_panel: ?struct {
        input: *WebviewInput,
        source: *FileEditorInput,
        source_group: u32,
    } = null,
    /// Image preview pane; also marks this as an image tab.
    image_preview: ?*ImagePreviewPane = null,
    image_input: ?*ImagePreviewEditorInput = null,
    terminal_input: ?*TerminalEditorInput = null,
    search_editor_input: ?*SearchEditorInput = null,
    image_runtime: ?*ui.image.Runtime = null,
    /// Io handed over by the workbench for async preview/image loads.
    async_io: ?Io = null,
    last_width: usize = 0,
    last_height: usize = 0,
    top_view_zone_rows: usize = 0,
    on_will_dispose: ?@import("../../../../base/common/event.zig").Emitter(void) = null,
    selection_listeners: ?*std.array_list.Managed(SelectionListener) = null,
    selection_handler: ViewEventHandler = .{},
    selection_handler_added: bool = false,

    pub fn init(factory: EditorViewFactory, allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize) !*Tab {
        return initWithDeclarative(factory, allocator, io, path, width, height, null);
    }

    pub fn initWithDeclarative(
        factory: EditorViewFactory,
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        declarative: ?*const @import("../../../services/extensions/common/extensionsRegistry.zig").Registry,
    ) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);

        const editor = try Editor.createWithDeclarativeOptions(allocator, io, path, width, height, declarative, .{ .reserve_scrollbar = true });
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }

        const view = try factory(allocator, editor);
        errdefer view.deinit();

        const input = try FileEditorInput.init(allocator, editor);
        errdefer input.deinit();

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .view = view,
            .file_input = input,
            .input = &input.base,
        };
        return self;
    }

    /// Builds a tab around an input that already owns its editor, used when a
    /// serialized group restores file inputs before the tab list is rebuilt.
    pub fn initFromInput(factory: EditorViewFactory, allocator: Allocator, input: *FileEditorInput) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);

        const view = try factory(allocator, input.editor);
        errdefer view.deinit();

        self.* = .{
            .allocator = allocator,
            .editor = input.editor,
            .view = view,
            .file_input = input,
            .input = &input.base,
        };
        return self;
    }

    /// Opens a virtual TextResourceEditorInput in its own code editor. The
    /// input's model remains shared with any comparison already displaying it.
    pub fn initResourceFromInput(factory: EditorViewFactory, allocator: Allocator, input: *TextResourceEditorInput, width: usize, height: usize) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);
        const editor = try Editor.createViewFromDocument(input.resolve(), width, height, .{ .reserve_scrollbar = true });
        errdefer {
            const editor_allocator = editor.allocator;
            editor.deinit();
            editor_allocator.destroy(editor);
        }
        editor.setReadOnly(true);
        const view = try factory(allocator, editor);
        errdefer view.deinit();
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .view = view,
            .file_input = null,
            .text_resource_input = input.retain(),
            .input = input.interface(),
        };
        return self;
    }

    pub fn initSearchEditor(factory: EditorViewFactory, allocator: Allocator, input: *SearchEditorInput) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);
        const view = try factory(allocator, input.editor);
        self.* = .{
            .allocator = allocator,
            .editor = input.editor,
            .view = view,
            .file_input = null,
            .input = &input.base,
            .search_editor_input = input,
        };
        return self;
    }

    /// Builds a read-only image preview tab. A text editor is still created
    /// with an empty model so the many workbench paths that read
    /// `tab.editor.path`/`view` keep working; it is read-only and never saved,
    /// and `paint`/`layoutCells` route to the image pane instead.
    pub fn initImage(
        factory: EditorViewFactory,
        allocator: Allocator,
        io: Io,
        path: []const u8,
        width: usize,
        height: usize,
        runtime: *ui.image.Runtime,
        window: ?*@import("../../../../base/common/windowDispatch.zig").Queue,
    ) !*Tab {
        const input = try ImagePreviewEditorInput.init(allocator, path);
        errdefer input.deinit();
        return initImageFromInput(factory, allocator, io, input, width, height, runtime, window);
    }

    pub fn initImageFromInput(
        factory: EditorViewFactory,
        allocator: Allocator,
        io: Io,
        image_input: *ImagePreviewEditorInput,
        width: usize,
        height: usize,
        runtime: *ui.image.Runtime,
        window: ?*@import("../../../../base/common/windowDispatch.zig").Queue,
    ) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);

        const editor = try Editor.createFromText(allocator, io, "", image_input.path, width, height);
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }
        editor.setReadOnly(true);

        const view = try factory(allocator, editor);
        errdefer view.deinit();

        const pane = if (window) |events|
            try ImagePreviewPane.initAsync(allocator, io, events, runtime, image_input.path)
        else
            try ImagePreviewPane.init(allocator, io, runtime, image_input.path);
        errdefer pane.deinit();

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .view = view,
            .file_input = null,
            .image_input = image_input,
            .image_preview = pane,
            .image_runtime = runtime,
            .input = &image_input.base,
        };
        return self;
    }

    /// The shell owns rendering and input. The editor shell carries a
    /// read-only placeholder for workbench paths that still require Editor/View.
    pub fn initTerminal(factory: EditorViewFactory, allocator: Allocator, io: Io, instance: *TerminalInstance) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);
        const input = try TerminalEditorInput.init(allocator, instance);
        errdefer input.deinit();
        const editor = try Editor.createFromText(allocator, io, "", input.resource, 1, 1);
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }
        editor.setReadOnly(true);
        const view = try factory(allocator, editor);
        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .view = view,
            .file_input = null,
            .terminal_input = input,
            .input = input.interface(),
        };
        return self;
    }

    pub fn terminalInstance(self: *const Tab) ?*TerminalInstance {
        return if (self.terminal_input) |input| input.instance else null;
    }

    /// Builds a diff tab around an already created `DiffView`.
    pub fn initDiff(allocator: Allocator, diff: *DiffView) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editor = diff.widget.modified_editor,
            .view = diff.widget.modified_view,
            .file_input = null,
            .input = diff.input(),
            .diff = diff,
        };
        _ = try diff.widget.on_did_change_focused_side.listen(self, onDiffFocusedSideChanged);
        diff.on_control_changed = .{ .context = self, .run = onDiffControlChanged };
        return self;
    }

    /// Mounts a composite multi-file editor. The placeholder is only the
    /// stable legacy tab adapter; actual text controls belong to the visible
    /// item bindings and are resolved through activeDiffWidget.
    pub fn initMultiDiff(factory: EditorViewFactory, allocator: Allocator, io: Io, pane: *MultiDiffPane) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);
        const editor = try Editor.createFromText(allocator, io, "", "Multi Diff Editor", 1, 1);
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }
        editor.setReadOnly(true);
        const view = try factory(allocator, editor);
        errdefer view.deinit();
        self.* = .{ .allocator = allocator, .editor = editor, .view = view, .file_input = null, .input = pane.input.interface(), .multi_diff = pane };
        self.multi_diff_listener = try pane.changed.listen(self, onMultiDiffChanged);
        errdefer pane.changed.unlisten(self.multi_diff_listener.?);
        self.multi_diff_resources_listener = try pane.input.on_did_change_resources.listen(self, onMultiDiffResourcesChanged);
        errdefer pane.input.on_did_change_resources.unlisten(self.multi_diff_resources_listener.?);
        self.multi_diff_documents_listener = try pane.input.document_set.on_did_change_documents.listen(self, onMultiDiffChanged);
        return self;
    }

    fn onMultiDiffChanged(_: void, self: *Tab) !void {
        if (self.control_change_service) |service| try service.on_did_visible_editors_change.fire({});
    }

    fn onMultiDiffResourcesChanged(_: void, self: *Tab) !void {
        if (self.control_change_service) |service| try service.on_did_change_input_resources.fire(self.input);
    }

    fn detachMultiDiffListeners(self: *Tab, pane: *MultiDiffPane) void {
        if (self.multi_diff_listener) |id| pane.changed.unlisten(id);
        if (self.multi_diff_resources_listener) |id| pane.input.on_did_change_resources.unlisten(id);
        if (self.multi_diff_documents_listener) |id| pane.input.document_set.on_did_change_documents.unlisten(id);
        self.multi_diff_listener = null;
        self.multi_diff_resources_listener = null;
        self.multi_diff_documents_listener = null;
    }

    pub fn activeDiffWidget(self: *Tab) ?*DiffWidget {
        if (self.diff) |diff| return diff.widget;
        if (self.multi_diff) |multi| return multi.widget.activeControl();
        return null;
    }

    /// Creates the editor contributions on first activation. The tab must have
    /// been attached to a view before any key/mouse event is routed to it.
    pub fn attachWindow(self: *Tab, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.window = window;
        self.editor.attachWindow(window);
        if (self.controllers) |controllers| controllers.attachWindow(window);
        if (self.original_controllers) |controllers| controllers.attachWindow(window);
        if (self.diff) |diff| {
            diff.widget.original_editor.attachWindow(window);
            diff.widget.attachWindow(window);
        }
    }

    pub fn attachDiffActionServices(self: *Tab, clipboard: @import("../../../../platform/clipboard/common/clipboardService.zig").IClipboardService, menu: @import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService) void {
        if (self.diff) |diff| diff.widget.attachActionServices(clipboard, menu);
    }

    pub fn saveEditorViewState(self: *Tab, allocator: Allocator, group: u32) !?groups.SerializedEditorViewState {
        if (self.multi_diff) |multi| {
            const resource = try multi.viewStateResource(allocator);
            errdefer allocator.free(resource);
            return .{ .group = group, .resource = resource, .state = try multi.computeEditorViewState(allocator) };
        }
        const diff = self.diff orelse return null;
        const resource = try diff.viewStateResource(allocator);
        errdefer allocator.free(resource);
        return .{ .group = group, .resource = resource, .state = try diff.computeEditorViewState(allocator) };
    }

    fn codeLensColors(palette: ?*const theme_colors_mod.ThemeColors) @import("../../../../editor/contrib/codelens/browser/codelensWidget.zig").Colors {
        const colors = palette orelse return .{};
        return .{ .foreground = colors.color("editorCodeLens.foreground", .{ 130, 130, 130 }), .hover = colors.color("editorLink.activeForeground", .{ 82, 170, 255 }) };
    }

    pub fn attachCodeLensServices(self: *Tab, features: *LanguageFeaturesService, cache: *@import("../../../../editor/contrib/codelens/browser/codeLensCache.zig").CodeLensCache, commands: @import("../../../../editor/contrib/codelens/browser/codelensWidget.zig").CommandHost, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        if (self.image_preview != null or self.terminal_input != null or self.markdown_panel != null or self.multi_diff != null) return;
        const services: CodeLensServices = .{ .features = features, .cache = cache, .commands = commands, .window = window };
        self.code_lens_services = services;
        self.ensureControllers() catch return;
        if (self.controllers) |controllers| controllers.attachCodeLensServices(services) catch {};
        if (self.original_controllers) |controllers| controllers.attachCodeLensServices(services) catch {};
    }

    pub fn attachCodeActionServices(self: *Tab, services: CodeActionServices) void {
        if (self.image_preview != null or self.terminal_input != null or self.markdown_panel != null or self.multi_diff != null) return;
        self.code_action_services = services;
        self.ensureControllers() catch return;
        if (self.controllers) |controllers| controllers.attachCodeActionServices(services) catch {};
        if (self.original_controllers) |controllers| controllers.attachCodeActionServices(services) catch {};
    }

    pub fn attachHoverServices(self: *Tab, opener: MarkerHoverParticipantOpener, menus: MarkerHoverMenuServices) void {
        self.hover_opener = opener;
        self.hover_menus = menus;
        if (self.controllers) |controllers| controllers.attachHoverServices(opener, menus);
        if (self.original_controllers) |controllers| controllers.attachHoverServices(opener, menus);
    }

    pub fn attachMarkerNavigationServices(self: *Tab, services: MarkerNavigationServices) void {
        if (self.image_preview != null or self.terminal_input != null or self.markdown_panel != null or self.multi_diff != null) return;
        self.marker_navigation_services = services;
        self.ensureControllers() catch return;
        if (self.controllers) |controllers| controllers.attachMarkerNavigationServices(services) catch {};
        if (self.original_controllers) |controllers| controllers.attachMarkerNavigationServices(services) catch {};
    }

    pub fn detachCodeLensServices(self: *Tab) void {
        if (self.controllers) |controllers| controllers.detachCodeLensServices();
        if (self.original_controllers) |controllers| controllers.detachCodeLensServices();
        self.code_lens_services = null;
    }

    pub fn attachDiffBreadcrumbs(self: *Tab, features: *LanguageFeaturesService, models: *@import("../../../../editor/contrib/documentSymbols/browser/outlineModel.zig").OutlineModelService) void {
        const diff = self.diff orelse return;
        if (diff.widget.breadcrumbs_factory != null) return;
        const factory = @import("../../../../editor/contrib/diffEditorBreadcrumbs/browser/contribution.zig").Factory.create(self.allocator, features.interface(), models) catch return;
        diff.widget.attachBreadcrumbs(factory) catch {};
    }

    pub fn detachDiffBreadcrumbs(self: *Tab) void {
        if (self.diff) |diff| diff.widget.detachBreadcrumbs();
    }

    pub fn attachDiffGutterServices(self: *Tab, menus: *@import("../../../../platform/actions/common/menuService.zig").MenuService, context: @import("../../../../platform/contextkey/common/contextkey.zig").IContext, menu: @import("../../../../platform/contextview/browser/contextMenuService.zig").IContextMenuService) void {
        if (self.diff) |diff| diff.widget.attachGutterServices(menus, context, menu) catch {};
    }

    /// Multi-diff templates may have subscribed to shared services after the
    /// pane was first mounted. Release them before window service teardown.
    pub fn detachMultiDiffControls(self: *Tab) void {
        const multi = self.multi_diff orelse return;
        self.detachMultiDiffListeners(multi);
        multi.input.detachSource();
        multi.detachServices();
        multi.widget.setViewModel(null, .{}) catch {};
    }

    pub fn detachDiffGutterServices(self: *Tab) void {
        if (self.diff) |diff| diff.widget.detachGutterServices();
    }

    pub fn ensureControllers(self: *Tab) !void {
        if (self.markdown_preview != null or self.image_preview != null or self.terminal_input != null or self.multi_diff != null) return;
        if (self.controllers == null) {
            self.controllers = try self.createControllers(self.editor, self.view);
        }
        if (self.diff) |diff| {
            if (self.original_controllers == null) self.original_controllers = try self.createControllers(diff.widget.original_editor, diff.widget.original_view);
        }
    }

    fn createControllers(self: *Tab, control: *Editor, view: *View) !*Controllers {
        const controllers = try Controllers.init(self.allocator, control, view);
        errdefer controllers.deinit();
        try controllers.attachWidgets();
        if (self.window) |window| controllers.attachWindow(window);
        if (self.code_lens_services) |services| try controllers.attachCodeLensServices(services);
        if (self.code_action_services) |services| try controllers.attachCodeActionServices(services);
        if (self.hover_opener) |opener| if (self.hover_menus) |menus| controllers.attachHoverServices(opener, menus);
        if (self.marker_navigation_services) |services| try controllers.attachMarkerNavigationServices(services);
        return controllers;
    }

    pub fn handleEditorKey(self: *Tab, event: *ui.KeyEvent, is_pasting: *bool, now_ms: i64, fallback: ?ui.KeyEvent) !bool {
        try self.ensureControllers();
        const controllers = self.controllers orelse return false;
        return editor_input_dispatch.handleKeyEvent(
            self.view.interface(),
            controllers.hover,
            controllers.word_highlighter,
            controllers.suggest,
            self.editor,
            event,
            is_pasting,
            now_ms,
            fallback,
        );
    }

    pub fn setThemeColors(self: *Tab, palette: ?*const @import("../../themeColors.zig").ThemeColors) void {
        if (self.multi_diff) |multi| {
            multi.setThemeColors(palette);
        } else if (self.diff) |diff| {
            diff.setThemeColors(palette);
        } else self.view.setThemeColors(palette);
        if (self.controllers) |controllers| controllers.setThemeColors(palette);
        if (self.original_controllers) |controllers| controllers.setThemeColors(palette);
    }

    pub fn refresh(self: *Tab) !void {
        if (self.markdown_preview != null) return;
        if (self.terminal_input != null) return;
        if (self.image_preview) |pane| {
            if (pane.dirty) return;
            pane.dirty = true;
            return;
        }
        if (self.multi_diff) |multi| {
            for (multi.widget.impl.manager.items) |managed| if (managed.binding()) |binding| if (binding.editor) |widget| {
                widget.original_view.invalidate();
                widget.modified_view.invalidate();
            };
            return;
        }
        if (self.diff) |diff| {
            diff.widget.original_view.invalidate();
            diff.widget.modified_view.invalidate();
            return;
        }
        try self.view.refresh();
    }

    /// A comparison only contributes the file-backed sides as working
    /// copies. Immutable virtual resources must never register as disk files.
    pub fn workingCopyCount(self: *const Tab) usize {
        if (self.multi_diff) |multi| return multi.input.entries.len * 2;
        return 2;
    }

    pub fn workingCopyAt(self: *Tab, index: usize) ?*Editor {
        if (self.multi_diff) |multi| {
            if (index / 2 >= multi.input.entries.len) return null;
            const entry = multi.input.entries[index / 2];
            const side = (if (index % 2 == 0) entry.original else entry.modified) orelse return null;
            return if (side.fileInput()) |input| input.editor else null;
        }
        if (self.diff) |diff| {
            const side = switch (index) {
                0 => diff.original_input,
                1 => diff.modified_input,
                else => return null,
            };
            const input = side.fileInput() orelse return null;
            return input.editor;
        }
        return if (index == 0 and self.file_input != null) self.editor else null;
    }

    pub fn isDiff(self: *const Tab) bool {
        return self.diff != null;
    }

    pub fn isMultiDiff(self: *const Tab) bool {
        return self.multi_diff != null;
    }

    pub fn isImage(self: *const Tab) bool {
        return self.image_preview != null;
    }

    pub fn setImageRuntime(self: *Tab, runtime: *ui.image.Runtime) void {
        self.image_runtime = runtime;
    }

    pub fn imagePreview(self: *Tab) ?*ImagePreviewPane {
        return self.image_preview;
    }

    pub fn setControlChangeService(self: *Tab, service: ?*groups.EditorGroupsService) void {
        self.control_change_service = service;
    }

    fn onDiffFocusedSideChanged(_: @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig").Side, self: *Tab) !void {
        if (self.control_change_service) |service| try service.on_did_visible_editors_change.fire({});
    }

    fn onDiffControlChanged(context: *anyopaque) void {
        const self: *Tab = @ptrCast(@alignCast(context));
        self.syncDiffViews();
    }

    /// Refreshes the cached modified editor/view after a `DiffView` replaced
    /// its widget (a `Refresh Diff` or a re-open of the same ref pair).
    pub fn syncDiffViews(self: *Tab) void {
        const diff = self.diff orelse return;
        const changed = self.editor != diff.widget.modified_editor;
        const had_controllers = self.controllers != null or self.original_controllers != null;
        if (changed) {
            if (self.editor == diff.widget.original_editor) {
                std.mem.swap(?*Controllers, &self.controllers, &self.original_controllers);
            } else {
                if (self.controllers) |controllers| controllers.deinit();
                if (self.original_controllers) |controllers| controllers.deinit();
                self.controllers = null;
                self.original_controllers = null;
            }
        }
        if (changed and self.selection_handler_added) self.editor.removeViewEventHandler(&self.selection_handler);
        self.editor = diff.widget.modified_editor;
        self.view = diff.widget.modified_view;
        if (changed and self.selection_handler_added) self.editor.addViewEventHandler(&self.selection_handler);
        if (self.window) |window| {
            self.editor.attachWindow(window);
            diff.widget.original_editor.attachWindow(window);
            diff.widget.attachWindow(window);
        }
        if (changed and had_controllers) self.ensureControllers() catch {};
        if (changed) if (self.control_change_service) |service| {
            service.on_did_change_input_resources.fire(self.input) catch {};
            service.on_did_visible_editors_change.fire({}) catch {};
        };
    }

    /// Mounts the visible editor instance inside its group. The terminal
    /// emulator and preview renderers also get a container for hit testing.
    pub fn mount(self: *Tab, surface: *ui.Surface, container: *ui.Node, x: usize, y: usize, w: usize, h: usize) !void {
        const doc = surface.document();
        const element = self.element orelse created: {
            const node = try doc.createElement(.div);
            errdefer doc.destroy(node);
            try node.addClass(@import("../../../../editor/browser/editorCss.zig").editor_group.Class.editor_instance);
            node.setStyle(.{ .position = .relative, .width = .{ .percent = 100 } });
            self.element = node;
            break :created node;
        };
        if (element.parent != container) {
            if (container.first_child) |old| _ = container.removeChild(old);
            _ = try container.appendChild(element);
        }
        if (self.terminal_input != null or self.isImage() or self.markdown_preview != null or self.multi_diff != null) return;
        if (self.last_width != w or self.last_height != h) self.layoutCells(w, h);
        if (self.diff) |diff| {
            try diff.widget.mount(surface, element, x, y);
        } else {
            try self.view.mountInto(surface, element, x, y, 0);
        }
    }

    /// Prepares shared editor elements and paints preview and terminal cells.
    pub fn paint(self: *Tab, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
        if (self.terminalInstance()) |instance| {
            try terminal_editor.paint(instance, &frame.next, .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(w), .h = @floatFromInt(h) });
            return;
        }
        const zone_rows = self.editorTopInset();
        if (zone_rows != self.top_view_zone_rows and self.last_width > 0 and self.last_height > 0) {
            self.layoutCells(self.last_width, self.last_height);
        }
        if (self.image_preview) |pane| {
            if (self.last_width != w or self.last_height != h) try self.layoutImage(w, h);
            try pane.paint(frame, x, y, w, h);
            return;
        }
        if (self.multi_diff) |multi| {
            try multi.paint(frame, x, y, w, h);
            return;
        }
        if (self.diff) |diff| {
            try diff.paint(frame, x, y, w, h);
            return;
        }
        if (self.last_width != w or self.last_height != h) self.layoutCells(w, h);
        if (self.markdown_preview) |preview| return preview.paint(frame, x, y, w, h);
        try self.view.paint();
    }

    /// The pointer shape under a pane-relative cell. The tab resolves the
    /// Markdown preview, the image pane and the diff
    /// widget; every surface answers from its own style tree.
    pub fn pointerAt(self: *Tab, x: usize, y: usize) !ui.Pointer {
        if (self.terminal_input != null) return .text;
        if (self.image_preview) |pane| {
            return (try pane.pointerAt(x, y)) orelse .default;
        }
        if (self.multi_diff) |multi| return multi.pointerAt(x, y);
        if (self.diff) |diff| return diff.widget.pointerAt(x, y);
        if (self.markdown_preview) |preview| return (try preview.pointerAt(x, y)) orelse .default;
        return self.view.pointerAt(x, y);
    }

    pub fn cursorCell(self: *Tab) ?Cell {
        if (self.terminalInstance()) |instance| {
            const cursor = terminal_editor.cursorCell(instance, .{ .w = @floatFromInt(self.last_width), .h = @floatFromInt(self.last_height) }) orelse return null;
            return .{ .row = cursor.row, .col = cursor.col };
        }
        if (self.image_preview != null or self.markdown_preview != null) return null;
        if (self.multi_diff) |multi| {
            const cell = multi.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col };
        }
        if (self.diff) |diff| {
            const cell = diff.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col };
        }
        return self.view.cursorCell();
    }

    pub fn focusEditor(self: *Tab) void {
        if (self.markdown_preview != null) return;
        if (self.terminal_input != null) return;
        if (self.image_preview) |pane| {
            pane.setFocused(true);
            return;
        }
        if (self.multi_diff) |multi| {
            multi.focus() catch {};
            return;
        }
        if (self.diff) |diff| {
            diff.focus();
            return;
        }
        self.view.focusEditor();
    }

    pub fn nextDiffChange(self: *Tab) bool {
        if (self.multi_diff) |multi| {
            multi.widget.goToNextChange() catch return false;
            return true;
        }
        const diff = self.diff orelse return false;
        return diff.nextChange();
    }

    pub fn previousDiffChange(self: *Tab) bool {
        if (self.multi_diff) |multi| {
            multi.widget.goToPreviousChange() catch return false;
            return true;
        }
        const diff = self.diff orelse return false;
        return diff.previousChange();
    }

    pub fn swapDiffSides(self: *Tab) void {
        if (self.diff) |diff| {
            diff.swapSides();
            self.syncDiffViews();
        }
    }

    pub fn handleDiffMouse(self: *Tab, event: *ui.MouseEvent) !bool {
        if (self.multi_diff) |multi| return multi.dispatchMouse(event);
        const diff = self.diff orelse return false;
        try self.ensureControllers();
        return diff.widget.dispatchMouseWith(event, .{ .context = self, .dispatch = dispatchDiffPaneMouse, .leave = leaveDiffPaneMouse });
    }

    fn dispatchDiffPaneMouse(context: *anyopaque, side: @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig").Side, view: *View, event: *ui.MouseEvent) !bool {
        const self: *Tab = @ptrCast(@alignCast(context));
        const controllers = (if (side == .original) self.original_controllers else self.controllers) orelse return view.dispatchMouse(event);
        if (event.kind == .move) {
            const other = if (side == .original) self.controllers else self.original_controllers;
            if (other) |inactive| inactive.hideHovers();
        }
        return editor_input_dispatch.handleMouseEvent(view, controllers.hover, controllers.suggest, controllers.editor, event);
    }

    fn leaveDiffPaneMouse(context: *anyopaque) void {
        const self: *Tab = @ptrCast(@alignCast(context));
        self.hideEditorHovers();
    }

    pub fn focusedControllers(self: *Tab) ?*Controllers {
        if (self.diff) |diff| if (diff.widget.focused == .original) return self.original_controllers;
        return self.controllers;
    }

    pub fn hideEditorHovers(self: *Tab) void {
        if (self.controllers) |controllers| controllers.hideHovers();
        if (self.original_controllers) |controllers| controllers.hideHovers();
        if (self.multi_diff) |multi| multi.widget.impl.leaveEditorHover();
    }

    pub fn cancelEditorPopups(self: *Tab) void {
        self.hideEditorHovers();
        if (self.controllers) |controllers| if (controllers.suggest) |suggest| suggest.cancel();
        if (self.original_controllers) |controllers| if (controllers.suggest) |suggest| suggest.cancel();
    }

    pub fn focusTabEdge(self: *Tab, direction: ui.dom.FocusDirection) void {
        if (self.multi_diff) |multi| {
            _ = multi.focusTabEdge(direction) catch false;
        } else if (self.diff) |diff| {
            diff.widget.focusTabEdge(direction);
        } else {
            self.focusEditor();
            self.view.focusTabEdge(direction);
        }
    }

    pub fn dispatchTabFocus(self: *Tab, event: *ui.KeyEvent, direction: ui.dom.FocusDirection) bool {
        if (self.multi_diff) |multi| return multi.dispatchTabFocus(event, direction) catch false;
        if (self.diff) |diff| return diff.widget.dispatchTabFocus(event, direction);
        return self.view.dispatchTabFocus(event, direction);
    }

    pub fn handleDiffKey(self: *Tab, event: *ui.KeyEvent) bool {
        if (self.multi_diff) |multi| return multi.dispatchKey(event) catch false;
        const diff = self.diff orelse return false;
        if (diff.widget.accessible_viewer.visible()) return diff.handleKey(event);
        if (diff.widget.handleDeletedSelectionKey(event)) return true;
        self.ensureControllers() catch return diff.handleKey(event);
        const controllers = (if (diff.widget.focused == .original) self.original_controllers else self.controllers) orelse return diff.handleKey(event);
        _ = editor_input_dispatch.handleKeyEvent(controllers.view.interface(), controllers.hover, controllers.word_highlighter, controllers.suggest, controllers.editor, event, &diff.widget.is_pasting, time_compat.milliTimestamp(), null) catch return false;
        diff.widget.syncScrollAfterInput();
        return true;
    }

    pub fn setEditorFocused(self: *Tab, focused: bool) void {
        if (self.multi_diff) |multi| {
            multi.setFocused(focused) catch {};
        } else if (self.diff) |diff| diff.widget.setEditorFocused(focused) else _ = self.view.setFocused(focused);
    }

    /// The tab's entry in the ported `EditorGroupModel`; the group view maps
    /// model editors to tab views through this accessor.
    pub fn interface(self: *Tab) editor_common.IVisibleEditorPane {
        return .{
            .context = self,
            .input = self.input,
            .id = if (self.multi_diff != null) @import("../../../contrib/multiDiffEditor/common/multiDiffEditor.zig").MULTI_DIFF_EDITOR_ID else self.input.editor_id orelse self.input.type_id,
            .multi_diff_file_list_host = if (self.multi_diff) |multi| .{
                .context = multi,
                .focus_file_list = struct {
                    fn focus(context: *anyopaque) !void {
                        const pane: *MultiDiffPane = @ptrCast(@alignCast(context));
                        try pane.focusFileList();
                    }
                }.focus,
                .restore_focus_file_list = struct {
                    fn focus(context: *anyopaque) void {
                        const pane: *MultiDiffPane = @ptrCast(@alignCast(context));
                        pane.focusFileList() catch {};
                    }
                }.focus,
            } else null,
            .get_control_fn = struct {
                fn get(context: *anyopaque) ?*anyopaque {
                    const tab: *Tab = @ptrCast(@alignCast(context));
                    if (tab.image_preview) |pane| return pane;
                    if (tab.markdown_preview) |pane| return pane;
                    if (tab.multi_diff) |multi| return multi.widget;
                    if (tab.diff) |diff| return diff.widget;
                    if (tab.terminalInstance()) |instance| return instance;
                    return tab.editor;
                }
            }.get,
        };
    }

    pub fn editorInput(self: *Tab) *EditorInput {
        return self.input;
    }

    /// Points the tab's registry-backed controllers at the workbench service.
    /// Called when language features are enabled after tabs already exist.
    pub fn attachLanguageRegistry(self: *Tab, features: *LanguageFeaturesService) void {
        if (self.controllers) |controllers| controllers.attachLanguageRegistry(features);
        if (self.original_controllers) |controllers| controllers.attachLanguageRegistry(features);
    }

    /// Lays the editor view out in the group pane. The height is the editor
    /// content height; the tab strip row is owned by the workbench.
    fn layoutImage(self: *Tab, width: usize, height: usize) !void {
        self.last_width = width;
        self.last_height = height;
        if (self.image_preview) |pane| try pane.layout(@max(width, 1), @max(height, 1));
    }

    /// getCodeEditor(activeEditorPane.getControl()) in the single-window
    /// terminal. A diff exposes its modified text control.
    pub fn codeEditorControl(self: *Tab) ?*Editor {
        if (self.isImage() or self.terminal_input != null or self.markdown_preview != null) return null;
        if (self.multi_diff) |multi| return if (multi.widget.activeControl()) |editor| editor.interface().getModifiedEditor() else null;
        if (self.diff) |diff| return diff.widget.interface().getModifiedEditor();
        return self.editor;
    }

    pub fn imageMetadataEvent(self: *Tab) ?*@import("../../../../base/common/event.zig").Emitter(void) {
        const pane = self.image_preview orelse return null;
        return &pane.editor.on_did_change_metadata;
    }

    pub fn imageStatusInfo(self: *Tab) ?@import("../../../contrib/mediaPreview/browser/mediaPreviewStatusBar.zig").Info {
        const pane = self.image_preview orelse return null;
        return pane.statusInfo();
    }

    pub fn handleImageKey(self: *Tab, event: *const ui.KeyEvent) @import("../../../contrib/mediaPreview/browser/imagePreviewPane.zig").Action {
        const pane = self.image_preview orelse return .none;
        return pane.handleKey(event);
    }

    pub fn handleImageMouse(
        self: *Tab,
        event: *const ui.MouseEvent,
        focus_gained: bool,
    ) @import("../../../contrib/mediaPreview/browser/imagePreviewPane.zig").Action {
        const pane = self.image_preview orelse return .none;
        return pane.handleMouse(event, focus_gained);
    }

    pub fn reloadImage(self: *Tab) void {
        if (self.image_preview) |pane| pane.reload();
    }

    pub fn invalidateImages(self: *Tab) void {
        if (self.image_preview) |pane| pane.invalidateImage();
        if (self.markdown_preview) |preview| preview.invalidateImages();
    }

    pub fn imageUsesPath(self: *Tab, path: []const u8) bool {
        const pane = self.image_preview orelse return false;
        return pane.usesPath(path);
    }

    pub fn imagePath(self: *const Tab) ?[]const u8 {
        return if (self.image_input) |input| input.path else null;
    }

    fn editorTopInset(self: *Tab) usize {
        if (self.diff != null or self.multi_diff != null) return 0;
        const query_rows = if (self.search_editor_input) |input| input.search_editor.headerRows() else 0;
        return query_rows;
    }

    pub fn layoutCells(self: *Tab, width: usize, height: usize) void {
        self.last_width = width;
        self.last_height = height;
        if (self.terminalInstance()) |instance| {
            terminal_editor.layout(instance, width, height);
            return;
        }
        if (self.image_preview) |pane| {
            pane.layout(@max(width, 1), @max(height, 1)) catch {};
            return;
        }
        if (self.multi_diff) |multi| {
            multi.layout(width, height);
            return;
        }
        if (self.diff) |diff| {
            diff.layout(@max(width, 1), @max(height, 1));
            return;
        }
        if (self.markdown_preview) |preview| {
            preview.resize(width, height) catch {};
            return;
        }
        const zone_rows = self.editorTopInset();
        self.top_view_zone_rows = zone_rows;
        self.editor.setViewport(@max(width, 1), @max(height, 1));
        self.editor.setTopInset(zone_rows);
        self.view.setTopInset(zone_rows);
        self.view.invalidate();
    }

    pub fn isMarkdown(self: *const Tab) bool {
        return self.file_input != null and isMarkdownLanguage(self.editor.languageId());
    }

    // extensions/markdown-language-features/src/util/file.ts
    pub fn isMarkdownLanguage(id: []const u8) bool {
        for ([_][]const u8{ "markdown", "prompt", "instructions", "chatagent", "skill" }) |language| {
            if (std.mem.eql(u8, id, language)) return true;
        }
        return false;
    }

    /// Port of DynamicMarkdownPreview.create in the Markdown extension. A
    /// WebviewInput gives the preview its own tab and normal group lifecycle.
    pub fn initMarkdownPanel(factory: EditorViewFactory, allocator: Allocator, source: *FileEditorInput, group: *groups.EditorGroup, config: MarkdownPreviewConfig, palette: ?*const theme_colors_mod.ThemeColors, runtime: *ui.image.Runtime, async_io: ?Io, window: *@import("../../../../base/common/windowDispatch.zig").Queue) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);
        const title = try std.fmt.allocPrint(allocator, "Preview {s}", .{source.base.getName()});
        defer allocator.free(title);
        const input = try WebviewInput.init(allocator, "markdown.preview", title);
        errdefer input.deinit();
        const editor = try Editor.createFromText(allocator, source.editor.io, "", input.resource, 1, 1);
        errdefer {
            editor.deinit();
            allocator.destroy(editor);
        }
        editor.setReadOnly(true);
        const view = try factory(allocator, editor);
        errdefer view.deinit();
        self.* = .{ .allocator = allocator, .editor = editor, .view = view, .file_input = null, .input = &input.base, .image_runtime = runtime, .async_io = async_io, .window = window };
        const preview = try self.createMarkdownPreview(source.editor, config, palette);
        errdefer preview.deinit();
        self.markdown_panel = .{ .input = input, .source = source.retain(), .source_group = group.id };
        self.markdown_preview = preview;
        return self;
    }

    fn createMarkdownPreview(self: *Tab, editor: *Editor, config: MarkdownPreviewConfig, palette: ?*const theme_colors_mod.ThemeColors) !*MarkdownPreview {
        const preview = try MarkdownPreview.init(self.allocator, editor, self.window);
        errdefer preview.deinit();
        preview.setImageRuntime(self.image_runtime);
        if (self.async_io) |io| preview.setAsyncIo(io);
        preview.setConfig(config);
        preview.setThemeColors(palette);
        try preview.resize(self.last_width, self.last_height);
        try preview.open(topmost.getVisibleLine(editor));
        return preview;
    }

    pub fn updateMarkdownPanel(self: *Tab, source: *FileEditorInput) !void {
        const panel = &self.markdown_panel.?;
        if (panel.source == source) return;
        const old = self.markdown_preview.?;
        const preview = try self.createMarkdownPreview(source.editor, old.options, old.theme);
        errdefer preview.deinit();
        const title = try std.fmt.allocPrint(self.allocator, "Preview {s}", .{source.base.getName()});
        defer self.allocator.free(title);
        try panel.input.setWebviewTitle(title);
        old.deinit();
        panel.source.deinit();
        panel.source = source.retain();
        self.markdown_preview = preview;
    }

    pub fn toggleMarkdownEditor(self: *Tab, config: MarkdownPreviewConfig, palette: ?*const theme_colors_mod.ThemeColors) !void {
        if (self.markdown_preview) |preview| {
            preview.deinit();
            self.markdown_preview = null;
        } else {
            self.markdown_preview = try self.createMarkdownPreview(self.editor, config, palette);
            self.view.detach();
        }
        self.layoutCells(self.last_width, self.last_height);
    }

    /// Stores the workbench's async Io so previews created later can read
    /// images off the TUI thread. Called by the workbench when it creates a tab.
    pub fn setAsyncIo(self: *Tab, io: Io) void {
        self.async_io = io;
        if (self.markdown_preview) |preview| preview.setAsyncIo(io);
    }

    pub fn setMarkdownPreviewConfig(self: *Tab, config: MarkdownPreviewConfig) void {
        if (self.markdown_preview) |preview| preview.setConfig(config);
    }

    pub fn refreshMarkdownPreview(self: *Tab, force: bool) void {
        if (self.markdown_preview) |preview| preview.refresh(force);
    }

    pub const SelectionListener = struct {
        context: *anyopaque,
        callback: *const fn (context: *anyopaque, reason: editor_common.EditorPaneSelectionChangeReason) void,
    };

    fn onSelectionEvent(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *Tab = @ptrCast(@alignCast(context));
        const reason: editor_common.EditorPaneSelectionChangeReason = switch (event.source) {
            .PROGRAMMATIC => .PROGRAMMATIC,
            .NAVIGATION => .NAVIGATION,
            .JUMP => .JUMP,
            .USER => .USER,
        };
        if (self.selection_listeners) |listeners| {
            for (listeners.items) |listener| listener.callback(listener.context, reason);
        }
        return false;
    }

    pub fn getSelection(self: *Tab, allocator: Allocator) !?editor_common.IEditorPaneSelection {
        if (self.isImage()) return null;
        const selections = try self.editor.getSelections();
        defer self.editor.allocator.free(selections);
        if (selections.len == 0) return null;
        const snapshot = try text_editor_selection.TextEditorPaneSelection.create(allocator, selections[0]);
        return snapshot.interface();
    }

    pub fn addSelectionListener(self: *Tab, listener: SelectionListener) !void {
        if (self.selection_listeners == null) {
            const listeners = try self.allocator.create(std.array_list.Managed(SelectionListener));
            listeners.* = std.array_list.Managed(SelectionListener).init(self.allocator);
            self.selection_listeners = listeners;
        }
        try self.selection_listeners.?.append(listener);
        if (!self.selection_handler_added) {
            self.selection_handler = ViewEventHandler.init(self, .{ .onCursorStateChanged = onSelectionEvent });
            self.editor.addViewEventHandler(&self.selection_handler);
            self.selection_handler_added = true;
        }
    }

    pub fn removeSelectionListener(self: *Tab, listener: SelectionListener) void {
        if (self.selection_listeners) |listeners| {
            for (listeners.items, 0..) |item, index| {
                if (item.context == listener.context and item.callback == listener.callback) {
                    _ = listeners.orderedRemove(index);
                    break;
                }
            }
        }
        if (self.selection_handler_added and (self.selection_listeners == null or self.selection_listeners.?.items.len == 0)) {
            self.editor.removeViewEventHandler(&self.selection_handler);
            self.selection_handler_added = false;
        }
    }

    pub fn listenWillDispose(self: *Tab, ctx: anytype, callback: fn (void, @TypeOf(ctx)) anyerror!void) !usize {
        if (self.on_will_dispose == null) self.on_will_dispose = .init(self.allocator);
        return self.on_will_dispose.?.listen(ctx, callback);
    }
    pub fn unlistenWillDispose(self: *Tab, id: usize) void {
        if (self.on_will_dispose) |*event| event.unlisten(id);
    }

    pub fn deinit(self: *Tab) void {
        self.detachCodeLensServices();
        // Disposable.onWillDispose: detach consumers while the code editor's
        // event handlers and its model still exist.
        if (self.on_will_dispose) |*event| {
            event.fire({}) catch {};
            event.deinit();
            self.on_will_dispose = null;
        }
        const instance_element = self.element;
        defer if (instance_element) |element| element.document.destroy(element);
        if (self.selection_handler_added) {
            self.editor.removeViewEventHandler(&self.selection_handler);
            self.selection_handler_added = false;
        }
        if (self.selection_listeners) |listeners| {
            listeners.deinit();
            self.allocator.destroy(listeners);
            self.selection_listeners = null;
        }
        if (self.image_preview) |pane| {
            pane.deinit();
            self.image_preview = null;
        }
        if (self.markdown_preview) |preview| {
            preview.deinit();
            self.markdown_preview = null;
        }
        if (self.controllers) |controllers| {
            controllers.deinit();
            self.controllers = null;
        }
        if (self.original_controllers) |controllers| {
            controllers.deinit();
            self.original_controllers = null;
        }
        if (self.diff) |diff| {
            self.diff = null;
            diff.destroy();
            self.allocator.destroy(self);
            return;
        }
        self.view.deinit();
        if (self.multi_diff) |multi| {
            self.detachMultiDiffListeners(multi);
            multi.destroy();
            self.editor.deinit();
            self.allocator.destroy(self.editor);
        } else if (self.image_input) |input| {
            self.editor.deinit();
            self.allocator.destroy(self.editor);
            input.deinit();
        } else if (self.markdown_panel) |panel| {
            panel.input.deinit();
            panel.source.deinit();
            self.editor.deinit();
            self.allocator.destroy(self.editor);
        } else if (self.terminal_input) |input| {
            self.editor.deinit();
            self.allocator.destroy(self.editor);
            input.deinit();
        } else if (self.file_input) |input| {
            input.deinit();
        } else if (self.text_resource_input) |input| {
            const allocator = self.editor.allocator;
            self.editor.deinit();
            allocator.destroy(self.editor);
            input.destroy();
        } else if (self.search_editor_input) |input| {
            input.deinit();
        }
        self.allocator.destroy(self);
    }
};

fn requestViewRender(context: ?*anyopaque) void {
    const view: *View = @ptrCast(@alignCast(context orelse return));
    view.invalidate();
}

fn SuggestControllerHostForView(view: *View) @import("../../../../editor/contrib/suggest/browser/suggestController.zig").SuggestControllerHost {
    return .{
        .context = view,
        .text_height = viewTextHeight,
        .visible_row_of = viewVisibleRowOf,
        .request_frame = viewRequestFrame,
        .focus_editor = viewFocusEditor,
        .has_editor_focus = viewHasEditorFocus,
    };
}

const CodeActionController = @import("../../../../editor/contrib/codeAction/browser/codeActionController.zig").CodeActionController;
const CodeActionServices = @import("../../../../editor/contrib/codeAction/browser/codeActionController.zig").Services;
const MarkerHoverParticipantOpener = @import("../../../../editor/contrib/hover/browser/markerHoverParticipant.zig").Opener;
const MarkerHoverMenuServices = @import("../../../../editor/contrib/hover/browser/markerHoverParticipant.zig").MenuServices;
const MarkerController = @import("../../../../editor/contrib/gotoError/browser/gotoError.zig").MarkerController;
const MarkerNavigationServices = @import("../../../../editor/contrib/gotoError/browser/gotoError.zig").Services;
const CodeLensContribution = @import("../../../../editor/contrib/codelens/browser/codelensController.zig").CodeLensContribution;
const CodeLensServices = struct {
    features: *LanguageFeaturesService,
    cache: *@import("../../../../editor/contrib/codelens/browser/codeLensCache.zig").CodeLensCache,
    commands: @import("../../../../editor/contrib/codelens/browser/codelensWidget.zig").CommandHost,
    window: *@import("../../../../base/common/windowDispatch.zig").Queue,
};

/// The per-tab editor contributions. Mirrors the construction order in the
/// single-editor app so the find/hover/word/suggest behavior is identical.
pub const Controllers = struct {
    allocator: Allocator,
    editor: *Editor,
    search_highlight_sink: ModelDecorationSink,
    hover_sink: ModelDecorationSink,
    word_sink: ModelDecorationSink,

    find: *FindController,
    view: *View,
    sticky_host: StickyScrollHost,
    sticky: ?*StickyScrollController,
    hover_provider: TuiHoverProvider,
    hover_providers: [1]languages.HoverProvider,
    hover_participant: MarkdownHoverParticipant,
    marker_hover_participant: MarkerHoverParticipant,
    participants: [2]hoverTypes.IEditorHoverParticipant,
    hover: ?*ContentHoverController,
    glyph_hover: ?*@import("../../../../editor/contrib/hover/browser/glyphHoverController.zig").GlyphHoverController,
    word_highlighter: *WordHighlighterContribution,
    word_provider: WordBasedCompletionProvider,
    completion_providers: [2]completion.CompletionItemProvider,
    completion_count: usize = 1,
    hover_registration: ?IDisposable = null,
    suggest: ?*SuggestController,
    code_lens: ?*CodeLensContribution,
    code_lens_services: ?CodeLensServices,
    code_action: ?*CodeActionController,
    code_action_services: ?CodeActionServices,
    hover_opener: ?MarkerHoverParticipantOpener,
    hover_menus: ?MarkerHoverMenuServices,
    marker_navigation_services: ?MarkerNavigationServices,
    marker_navigation: ?*MarkerController,
    language_features: ?*LanguageFeaturesService,
    window: ?*@import("../../../../base/common/windowDispatch.zig").Queue,
    widgets_attached: bool = false,

    /// Applies the palette-derived hover code-block background and the find
    /// bar theme. Upstream resolves these through CSS variables and the
    /// workbench theme service; the terminal layer passes the resolved cells.
    pub fn hideHovers(self: *Controllers) void {
        if (self.hover) |hover| hover.hideContentHover();
        if (self.glyph_hover) |glyph| glyph.hideGlyphHover();
    }

    pub fn setThemeColors(self: *Controllers, palette: ?*const theme_colors_mod.ThemeColors) void {
        var code_background: ?ui.Color = null;
        if (palette) |colors| {
            if (colors.rawColor("textCodeBlock.background")) |raw| {
                code_background = colors.compositeColor(raw);
            }
            var selection_background: ?ui.Color = null;
            var selection_foreground: ?ui.Color = null;
            if (colors.rawColor("editor.selectionBackground")) |raw| {
                selection_background = colors.compositeColor(raw);
            }
            if (colors.rawColor("editor.selectionForeground")) |raw| {
                selection_foreground = colors.compositeColor(raw);
            }
            const suggest_theme: @import("../../../../editor/contrib/suggest/browser/suggestWidget.zig").Theme = .{
                .background = colors.color("editorSuggestWidget.background", .{ 30, 31, 38 }),
                .foreground = colors.color("editorSuggestWidget.foreground", .{ 220, 220, 220 }),
                .dim_foreground = colors.color("editorSuggestWidget.highlightForeground", .{ 140, 142, 150 }),
                .selected_background = colors.color("editorSuggestWidget.selectedBackground", .{ 58, 62, 82 }),
                .selected_foreground = colors.color("editorSuggestWidget.selectedForeground", .{ 255, 255, 255 }),
                .scrollbar_foreground = colors.color("scrollbarSlider.background", .{ 160, 160, 170 }),
            };
            self.find.setTheme(.{
                .background = colors.color("editorWidget.background", .{ 45, 45, 55 }),
                .foreground = colors.color("editorWidget.foreground", .{ 230, 230, 230 }),
                .dim_foreground = colors.color("input.placeholderForeground", .{ 140, 140, 150 }),
                .hover_background = colors.color("toolbar.hoverBackground", .{ 72, 72, 92 }),
                .sash_hover_border = colors.sashHoverBorder(),
                .input_background = colors.color("input.background", .{ 30, 30, 35 }),
                .input_foreground = colors.color("input.foreground", .{ 230, 230, 230 }),
                .placeholder = colors.color("input.placeholderForeground", .{ 140, 140, 150 }),
                .active_background = colors.color("inputOption.activeBackground", .{ 230, 230, 230 }),
                .active_foreground = colors.color("inputOption.activeForeground", .{ 45, 45, 55 }),
                .selection_background = selection_background,
                .selection_foreground = selection_foreground,
            });
            if (self.suggest) |suggest| suggest.setTheme(suggest_theme);
            const hover_theme = theme_colors_mod.ThemeColors.hoverTheme(palette);
            if (self.hover) |hover| hover.setTheme(hover_theme);
            if (self.glyph_hover) |glyph| glyph.setTheme(hover_theme, code_background);
        } else {
            if (self.hover) |hover| hover.setTheme(.{});
            if (self.glyph_hover) |glyph| glyph.setTheme(.{}, null);
            self.find.setTheme(.{});
        }
        if (self.hover != null) self.hover_participant.setCodeBackground(code_background);
        if (self.code_lens) |lens| lens.setColors(Tab.codeLensColors(palette));
        if (self.marker_navigation) |controller| if (controller.widget) |widget| widget.applyTheme();
    }

    pub fn init(allocator: Allocator, editor: *Editor, view: *View) !*Controllers {
        const self = try allocator.create(Controllers);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.editor = editor;
        self.sticky = null;
        self.hover = null;
        self.glyph_hover = null;
        self.suggest = null;
        self.code_lens = null;
        self.code_lens_services = null;
        self.code_action = null;
        self.code_action_services = null;
        self.hover_opener = null;
        self.hover_menus = null;
        self.marker_navigation_services = null;
        self.marker_navigation = null;
        self.language_features = editor.language_features;
        self.window = null;
        self.hover_registration = null;
        self.widgets_attached = false;

        self.search_highlight_sink = ModelDecorationSink.incrementalSearch(editor.model);
        editor.setSearchHighlightSink(.{
            .context = self.search_highlight_sink.context(),
            .set = ModelDecorationSink.set,
        });
        errdefer editor.setSearchHighlightSink(null);
        self.find = try FindController.getOrCreate(editor);
        self.find.widget().layout_context = view;
        self.find.widget().on_layout = requestViewRender;
        errdefer {
            self.find.widget().layout_context = null;
            self.find.widget().on_layout = null;
        }
        editor.setFindController(self.find, FindController.startFromContext);
        errdefer editor.setFindController(null, null);

        self.view = view;
        self.sticky_host = view.stickyScrollHost();
        self.hover_sink = .{ .model = editor.model, .owner = 4 };
        self.word_sink = .{ .model = editor.model, .owner = 3 };

        self.word_highlighter = try WordHighlighterContribution.getOrCreate(editor, .{
            .context = view,
            .decoration_context = self.word_sink.context(),
            .has_text_focus = viewHasWordTextFocus,
            .set_decorations = ModelDecorationSink.set,
            .request_frame = viewRequestFrame,
        }, wordHighlightSettings(view));
        errdefer self.word_highlighter.unbindHost();

        errdefer self.detachDeferredContributions();
        if (editor.getInstantiatedContribution(StickyScrollController) != null) {
            try createSticky(self);
        } else try @import("../../../../editor/contrib/stickyScroll/browser/stickyScrollContribution.zig").register(editor, self, createSticky);
        if (editor.getInstantiatedContribution(ContentHoverController) != null) {
            try createHover(self);
        } else try @import("../../../../editor/contrib/hover/browser/hoverContribution.zig").register(editor, self, createHover);
        const GlyphHoverController = @import("../../../../editor/contrib/hover/browser/glyphHoverController.zig").GlyphHoverController;
        if (editor.getInstantiatedContribution(GlyphHoverController) != null) {
            try createGlyphHover(self);
        } else try @import("../../../../editor/contrib/hover/browser/hoverContribution.zig").registerGlyph(editor, self, createGlyphHover);
        if (editor.getInstantiatedContribution(SuggestController) != null) {
            try createSuggest(self);
        } else try SuggestController.registerFactory(editor, self, createSuggest);

        self.setThemeColors(view.themeColors());
        self.find.applyConfiguration(view.terminal_view_host.options.get(.find));
        self.find.widget().attachViewZones(editor, view.terminal_view_host, view.viewZones());
        errdefer self.find.widget().detachViewZones();
        try view.addConfigurationListener(.{ .context = self, .notify = onConfigurationChanged });
        errdefer view.removeConfigurationListener(.{ .context = self, .notify = onConfigurationChanged });
        return self;
    }

    fn createSticky(context: *anyopaque) !void {
        const self: *Controllers = @ptrCast(@alignCast(context));
        if (self.sticky != null) return;
        const sticky = try StickyScrollController.getOrCreate(self.editor, self.sticky_host.interface());
        errdefer sticky.unbindHost();
        self.sticky_host.attach(sticky);
        if (self.window) |window| sticky.attachWindow(window);
        if (self.widgets_attached) try self.view.addOverlayWidget(sticky.widget.interface());
        self.sticky = sticky;
    }

    fn createHover(context: *anyopaque) !void {
        const self: *Controllers = @ptrCast(@alignCast(context));
        if (self.hover != null) return;
        const allocator = self.allocator;
        const editor = self.editor;
        const view = self.view;

        self.hover_provider = TuiHoverProvider.init(allocator);
        self.hover_provider.json_document = &editor.document.json;
        self.hover_provider.setModel(editor.model);
        errdefer self.hover_provider.deinit();
        self.hover_providers = .{self.hover_provider.interface()};

        const features = self.language_features;
        if (features) |service| {
            self.hover_registration = service.hover_provider.register(.{ .language = "*" }, self.hover_provider.interface()) catch null;
        }
        errdefer {
            if (self.hover_registration) |registration| registration.dispose();
            self.hover_registration = null;
        }
        self.hover_participant = if (features) |service|
            MarkdownHoverParticipant.initWithRegistry(allocator, editor.model, &self.hover_providers, &service.hover_provider)
        else
            MarkdownHoverParticipant.init(allocator, editor.model, &self.hover_providers);
        errdefer self.hover_participant.deinit();
        self.marker_hover_participant = MarkerHoverParticipant.init(
            allocator,
            editor.model,
            editor.marker_decorations,
        );
        self.marker_hover_participant.opener = self.hover_opener;
        self.marker_hover_participant.menus = self.hover_menus;
        if (self.code_action_services) |services| self.marker_hover_participant.code_actions = .{ .editor = self.editor, .registry = services.registry, .window = services.window };
        errdefer self.marker_hover_participant.deinit();
        self.participants = .{
            self.marker_hover_participant.interface(),
            self.hover_participant.interface(),
        };

        const settings = hoverSettings(view);
        self.hover_participant.show_long_line_warning = settings.show_long_line_warning;
        const hover = try ContentHoverController.getOrCreate(editor, &self.participants, settings, .{
            .context = view,
            .decoration_context = self.hover_sink.context(),
            .text_height = viewTextHeight,
            .visible_row_of = viewVisibleRowOf,
            .request_frame = viewRequestFrame,
            .focus_editor = viewFocusEditor,
            .set_hover_decoration = setHoverModelDecoration,
            .coordinates = .{
                .context = view,
                .model_column_at_view_line_start = viewModelColumnAtViewLineStart,
            },
        });
        errdefer hover.unbindModel();
        if (self.window) |window| hover.attachWindow(window);
        if (self.widgets_attached) try view.addContentWidget(hover.widget().contentWidget());
        self.hover = hover;
        self.setThemeColors(view.themeColors());
    }

    fn createGlyphHover(context: *anyopaque) !void {
        const self: *Controllers = @ptrCast(@alignCast(context));
        if (self.glyph_hover != null) return;
        const GlyphHoverController = @import("../../../../editor/contrib/hover/browser/glyphHoverController.zig").GlyphHoverController;
        const glyph = try GlyphHoverController.getOrCreate(self.editor, self.view, hoverSettings(self.view));
        if (self.window) |window| glyph.attachWindow(window);
        self.glyph_hover = glyph;
        self.setThemeColors(self.view.themeColors());
    }

    fn createSuggest(context: *anyopaque) !void {
        const self: *Controllers = @ptrCast(@alignCast(context));
        if (self.suggest != null) return;
        const editor = self.editor;
        const view = self.view;
        const features = self.language_features;

        self.word_provider = WordBasedCompletionProvider.init();
        self.completion_providers[0] = self.word_provider.interface();
        self.completion_count = 1;
        if (editor.document.json.client != null) {
            self.completion_providers[1] = .{
                .context = editor,
                .provide_completion_items = Editor.jsonProvideCompletion,
                .provide_completion_items_deferred = if (editor.document.json.client.?.hasWindow()) Editor.jsonProvideCompletionDeferred else null,
                .trigger_characters = &.{ "\"", ":" },
            };
            self.completion_count = 2;
        }

        const suggest_host = SuggestControllerHostForView(view);
        const suggest = try SuggestController.getOrCreate(editor, if (features != null) &.{} else self.completion_providers[0..self.completion_count], suggest_host, if (features) |service| &service.completion_provider else null);
        errdefer suggest.unbindHost();
        if (self.window) |window| suggest.attachWindow(window);
        if (self.widgets_attached) try view.addContentWidget(suggest.widgetInterface());
        self.suggest = suggest;
        self.setThemeColors(view.themeColors());
    }

    pub fn attachCodeActionServices(self: *Controllers, services: CodeActionServices) !void {
        if (self.code_action_services != null) return;
        self.code_action_services = services;
        errdefer self.code_action_services = null;
        if (self.editor.getInstantiatedContribution(CodeActionController) != null) {
            try createCodeAction(self);
        } else try CodeActionController.registerFactory(self.editor, self, createCodeAction);
        if (self.hover != null) self.marker_hover_participant.code_actions = .{ .editor = self.editor, .registry = services.registry, .window = services.window };
    }

    pub fn attachHoverServices(self: *Controllers, opener: MarkerHoverParticipantOpener, menus: MarkerHoverMenuServices) void {
        self.hover_opener = opener;
        self.hover_menus = menus;
        if (self.hover != null) {
            self.marker_hover_participant.opener = opener;
            self.marker_hover_participant.menus = menus;
        }
    }

    pub fn attachMarkerNavigationServices(self: *Controllers, services: MarkerNavigationServices) !void {
        if (self.marker_navigation_services != null) return;
        self.marker_navigation_services = services;
        errdefer self.marker_navigation_services = null;
        if (self.editor.getInstantiatedContribution(MarkerController) != null) {
            try createMarkerNavigation(self);
        } else try MarkerController.registerFactory(self.editor, self, createMarkerNavigation);
    }

    fn createMarkerNavigation(context: *anyopaque) !void {
        const self: *Controllers = @ptrCast(@alignCast(context));
        if (self.marker_navigation != null) return;
        const services = self.marker_navigation_services orelse return error.MarkerNavigationUnavailable;
        self.marker_navigation = try MarkerController.getOrCreate(self.editor, self.view, services);
    }

    fn detachMarkerNavigationServices(self: *Controllers) void {
        self.editor.unregisterContributionFactory(MarkerController, self);
        if (self.marker_navigation) |controller| controller.unbind();
        self.marker_navigation = null;
        self.marker_navigation_services = null;
    }

    fn createCodeAction(context: *anyopaque) !void {
        const self: *Controllers = @ptrCast(@alignCast(context));
        if (self.code_action != null) return;
        const services = self.code_action_services orelse return error.CodeActionServicesUnavailable;
        self.code_action = try CodeActionController.getOrCreate(self.editor, self.view, services);
    }

    pub fn detachCodeActionServices(self: *Controllers) void {
        if (self.hover) |hover| {
            hover.hideContentHover();
            self.marker_hover_participant.code_actions = null;
        }
        self.editor.unregisterContributionFactory(CodeActionController, self);
        if (self.code_action) |controller| controller.unbind();
        self.code_action = null;
        self.code_action_services = null;
    }

    pub fn attachCodeLensServices(self: *Controllers, services: CodeLensServices) !void {
        if (self.code_lens_services != null) return;
        self.code_lens_services = services;
        errdefer self.code_lens_services = null;
        if (self.editor.getInstantiatedContribution(CodeLensContribution) != null) {
            try createCodeLens(self);
        } else try CodeLensContribution.registerFactory(self.editor, self, createCodeLens);
    }

    fn createCodeLens(context: *anyopaque) !void {
        const self: *Controllers = @ptrCast(@alignCast(context));
        if (self.code_lens != null) return;
        const services = self.code_lens_services orelse return error.CodeLensServicesUnavailable;
        const view = self.view;
        const lens = try CodeLensContribution.getOrCreate(self.editor, view.terminal_view_host, view.viewZones(), services.features.interface(), services.cache, services.commands, services.window);
        lens.setColors(Tab.codeLensColors(view.themeColors()));
        self.code_lens = lens;
    }

    pub fn detachCodeLensServices(self: *Controllers) void {
        self.editor.unregisterContributionFactory(CodeLensContribution, self);
        if (self.code_lens) |lens| lens.unbindView();
        self.code_lens = null;
        self.code_lens_services = null;
    }

    pub fn attachWidgets(self: *Controllers) !void {
        const find = self.find.widget().interface();
        if (self.sticky) |controller| try self.view.addOverlayWidget(controller.widget.interface());
        errdefer if (self.sticky) |controller| {
            const widget = controller.widget.interface();
            self.view.removeOverlayWidget(widget.get_id(widget.context)) catch {};
        };
        try self.view.addOverlayWidget(find);
        errdefer self.view.removeOverlayWidget(find.get_id(find.context)) catch {};
        if (self.hover) |controller| try self.view.addContentWidget(controller.widget().contentWidget());
        errdefer if (self.hover) |controller| {
            const widget = controller.widget().contentWidget();
            self.view.removeContentWidget(widget.get_id(widget.context)) catch {};
        };
        if (self.suggest) |controller| try self.view.addContentWidget(controller.widgetInterface());
        self.widgets_attached = true;
    }

    pub fn attachLanguageRegistry(self: *Controllers, features: *LanguageFeaturesService) void {
        self.language_features = features;
        if (self.hover != null) {
            self.hover_participant.registry = &features.hover_provider;
            self.marker_hover_participant.marker_decorations = self.view.editor.marker_decorations;
            if (self.hover_registration == null) {
                self.hover_registration = features.hover_provider.register(.{ .language = "*" }, self.hover_provider.interface()) catch null;
            }
        }
        if (self.suggest) |suggest| suggest.model.registry = &features.completion_provider;
    }

    fn attachWindow(self: *Controllers, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.window = window;
        self.find.attachWindow(window);
        self.word_highlighter.attachWindow(window);
        if (self.hover) |hover| hover.attachWindow(window);
        if (self.glyph_hover) |glyph| glyph.attachWindow(window);
        if (self.sticky) |sticky| sticky.attachWindow(window);
        if (self.suggest) |suggest| suggest.attachWindow(window);
        self.editor.attachContributionWindow(window);
    }

    fn detachDeferredContributions(self: *Controllers) void {
        self.editor.unregisterContributionFactory(StickyScrollController, self);
        self.editor.unregisterContributionFactory(ContentHoverController, self);
        self.editor.unregisterContributionFactory(@import("../../../../editor/contrib/hover/browser/glyphHoverController.zig").GlyphHoverController, self);
        if (self.glyph_hover) |glyph| glyph.unbindHost();
        self.glyph_hover = null;
        self.editor.unregisterContributionFactory(SuggestController, self);
        if (self.sticky) |sticky| {
            if (self.widgets_attached) {
                const widget = sticky.widget.interface();
                self.view.removeOverlayWidget(widget.get_id(widget.context)) catch {};
            }
            sticky.unbindHost();
            self.sticky = null;
        }
        if (self.hover) |hover| {
            if (self.widgets_attached) {
                const widget = hover.widget().contentWidget();
                self.view.removeContentWidget(widget.get_id(widget.context)) catch {};
            }
            hover.unbindModel();
            if (self.hover_registration) |registration| registration.dispose();
            self.hover_registration = null;
            self.marker_hover_participant.deinit();
            self.hover_participant.deinit();
            self.hover_provider.deinit();
            self.hover = null;
        }
        if (self.suggest) |suggest| {
            if (self.widgets_attached) {
                const widget = suggest.widgetInterface();
                self.view.removeContentWidget(widget.get_id(widget.context)) catch {};
            }
            suggest.unbindHost();
            self.suggest = null;
        }
    }

    pub fn deinit(self: *Controllers) void {
        self.detachCodeActionServices();
        self.detachMarkerNavigationServices();
        self.detachCodeLensServices();
        self.find.widget().detachViewZones();
        if (self.widgets_attached) {
            const find = self.find.widget().interface();
            self.view.removeOverlayWidget(find.get_id(find.context)) catch {};
        }
        self.editor.setFindController(null, null);
        self.find.widget().layout_context = null;
        self.find.widget().on_layout = null;
        self.detachDeferredContributions();
        self.word_highlighter.unbindHost();
        // The sink context points at this controller; detach before it dies.
        self.editor.setSearchHighlightSink(null);
        self.view.removeConfigurationListener(.{ .context = self, .notify = onConfigurationChanged });
        self.allocator.destroy(self);
    }
};

/// The same editor contributions used by single diff tabs, but lifetime is
/// that of a virtualized diff binding rather than the composite Tab.
pub const MultiDiffBindingServices = struct {
    allocator: Allocator,
    widget: *DiffWidget,
    original: *Controllers,
    modified: *Controllers,

    pub fn create(allocator: Allocator, widget: *DiffWidget, window: *@import("../../../../base/common/windowDispatch.zig").Queue) !DiffWidget.NativeInputServices {
        const self = try allocator.create(MultiDiffBindingServices);
        errdefer allocator.destroy(self);
        const original = try Controllers.init(allocator, widget.original_editor, widget.original_view);
        errdefer original.deinit();
        try original.attachWidgets();
        original.attachWindow(window);
        const modified = try Controllers.init(allocator, widget.modified_editor, widget.modified_view);
        errdefer modified.deinit();
        try modified.attachWidgets();
        modified.attachWindow(window);
        self.* = .{ .allocator = allocator, .widget = widget, .original = original, .modified = modified };
        return self.interface();
    }
    pub fn interface(self: *MultiDiffBindingServices) DiffWidget.NativeInputServices {
        return .{
            .context = self,
            .handle_key = handleKey,
            .mouse_target = .{ .context = self, .dispatch = handleMouse, .leave = leaveMouse },
            .set_theme = setTheme,
            .attach_language = attachLanguage,
            .dispose = dispose,
        };
    }
    fn handleKey(context: *anyopaque, event: *ui.KeyEvent) !bool {
        const self: *MultiDiffBindingServices = @ptrCast(@alignCast(context));
        const controllers = if (self.widget.focused == .original) self.original else self.modified;
        _ = try editor_input_dispatch.handleKeyEvent(controllers.view.interface(), controllers.hover, controllers.word_highlighter, controllers.suggest, controllers.editor, event, &self.widget.is_pasting, time_compat.milliTimestamp(), null);
        return true;
    }
    fn handleMouse(context: *anyopaque, side: @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig").Side, view: *View, event: *ui.MouseEvent) !bool {
        const self: *MultiDiffBindingServices = @ptrCast(@alignCast(context));
        const controllers = if (side == .original) self.original else self.modified;
        const other = if (side == .original) self.modified else self.original;
        if (event.kind == .move) other.hideHovers();
        return editor_input_dispatch.handleMouseEvent(view, controllers.hover, controllers.suggest, controllers.editor, event);
    }
    fn leaveMouse(context: *anyopaque) void {
        const self: *MultiDiffBindingServices = @ptrCast(@alignCast(context));
        self.original.hideHovers();
        self.modified.hideHovers();
    }
    fn setTheme(context: *anyopaque, palette: ?*const theme_colors_mod.ThemeColors) void {
        const self: *MultiDiffBindingServices = @ptrCast(@alignCast(context));
        self.original.setThemeColors(palette);
        self.modified.setThemeColors(palette);
    }
    fn attachLanguage(context: *anyopaque, host: DiffWidget.NativeInputServices.LanguageHost) void {
        const self: *MultiDiffBindingServices = @ptrCast(@alignCast(context));
        self.original.attachLanguageRegistry(host.features);
        self.modified.attachLanguageRegistry(host.features);
        if (host.opener) |opener| if (host.hover_menus) |menus| {
            self.original.attachHoverServices(opener, menus);
            self.modified.attachHoverServices(opener, menus);
        };
        if (host.marker_navigation) |services| {
            self.original.attachMarkerNavigationServices(services) catch {};
            self.modified.attachMarkerNavigationServices(services) catch {};
        }
        if (host.code_actions) |services| {
            self.original.attachCodeActionServices(services) catch {};
            self.modified.attachCodeActionServices(services) catch {};
        }
        const cache = host.cache orelse return;
        const commands = host.commands orelse return;
        const services: CodeLensServices = .{ .features = host.features, .cache = cache, .commands = commands, .window = host.window };
        self.original.attachCodeLensServices(services) catch {};
        self.modified.attachCodeLensServices(services) catch {};
    }
    fn dispose(context: *anyopaque) void {
        const self: *MultiDiffBindingServices = @ptrCast(@alignCast(context));
        self.original.deinit();
        self.modified.deinit();
        self.allocator.destroy(self);
    }
};

fn onConfigurationChanged(context: *anyopaque, event: @import("../../../../editor/common/config/editorOptions.zig").ConfigurationChangedEvent) void {
    const self: *Controllers = @ptrCast(@alignCast(context));
    if (event.hasChanged(.find)) self.find.applyConfiguration(self.view.terminal_view_host.options.get(.find));
    if (event.hasChanged(.occurrencesHighlight) or event.hasChanged(.occurrencesHighlightDelay) or event.hasChanged(.occurrencesHighlightFromAllProviders)) self.word_highlighter.applyConfiguration(wordHighlightSettings(self.view));
    if (event.hasChanged(.hover) or event.hasChanged(.multiCursorModifier)) {
        const settings = hoverSettings(self.view);
        if (self.hover) |hover| {
            self.hover_participant.show_long_line_warning = settings.show_long_line_warning;
            hover.updateSettings(settings);
        }
        if (self.glyph_hover) |glyph| glyph.applySettings(settings);
    }
    if (event.hasChanged(.lightbulb)) if (self.code_action) |controller| controller.updateSettings();
    if (self.sticky) |sticky| sticky.onConfigurationChanged();
}

fn hoverSettings(view: *View) @import("../../../../editor/contrib/hover/browser/contentHoverController.zig").HoverSettings {
    const options = &view.terminal_view_host.options;
    const hover = options.get(.hover);
    return .{
        .enabled = hover.enabled,
        .sticky = hover.sticky,
        .delay = @intCast(hover.delay),
        .hiding_delay = @intCast(hover.hiding_delay),
        .multi_cursor_modifier = switch (options.get(.multiCursorModifier)) {
            .alt_key => .alt,
            .ctrl_key => .ctrl,
            .meta_key => .meta,
        },
        .above = hover.above,
        .show_long_line_warning = hover.show_long_line_warning,
    };
}

fn wordHighlightSettings(view: *View) @import("../../../../editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterSettings {
    const options = &view.terminal_view_host.options;
    return .{ .occurrences_highlight = options.get(.occurrencesHighlight), .delay_ms = @intCast(options.get(.occurrencesHighlightDelay)), .merge_providers = options.get(.occurrencesHighlightFromAllProviders) };
}

fn viewTextHeight(context: *anyopaque) usize {
    const view: *View = @ptrCast(@alignCast(context));
    return view.editor.textHeight();
}

fn viewVisibleRowOf(context: *anyopaque, position: Position) ?usize {
    const view: *View = @ptrCast(@alignCast(context));
    return view.visibleRowOf(position);
}

fn viewRequestFrame(_: *anyopaque) void {}

fn viewFocusEditor(context: *anyopaque) void {
    const view: *View = @ptrCast(@alignCast(context));
    view.focusEditor();
}

fn viewHasWordTextFocus(context: *anyopaque) bool {
    const view: *View = @ptrCast(@alignCast(context));
    return view.isFocused() and view.hasEditorFocus();
}

fn viewHasEditorFocus(context: *anyopaque) bool {
    const view: *View = @ptrCast(@alignCast(context));
    return view.hasEditorFocus();
}

fn setHoverModelDecoration(context: *anyopaque, range: ?Range) void {
    if (range) |value| {
        const decorations = [_]editorBrowser.Decoration{
            .{ .range = value, .kind = .hover_highlight },
        };
        ModelDecorationSink.set(context, &decorations);
    } else {
        ModelDecorationSink.set(context, &.{});
    }
}

fn viewModelColumnAtViewLineStart(context: *anyopaque, position: Position) usize {
    const view: *View = @ptrCast(@alignCast(context));
    const view_position = view.editor.viewPositionOfModelPosition(position);
    const data = view.editor.viewLineData(view_position.lineNumber) catch return 1;
    return view.editor.modelColumnOfViewPosition(view_position.lineNumber, data.minColumn);
}

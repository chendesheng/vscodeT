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
const View = @import("../../../../../tui/editorView.zig").View;
const Cell = @import("../../../../../tui/editorView.zig").Cell;
const editor_input_dispatch = @import("../../../../../tui/editorInputDispatch.zig");
const FileEditorInput = @import("../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const DiffView = @import("./textDiffEditor.zig").DiffView;
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
const MarkdownPreview = @import("../../../../../tui/markdownPreview.zig").MarkdownPreview;
const MarkdownPreviewConfig = @import("../../../contrib/markdown/browser/markdownPreviewConfig.zig").MarkdownPreviewConfig;
const StickyScrollHost = @import("../../../../../tui/stickyScrollHost.zig").StickyScrollHost;
const StickyScrollController = @import("../../../../editor/contrib/stickyScroll/browser/stickyScrollController.zig").StickyScrollController;
const ImagePreviewPane = @import("../../../../../tui/imagePreview.zig").ImagePreviewPane;
const ImagePreviewEditorInput = @import("../../../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;

const SearchEditorInput = @import("../../../contrib/searchEditor/browser/searchEditorInput.zig").SearchEditorInput;
const TerminalEditorInput = @import("../../../contrib/terminal/browser/terminalEditorInput.zig").TerminalEditorInput;
const TerminalInstance = @import("../../../contrib/terminal/browser/terminalInstance.zig").TerminalInstance;
const terminal_editor = @import("../../../contrib/terminal/browser/terminalEditor.zig");

/// Restores the terminal view for an input already deserialized by its group.
/// The group owns the view from addTab onward. The model keeps its original
/// active, pinned, sticky and preview selections.
pub const RestoredEditorPanes = struct {
    io: Io,
    width: usize,
    height: usize,
    images: *ui.image.Runtime,
    history: *@import("../../../services/history/browser/historyService.zig").HistoryService,
    working_copies: *@import("../../../services/workingCopy/common/workingCopyService.zig").WorkingCopyService,

    pub fn createPane(self: RestoredEditorPanes, allocator: Allocator, input: *EditorInput) !?*Tab {
        if (std.mem.eql(u8, input.type_id, ImagePreviewEditorInput.ID)) {
            return try Tab.initImageFromInput(allocator, self.io, @ptrCast(@alignCast(input.impl.?)), self.width, self.height, self.images, null);
        }
        if (!std.mem.eql(u8, input.type_id, FileEditorInput.TYPE_ID)) return null;
        const tab = try Tab.initFromInput(allocator, @ptrCast(@alignCast(input.impl.?)));
        tab.setImageRuntime(self.images);
        return tab;
    }

    pub fn didRestore(self: RestoredEditorPanes, tab: *Tab) !void {
        try tab.view.setStatusBarVisible(false);
        if (tab.file_input != null) {
            const widget = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig");
            self.working_copies.registerWorkingCopy(widget.workingCopyInterface(tab.editor)) catch |err| switch (err) {
                error.AlreadyRegistered => {},
                else => return err,
            };
        }
        try self.history.add(tab.editor.path);
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
    /// The group-model input (a `FileEditorInput` or a `DiffEditorInput`).
    input: *EditorInput,
    controllers: ?*Controllers = null,
    diff: ?*DiffView = null,
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

    pub fn init(allocator: Allocator, io: Io, path: []const u8, width: usize, height: usize) !*Tab {
        return initWithDeclarative(allocator, io, path, width, height, null);
    }

    pub fn initWithDeclarative(
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

        const view = try View.init(allocator, editor);
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
    pub fn initFromInput(allocator: Allocator, input: *FileEditorInput) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);

        const view = try View.init(allocator, input.editor);
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

    pub fn initSearchEditor(allocator: Allocator, input: *SearchEditorInput) !*Tab {
        const self = try allocator.create(Tab);
        errdefer allocator.destroy(self);
        const view = try View.init(allocator, input.editor);
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
        return initImageFromInput(allocator, io, input, width, height, runtime, window);
    }

    pub fn initImageFromInput(
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

        const view = try View.init(allocator, editor);
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
    pub fn initTerminal(allocator: Allocator, io: Io, instance: *TerminalInstance) !*Tab {
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
        const view = try View.init(allocator, editor);
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
        return self;
    }

    /// Creates the editor contributions on first activation. The tab must have
    /// been attached to a view before any key/mouse event is routed to it.
    pub fn attachWindow(self: *Tab, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.window = window;
        self.editor.attachWindow(window);
        if (self.controllers) |controllers| controllers.attachWindow(window);
        if (self.diff) |diff| diff.widget.original_editor.attachWindow(window);
    }

    pub fn ensureControllers(self: *Tab) !void {
        if (self.controllers != null or self.markdown_preview != null or self.diff != null or self.image_preview != null or self.terminal_input != null) return;

        const controllers = try Controllers.init(self.allocator, self.editor, self.view);
        errdefer controllers.deinit();

        try self.view.addOverlayWidget(controllers.sticky.widget.interface());
        try self.view.addOverlayWidget(controllers.find.widget().interface());
        try self.view.addContentWidget(controllers.hover.widget().contentWidget());
        try self.view.addContentWidget(controllers.suggest.widgetInterface());

        self.controllers = controllers;
        if (self.window) |window| controllers.attachWindow(window);
    }

    pub fn handleEditorKey(self: *Tab, event: *ui.KeyEvent, is_pasting: *bool, now_ms: i64, fallback: ?ui.KeyEvent) !bool {
        try self.ensureControllers();
        const controllers = self.controllers orelse return false;
        return editor_input_dispatch.handleKeyEvent(
            self.view,
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

    pub fn onEditorChanged(self: *Tab, _: i64) void {
        if (self.diff != null) return;
        if (self.controllers) |controllers| {
            _ = controllers.suggest.onEditorChanged() catch {};
        }
    }

    pub fn refresh(self: *Tab) !void {
        if (self.markdown_preview != null) return;
        if (self.terminal_input != null) return;
        if (self.image_preview) |pane| {
            if (pane.dirty) return;
            pane.dirty = true;
            return;
        }
        if (self.diff) |diff| {
            diff.widget.original_view.refresh() catch {};
            diff.widget.modified_view.refresh() catch {};
            return;
        }
        try self.view.refresh();
    }

    pub fn isDiff(self: *const Tab) bool {
        return self.diff != null;
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

    /// Refreshes the cached modified editor/view after a `DiffView` replaced
    /// its widget (a `Refresh Diff` or a re-open of the same ref pair).
    pub fn syncDiffViews(self: *Tab) void {
        const diff = self.diff orelse return;
        self.editor = diff.widget.modified_editor;
        self.view = diff.widget.modified_view;
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
        if (self.terminal_input != null or self.isImage() or self.markdown_preview != null) return;
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
        if (self.diff) |diff| {
            diff.focus();
            return;
        }
        self.view.focusEditor();
    }

    pub fn nextDiffChange(self: *Tab) bool {
        const diff = self.diff orelse return false;
        return diff.nextChange();
    }

    pub fn previousDiffChange(self: *Tab) bool {
        const diff = self.diff orelse return false;
        return diff.previousChange();
    }

    pub fn swapDiffSides(self: *Tab) void {
        if (self.diff) |diff| diff.swapSides();
    }

    pub fn handleDiffMouse(self: *Tab, event: *ui.MouseEvent) !bool {
        const diff = self.diff orelse return false;
        return diff.handleMouse(event);
    }

    pub fn handleDiffKey(self: *Tab, event: *ui.KeyEvent) bool {
        const diff = self.diff orelse return false;
        return diff.handleKey(event);
    }

    /// The tab's entry in the ported `EditorGroupModel`; the group view maps
    /// model editors to tab views through this accessor.
    pub fn editorInput(self: *Tab) *EditorInput {
        return self.input;
    }

    /// Points the tab's registry-backed controllers at the workbench service.
    /// Called when language features are enabled after tabs already exist.
    pub fn attachLanguageRegistry(self: *Tab, features: *LanguageFeaturesService) void {
        if (self.controllers) |controllers| controllers.attachLanguageRegistry(features);
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
        if (self.diff) |diff| return diff.widget.modified_editor;
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

    pub fn handleImageKey(self: *Tab, event: *const ui.KeyEvent) @import("../../../../../tui/imagePreview.zig").Action {
        const pane = self.image_preview orelse return .none;
        return pane.handleKey(event);
    }

    pub fn handleImageMouse(
        self: *Tab,
        event: *const ui.MouseEvent,
        focus_gained: bool,
    ) @import("../../../../../tui/imagePreview.zig").Action {
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
        const find_rows = if (self.controllers) |controllers| controllers.find.viewZoneRows() else 0;
        const query_rows = if (self.search_editor_input) |input| input.search_editor.headerRows() else 0;
        return find_rows + query_rows;
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
    pub fn initMarkdownPanel(allocator: Allocator, source: *FileEditorInput, group: *groups.EditorGroup, config: MarkdownPreviewConfig, palette: ?*const theme_colors_mod.ThemeColors, runtime: *ui.image.Runtime, async_io: ?Io, window: *@import("../../../../base/common/windowDispatch.zig").Queue) !*Tab {
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
        const view = try View.init(allocator, editor);
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
        if (self.diff) |diff| {
            self.diff = null;
            diff.destroy();
            self.allocator.destroy(self);
            return;
        }
        self.view.deinit();
        if (self.image_input) |input| {
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

/// The per-tab editor contributions. Mirrors the construction order in the
/// single-editor app so the find/hover/word/suggest behavior is identical.
pub const Controllers = struct {
    allocator: Allocator,
    editor: *Editor,
    find_sink: View.ModelDecorationSink,
    search_highlight_sink: View.ModelDecorationSink,
    hover_sink: View.ModelDecorationSink,
    word_sink: View.ModelDecorationSink,

    find: *FindController,
    view: *View,
    sticky_host: StickyScrollHost,
    sticky: *StickyScrollController,
    hover_provider: TuiHoverProvider,
    hover_providers: [1]languages.HoverProvider,
    hover_participant: MarkdownHoverParticipant,
    marker_hover_participant: MarkerHoverParticipant,
    participants: [2]hoverTypes.IEditorHoverParticipant,
    hover: *ContentHoverController,
    word_highlighter: *WordHighlighterContribution,
    word_provider: WordBasedCompletionProvider,
    completion_providers: [2]completion.CompletionItemProvider,
    completion_count: usize = 1,
    hover_registration: ?IDisposable = null,
    suggest: *SuggestController,

    /// Applies the palette-derived hover code-block background and the find
    /// bar theme. Upstream resolves these through CSS variables and the
    /// workbench theme service; the terminal layer passes the resolved cells.
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
            self.suggest.setTheme(suggest_theme);
            self.hover.setTheme(.{
                .background = colors.color("editorHoverWidget.background", .{ 37, 37, 38 }),
                .foreground = colors.color("editorHoverWidget.foreground", .{ 204, 204, 204 }),
                .border = colors.color("editorHoverWidget.border", .{ 69, 69, 69 }),
                .focused_border = colors.color("focusBorder", .{ 96, 130, 200 }),
                .scrollbar = colors.color("scrollbarSlider.background", .{ 90, 90, 90 }),
                .scrollbar_thumb = colors.color("scrollbarSlider.hoverBackground", .{ 160, 160, 160 }),
            });
        } else {
            self.find.setTheme(.{});
        }
        self.hover_participant.setCodeBackground(code_background);
    }

    pub fn init(allocator: Allocator, editor: *Editor, view: *View) !*Controllers {
        const self = try allocator.create(Controllers);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.editor = editor;
        self.hover_registration = null;

        self.find_sink = .{ .model = editor.model, .owner = 1 };
        self.search_highlight_sink = View.ModelDecorationSink.incrementalSearch(editor.model);
        editor.setSearchHighlightSink(.{
            .context = self.search_highlight_sink.context(),
            .set = View.ModelDecorationSink.set,
        });
        errdefer editor.setSearchHighlightSink(null);
        self.find = try FindController.init(allocator, editor, .{
            .context = self.find_sink.context(),
            .set = View.ModelDecorationSink.set,
        });
        errdefer self.find.deinit();
        self.find.widget().layout_context = view;
        self.find.widget().on_layout = requestViewRender;
        editor.setFindController(self.find, FindController.startFromContext);

        self.view = view;
        self.sticky_host = StickyScrollHost.init(allocator, view);
        self.sticky = try StickyScrollController.init(allocator, editor, self.sticky_host.interface());
        errdefer self.sticky.deinit();
        self.sticky_host.attach(self.sticky);

        self.hover_sink = .{ .model = editor.model, .owner = 4 };
        self.word_sink = .{ .model = editor.model, .owner = 3 };

        self.hover_provider = TuiHoverProvider.init(allocator);
        self.hover_provider.json_document = &editor.document.json;
        self.hover_provider.setModel(editor.model);
        errdefer self.hover_provider.deinit();
        self.hover_providers = .{self.hover_provider.interface()};

        const features = editor.language_features;
        if (features) |service| {
            self.hover_registration = service.hover_provider.register(.{ .language = "*" }, self.hover_provider.interface()) catch null;
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
        errdefer self.marker_hover_participant.deinit();
        self.participants = .{
            self.marker_hover_participant.interface(),
            self.hover_participant.interface(),
        };

        self.hover = try ContentHoverController.init(allocator, editor.model, &self.participants, .{}, .{
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
        errdefer self.hover.deinit();

        self.word_highlighter = try WordHighlighterContribution.init(allocator, editor, .{
            .context = view,
            .decoration_context = self.word_sink.context(),
            .has_text_focus = viewHasWordTextFocus,
            .set_decorations = View.ModelDecorationSink.set,
            .request_frame = viewRequestFrame,
        }, .{});
        errdefer self.word_highlighter.deinit();

        self.word_provider = WordBasedCompletionProvider.init();
        self.completion_providers[0] = self.word_provider.interface();
        self.completion_count = 1;
        if (editor.document.json.client != null) {
            self.completion_providers[1] = .{
                .context = editor,
                .provide_completion_items = Editor.jsonProvideCompletion,
                .trigger_characters = &.{ "\"", ":" },
            };
            self.completion_count = 2;
        }

        const suggest_host = SuggestControllerHostForView(view);
        self.suggest = if (features) |service|
            try SuggestController.initWithRegistry(allocator, editor, &.{}, suggest_host, &service.completion_provider)
        else
            try SuggestController.init(allocator, editor, self.completion_providers[0..self.completion_count], suggest_host);
        errdefer self.suggest.deinit();

        // Suggest controllers only exist after the block above; applying the
        // theme earlier dereferenced an unset widget.
        self.setThemeColors(view.theme_colors);

        self.find.applyConfiguration(view.terminal_view_host.options.get(.find));
        try view.addConfigurationListener(.{ .context = self, .notify = onConfigurationChanged });
        return self;
    }

    pub fn attachLanguageRegistry(self: *Controllers, features: *LanguageFeaturesService) void {
        self.hover_participant.registry = &features.hover_provider;
        self.marker_hover_participant.marker_decorations = self.view.editor.marker_decorations;
        self.suggest.model.registry = &features.completion_provider;
        if (self.hover_registration == null) {
            self.hover_registration = features.hover_provider.register(
                .{ .language = "*" },
                self.hover_provider.interface(),
            ) catch null;
        }
    }

    fn attachWindow(self: *Controllers, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.find.attachWindow(window);
        self.hover.attachWindow(window);
        self.word_highlighter.attachWindow(window);
        self.sticky.attachWindow(window);
        self.suggest.attachWindow(window);
    }
    pub fn deinit(self: *Controllers) void {
        // The sink context points at this controller; detach before it dies.
        self.editor.setSearchHighlightSink(null);
        self.view.removeConfigurationListener(.{ .context = self, .notify = onConfigurationChanged });
        self.sticky.deinit();
        if (self.hover_registration) |registration| registration.dispose();
        self.suggest.deinit();
        self.word_highlighter.deinit();
        self.hover.deinit();
        self.marker_hover_participant.deinit();
        self.hover_participant.deinit();
        self.hover_provider.deinit();
        self.find.deinit();
        self.allocator.destroy(self);
    }
};

fn onConfigurationChanged(context: *anyopaque, event: @import("../../../../editor/common/config/editorOptions.zig").ConfigurationChangedEvent) void {
    const self: *Controllers = @ptrCast(@alignCast(context));
    if (event.hasChanged(.find)) self.find.applyConfiguration(self.view.terminal_view_host.options.get(.find));
    self.sticky.onConfigurationChanged();
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
        View.ModelDecorationSink.set(context, &decorations);
    } else {
        View.ModelDecorationSink.set(context, &.{});
    }
}

fn viewModelColumnAtViewLineStart(context: *anyopaque, position: Position) usize {
    const view: *View = @ptrCast(@alignCast(context));
    const view_position = view.editor.viewPositionOfModelPosition(position);
    const data = view.editor.viewLineData(view_position.lineNumber) catch return 1;
    return view.editor.modelColumnOfViewPosition(view_position.lineNumber, data.minColumn);
}

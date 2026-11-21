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
const FileEditorInput = @import("../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const DiffView = @import("./textDiffEditor.zig").DiffView;
const FindController = @import("../../../../editor/contrib/find/browser/findController.zig").FindController;
const word_character_classifier = @import("../../../../editor/common/core/wordCharacterClassifier.zig");
const editorBrowser = @import("../../../../editor/browser/editorBrowser.zig");
const Position = @import("../../../../editor/common/core/position.zig").Position;
const Range = @import("../../../../editor/common/core/range.zig").Range;
const Selection = @import("../../../../editor/common/core/selection.zig").Selection;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const languages = @import("../../../../editor/common/languages.zig");
const hoverTypes = @import("../../../../editor/contrib/hover/browser/hoverTypes.zig");
const ContentHoverController = @import("../../../../editor/contrib/hover/browser/contentHoverController.zig").ContentHoverController;
const MarkdownHoverParticipant = @import("../../../../editor/contrib/hover/browser/markdownHoverParticipant.zig").MarkdownHoverParticipant;
const WordHighlighterContribution = @import("../../../../editor/contrib/wordHighlighter/browser/wordHighlighter.zig").WordHighlighterContribution;
const SuggestController = @import("../../../../editor/contrib/suggest/browser/suggestController.zig").SuggestController;
const WordBasedCompletionProvider = @import("../../../../editor/contrib/suggest/browser/wordBasedSuggestions.zig").WordBasedCompletionProvider;
const TuiHoverProvider = @import("../../../../editor/contrib/hover/browser/terminalHoverProvider.zig").TuiHoverProvider;
const completion = @import("../../../../editor/common/languages/completion.zig");
const LanguageFeaturesService = @import("../../../../editor/common/services/languageFeaturesService.zig").LanguageFeaturesService;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const MarkdownPreview = @import("../../../../../tui/markdownPreview.zig").MarkdownPreview;
const MarkdownPreviewConfig = @import("../../../contrib/markdown/browser/markdownPreviewConfig.zig").MarkdownPreviewConfig;
const ImagePreviewPane = @import("../../../../../tui/imagePreview.zig").ImagePreviewPane;
const ImagePreviewEditorInput = @import("../../../contrib/mediaPreview/browser/imagePreviewEditorInput.zig").ImagePreviewEditorInput;

pub const Tab = struct {
    allocator: Allocator,
    /// Modified/first editor. For a diff tab this is the modified pane.
    editor: *Editor,
    /// Modified/first view. For a diff tab this is the modified pane.
    view: *View,
    /// File input for a normal tab; null for a diff tab.
    file_input: ?*FileEditorInput,
    /// The group-model input (a `FileEditorInput` or a `DiffEditorInput`).
    input: *EditorInput,
    controllers: ?*Controllers = null,
    diff: ?*DiffView = null,
    markdown_preview: ?*MarkdownPreview = null,
    markdown_preview_visible: bool = false,
    /// Image preview pane; also marks this as an image tab.
    image_preview: ?*ImagePreviewPane = null,
    image_input: ?*ImagePreviewEditorInput = null,
    image_runtime: ?*ui.image.Runtime = null,
    last_width: usize = 0,
    last_height: usize = 0,
    preview_rect: ?ui.Rect = null,

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
    ) !*Tab {
        const input = try ImagePreviewEditorInput.init(allocator, path);
        errdefer input.deinit();
        return initImageFromInput(allocator, io, input, width, height, runtime);
    }

    pub fn initImageFromInput(
        allocator: Allocator,
        io: Io,
        image_input: *ImagePreviewEditorInput,
        width: usize,
        height: usize,
        runtime: *ui.image.Runtime,
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

        const pane = try ImagePreviewPane.init(allocator, io, runtime, image_input.path);
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
    pub fn ensureControllers(self: *Tab) !void {
        if (self.controllers != null or self.diff != null or self.image_preview != null) return;

        const controllers = try Controllers.init(self.allocator, self.editor, self.view);
        errdefer controllers.deinit();

        try self.view.addOverlayWidget(controllers.find.widget().interface());
        try self.view.addContentWidget(controllers.hover.widget().contentWidget());
        try self.view.addContentWidget(controllers.suggest.widgetInterface());

        self.controllers = controllers;
        controllers.word_highlighter.onEditorChanged(time_compat.milliTimestamp());
    }

    pub fn onEditorChanged(self: *Tab, now_ms: i64) void {
        if (self.diff != null) return;
        if (self.controllers) |controllers| {
            controllers.find.onEditorChanged();
            controllers.word_highlighter.onEditorChanged(now_ms);
            _ = controllers.suggest.onEditorChanged() catch {};
        }
    }

    pub fn refresh(self: *Tab) !void {
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

    /// Paints the tab into `frame`. A file tab paints its single view; a diff
    /// tab paints both panes plus the center gutter.
    pub fn paint(self: *Tab, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
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
        const preview_width = if (self.markdown_preview_visible) markdownPreviewWidth(w) else 0;
        if (preview_width == 0 or self.markdown_preview == null) {
            try self.view.paint();
            try ui.CellGrid.blit(&frame.next, self.view.grid(), x, y, w, h);
            return;
        }
        const editor_width = w -| preview_width -| 1;
        try self.view.paint();
        try ui.CellGrid.blit(&frame.next, self.view.grid(), x, y, editor_width, h);
        const divider = ui.cell.PaintStyle{
            .fg = ui.cell.packColor(.{ .r = 70, .g = 70, .b = 70 }),
            .bg = ui.cell.packColor(.{ .r = 30, .g = 30, .b = 33 }),
        };
        var row: usize = 0;
        while (row < h) : (row += 1) {
            frame.next.putCodepoint(x + editor_width, y + row, '│', 1, divider);
        }
        try self.markdown_preview.?.paint(frame, x + editor_width + 1, y, preview_width, h);
    }

    pub fn cursorCell(self: *Tab) ?Cell {
        if (self.image_preview != null) return null;
        if (self.diff) |diff| {
            const cell = diff.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col };
        }
        return self.view.cursorCell();
    }

    pub fn focusEditor(self: *Tab) void {
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

    pub fn layoutCells(self: *Tab, width: usize, height: usize) void {
        self.last_width = width;
        self.last_height = height;
        if (self.image_preview) |pane| {
            pane.layout(@max(width, 1), @max(height, 1)) catch {};
            return;
        }
        if (self.diff) |diff| {
            diff.layout(@max(width, 1), @max(height, 1));
            return;
        }
        const preview_width = if (self.markdown_preview_visible) markdownPreviewWidth(width) else 0;
        const editor_width = if (preview_width > 0) width -| preview_width -| 1 else width;
        self.editor.setViewport(@max(editor_width, 1), @max(height, 1));
        self.view.resize() catch {};
        if (preview_width > 0) {
            if (self.markdown_preview) |preview| {
                preview.resize(preview_width, height) catch {};
            }
            self.preview_rect = .{
                .x = @floatFromInt(editor_width + 1),
                .y = 0,
                .w = @floatFromInt(preview_width),
                .h = @floatFromInt(height),
            };
        } else {
            self.preview_rect = null;
            if (self.markdown_preview) |preview| {
                preview.resize(0, 0) catch {};
            }
        }
    }

    pub fn isMarkdown(self: *const Tab) bool {
        return self.diff == null and std.mem.eql(u8, self.editor.languageId(), "markdown");
    }

    pub fn markdownPreviewVisible(self: *const Tab) bool {
        return self.markdown_preview_visible;
    }

    pub fn ensureMarkdownPreview(self: *Tab) !?*MarkdownPreview {
        if (!self.isMarkdown()) return null;
        if (self.markdown_preview == null) {
            self.markdown_preview = try MarkdownPreview.init(self.allocator, self.editor);
            self.markdown_preview.?.setImageRuntime(self.image_runtime);
        }
        return self.markdown_preview;
    }

    pub fn setMarkdownPreviewVisible(self: *Tab, visible: bool) !void {
        if (visible) {
            const preview = (try self.ensureMarkdownPreview()) orelse return error.NotMarkdown;
            self.markdown_preview_visible = true;
            if (self.last_width > 0 or self.last_height > 0) {
                self.layoutCells(self.last_width, self.last_height);
            }
            preview.open(null) catch |err| {
                self.editor.setMessage("markdown preview: {s}", .{@errorName(err)});
            };
        } else {
            self.markdown_preview_visible = false;
            if (self.markdown_preview) |preview| preview.close();
            if (self.last_width > 0 or self.last_height > 0) {
                self.layoutCells(self.last_width, self.last_height);
            }
        }
    }

    pub fn toggleMarkdownPreview(self: *Tab) !void {
        try self.setMarkdownPreviewVisible(!self.markdown_preview_visible);
    }

    pub fn setMarkdownPreviewConfig(self: *Tab, config: MarkdownPreviewConfig) void {
        if (self.markdown_preview) |preview| preview.setConfig(config);
    }

    pub fn refreshMarkdownPreview(self: *Tab, force: bool) void {
        if (self.markdown_preview) |preview| preview.refresh(force);
    }

    pub fn onMarkdownPreviewTick(self: *Tab, now_ms: i64) bool {
        if (self.markdown_preview) |preview| return preview.onTick(now_ms);
        return false;
    }

    pub fn markdownPreviewTimeout(self: *const Tab, now_ms: i64) ?u32 {
        if (self.markdown_preview) |preview| return preview.nextTimeout(now_ms);
        return null;
    }

    /// Routes a pane-content-relative mouse event to the preview. Returns true
    /// when the preview consumed it.
    pub fn handleMarkdownPreviewMouse(self: *Tab, event: *const ui.MouseEvent, now_ms: i64) bool {
        if (!self.markdown_preview_visible) return false;
        const rect = self.preview_rect orelse return false;
        const x = ui.cell.snap(rect.x);
        const y = ui.cell.snap(rect.y);
        const w = ui.cell.snap(rect.w);
        const h = ui.cell.snap(rect.h);
        if (event.x < x or event.y < y or event.x >= x + w or event.y >= y + h) return false;
        var local = event.*;
        local.x -= x;
        local.y -= y;
        return if (self.markdown_preview) |preview| preview.handleMouse(&local, now_ms) else false;
    }

    fn markdownPreviewWidth(total: usize) usize {
        if (total < 33) return 0;
        const preview = @max(@as(usize, 12), total / 2);
        const editor = total -| preview -| 1;
        if (editor < 20) return 0;
        return preview;
    }

    pub fn deinit(self: *Tab) void {
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
        } else if (self.file_input) |input| {
            input.deinit();
        }
        self.allocator.destroy(self);
    }
};

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
    find_sink: View.ModelDecorationSink,
    hover_sink: View.ModelDecorationSink,
    word_sink: View.ModelDecorationSink,

    find: *FindController,
    hover_provider: TuiHoverProvider,
    hover_providers: [1]languages.HoverProvider,
    hover_participant: MarkdownHoverParticipant,
    participants: [1]hoverTypes.IEditorHoverParticipant,
    hover: *ContentHoverController,
    word_highlighter: *WordHighlighterContribution,
    word_provider: WordBasedCompletionProvider,
    completion_providers: [2]completion.CompletionItemProvider,
    completion_count: usize = 1,
    hover_registration: ?IDisposable = null,
    suggest: *SuggestController,

    pub fn init(allocator: Allocator, editor: *Editor, view: *View) !*Controllers {
        const self = try allocator.create(Controllers);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.hover_registration = null;

        self.find_sink = .{ .model = editor.model, .owner = 1 };
        self.find = try FindController.init(allocator, editor, .{
            .context = self.find_sink.context(),
            .set = View.ModelDecorationSink.set,
        });
        errdefer self.find.deinit();
        editor.setFindController(self.find, FindController.startFromContext);

        self.hover_sink = .{ .model = editor.model, .owner = 4 };
        self.word_sink = .{ .model = editor.model, .owner = 3 };

        self.hover_provider = TuiHoverProvider.init(allocator);
        self.hover_provider.setJsonDocument(editor.json_client, editor.json_uri);
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
        self.participants = .{self.hover_participant.interface()};

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
            .has_text_focus = viewHasEditorFocus,
            .set_decorations = View.ModelDecorationSink.set,
            .request_frame = viewRequestFrame,
        }, .{});
        errdefer self.word_highlighter.deinit();

        self.word_provider = WordBasedCompletionProvider.init();
        self.completion_providers[0] = self.word_provider.interface();
        self.completion_count = 1;
        if (editor.json_client != null) {
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

        return self;
    }

    pub fn attachLanguageRegistry(self: *Controllers, features: *LanguageFeaturesService) void {
        self.hover_participant.registry = &features.hover_provider;
        self.suggest.model.registry = &features.completion_provider;
        if (self.hover_registration == null) {
            self.hover_registration = features.hover_provider.register(
                .{ .language = "*" },
                self.hover_provider.interface(),
            ) catch null;
        }
    }

    pub fn deinit(self: *Controllers) void {
        if (self.hover_registration) |registration| registration.dispose();
        self.suggest.deinit();
        self.word_highlighter.deinit();
        self.hover.deinit();
        self.hover_participant.deinit();
        self.hover_provider.deinit();
        self.find.deinit();
        self.allocator.destroy(self);
    }
};

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

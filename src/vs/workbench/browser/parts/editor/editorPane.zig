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
const View = @import("../../../../editor/browser/viewTerminal.zig").View;
const FileEditorInput = @import("../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
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

pub const Tab = struct {
    allocator: Allocator,
    editor: *Editor,
    view: *View,
    input: *FileEditorInput,
    controllers: ?*Controllers = null,

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
            .input = input,
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
            .input = input,
        };
        return self;
    }

    /// Creates the editor contributions on first activation. The tab must have
    /// been attached to a view before any key/mouse event is routed to it.
    pub fn ensureControllers(self: *Tab) !void {
        if (self.controllers != null) return;

        const controllers = try Controllers.init(self.allocator, self.editor, self.view);
        errdefer controllers.deinit();

        try self.view.addOverlayWidget(controllers.find.widget().interface());
        try self.view.addContentWidget(controllers.hover.widget().contentWidget());
        try self.view.addContentWidget(controllers.suggest.widgetInterface());

        self.controllers = controllers;
        controllers.word_highlighter.onEditorChanged(time_compat.milliTimestamp());
    }

    pub fn onEditorChanged(self: *Tab, now_ms: i64) void {
        if (self.controllers) |controllers| {
            controllers.find.onEditorChanged();
            controllers.word_highlighter.onEditorChanged(now_ms);
            _ = controllers.suggest.onEditorChanged() catch {};
        }
    }

    pub fn refresh(self: *Tab) !void {
        try self.view.refresh();
    }

    /// The tab's entry in the ported `EditorGroupModel`; the group view maps
    /// model editors to tab views through this accessor.
    pub fn editorInput(self: *Tab) *EditorInput {
        return &self.input.base;
    }

    /// Points the tab's registry-backed controllers at the workbench service.
    /// Called when language features are enabled after tabs already exist.
    pub fn attachLanguageRegistry(self: *Tab, features: *LanguageFeaturesService) void {
        if (self.controllers) |controllers| {
            controllers.hover_participant.registry = &features.hover_provider;
            controllers.suggest.model.registry = &features.completion_provider;
        }
    }

    /// Lays the editor view out in the group pane. The height is the editor
    /// content height; the tab strip row is owned by the workbench.
    pub fn layoutCells(self: *Tab, width: usize, height: usize) void {
        self.editor.setViewport(@max(width, 1), @max(height, 1));
        self.view.resize() catch {};
    }

    pub fn deinit(self: *Tab) void {
        if (self.controllers) |controllers| {
            controllers.deinit();
            self.controllers = null;
        }
        self.view.deinit();
        self.input.deinit();
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

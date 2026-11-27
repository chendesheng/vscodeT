// Terminal adapter that exposes the terminal `Editor` through the upstream
// `IViewModel`/`IViewLayout`/`IEditorConfiguration` contracts so the ported
// `ViewLines` stack can render it.
//
// This is the wiring seam for replacing the collapsed terminal renderer: the
// model stays in `Editor`, while `ViewLines` owns line layout, dirty tracking,
// decoration normalization and width bookkeeping exactly as upstream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");

const Editor = @import("./codeEditorWidgetTerminal.zig").Editor;
const view_model = @import("../../../common/viewModel.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const view_lines_mod = @import("../../viewParts/viewLines/viewLines.zig");
const view_line_options_mod = @import("../../viewParts/viewLines/viewLineOptions.zig");
const view_mod = @import("../../view.zig");
const StringBuilder = @import("../../../common/core/stringBuilder.zig").StringBuilder;
const view_model_decorations = @import("../../../common/viewModel/viewModelDecorations.zig");
const line_numbers_mod = @import("../../viewParts/lineNumbers/lineNumbers.zig");
const indent_guides_mod = @import("../../viewParts/indentGuides/indentGuides.zig");
const selections_mod = @import("../../viewParts/selections/selections.zig");
const current_line_mod = @import("../../viewParts/currentLineHighlight/currentLineHighlight.zig");
const view_cursors_mod = @import("../../viewParts/viewCursors/viewCursors.zig");
const folding_decorations_mod = @import("../../../contrib/folding/browser/foldingDecorations.zig");
const lines_decorations_mod = @import("../../viewParts/linesDecorations/linesDecorations.zig");
const decorations_overlay_mod = @import("../../viewParts/decorations/decorations.zig");
const block_decorations_mod = @import("../../viewParts/blockDecorations/blockDecorations.zig");
const glyph_margin_mod = @import("../../viewParts/glyphMargin/glyphMargin.zig");
const margin_decorations_mod = @import("../../viewParts/marginDecorations/marginDecorations.zig");
const restricted_context = @import("../../view/renderingContext.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const browser_config = @import("../../config/editorConfiguration.zig");
const terminal_editor_config = @import("../../config/terminalEditorConfiguration.zig");
const editor_options = @import("../../../common/config/editorOptions.zig");
const theme_service = @import("../../../../platform/theme/common/themeService.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const Position = @import("../../../common/core/position.zig").Position;
const TextDirection = @import("../../../common/standalone/standaloneEnums.zig").TextDirection;
const IActiveIndentGuideInfo = @import("../../../common/textModelGuides.zig").IActiveIndentGuideInfo;
const BracketGuideOptions = @import("../../../common/textModelGuides.zig").BracketGuideOptions;
const LineGuides = @import("../../../common/textModelGuides.zig").LineGuides;

const IViewModel = view_model.IViewModel;
const IViewLayout = view_model.IViewLayout;
const ViewportData = viewport_data.ViewportData;
const ViewLines = view_lines_mod.ViewLines;
const ViewLineOptions = view_line_options_mod.ViewLineOptions;
const View = view_mod.View;
const ViewEventHandler = view_event_handler.ViewEventHandler;
const ViewEvent = view_events.ViewEvent;
const ViewModelDecorations = view_model_decorations.ViewModelDecorations;
const LineNumbersOverlay = line_numbers_mod.LineNumbersOverlay;
const IndentGuidesOverlay = indent_guides_mod.IndentGuidesOverlay;
const RenderedLineNumber = line_numbers_mod.RenderedLineNumber;
const RenderingContext = rendering_context.RenderingContext;
const SelectionsOverlay = selections_mod.SelectionsOverlay;
const LineSelectionRender = selections_mod.LineSelectionRender;
const CurrentLineHighlightOverlay = current_line_mod.CurrentLineHighlightOverlay;
const LineHighlightRenderData = current_line_mod.LineHighlightRenderData;
const ViewCursors = view_cursors_mod.ViewCursors;
const FoldingDecorationProvider = folding_decorations_mod.FoldingDecorationProvider;
const LinesDecorationsOverlay = lines_decorations_mod.LinesDecorationsOverlay;
const DecorationsOverlay = decorations_overlay_mod.DecorationsOverlay;
const BlockDecorations = block_decorations_mod.BlockDecorations;
const GlyphMarginWidgets = glyph_margin_mod.GlyphMarginWidgets;
const GlyphMarginLanesModel = @import("../../../common/viewModel/glyphLanesModel.zig").GlyphMarginLanesModel;
const ViewLine = @import("../../viewParts/viewLines/viewLine.zig").ViewLine;
const ViewCursorRenderData = @import("../../viewParts/viewCursors/viewCursor.zig").ViewCursorRenderData;
const RestrictedRenderingContext = restricted_context.RestrictedRenderingContext;
const InlineDecoration = @import("../../../common/viewModel/inlineDecorations.zig").InlineDecoration;
const IViewModelLines = view_model_decorations.IViewModelLines;
const ViewContext = view_context.ViewContext;
const IColorTheme = theme_service.IColorTheme;

/// Minimal terminal color theme. The terminal renderer resolves token colors
/// through `TokenizationRegistry`; the view context only needs the scheme type
/// and a vtable that reports no CSS colors.
const TerminalColorTheme = struct {
    scheme: @import("../../../../platform/theme/common/theme.zig").ColorScheme = .DARK,

    fn getColor(_: *anyopaque, _: []const u8, _: bool) ?@import("../../../../base/common/color.zig").Color {
        return null;
    }
    fn defines(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn getTokenStyleMetadata(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) ?theme_service.ITokenStyle {
        return null;
    }

    fn interface(self: *TerminalColorTheme) IColorTheme {
        return .{
            .theme_type = self.scheme,
            .label = "terminal",
            .context = self,
            .vtable = &.{
                .getColor = getColor,
                .defines = defines,
                .getTokenStyleMetadata = getTokenStyleMetadata,
            },
        };
    }
};

/// Upstream `IViewModelLines` adapter over the terminal projection.
const LinesAdapter = struct {
    editor: *Editor,
    scratch: []ModelDecoration = &.{},

    fn deinit(self: *LinesAdapter) void {
        if (self.scratch.len > 0) self.editor.allocator.free(self.scratch);
        self.scratch = &.{};
    }

    fn interface(self: *LinesAdapter) IViewModelLines {
        return .{
            .context = self,
            .getDecorationsInRange = getDecorationsInRange,
            .getViewLineMinColumn = getViewLineMinColumn,
            .getViewLineMaxColumn = getViewLineMaxColumn,
        };
    }

    fn getDecorationsInRange(
        context: *anyopaque,
        view_range: Range,
        owner_id: i32,
        filter_validation_decorations: bool,
        _: bool,
        only_minimap_decorations: bool,
        only_margin_decorations: bool,
    ) []const ModelDecoration {
        const self: *LinesAdapter = @ptrCast(@alignCast(context));
        if (self.scratch.len > 0) self.editor.allocator.free(self.scratch);
        self.scratch = &.{};
        const converter = self.editor.converter.interface();
        const model_range = converter.convertViewRangeToModelRange(converter.context, view_range);
        self.scratch = self.editor.model.getDecorationsInRange(
            model_range,
            @intCast(@max(owner_id, 0)),
            filter_validation_decorations,
            only_minimap_decorations,
            only_margin_decorations,
        ) catch return &.{};
        return self.scratch;
    }

    fn getViewLineMinColumn(context: *anyopaque, line_number: usize) usize {
        const self: *LinesAdapter = @ptrCast(@alignCast(context));
        return self.editor.view_lines.getLineMinColumn(line_number);
    }

    fn getViewLineMaxColumn(context: *anyopaque, line_number: usize) usize {
        const self: *LinesAdapter = @ptrCast(@alignCast(context));
        return self.editor.view_lines.getLineMaxColumn(line_number);
    }
};

/// Owns the terminal adapters and a ported `ViewLines` instance.
pub const TerminalViewHost = struct {
    allocator: Allocator,
    editor: *Editor,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    theme: TerminalColorTheme,
    context: ViewContext,
    view: View,
    scratch_text: StringBuilder,
    scratch_inline_decorations: std.ArrayList(InlineDecoration) = .empty,
    decorations: *ViewModelDecorations,
    line_numbers: LineNumbersOverlay,
    indent_guides: IndentGuidesOverlay,
    line_decorations: LinesDecorationsOverlay,
    decorations_overlay: DecorationsOverlay,
    block_decorations: BlockDecorations,
    glyph_margin: GlyphMarginWidgets,
    margin_decorations: margin_decorations_mod.MarginViewLineDecorationsOverlay,
    glyph_lanes: GlyphMarginLanesModel,
    glyph_margin_dirty: bool = true,
    configured_glyph_margin: bool = false,
    configured_sticky_scroll: editor_options.EditorStickyScrollOptions = .{},
    configured_code_lens: bool = true,
    glyph_margin_override: ?bool = null,
    sticky_scroll_override: ?bool = null,
    code_lens_override: ?bool = null,
    line_decorations_dirty: bool = true,
    auto_line_decorations: bool = false,
    selections_overlay: SelectionsOverlay,
    current_line: CurrentLineHighlightOverlay,
    current_line_margin: CurrentLineHighlightOverlay,
    view_cursors: ViewCursors,
    lines_adapter: LinesAdapter,
    offsets: std.ArrayListUnmanaged(f64) = .empty,
    selections: []Selection = &.{},
    max_line_width: f64 = 0,
    /// Resets the view-model decoration resolver when the line mapping or the
    /// model decorations change.
    view_model_handler: ViewEventHandler = .{},
    first_frame: bool = true,
    folding_decorations: FoldingDecorationProvider = .{},

    pub fn init(allocator: Allocator, editor: *Editor) !*TerminalViewHost {
        const self = try allocator.create(TerminalViewHost);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .editor = editor,
            .options = browser_config.ComputedEditorOptions.init(),
            .configuration = undefined,
            .theme = .{},
            .context = undefined,
            .view = undefined,
            .scratch_text = undefined,
            .decorations = undefined,
            .line_numbers = undefined,
            .indent_guides = undefined,
            .line_decorations = undefined,
            .decorations_overlay = undefined,
            .block_decorations = undefined,
            .glyph_margin = undefined,
            .margin_decorations = undefined,
            .glyph_lanes = undefined,
            .selections_overlay = undefined,
            .current_line = undefined,
            .current_line_margin = undefined,
            .view_cursors = undefined,
            .lines_adapter = undefined,
        };

        self.options.set(.lineHeight, 1);
        self.options.set(.tabFocusMode, editor.getTabFocusMode());
        // The shared line renderer owns whitespace rendering (the browser's
        // SVG whitespace layer is not ported), so keep
        // `experimentalWhitespaceRendering` off and retain the upstream
        // `selection` default: selecting text reveals middots for spaces and an
        // arrow for tabs. An explicit `editor.renderWhitespace` setting still
        // overrides it in `applyEditorSettings`.
        self.options.set(.experimentalWhitespaceRendering, .off);
        // The terminal configuration surface does not map `editor.guides.*`
        // yet; keep the renderer's existing indentation and bracket-pair
        // defaults until that mapping is ported.
        self.options.set(.guides, .{
            .bracket_pairs = .on,
            .bracket_pairs_horizontal = .off,
            .highlight_active_bracket_pair = true,
            .indentation = true,
            .highlight_active_indentation = .on,
        });
        self.options.set(.wordWrap, .on);
        self.options.set(.stopRenderingLineAfter, -1);
        self.configured_glyph_margin = self.options.get(.glyphMargin);
        self.configured_sticky_scroll = self.options.get(.stickyScroll);
        self.configured_code_lens = self.options.get(.codeLens);
        self.syncGutterOptions();
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.lines_adapter = .{ .editor = editor };
        self.decorations = try ViewModelDecorations.create(
            allocator,
            0,
            editor.model,
            false,
            false,
            self.lines_adapter.interface(),
            editor.converter.interface(),
        );
        self.context = ViewContext.init(&self.configuration, self.theme.interface(), self.modelInterface());
        self.glyph_lanes = try GlyphMarginLanesModel.init(allocator, 0);
        self.view.init(allocator, &self.context);
        self.view.view_zones.attach(editor, &self.context);
        try self.view.addViewPart(&self.view.view_zones.base);
        self.view.scrollbar.overview.attach(allocator, &self.context);
        try self.view.addViewPart(&self.view.scrollbar.overview.base);
        self.scratch_text = try StringBuilder.init(allocator, 256);
        self.line_numbers.init(allocator, &self.context);
        self.indent_guides.init(allocator, &self.context);
        self.line_decorations.init(allocator, &self.context);
        self.decorations_overlay.init(allocator, &self.context);
        self.block_decorations.init(allocator, &self.context);
        self.glyph_margin.init(allocator, &self.context, &self.glyph_lanes);
        self.margin_decorations.init(allocator, &self.context);
        self.selections_overlay.init(allocator, &self.context);
        self.current_line.initContent(allocator, &self.context);
        self.current_line_margin.initMargin(allocator, &self.context);
        self.view_cursors.init(allocator, &self.context);

        // The ported `View` coordinates the render pass. Register the overlays
        // as content overlays exactly like upstream `ContentViewOverlays`.
        try self.view.addContentOverlay(&self.line_numbers.base);
        try self.view.addContentOverlay(&self.indent_guides.base);
        try self.view.addContentOverlay(&self.line_decorations.base);
        try self.view.addContentOverlay(&self.decorations_overlay.base);
        try self.view.addContentOverlay(&self.selections_overlay.base);
        try self.view.addContentOverlay(&self.current_line.base);
        try self.view.addContentOverlay(&self.current_line_margin.base);
        try self.view.addViewPart(&self.glyph_margin.base);
        try self.view.addContentOverlay(&self.margin_decorations.base);
        try self.view.addViewPart(&self.block_decorations.base);

        self.view_model_handler = ViewEventHandler.init(self, .{
            .onLineMappingChanged = onEditorLineMappingChanged,
            .onDecorationsChanged = onEditorDecorationsChanged,
        });
        editor.addViewEventHandler(&self.view_model_handler);
        return self;
    }

    /// Applies the configured `editor.*` view settings, keeping the
    /// terminal-specific accommodations. `changed` receives the option ids
    /// whose values changed so the caller can fan a configuration event out
    /// through the ported `View`.
    pub fn applyEditorSettings(
        self: *TerminalViewHost,
        reader: terminal_editor_config.Reader,
        language_id: ?[]const u8,
        resource: ?[]const u8,
        changed: *terminal_editor_config.ChangeSet,
    ) bool {
        const previous_glyph = self.options.get(.glyphMargin);
        const previous_sticky = self.options.get(.stickyScroll);
        const previous_code_lens = self.options.get(.codeLens);
        const previous_tab_focus = self.options.get(.tabFocusMode);
        self.options.set(.codeLens, self.configured_code_lens);
        self.options.set(.glyphMargin, self.configured_glyph_margin);
        self.options.set(.stickyScroll, self.configured_sticky_scroll);
        _ = terminal_editor_config.applyViewSettings(&self.options, reader, language_id, resource, changed);
        self.editor.tab_focus_mode_configured = terminal_editor_config.tabFocusModeSetting(reader, language_id, resource);
        self.options.set(.tabFocusMode, self.editor.getTabFocusMode());
        changed[@backingInt(editor_options.EditorOption.tabFocusMode)] = previous_tab_focus != self.options.get(.tabFocusMode);
        self.configured_glyph_margin = self.options.get(.glyphMargin);
        self.configured_sticky_scroll = self.options.get(.stickyScroll);
        self.configured_code_lens = self.options.get(.codeLens);
        self.applySubEditorOptionValues();
        changed[@backingInt(editor_options.EditorOption.glyphMargin)] = previous_glyph != self.options.get(.glyphMargin);
        changed[@backingInt(editor_options.EditorOption.codeLens)] = previous_code_lens != self.options.get(.codeLens);
        changed[@backingInt(editor_options.EditorOption.stickyScroll)] = !std.meta.eql(previous_sticky, self.options.get(.stickyScroll));
        // Cell rendering keeps its one-row metrics even when settings choose a
        // font size or line height; those options have no terminal meaning.
        self.options.set(.lineHeight, 1);
        self.options.set(.experimentalWhitespaceRendering, .off);
        self.options.set(.stopRenderingLineAfter, -1);
        self.syncGutterOptions();
        self.editor.setWordWrapOptions(
            self.options.get(.wordWrap),
            self.options.get(.wordWrapColumn),
            self.options.get(.wrappingIndent),
            self.options.get(.wordWrapIndicator),
        );
        self.glyph_margin_dirty = true;
        self.line_decorations_dirty = true;
        return std.mem.indexOfScalar(bool, changed, true) != null;
    }

    /// EmbeddedDiffEditorWidget inherits the parent's code-editor options,
    /// then applies its own diff/peek overrides. Geometry and read-only state
    /// belong to the child and are not copied from the parent.
    pub fn inheritEmbeddedOptions(self: *TerminalViewHost, parent: *const TerminalViewHost, changed: *terminal_editor_config.ChangeSet) void {
        self.editor.tab_focus_mode_configured = parent.editor.tab_focus_mode_configured;
        self.editor.tab_focus = parent.editor.tab_focus;
        const layout_info = self.options.layout_info;
        const wrapping_info = self.options.wrapping_info;
        self.options = parent.options;
        self.options.layout_info = layout_info;
        self.options.wrapping_info = wrapping_info;
        self.options.set(.readOnly, self.editor.isReadOnly());
        self.options.set(.folding, false);
        self.options.set(.fixedOverflowWidgets, true);
        self.options.set(.scrollBeyondLastLine, false);
        self.options.set(.allowVariableFonts, false);
        self.options.set(.allowVariableFontsInAccessibilityMode, false);
        var minimap = self.options.get(.minimap);
        minimap.enabled = false;
        self.options.set(.minimap, minimap);
        self.configured_glyph_margin = parent.configured_glyph_margin;
        self.configured_sticky_scroll = parent.configured_sticky_scroll;
        self.configured_code_lens = parent.configured_code_lens;
        self.sticky_scroll_override = false;
        self.applySubEditorOptionValues();
        self.syncGutterOptions();
        self.editor.setWordWrapOptions(self.options.get(.wordWrap), self.options.get(.wordWrapColumn), self.options.get(.wrappingIndent), self.options.get(.wordWrapIndicator));
        self.glyph_margin_dirty = true;
        self.line_decorations_dirty = true;
        @memset(changed[0..], true);
    }

    fn applySubEditorOptionValues(self: *TerminalViewHost) void {
        self.options.set(.glyphMargin, self.glyph_margin_override orelse self.configured_glyph_margin);
        var sticky = self.configured_sticky_scroll;
        sticky.enabled = self.sticky_scroll_override orelse sticky.enabled;
        self.options.set(.stickyScroll, sticky);
        self.options.set(.codeLens, self.code_lens_override orelse self.configured_code_lens);
    }

    /// A composite editor can override configured sub-editor options without
    /// replacing their underlying user settings. Report effective changes
    /// through the ordinary configuration event, including blank glyph lanes.
    pub fn setSubEditorOptionOverrides(self: *TerminalViewHost, glyph_margin: ?bool, sticky_scroll: ?bool, code_lens: ?bool, changed: *terminal_editor_config.ChangeSet) bool {
        @memset(changed, false);
        if (self.glyph_margin_override == glyph_margin and self.sticky_scroll_override == sticky_scroll and self.code_lens_override == code_lens) return false;
        const old_glyph_override = self.glyph_margin_override;
        const old_sticky_override = self.sticky_scroll_override;
        const previous_glyph = self.options.get(.glyphMargin);
        const previous_sticky = self.options.get(.stickyScroll);
        const previous_code_lens = self.options.get(.codeLens);
        self.code_lens_override = code_lens;
        self.glyph_margin_override = glyph_margin;
        self.sticky_scroll_override = sticky_scroll;
        self.editor.sticky_scroll_override = sticky_scroll;
        self.applySubEditorOptionValues();
        changed[@backingInt(editor_options.EditorOption.glyphMargin)] = previous_glyph != self.options.get(.glyphMargin) or old_glyph_override != glyph_margin;
        changed[@backingInt(editor_options.EditorOption.stickyScroll)] = !std.meta.eql(previous_sticky, self.options.get(.stickyScroll)) or old_sticky_override != sticky_scroll;
        changed[@backingInt(editor_options.EditorOption.codeLens)] = previous_code_lens != self.options.get(.codeLens);
        self.glyph_margin_dirty = true;
        self.prepareFrame();
        return true;
    }

    /// Port of `CodeEditorWidget.updateOptions({ lineNumbers })`: writes the
    /// computed option and refreshes the gutter without consulting the
    /// configuration service. Zen mode uses this for its temporary
    /// `editor.lineNumbers: off` override; `applyEditorSettings` restores the
    /// configured value when zen mode exits.
    pub fn setLineNumbersOption(self: *TerminalViewHost, render_type: editor_options.RenderLineNumbersType) bool {
        if (self.options.get(.lineNumbers).render_type == render_type) return false;
        self.options.set(.lineNumbers, .{ .render_type = render_type, .render_fn = null });
        self.syncGutterOptions();
        return true;
    }

    /// Maps the gutter-related editor options to the cell layout owned by the
    /// editor. Upstream computes the same widths in `EditorLayoutInfoComputer`.
    fn syncGutterOptions(self: *TerminalViewHost) void {
        const line_numbers = self.options.get(.lineNumbers).render_type != .Off;
        const min_chars: usize = @intCast(@max(self.options.get(.lineNumbersMinChars), 1));
        const folding = self.options.get(.folding) and
            self.options.get(.showFoldingControls) != .never;
        self.editor.setGutterOptions(line_numbers, min_chars, folding);
        // Port of `FoldingController`'s construction/configuration handler:
        // the decoration provider follows `showFoldingControls`. The
        // `foldingHighlight` option is not ported yet, so the provider keeps
        // its upstream default (`true`).
        self.folding_decorations.show_folding_controls = self.options.get(.showFoldingControls);
    }

    pub fn deinit(self: *TerminalViewHost) void {
        self.editor.removeViewEventHandler(&self.view_model_handler);
        self.view.deinit();
        self.scratch_text.deinit();
        self.scratch_inline_decorations.deinit(self.allocator);
        self.view_cursors.deinit();
        self.current_line.deinit();
        self.current_line_margin.deinit();
        self.selections_overlay.deinit();
        self.block_decorations.deinit();
        self.glyph_margin.deinit();
        self.margin_decorations.deinit();
        self.glyph_lanes.deinit();
        self.decorations_overlay.deinit();
        self.line_decorations.deinit();
        self.line_numbers.deinit();
        self.indent_guides.deinit();
        self.decorations.destroy();
        self.lines_adapter.deinit();
        self.offsets.deinit(self.allocator);
        if (self.selections.len > 0) self.allocator.free(self.selections);
        self.allocator.destroy(self);
    }

    /// Renders `[start_line, end_line]` (1-based view lines) through the ported
    /// `ViewLines`. Test hosts use this for a fixed range; the editor view uses
    /// `renderViewport`, which takes the range from the editor's `ViewLayout`.
    pub fn renderRange(self: *TerminalViewHost, start_line: usize, end_line: usize) !void {
        const count = end_line -| start_line + 1;
        try self.offsets.resize(self.allocator, count);
        for (0..count) |i| self.offsets.items[i] = @floatFromInt(i);

        const partial = view_model.IPartialViewLinesViewportData{
            .bigNumbersDelta = 0,
            .startLineNumber = start_line,
            .endLineNumber = end_line,
            .relativeVerticalOffset = self.offsets.items,
            .centeredLineNumber = start_line + count / 2,
            .completelyVisibleStartLineNumber = start_line,
            .completelyVisibleEndLineNumber = end_line,
            .lineHeight = 1,
        };
        try self.renderPartial(partial, &.{});
    }

    /// Renders the editor's current viewport. The line range and relative
    /// offsets come from the same `ViewLayout` that owns the scroll position,
    /// as upstream `ViewLayout.getLinesViewportData`.
    pub fn renderViewport(self: *TerminalViewHost) !void {
        var data = try self.editor.viewLayout().getLinesViewportData(self.allocator);
        defer data.deinit();
        const whitespace = try self.editor.viewLayout().getWhitespaceViewportData(self.allocator);
        defer self.allocator.free(whitespace);
        try self.renderPartial(data.data, whitespace);
    }

    fn renderPartial(self: *TerminalViewHost, partial: view_model.IPartialViewLinesViewportData, whitespace: []const view_model.IViewWhitespaceViewportData) !void {
        if (self.selections.len > 0) self.allocator.free(self.selections);
        self.selections = try self.editor.getViewSelections();

        if (self.first_frame) {
            self.decorations.onModelDecorationsChanged();
            self.view.getViewLines().invalidateDecorations();
            self.dispatch(.{ .ViewDecorationsChanged = .{
                .affectsMinimap = false,
                .affectsOverviewRuler = false,
                .affectsGlyphMargin = false,
                .affectsLineNumber = true,
            } });
        }
        const viewport = ViewportData.init(self.selections, partial, whitespace, self.modelInterface());
        // A viewport resize changes the visible line range without raising a
        // view event. Force the retained line window to render the new range
        // instead of keeping the old (shorter) window.
        const view_lines = self.view.getViewLines();
        if (view_lines.windowStart() != viewport.startLineNumber or
            view_lines.windowEnd() != viewport.endLineNumber)
        {
            view_lines.base.handler.forceShouldRender();
        }
        // ViewLine owns copies of its render input, so scrolling can retain
        // unchanged rendered lines instead of invalidating the whole window.
        // `ViewLines` is dirtied by the view events (scroll/tokens/decorations/
        // cursor), as upstream; do not force a full render here. The by-value
        // viewport record is refreshed every pass because the parts query it
        // after `View.renderText` returns.
        self.view.getViewLines().setViewportData(&viewport);

        // A viewport resize changes the visible range without a guide-relevant
        // view event; force the overlay to cover the new range so the last
        // rows are not left without guides.
        const guide_end_line = @min(partial.endLineNumber + 1, self.editor.viewLineCount());
        if (!self.indent_guides.coversLines(partial.startLineNumber, guide_end_line)) {
            self.indent_guides.base.handler.forceShouldRender();
        }

        self.selections_overlay.setSelections(self.selections);

        // Content, line-mapping, decoration, cursor and scroll events come
        // from the editor's view-model dispatcher. The first frame still needs
        // the current cursor/scroll state because those events predate the
        // view's handler registration.
        if (self.first_frame) self.editor.emitCurrentViewState();
        self.first_frame = false;

        // The ported `View` owns the render pass: it prepares content
        // overlays, renders `ViewLines`, collects dirty parts and clears
        // their dirty bits.
        self.scratch_text.reset();
        const ruler = &self.view.scrollbar.overview;
        ruler.setHeight(if (self.editor.scrollbar_width > 0) self.editor.textHeight() else 0);
        try self.view.renderText(&viewport, &self.scratch_text);
        if (ruler.render_error) |err| {
            ruler.render_error = null;
            ruler.base.handler.forceShouldRender();
            return err;
        }

        var rendering = RenderingContext.init(self.context.view_layout, &viewport, self.view.getViewLines().interface());
        self.view_cursors.prepareRender(&rendering);
        var restricted = RestrictedRenderingContext.init(self.context.view_layout, &viewport);
        self.view_cursors.render(&restricted);
    }

    pub fn getRenderedLine(self: *const TerminalViewHost, line_number: usize) ?*const @import("../../viewParts/viewLines/viewLine.zig").ViewLine.RenderedViewLine {
        return self.view.viewLinesConst().getRenderedViewLine(line_number);
    }

    pub fn getViewLine(self: *const TerminalViewHost, line_number: usize) ?*@import("../../viewParts/viewLines/viewLine.zig").ViewLine {
        return self.view.viewLinesConst().getViewLine(line_number);
    }

    pub fn viewLineNumberForNode(self: *const TerminalViewHost, node: *const @import("ui").Node) ?usize {
        return self.view.viewLinesConst().viewLineNumberForNode(node);
    }

    pub fn getLineWidth(self: *const TerminalViewHost, line_number: usize) usize {
        return self.view.viewLinesConst().getLineWidth(line_number);
    }

    pub fn foldingDecorations(self: *TerminalViewHost) *FoldingDecorationProvider {
        return &self.folding_decorations;
    }

    pub fn foldingDecorationsConst(self: *const TerminalViewHost) *const FoldingDecorationProvider {
        return &self.folding_decorations;
    }

    /// The ported `BlockDecorations` view part. The compositor paints the
    /// blocks it computed for the current viewport.
    pub fn blockDecorations(self: *TerminalViewHost) *BlockDecorations {
        return &self.block_decorations;
    }

    /// The ported glyph-margin overlay.
    pub fn glyphMargin(self: *TerminalViewHost) *GlyphMarginWidgets {
        return &self.glyph_margin;
    }

    pub fn addGlyphMarginWidget(self: *TerminalViewHost, widget: @import("../../editorBrowser.zig").IGlyphMarginWidget) !void {
        try self.glyph_margin.addWidget(widget);
        self.glyphWidgetsChanged();
    }

    pub fn layoutGlyphMarginWidget(self: *TerminalViewHost, widget: @import("../../editorBrowser.zig").IGlyphMarginWidget) void {
        self.glyph_margin.layoutWidget(widget);
        self.glyphWidgetsChanged();
    }

    pub fn removeGlyphMarginWidget(self: *TerminalViewHost, id: []const u8) void {
        if (self.glyph_margin.removeWidget(id)) self.glyphWidgetsChanged();
    }

    fn glyphWidgetsChanged(self: *TerminalViewHost) void {
        self.view.forceRender();
        if (self.glyph_margin_dirty) return;
        self.glyph_margin_dirty = true;
        self.editor.emitViewEvent(.{ .ViewDecorationsChanged = .{ .affectsGlyphMargin = true, .affectsLineNumber = false, .affectsMinimap = false, .affectsOverviewRuler = false } });
    }

    pub fn dispatchGlyphMarginMouse(self: *TerminalViewHost, view_line: ?usize, lane: usize, event: *ui.MouseEvent) !bool {
        return self.glyph_margin.dispatchMouse(view_line, lane, event);
    }

    /// The glyph-margin hover message for a visible line/lane, if any.
    pub fn glyphTooltipAt(self: *TerminalViewHost, view_line: usize, lane: usize) ?[]const u8 {
        if (lane >= 3) return null;
        const line = self.glyph_margin.renderedLine(view_line);
        const slot = line.lanes[lane] orelse return null;
        return slot.glyph.tooltip;
    }

    /// Managed glyph-widget hover text, independent of a decoration hover.
    pub fn glyphWidgetTooltipAt(self: *TerminalViewHost, model_line: usize, lane: @import("../../../common/model.zig").GlyphMarginLane) ?[]const u8 {
        const view_line = self.editor.viewPositionOfModelPosition(Position.init(model_line, 1)).lineNumber;
        const lanes = self.glyph_lanes.getLanesAtLine(self.allocator, model_line) catch return null;
        defer self.allocator.free(lanes);
        const column = std.mem.indexOfScalar(@TypeOf(lane), lanes, lane) orelse return null;
        if (column >= 3) return null;
        const slot = self.glyph_margin.renderedLine(view_line).lanes[column] orelse return null;
        return if (slot.widget != null) slot.glyph.tooltip else null;
    }

    /// The ported `marginClassName` overlay.
    pub fn marginDecorations(self: *TerminalViewHost) *margin_decorations_mod.MarginViewLineDecorationsOverlay {
        return &self.margin_decorations;
    }

    /// The ported content-line highlight overlay; the margin consumes its
    /// `in_margin` decision for `renderLineHighlight: gutter|all`.
    pub fn currentLine(self: *TerminalViewHost) *const CurrentLineHighlightOverlay {
        return &self.current_line;
    }

    /// The margin half of the current-line overlay (`renderLineHighlight:
    /// gutter|all`); its `in_margin` flag drives the gutter row background.
    pub fn currentLineMargin(self: *TerminalViewHost) *const CurrentLineHighlightOverlay {
        return &self.current_line_margin;
    }

    /// Applies pending decoration-dependent gutter state before the frame
    /// computes its geometry. The terminal reserves one glyph cell only while
    /// a glyph decoration exists.
    pub fn prepareFrame(self: *TerminalViewHost) void {
        if (!self.glyph_margin_dirty and !self.line_decorations_dirty) return;
        const model = self.editor.model;
        const allocator = model.getAllocator();

        if (self.glyph_margin_dirty) {
            // Upstream View._computeGlyphMarginLanes queries only authored
            // glyph margin decorations, never bracket-colorization providers.
            const margins = model.getAllMarginDecorations(0) catch return;
            defer allocator.free(margins);
            const Glyph = struct {
                range: Range,
                lane: @import("../../../common/model.zig").GlyphMarginLane,
                persist: bool = false,
                fn lessThan(_: void, a: @This(), b: @This()) bool {
                    return @import("../../../common/core/range.zig").compareRangesUsingStarts(&a.range, &b.range) < 0;
                }
            };
            var glyphs: std.ArrayList(Glyph) = .empty;
            defer glyphs.deinit(allocator);
            glyphs.ensureTotalCapacity(allocator, margins.len + self.glyph_margin.getWidgets().len) catch return;
            var max_line: usize = 0;
            for (margins) |decoration| {
                const glyph_options = decoration.options.glyphMargin;
                const range = model.validateRange(decoration.range);
                max_line = @max(max_line, range.endLineNumber);
                glyphs.appendAssumeCapacity(.{
                    .range = range,
                    .lane = if (glyph_options) |options| options.position else .Center,
                    .persist = if (glyph_options) |options| options.persistLane orelse false else false,
                });
            }
            for (self.glyph_margin.getWidgets()) |widget| {
                const range = model.validateRange(widget.preference.range);
                max_line = @max(max_line, range.endLineNumber);
                glyphs.appendAssumeCapacity(.{ .range = range, .lane = widget.preference.lane });
            }
            std.mem.sort(Glyph, glyphs.items, {}, Glyph.lessThan);
            self.glyph_lanes.reset(max_line) catch return;
            for (glyphs.items) |glyph| self.glyph_lanes.push(glyph.lane, glyph.range, glyph.persist);
            self.glyph_margin_dirty = false;
            const enabled = self.options.get(.glyphMargin);
            const lanes = @max(self.glyph_lanes.requiredLanes(), 1);
            const width = if ((glyphs.items.len != 0 or self.glyph_margin_override == true) and enabled) @min(lanes, 3) else 0;
            self.editor.setGlyphMarginWidth(width);
        }

        if (self.line_decorations_dirty) {
            // Terminal-specific cell reservation needs only the authored
            // line margin classes; dynamic inline providers cannot add one.
            const all = model.getAllLineDecorations(0) catch return;
            defer allocator.free(all);
            self.line_decorations_dirty = false;
            var has_line_decoration = false;
            for (all) |decoration| {
                const classes = decoration.options.linesDecorationsClassName orelse continue;
                var tokens = std.mem.tokenizeScalar(u8, classes, ' ');
                while (tokens.next()) |token| {
                    if (mappedLineDecorationClass(token)) {
                        has_line_decoration = true;
                        break;
                    }
                }
                if (has_line_decoration) break;
            }

            if (self.editor.lineDecorationsWidth() == 0 and has_line_decoration) {
                self.auto_line_decorations = true;
                self.editor.setLineDecorationsWidth(1);
            } else if (self.auto_line_decorations and !has_line_decoration) {
                self.auto_line_decorations = false;
                self.editor.setLineDecorationsWidth(0);
            }
        }
    }

    fn mappedLineDecorationClass(class_name: []const u8) bool {
        return std.mem.eql(u8, class_name, "insert-sign") or
            std.mem.eql(u8, class_name, "delete-sign") or
            std.mem.eql(u8, class_name, "comment-range-glyph") or
            std.mem.eql(u8, class_name, "first-line");
    }

    pub fn foldingShowsEllipsis(self: *const TerminalViewHost, model_line: usize) bool {
        const state = self.editor.foldStateAtModelLine(model_line);
        if (state == .none) return false;
        return self.folding_decorations.getDecorationOption(state == .collapsed, false, false).ellipsis;
    }

    pub const PaintGuide = struct {
        row: usize,
        column: usize,
        color: [3]u8,
    };

    pub const ViewportPaintArgs = struct {
        doc: *ui.Document,
        root: *ui.Node,
        left_cells: usize,
        width_cells: usize,
        top_row: usize,
        guides: []const PaintGuide,
        top: usize,
        text_width: usize,
        cursor: Position,
        style_fn: ViewLine.PartStyleFn,
        decoration_bits_fn: ?*const fn (classes: []const u8) u32,
        /// Per-visible-row whole-line backgrounds, indexed by `view_line - top`.
        /// A decoration background wins over the current-line highlight.
        line_backgrounds: []const ?ui.Color = &.{},
        selected_flag: u32,
        secondary_cursor_flag: u32,
        background_color: ?ui.Color,
        ellipsis_style: ui.Style,
    };

    /// Paints the visible viewport through `ViewLines`. The per-line flag,
    /// guide and fold decisions stay host-side because they are terminal paint
    /// inputs; the assembly and line DOM belong to the ported stack.
    pub fn paintViewport(self: *TerminalViewHost, args: ViewportPaintArgs) !void {
        const Context = struct {
            host: *TerminalViewHost,
            args: *const ViewportPaintArgs,
        };
        var context = Context{ .host = self, .args = &args };
        try self.view.getViewLines().paintViewport(.{
            .allocator = self.allocator,
            .doc = args.doc,
            .root = args.root,
            .left_cells = args.left_cells,
            .width_cells = args.width_cells,
            .top_row = args.top_row,
            .provider = .{ .context = &context, .get = linePaintData },
            .style_fn = args.style_fn,
            .decoration_bits_fn = args.decoration_bits_fn,
        });
    }

    fn linePaintData(context: *anyopaque, view_line: usize) anyerror!ViewLines.LinePaintData {
        const Context = struct {
            host: *TerminalViewHost,
            args: *const ViewportPaintArgs,
        };
        const ctx: *Context = @ptrCast(@alignCast(context));
        const self = ctx.host;
        const args = ctx.args;
        const editor = self.editor;

        const line_width = self.getLineWidth(view_line);
        // Keep one extra flag cell for a collapsed marker just past the last
        // rendered glyph (for example a missing `}` reported at end of line).
        // ViewLine paints those cells as underlined spaces because they have
        // no text run of their own.
        var flags_len = @max(line_width, 1);
        for (self.decorationsForLine(view_line)) |decoration| {
            const range = decoration.cell_range orelse continue;
            const end = if (range.end == std.math.maxInt(usize))
                @min(args.width_cells, editor.scrollLeft() +| args.text_width)
            else
                @min(range.end, args.width_cells);
            flags_len = @max(flags_len, end);
        }
        // Upstream's selection overlay can extend one character past the text
        // when the range crosses a newline. Keep that cell in the flag buffer so
        // `ViewLine.paint` can draw it as a styled space after the last run.
        const selection = self.getSelectionRanges(view_line);
        if (selection) |rendered| {
            for (rendered.ranges) |range| {
                if (range.width <= 0) continue;
                const start: usize = @intCast(@max(range.left, 0));
                const end = start +| @as(usize, @intCast(range.width));
                flags_len = @max(flags_len, end);
            }
        }
        const flags = try self.allocator.alloc(u32, flags_len);
        errdefer self.allocator.free(flags);
        @memset(flags, 0);

        // Range decorations (marker squiggles, range highlights and other
        // `className` decorations) are painted by the ported
        // `DecorationsOverlay`; map their visible cell ranges to the same
        // per-cell flags ViewLine uses for inline classes.
        if (args.decoration_bits_fn) |bits_fn| {
            self.applyRangeDecorationFlags(view_line, flags, bits_fn);
        }

        if (selection) |rendered| {
            for (rendered.ranges) |range| {
                if (range.width <= 0) continue;
                const start: usize = @intCast(@max(range.left, 0));
                const end = @min(start +| @as(usize, @intCast(range.width)), flags.len);
                var cell = start;
                while (cell < end and cell < flags.len) : (cell += 1) {
                    flags[cell] |= args.selected_flag;
                }
            }
        }

        const model_line = editor.modelLineNumber(view_line);
        const output_index = editor.outputLineIndex(view_line);
        markSecondaryCursors(
            self.getCursorRenderData(),
            view_line,
            flags,
            args.secondary_cursor_flag,
        );

        const row = editor.visibleRowOfViewLine(view_line) orelse std.math.maxInt(usize);
        var guide_count: usize = 0;
        for (args.guides) |guide| {
            if (guide.row == row) guide_count += 1;
        }
        const guides = try self.allocator.alloc(ViewLine.Guide, guide_count);
        errdefer self.allocator.free(guides);
        var guide_index: usize = 0;
        for (args.guides) |guide| {
            if (guide.row != row) continue;
            guides[guide_index] = .{
                .column = guide.column,
                .color = .{ .r = guide.color[0], .g = guide.color[1], .b = guide.color[2] },
            };
            guide_index += 1;
        }

        const current_line = self.getCurrentLineHighlight(view_line);
        const is_cursor_line = if (current_line) |highlight|
            highlight.highlight and highlight.in_content
        else
            view_line == args.cursor.lineNumber;

        const decoration_background = if (row < args.line_backgrounds.len)
            args.line_backgrounds[row]
        else
            null;

        return .{
            .flags = flags,
            .background = decoration_background orelse (if (is_cursor_line) args.background_color else null),
            .folded_ellipsis = output_index == 0 and line_width < args.text_width and
                self.foldingShowsEllipsis(model_line),
            .folded_ellipsis_style = args.ellipsis_style,
            .guides = guides,
        };
    }

    fn markSecondaryCursors(
        cursors: []const ViewCursorRenderData,
        view_line: usize,
        flags: []u32,
        secondary_flag: u32,
    ) void {
        for (cursors) |cursor| {
            if (cursor.plurality != .multi_secondary or cursor.position.lineNumber != view_line) continue;
            if (cursor.left < flags.len) flags[cursor.left] |= secondary_flag;
        }
    }

    pub fn getMaxLineWidth(self: *const TerminalViewHost) f64 {
        return self.view.viewLinesConst().getMaxLineWidth();
    }

    pub fn viewRef(self: *TerminalViewHost) *View {
        return &self.view;
    }

    pub fn viewConst(self: *const TerminalViewHost) *const View {
        return &self.view;
    }

    pub fn getLineNumber(self: *const TerminalViewHost, view_line: usize) ?*const RenderedLineNumber {
        return self.line_numbers.renderedLine(view_line);
    }

    /// The ported `IndentGuidesOverlay`, painted by the terminal compositor.
    pub fn indentGuides(self: *TerminalViewHost) *IndentGuidesOverlay {
        return &self.indent_guides;
    }

    /// The line-decoration classes for a view line, from the ported
    /// `LinesDecorationsOverlay`.
    pub fn lineDecorations(self: *const TerminalViewHost, view_line: usize) ?*const @import("../../viewParts/glyphMargin/glyphMargin.zig").VisibleLineDecorationsToRender {
        return self.line_decorations.renderedLine(view_line);
    }

    /// The whole-line/range decoration classes for a view line, from the ported
    /// `DecorationsOverlay`.
    pub fn decorationsForLine(self: *const TerminalViewHost, view_line: usize) []const decorations_overlay_mod.LineDecoration {
        return self.decorations_overlay.renderedLine(view_line);
    }

    /// ORs the flags for range decorations onto the line's paint flags. The
    /// class-to-flag mapping is the editor view's `decoration_bits_fn`, the same
    /// adapter `ViewLine.paint` uses for inline classes.
    fn applyRangeDecorationFlags(
        self: *const TerminalViewHost,
        view_line: usize,
        flags: []u32,
        bits_fn: *const fn (classes: []const u8) u32,
    ) void {
        for (self.decorationsForLine(view_line)) |decoration| {
            const range = decoration.cell_range orelse continue;
            const bits = bits_fn(decoration.class_name);
            if (bits == 0) continue;
            const start = @min(range.start, flags.len);
            const end = @min(range.end, flags.len);
            var cell = start;
            while (cell < end) : (cell += 1) flags[cell] |= bits;
        }
    }

    pub fn getSelectionRanges(self: *const TerminalViewHost, view_line: usize) ?*const LineSelectionRender {
        return self.selections_overlay.renderedLine(view_line);
    }

    pub fn getCurrentLineHighlight(self: *const TerminalViewHost, view_line: usize) ?*const LineHighlightRenderData {
        return self.current_line.renderedLine(view_line);
    }

    pub fn getCursorRenderData(self: *const TerminalViewHost) []const ViewCursorRenderData {
        return self.view_cursors.getLastRenderData();
    }

    /// The `IViewModel` adapter used by the terminal renderer and by
    /// contributions that render additional lines (sticky scroll).
    pub fn viewModelInterface(self: *TerminalViewHost) IViewModel {
        return self.modelInterface();
    }

    /// The `ViewLineOptions` snapshot for the current options.
    pub fn viewLineOptions(self: *const TerminalViewHost) ViewLineOptions {
        return ViewLineOptions.init(&self.configuration, self.theme.scheme);
    }

    fn overviewDecorations(context: *anyopaque, allocator: Allocator) ![]@import("../../../common/viewModel.zig").OverviewDecoration {
        const self: *TerminalViewHost = @ptrCast(@alignCast(context));
        return @import("../../../common/viewModel/viewModelImpl.zig").getAllOverviewRulerDecorations(self.editor.model, self.editor.converter.interface(), allocator);
    }

    fn modelInterface(self: *TerminalViewHost) IViewModel {
        return .{
            .context = self,
            .view_layout = self.layoutInterface(),
            .coordinates_converter = self.editor.converter.interface(),
            .get_all_overview_ruler_decorations = overviewDecorations,
            .add_view_event_handler = addViewEventHandler,
            .remove_view_event_handler = removeViewEventHandler,
            .get_selections = getSelections,
            .getLineMinColumn = getLineMinColumn,
            .getLineMaxColumn = getLineMaxColumn,
            .getLineCount = getLineCount,
            .getLineLength = getLineLength,
            .getViewportViewLineRenderingData = getViewportViewLineRenderingData,
            .getViewLineContinuesWithWrappedLine = getViewLineContinuesWithWrappedLine,
            .getDecorationsInViewport = getDecorationsInViewport,
            .getIndentSize = getIndentSize,
            .getActiveIndentGuide = getActiveIndentGuide,
            .getLinesIndentGuides = getLinesIndentGuides,
            .getBracketGuidesInRangeByLine = getBracketGuidesInRangeByLine,
        };
    }

    fn layoutInterface(self: *TerminalViewHost) IViewLayout {
        return .{
            .context = self,
            .get_scroll_width = getScrollWidth,
            .get_scroll_height = getScrollHeight,
            .get_current_viewport = getCurrentViewport,
            .get_vertical_offset_for_line_number = getVerticalOffsetBefore,
            .get_vertical_offset_after_line_number = getVerticalOffsetAfter,
            .get_line_height_for_line_number = getLineHeight,
            .set_max_line_width = setMaxLineWidth,
        };
    }

    fn host(context: *anyopaque) *TerminalViewHost {
        return @ptrCast(@alignCast(context));
    }

    fn getScrollWidth(context: *anyopaque) f64 {
        return host(context).editor.viewLayout().getScrollWidth();
    }
    fn getScrollHeight(context: *anyopaque) f64 {
        return host(context).editor.viewLayout().getScrollHeight();
    }
    fn getCurrentViewport(context: *anyopaque) view_model.Viewport {
        return host(context).editor.viewLayout().getCurrentViewport();
    }
    fn getVerticalOffsetBefore(context: *anyopaque, line_number: usize, include_view_zones: bool) f64 {
        return host(context).editor.viewLayout().getVerticalOffsetForLineNumber(line_number, include_view_zones);
    }
    fn getVerticalOffsetAfter(context: *anyopaque, line_number: usize, include_view_zones: bool) f64 {
        return host(context).editor.viewLayout().getVerticalOffsetAfterLineNumber(line_number, include_view_zones);
    }
    fn getLineHeight(context: *anyopaque, line_number: usize) f64 {
        return host(context).editor.viewLayout().getLineHeightForLineNumber(line_number);
    }
    fn setMaxLineWidth(context: *anyopaque, width: f64) void {
        host(context).max_line_width = width;
        host(context).editor.viewLayout().setMaxLineWidth(width);
    }

    fn getSelections(context: *anyopaque) []const Selection {
        return host(context).selections;
    }

    fn addViewEventHandler(context: *anyopaque, handler: *anyopaque) void {
        const self = host(context);
        self.editor.addViewEventHandler(@ptrCast(@alignCast(handler)));
    }

    fn removeViewEventHandler(context: *anyopaque, handler: *anyopaque) void {
        const self = host(context);
        self.editor.removeViewEventHandler(@ptrCast(@alignCast(handler)));
    }

    fn dispatch(self: *TerminalViewHost, event: ViewEvent) void {
        self.editor.emitViewEvent(event);
    }

    fn onEditorLineMappingChanged(context: *anyopaque, _: *const view_events.ViewLineMappingChangedEvent) bool {
        const self = host(context);
        self.decorations.onLineMappingChanged();
        return false;
    }

    fn onEditorDecorationsChanged(context: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        const self = host(context);
        self.decorations.onModelDecorationsChanged();
        self.glyph_margin_dirty = true;
        self.line_decorations_dirty = true;
        return false;
    }

    fn getLineMinColumn(context: *anyopaque, line_number: usize) usize {
        return host(context).editor.view_lines.getLineMinColumn(line_number);
    }
    fn getLineMaxColumn(context: *anyopaque, line_number: usize) usize {
        return host(context).editor.view_lines.getLineMaxColumn(line_number);
    }
    fn getLineCount(context: *anyopaque) usize {
        return host(context).editor.viewLineCount();
    }
    fn getLineLength(context: *anyopaque, line_number: usize) usize {
        const data = host(context).editor.viewLineData(line_number) catch return 0;
        return data.content.len;
    }
    fn getViewportViewLineRenderingData(context: *anyopaque, visible_range: Range, line_number: usize) anyerror!view_model.ViewLineRenderingData {
        const self = host(context);
        const data = try self.editor.viewLineData(line_number);

        var inline_decorations: []const InlineDecoration = &.{};
        var has_variable_fonts = false;
        const collection = try self.decorations.getDecorationsViewportData(visible_range);
        const line_index = line_number -| visible_range.startLineNumber;
        if (line_index < collection.inlineDecorations.len) {
            inline_decorations = collection.inlineDecorations[line_index];
        }
        if (line_index < collection.hasVariableFonts.len) {
            has_variable_fonts = collection.hasVariableFonts[line_index];
        }
        if (data.inlineDecorations) |injected| {
            self.scratch_inline_decorations.clearRetainingCapacity();
            try self.scratch_inline_decorations.appendSlice(self.allocator, inline_decorations);
            try self.scratch_inline_decorations.appendSlice(self.allocator, injected);
            inline_decorations = self.scratch_inline_decorations.items;
        }

        return view_model.ViewLineRenderingData.init(
            data.minColumn,
            data.maxColumn,
            data.content,
            data.continuesWithWrappedLine,
            false,
            false,
            data.tokens,
            inline_decorations,
            self.editor.tabSize(),
            data.startVisibleColumn,
            TextDirection.LTR,
            has_variable_fonts,
        );
    }
    fn getViewLineContinuesWithWrappedLine(context: *anyopaque, line_number: usize) bool {
        const data = host(context).editor.viewLineData(line_number) catch return false;
        return data.continuesWithWrappedLine;
    }
    fn getIndentSize(context: *anyopaque) usize {
        return host(context).editor.model.getOptions().indentSize;
    }
    fn getActiveIndentGuide(context: *anyopaque, line_number: usize, min_line_number: usize, max_line_number: usize) anyerror!IActiveIndentGuideInfo {
        return host(context).editor.view_lines.getActiveIndentGuide(line_number, min_line_number, max_line_number);
    }
    fn getLinesIndentGuides(context: *anyopaque, start_line_number: usize, end_line_number: usize, allocator: Allocator) anyerror![]usize {
        return host(context).editor.view_lines.getViewLinesIndentGuides(allocator, start_line_number, end_line_number);
    }
    fn getBracketGuidesInRangeByLine(context: *anyopaque, start_line_number: usize, end_line_number: usize, active_position: ?Position, options: BracketGuideOptions, allocator: Allocator) anyerror![]LineGuides {
        return host(context).editor.view_lines.getViewLinesBracketGuides(
            allocator,
            start_line_number,
            end_line_number,
            active_position,
            options,
        );
    }
    fn getDecorationsInViewport(context: *anyopaque, visible_range: Range, allocator: Allocator) anyerror![]view_model.ViewModelDecoration {
        const self = host(context);
        const converter = self.editor.converter.interface();
        const model_range = converter.convertViewRangeToModelRange(converter.context, visible_range);
        const decorations = try self.editor.model.getDecorationsInRange(model_range, 0, false, false, false);
        defer self.editor.allocator.free(decorations);
        const result = try allocator.alloc(view_model.ViewModelDecoration, decorations.len);
        for (decorations, 0..) |decoration, index| {
            result[index] = .{
                .range = converter.convertModelRangeToViewRange(converter.context, decoration.range, .None),
                .options = decoration.options,
            };
        }
        return result;
    }
};

test "terminal view host renders lines through the ported ViewLines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\tb\nsecond", "test.zig", 40, 8);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    try host.renderRange(1, 2);
    try std.testing.expectEqual(@as(usize, 5), host.view.getViewLines().getLineWidth(1));
    try std.testing.expectEqual(@as(usize, 6), host.view.getViewLines().getLineWidth(2));
    try std.testing.expectEqual(@as(f64, 6), host.getMaxLineWidth());
    try std.testing.expectEqual(@as(f64, 6), host.max_line_width);

    const first = host.getRenderedLine(1).?;
    try std.testing.expectEqualStrings("a   b", first.rendered.bytes);
    const second = host.getRenderedLine(2).?;
    try std.testing.expectEqualStrings("second", second.rendered.bytes);

    // The gutter text comes from the ported `LineNumbersOverlay`.
    try std.testing.expectEqualStrings("1", host.getLineNumber(1).?.text);
    try std.testing.expectEqualStrings("2", host.getLineNumber(2).?.text);

    // The current-line overlay owns the cursor-line highlight decision.
    const highlight = host.getCurrentLineHighlight(1).?;
    try std.testing.expect(highlight.highlight);
    try std.testing.expect(highlight.in_content);

    // The cursor overlay reports the primary cursor in view coordinates.
    const cursors = host.getCursorRenderData();
    try std.testing.expect(cursors.len > 0);
    try std.testing.expectEqual(@as(usize, 1), cursors[0].position.lineNumber);
}

test "terminal view host selects wrapped continuation lines" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // Gutter is six columns, so this wraps at five text columns:
    // abcde / fghij.
    const editor = try Editor.createFromText(allocator, io, "abcdefghij", "test.txt", 11, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    try host.renderRange(1, 2);
    try editor.setSelection(Range.init(1, 1, 1, 11));
    try host.renderRange(1, 2);

    // Selection columns are view columns: the continuation view line starts at
    // column 1, so both visual rows are covered from their first cell.
    const first = host.getSelectionRanges(1).?;
    try std.testing.expectEqual(@as(usize, 1), first.ranges.len);
    try std.testing.expectEqual(@as(i32, 0), first.ranges[0].left);
    try std.testing.expectEqual(@as(i32, 5), first.ranges[0].width);

    const second = host.getSelectionRanges(2).?;
    try std.testing.expectEqual(@as(usize, 1), second.ranges.len);
    try std.testing.expectEqual(@as(i32, 0), second.ranges[0].left);
    try std.testing.expectEqual(@as(i32, 5), second.ranges[0].width);

    const view_lines = host.viewRef().getViewLines();
    const visible = view_lines.linesVisibleRangesForRange(Range.init(1, 1, 2, 6), true).?;
    try std.testing.expectEqual(@as(usize, 2), visible.len);
    try std.testing.expect(visible[0].continuesOnNextLine);
    try std.testing.expect(!visible[1].continuesOnNextLine);

    // The same mapping is used for hit testing inside a wrapped line.
    const position = view_lines.visibleRangeForPosition(Position.init(2, 2)).?;
    try std.testing.expectEqual(@as(i32, 1), position.left);
}

test "terminal view host widens selection into a model line break" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "abc\ndef", "test.txt", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    try host.renderRange(1, 2);
    try editor.setSelection(Range.init(1, 2, 2, 2));
    try host.renderRange(1, 2);

    // Upstream adds one character width on the line before a model line break,
    // so the newline is part of the selected region.
    const first = host.getSelectionRanges(1).?;
    try std.testing.expectEqual(@as(usize, 1), first.ranges.len);
    try std.testing.expectEqual(@as(i32, 1), first.ranges[0].left);
    try std.testing.expectEqual(@as(i32, 3), first.ranges[0].width);

    const second = host.getSelectionRanges(2).?;
    try std.testing.expectEqual(@as(usize, 1), second.ranges.len);
    try std.testing.expectEqual(@as(i32, 0), second.ranges[0].left);
    try std.testing.expectEqual(@as(i32, 1), second.ranges[0].width);
}

test "terminal view host updates the current-line overlay on cursor moves" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "a\nb", "test.zig", 20, 4);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    try host.renderRange(1, 2);
    try std.testing.expect(host.getCurrentLineHighlight(1).?.highlight);
    try std.testing.expect(!host.getCurrentLineHighlight(2).?.highlight);

    try editor.moveDown(false);
    try host.renderRange(1, 2);
    try std.testing.expect(!host.getCurrentLineHighlight(1).?.highlight);
    try std.testing.expect(host.getCurrentLineHighlight(2).?.highlight);
}

test "terminal view host receives cursor and scroll events from the editor" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo\nthree", "test.zig", 40, 2);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    const Counter = struct {
        cursors: usize = 0,
        scrolls: usize = 0,

        fn onCursor(context: *anyopaque, _: *const view_events.ViewCursorStateChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cursors += 1;
            return false;
        }
        fn onScroll(context: *anyopaque, _: *const view_events.ViewScrollChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.scrolls += 1;
            return false;
        }
    };
    var counter = Counter{};
    var handler = ViewEventHandler.init(&counter, .{
        .onCursorStateChanged = Counter.onCursor,
        .onScrollChanged = Counter.onScroll,
    });
    editor.addViewEventHandler(&handler);
    defer editor.removeViewEventHandler(&handler);

    try host.renderRange(1, 2);
    counter.cursors = 0;
    counter.scrolls = 0;

    try editor.moveDown(false);
    try std.testing.expect(counter.cursors > 0);

    counter.scrolls = 0;
    try std.testing.expect(editor.scrollViewLines(1));
    try std.testing.expect(counter.scrolls > 0);
}

test "terminal view host dispatches ViewDecorationsChanged when the model generation changes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.zig", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    const Counter = struct {
        decorations: usize = 0,
        fn onDecorations(ctx: *anyopaque, _: *const @import("../../../common/viewEvents.zig").ViewDecorationsChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.decorations += 1;
            return false;
        }
    };
    var counter = Counter{};
    var handler = @import("../../../common/viewEventHandler.zig").ViewEventHandler.init(&counter, .{
        .onDecorationsChanged = Counter.onDecorations,
    });
    editor.addViewEventHandler(&handler);
    defer editor.removeViewEventHandler(&handler);

    try host.renderRange(1, 2);
    // The first frame dispatches for the initial decoration generation.
    const before = counter.decorations;
    try std.testing.expect(before >= 1);

    var options = @import("../../../common/model.zig").ModelDecorationOptions.init("line-insert", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "line-insert";
    options.linesDecorationsClassName = "dirty-diff-glyph dirty-diff-added primary";
    options.isWholeLine = true;
    const delta = [_]@import("../../../common/model.zig").ModelDeltaDecoration{.{
        .range = Range.init(1, 1, 1, 1),
        .options = &options,
    }};
    const ids = try editor.model.deltaDecorations(&.{}, &delta, 70);
    defer std.testing.allocator.free(ids);

    try host.renderRange(1, 2);
    try std.testing.expect(counter.decorations > before);

    // Both decoration overlays are registered and expose the prepared data.
    var found_line_decorations = false;
    var found_whole_line = false;
    for (host.view.content_overlays.items) |overlay| {
        if (overlay == &host.line_decorations.base) found_line_decorations = true;
        if (overlay == &host.decorations_overlay.base) found_whole_line = true;
    }
    try std.testing.expect(found_line_decorations);
    try std.testing.expect(found_whole_line);
    try std.testing.expect(host.lineDecorations(1) != null);
    try std.testing.expectEqual(@as(usize, 1), host.decorationsForLine(1).len);
    try std.testing.expectEqualStrings("line-insert", host.decorationsForLine(1)[0].class_name);
}

test "terminal view host exposes marker range cell decorations" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const editor = try Editor.createFromText(allocator, io, "one\ntwo", "test.zig", 40, 5);
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }

    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();

    var options = @import("../../../common/model.zig").ModelDecorationOptions.init("squiggly-error", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "squiggly-error";
    options.showIfCollapsed = true;
    const delta = [_]@import("../../../common/model.zig").ModelDeltaDecoration{.{
        .range = Range.init(1, 2, 1, 4),
        .options = &options,
    }};
    const ids = try editor.model.deltaDecorations(&.{}, &delta, 71);
    defer allocator.free(ids);

    try host.renderRange(1, 2);

    const line = host.decorationsForLine(1);
    try std.testing.expectEqual(@as(usize, 1), line.len);
    try std.testing.expectEqualStrings("squiggly-error", line[0].class_name);
    const range = line[0].cell_range.?;
    try std.testing.expectEqual(@as(usize, 1), range.start);
    try std.testing.expectEqual(@as(usize, 3), range.end);
}

test "overview ruler ignores unrelated view events and updates on ruler decorations" {
    const allocator = std.testing.allocator;
    const editor = try Editor.createFromTextWithOptions(allocator, std.Io.Threaded.global_single_threaded.io(), "one\ntwo\nthree\nfour\nfive\nsix", "ruler.txt", 40, 4, .{ .reserve_scrollbar = true });
    defer {
        editor.deinit();
        allocator.destroy(editor);
    }
    const host = try TerminalViewHost.init(allocator, editor);
    defer host.deinit();
    try host.renderViewport();
    const ruler = &host.view.scrollbar.overview;
    try std.testing.expect(!ruler.base.handler.shouldRender());
    _ = editor.scrollViewLines(1);
    try std.testing.expect(!ruler.base.handler.shouldRender());

    const model = @import("../../../common/model.zig");
    var plain = model.ModelDecorationOptions.init("inline", .AlwaysGrowsWhenTypingAtEdges);
    plain.inlineClassName = "test";
    const plain_ids = try editor.model.deltaDecorations(&.{}, &.{.{ .range = Range.init(1, 1, 1, 2), .options = &plain }}, 0);
    defer allocator.free(plain_ids);
    try std.testing.expect(!ruler.base.handler.shouldRender());
    var highlighted = model.ModelDecorationOptions.init("ruler", .AlwaysGrowsWhenTypingAtEdges);
    highlighted.overviewRuler = .{ .position = .Right, .color = .{ 25, 40, 80 } };
    const ids = try editor.model.deltaDecorations(&.{}, &.{.{ .range = Range.init(5, 1, 5, 2), .options = &highlighted }}, 0);
    defer allocator.free(ids);
    try std.testing.expect(ruler.base.handler.shouldRender());
    try host.renderViewport();
    try std.testing.expectEqual(@as(usize, 1), ruler.decorations.len);
    for (ruler.rows) |row| {
        if (row) |marker| if (std.meta.eql(marker.color, [3]u8{ 25, 40, 80 })) return;
    }
    return error.MissingOverviewMarker;
}

test "TerminalViewHost: margin geometry does not materialize bracket decorations" {
    const a = std.testing.allocator;
    const editor = try Editor.createFromText(a, std.testing.io, "const x = (1);\nconst y = (2);", "test.zig", 70, 8);
    defer {
        editor.deinit();
        a.destroy(editor);
    }
    var options = @import("../../../common/model.zig").ModelDecorationOptions.init("insert-line", .AlwaysGrowsWhenTypingAtEdges);
    options.linesDecorationsClassName = "insert-sign";
    const ids = try editor.model.deltaDecorations(&.{}, &.{.{ .range = Range.init(2, 1, 2, 1), .options = &options }}, 0);
    defer a.free(ids);
    const host = try TerminalViewHost.init(a, editor);
    defer host.deinit();
    const brackets = editor.model.bracketPairs();
    try std.testing.expect(brackets._dirty);
    host.prepareFrame();
    try std.testing.expect(brackets._dirty);
    try std.testing.expectEqual(@as(usize, 1), editor.lineDecorationsWidth());
}

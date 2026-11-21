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
const view_mod = @import("../../view.zig");
const StringBuilder = @import("../../../common/core/stringBuilder.zig").StringBuilder;
const view_model_decorations = @import("../../../common/viewModel/viewModelDecorations.zig");
const line_numbers_mod = @import("../../viewParts/lineNumbers/lineNumbers.zig");
const selections_mod = @import("../../viewParts/selections/selections.zig");
const current_line_mod = @import("../../viewParts/currentLineHighlight/currentLineHighlight.zig");
const view_cursors_mod = @import("../../viewParts/viewCursors/viewCursors.zig");
const folding_decorations_mod = @import("../../../contrib/folding/browser/foldingDecorations.zig");
const lines_decorations_mod = @import("../../viewParts/linesDecorations/linesDecorations.zig");
const decorations_overlay_mod = @import("../../viewParts/decorations/decorations.zig");
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

const IViewModel = view_model.IViewModel;
const IViewLayout = view_model.IViewLayout;
const ViewportData = viewport_data.ViewportData;
const ViewLines = view_lines_mod.ViewLines;
const View = view_mod.View;
const ViewEventHandler = view_event_handler.ViewEventHandler;
const ViewEvent = view_events.ViewEvent;
const ViewModelDecorations = view_model_decorations.ViewModelDecorations;
const LineNumbersOverlay = line_numbers_mod.LineNumbersOverlay;
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
const CursorState = @import("../../../common/cursorCommon.zig").CursorState;
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;
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
    decorations: *ViewModelDecorations,
    line_numbers: LineNumbersOverlay,
    line_decorations: LinesDecorationsOverlay,
    decorations_overlay: DecorationsOverlay,
    selections_overlay: SelectionsOverlay,
    current_line: CurrentLineHighlightOverlay,
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
            .line_decorations = undefined,
            .decorations_overlay = undefined,
            .selections_overlay = undefined,
            .current_line = undefined,
            .view_cursors = undefined,
            .lines_adapter = undefined,
        };

        self.options.set(.lineHeight, 1);
        self.options.set(.experimentalWhitespaceRendering, .off);
        self.options.set(.renderWhitespace, .none);
        self.options.set(.stopRenderingLineAfter, -1);
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
        self.view.init(allocator, &self.context);
        self.scratch_text = try StringBuilder.init(allocator, 256);
        self.line_numbers.init(allocator, &self.context);
        self.line_decorations.init(allocator, &self.context);
        self.decorations_overlay.init(allocator, &self.context);
        self.selections_overlay.init(allocator, &self.context);
        self.current_line.initContent(allocator, &self.context);
        self.view_cursors.init(allocator, &self.context);

        // The ported `View` coordinates the render pass. Register the overlays
        // as content overlays exactly like upstream `ContentViewOverlays`.
        try self.view.addContentOverlay(&self.line_numbers.base);
        try self.view.addContentOverlay(&self.line_decorations.base);
        try self.view.addContentOverlay(&self.decorations_overlay.base);
        try self.view.addContentOverlay(&self.selections_overlay.base);
        try self.view.addContentOverlay(&self.current_line.base);

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
        const any = terminal_editor_config.applyViewSettings(&self.options, reader, language_id, resource, changed);
        // Cell rendering keeps its one-row metrics even when settings choose a
        // font size or line height; those options have no terminal meaning.
        self.options.set(.lineHeight, 1);
        self.options.set(.experimentalWhitespaceRendering, .off);
        self.options.set(.stopRenderingLineAfter, -1);
        return any;
    }

    pub fn deinit(self: *TerminalViewHost) void {
        self.editor.removeViewEventHandler(&self.view_model_handler);
        self.view.deinit();
        self.scratch_text.deinit();
        self.view_cursors.deinit();
        self.current_line.deinit();
        self.selections_overlay.deinit();
        self.decorations_overlay.deinit();
        self.line_decorations.deinit();
        self.line_numbers.deinit();
        self.decorations.destroy();
        self.lines_adapter.deinit();
        self.offsets.deinit(self.allocator);
        if (self.selections.len > 0) self.allocator.free(self.selections);
        self.allocator.destroy(self);
    }

    /// Renders `[start_line, end_line]` (1-based view lines) through the ported
    /// `ViewLines`. The model is expected to have a viewport of that size.
    pub fn renderRange(self: *TerminalViewHost, start_line: usize, end_line: usize) !void {
        const count = end_line -| start_line + 1;
        try self.offsets.resize(self.allocator, count);
        for (0..count) |i| self.offsets.items[i] = @floatFromInt(i);

        if (self.selections.len > 0) self.allocator.free(self.selections);
        self.selections = try self.editor.getViewSelections();

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
        const viewport = ViewportData.init(self.selections, partial, &.{}, self.modelInterface());
        // ViewLine owns copies of its render input, so scrolling can retain
        // unchanged rendered lines instead of invalidating the whole window.
        // The viewport is a stack value, so `ViewLines.last_viewport` must be
        // refreshed on every pass before overlays query it.
        self.view.getViewLines().forceShouldRender();

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
        try self.view.renderText(&viewport, &self.scratch_text);

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
        tab_size: usize,
        text_width: usize,
        cursor: Position,
        states: []const CursorState,
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
        const flags = try self.allocator.alloc(u32, @max(line_width, 1));
        errdefer self.allocator.free(flags);
        @memset(flags, 0);

        if (self.getSelectionRanges(view_line)) |selection| {
            for (selection.ranges) |range| {
                if (range.width <= 0) continue;
                const start: usize = @intCast(@max(range.left, 0));
                const end = @min(start +| @as(usize, @intCast(range.width)), flags.len);
                var cell = start;
                while (cell < end and cell < flags.len) : (cell += 1) {
                    flags[cell] |= args.selected_flag;
                }
            }
        }

        const data = try editor.viewLineData(view_line);
        const model_line = editor.modelLineNumber(view_line);
        const output_index = editor.outputLineIndex(view_line);
        var model_content = try editor.model.getLineContent(model_line);
        defer model_content.deinit();
        markSecondaryCursors(
            args.states,
            view_line,
            model_content.items,
            args.tab_size,
            data.startVisibleColumn,
            data.minColumn - 1,
            flags,
            args.secondary_cursor_flag,
        );

        const row = view_line -| args.top;
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
        states: []const CursorState,
        view_line: usize,
        model_content: []const u8,
        tab_size: usize,
        start_visible_column: usize,
        indent_cells: usize,
        flags: []u32,
        secondary_flag: u32,
    ) void {
        if (states.len > 1) {
            for (states[1..]) |state| {
                const position = state.viewState.position;
                if (position.lineNumber != view_line) continue;
                const cell = visibleOffset(model_content, position.column, tab_size, start_visible_column, indent_cells);
                if (cell < flags.len) flags[cell] |= secondary_flag;
            }
        }
    }

    pub fn visibleOffset(
        model_content: []const u8,
        column: usize,
        tab_size: usize,
        start_visible_column: usize,
        indent_cells: usize,
    ) usize {
        const visible = CursorColumns.visibleColumnFromColumn(model_content, column, tab_size);
        return (visible -| start_visible_column) + indent_cells;
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

    pub fn getSelectionRanges(self: *const TerminalViewHost, view_line: usize) ?*const LineSelectionRender {
        return self.selections_overlay.renderedLine(view_line);
    }

    pub fn getCurrentLineHighlight(self: *const TerminalViewHost, view_line: usize) ?*const LineHighlightRenderData {
        return self.current_line.renderedLine(view_line);
    }

    pub fn getCursorRenderData(self: *const TerminalViewHost) []const ViewCursorRenderData {
        return self.view_cursors.getLastRenderData();
    }

    fn modelInterface(self: *TerminalViewHost) IViewModel {
        return .{
            .context = self,
            .view_layout = self.layoutInterface(),
            .coordinates_converter = self.editor.converter.interface(),
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
        return @floatFromInt(host(context).editor.textAreaWidth());
    }
    fn getScrollHeight(context: *anyopaque) f64 {
        return @floatFromInt(host(context).editor.scrollHeight());
    }
    fn getCurrentViewport(context: *anyopaque) view_model.Viewport {
        const self = host(context);
        return view_model.Viewport.init(
            @floatFromInt(self.editor.topViewLine() -| 1),
            0,
            @floatFromInt(self.editor.textAreaWidth()),
            @floatFromInt(self.editor.textHeight()),
        );
    }
    fn getVerticalOffsetBefore(context: *anyopaque, line_number: usize, _: bool) f64 {
        _ = host(context);
        return @floatFromInt(line_number -| 1);
    }
    fn getVerticalOffsetAfter(context: *anyopaque, line_number: usize, _: bool) f64 {
        _ = host(context);
        return @floatFromInt(line_number);
    }
    fn getLineHeight(context: *anyopaque, _: usize) f64 {
        _ = host(context);
        return 1;
    }
    fn setMaxLineWidth(context: *anyopaque, width: f64) void {
        host(context).max_line_width = width;
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

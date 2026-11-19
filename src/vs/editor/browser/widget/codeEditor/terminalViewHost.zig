// Terminal adapter that exposes the terminal `Editor` through the upstream
// `IViewModel`/`IViewLayout`/`IEditorConfiguration` contracts so the ported
// `ViewLines` stack can render it.
//
// This is the wiring seam for replacing the collapsed terminal renderer: the
// model stays in `Editor`, while `ViewLines` owns line layout, dirty tracking,
// decoration normalization and width bookkeeping exactly as upstream.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Editor = @import("./codeEditorWidgetTerminal.zig").Editor;
const view_model = @import("../../../common/viewModel.zig");
const view_events = @import("../../../common/viewEvents.zig");
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
const restricted_context = @import("../../view/renderingContext.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const browser_config = @import("../../config/editorConfiguration.zig");
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
const ViewModelDecorations = view_model_decorations.ViewModelDecorations;
const LineNumbersOverlay = line_numbers_mod.LineNumbersOverlay;
const RenderedLineNumber = line_numbers_mod.RenderedLineNumber;
const RenderingContext = rendering_context.RenderingContext;
const SelectionsOverlay = selections_mod.SelectionsOverlay;
const LineSelectionRender = selections_mod.LineSelectionRender;
const CurrentLineHighlightOverlay = current_line_mod.CurrentLineHighlightOverlay;
const LineHighlightRenderData = current_line_mod.LineHighlightRenderData;
const ViewCursors = view_cursors_mod.ViewCursors;
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
    selections_overlay: SelectionsOverlay,
    current_line: CurrentLineHighlightOverlay,
    view_cursors: ViewCursors,
    lines_adapter: LinesAdapter,
    offsets: std.ArrayListUnmanaged(f64) = .empty,
    selections: []Selection = &.{},
    max_line_width: f64 = 0,

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
        self.selections_overlay.init(allocator, &self.context);
        self.current_line.initContent(allocator, &self.context);
        self.view_cursors.init(allocator, &self.context);

        // The ported `View` coordinates the render pass. Register the overlays
        // as content overlays exactly like upstream `ContentViewOverlays`.
        try self.view.addContentOverlay(&self.line_numbers.base);
        try self.view.addContentOverlay(&self.selections_overlay.base);
        try self.view.addContentOverlay(&self.current_line.base);
        return self;
    }

    pub fn deinit(self: *TerminalViewHost) void {
        self.view.deinit();
        self.scratch_text.deinit();
        self.view_cursors.deinit();
        self.current_line.deinit();
        self.selections_overlay.deinit();
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
        self.decorations.onModelDecorationsChanged();
        const viewport = ViewportData.init(self.selections, partial, &.{}, self.modelInterface());
        // The terminal view model owns one reusable line-content buffer.
        // Retained render inputs would point at the previous line's data.
        self.view.getViewLines().invalidateRenderedInputs();
        // The viewport is a stack value, so `ViewLines.last_viewport` must be
        // refreshed on every pass before overlays query it.
        self.view.getViewLines().forceShouldRender();

        self.selections_overlay.setSelections(self.selections);
        const cursor_event = view_events.ViewCursorStateChangedEvent{
            .selections = self.selections,
            .modelSelections = self.selections,
            .reason = .NotSet,
        };
        _ = self.current_line.base.handler.onCursorStateChanged(&cursor_event);
        _ = self.view_cursors.base.handler.onCursorStateChanged(&cursor_event);

        // The terminal host has no view-event dispatch loop yet, so every
        // overlay is dirty per frame. Upstream marks them dirty through the
        // view event handler when the viewport or folding changes.
        self.line_numbers.base.handler.forceShouldRender();
        self.selections_overlay.base.handler.forceShouldRender();
        self.current_line.base.handler.forceShouldRender();

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

    pub fn getMaxLineWidth(self: *const TerminalViewHost) f64 {
        return self.view.viewLinesConst().getMaxLineWidth();
    }

    pub fn getLineNumber(self: *const TerminalViewHost, view_line: usize) ?*const RenderedLineNumber {
        return self.line_numbers.renderedLine(view_line);
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

    fn addViewEventHandler(_: *anyopaque, _: *anyopaque) void {}
    fn removeViewEventHandler(_: *anyopaque, _: *anyopaque) void {}
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
    fn getDecorationsInViewport(context: *anyopaque, _: Range, allocator: Allocator) anyerror![]view_model.ViewModelDecoration {
        _ = host(context);
        return allocator.alloc(view_model.ViewModelDecoration, 0);
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

// Port of the orchestration subset of `src/vs/editor/browser/view.ts`.
//
// Terminal adaptation: there is no DOM, edit context, pointer handler,
// animation-frame scheduler or GPU context. The terminal `View` owns the
// ported view parts/overlays, broadcasts view events across them, and drives
// the text render pipeline (`prepareRender` -> `viewLines.renderText` ->
// part render). The TUI compositor paints the parts' structured data; this
// class provides the upstream-shaped container and event fan-out.
const std = @import("std");
const Allocator = std.mem.Allocator;

const render_ctx = @import("./view/renderingContext.zig");
const view_part_mod = @import("./view/viewPart.zig");
const dynamic_overlay_mod = @import("./view/dynamicViewOverlay.zig");
const view_context_mod = @import("../common/viewModel/viewContext.zig");
const view_events = @import("../common/viewEvents.zig");
const viewport_data = @import("../common/viewLayout/viewLinesViewportData.zig");
const StringBuilder = @import("../common/core/stringBuilder.zig").StringBuilder;
const view_lines_mod = @import("./viewParts/viewLines/viewLines.zig");
const content_widgets_mod = @import("./viewParts/contentWidgets/contentWidgets.zig");
const overlay_widgets_mod = @import("./viewParts/overlayWidgets/overlayWidgets.zig");
const margin_mod = @import("./viewParts/margin/margin.zig");
const editor_scrollbar_mod = @import("./viewParts/editorScrollbar/editorScrollbar.zig");
const view_event_handler = @import("../common/viewEventHandler.zig");
const ViewEventHandler = view_event_handler.ViewEventHandler;
const ViewEvent = view_events.ViewEvent;
const Position = @import("../common/core/position.zig").Position;
const PositionAffinity = @import("../common/model.zig").PositionAffinity;

const RenderingContext = render_ctx.RenderingContext;
const RestrictedRenderingContext = render_ctx.RestrictedRenderingContext;
const ViewPart = view_part_mod.ViewPart;
const DynamicViewOverlay = dynamic_overlay_mod.DynamicViewOverlay;
const ViewContext = view_context_mod.ViewContext;
const ViewportData = viewport_data.ViewportData;
const ViewLines = view_lines_mod.ViewLines;
const ViewContentWidgets = content_widgets_mod.ViewContentWidgets;
const ViewOverlayWidgets = overlay_widgets_mod.ViewOverlayWidgets;
const TerminalMargin = margin_mod.TerminalMargin;
const TerminalScrollbar = editor_scrollbar_mod.TerminalScrollbar;
const IContentWidget = @import("./editorBrowser.zig").IContentWidget;
const IOverlayWidget = @import("./editorBrowser.zig").IOverlayWidget;

/// Terminal `View`: owns the view lines, view parts and dynamic overlays, and
/// fans view events out to them.
pub const View = struct {
    allocator: Allocator,
    context: *ViewContext,
    view_lines: ViewLines,
    content_widgets: ViewContentWidgets,
    overlay_widgets: ViewOverlayWidgets,
    margin: TerminalMargin,
    scrollbar: TerminalScrollbar,
    view_parts: std.array_list.Managed(*ViewPart),
    content_overlays: std.array_list.Managed(*DynamicViewOverlay),
    is_focused: bool = false,
    handler: ViewEventHandler = .{},
    should_render: bool = true,

    pub fn init(self: *View, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .allocator = allocator,
            .context = context,
            .view_lines = undefined,
            .content_widgets = ViewContentWidgets.init(allocator),
            .overlay_widgets = ViewOverlayWidgets.init(allocator),
            .margin = .{},
            .scrollbar = TerminalScrollbar.init(allocator),
            .view_parts = std.array_list.Managed(*ViewPart).init(allocator),
            .content_overlays = std.array_list.Managed(*DynamicViewOverlay).init(allocator),
        };
        self.view_lines.init(allocator, context);
        self.handler = ViewEventHandler.init(self, handlerCallbacks());
        context.addEventHandler(&self.handler);
    }

    pub fn deinit(self: *View) void {
        self.context.removeEventHandler(&self.handler);
        self.view_lines.deinit();
        self.content_widgets.deinit();
        self.overlay_widgets.deinit();
        self.margin = .{};
        self.scrollbar.deinit();
        self.view_parts.deinit();
        self.content_overlays.deinit();
    }

    pub fn addViewPart(self: *View, part: *ViewPart) !void {
        try self.view_parts.append(part);
    }

    pub fn addContentOverlay(self: *View, overlay: *DynamicViewOverlay) !void {
        try self.content_overlays.append(overlay);
    }

    pub fn getViewLines(self: *View) *ViewLines {
        return &self.view_lines;
    }

    pub fn viewLinesConst(self: *const View) *const ViewLines {
        return &self.view_lines;
    }
    /// Port of `View.addContentWidget`/`removeContentWidget`.
    pub fn addContentWidget(self: *View, widget: IContentWidget) !void {
        try self.content_widgets.add(widget);
    }

    pub fn removeContentWidget(self: *View, id: []const u8) bool {
        return self.content_widgets.remove(id);
    }

    /// Port of `View.addOverlayWidget`/`removeOverlayWidget`.
    pub fn addOverlayWidget(self: *View, widget: IOverlayWidget) !void {
        try self.overlay_widgets.add(widget);
    }

    pub fn removeOverlayWidget(self: *View, id: []const u8) bool {
        return self.overlay_widgets.remove(id);
    }

    pub fn contentWidgets(self: *View) *ViewContentWidgets {
        return &self.content_widgets;
    }

    pub fn contentWidgetsConst(self: *const View) *const ViewContentWidgets {
        return &self.content_widgets;
    }

    pub fn overlayWidgets(self: *View) *ViewOverlayWidgets {
        return &self.overlay_widgets;
    }

    pub fn overlayWidgetsConst(self: *const View) *const ViewOverlayWidgets {
        return &self.overlay_widgets;
    }
    pub fn marginPart(self: *View) *TerminalMargin {
        return &self.margin;
    }

    pub fn scrollbarPart(self: *View) *TerminalScrollbar {
        return &self.scrollbar;
    }

    pub fn scrollbarPartConst(self: *const View) *const TerminalScrollbar {
        return &self.scrollbar;
    }

    /// Port of upstream `View._getViewPartsToRender`: the view parts that
    /// currently need a render pass. The caller owns the returned slice.
    pub fn getViewPartsToRender(self: *View, allocator: Allocator) ![]*ViewPart {
        var result = std.array_list.Managed(*ViewPart).init(allocator);
        errdefer result.deinit();
        for (self.view_parts.items) |part| {
            if (part.handler.shouldRender()) try result.append(part);
        }
        return result.toOwnedSlice();
    }

    /// Port of upstream `View.getLineWidth`, in terminal cells. Model line
    /// numbers are converted to view lines exactly like upstream.
    pub fn getLineWidth(self: *View, model_line_number: usize) usize {
        const converter = self.context.view_model.coordinates_converter;
        const model_position = Position.init(model_line_number, self.context.view_model.lineMaxColumn(model_line_number));
        const view_position = converter.convertModelPositionToViewPosition(
            converter.context,
            model_position,
            .None,
            false,
            false,
        );
        return self.view_lines.getLineWidth(view_position.lineNumber);
    }

    /// Port of upstream `View.resetLineWidthCaches`.
    pub fn resetLineWidthCaches(self: *View) void {
        self.view_lines.resetLineWidthCaches();
    }

    /// Port of upstream `View.getOffsetForColumn`, in terminal cells. Returns
    /// null when the position is outside the rendered lines.
    pub fn getOffsetForColumn(self: *View, model_line_number: usize, model_column: usize) ?f64 {
        const converter = self.context.view_model.coordinates_converter;
        const model_position = Position.init(model_line_number, model_column);
        const view_position = converter.convertModelPositionToViewPosition(
            converter.context,
            model_position,
            .None,
            false,
            false,
        );
        const range = self.view_lines.visibleRangeForPosition(view_position) orelse return null;
        return @floatFromInt(range.left);
    }

    /// Port of upstream `View.focus`.
    pub fn focus(self: *View) void {
        _ = self.setFocused(true);
    }

    /// Port of upstream `View.isFocused`.
    pub fn isFocused(self: *const View) bool {
        return self.is_focused;
    }

    pub fn hasFocus(self: *const View) bool {
        return self.is_focused;
    }

    /// Broadcasts a focus change to the parts and overlays.
    pub fn setFocused(self: *View, focused: bool) bool {
        self.is_focused = focused;
        const event = view_events.ViewFocusChangedEvent{ .isFocused = focused };
        var should_render = false;
        for (self.view_parts.items) |part| {
            should_render = part.handler.onFocusChanged(&event) or should_render;
        }
        for (self.content_overlays.items) |overlay| {
            should_render = overlay.handler.onFocusChanged(&event) or should_render;
        }
        return should_render;
    }

    /// Port of upstream `View.handleEvents`: dispatch the events to the view
    /// handler and mark the view dirty so the host schedules a render.
    pub fn handleEvents(self: *View, events: []const ViewEvent) void {
        self.handler.handleEvents(events);
        self.should_render = true;
    }

    /// Port of upstream `ViewEventHandler.shouldRender`.
    pub fn shouldRender(self: *const View) bool {
        return self.should_render;
    }

    pub fn forceRender(self: *View) void {
        self.should_render = true;
    }

    /// Called by the host after a frame has been presented.
    pub fn onDidRender(self: *View) void {
        self.should_render = false;
    }

    pub fn prepareRender(self: *View, viewport: *const ViewportData) void {
        var rendering = RenderingContext.init(self.context.view_layout, viewport, self.view_lines.interface());
        for (self.content_overlays.items) |overlay| {
            if (!overlay.handler.shouldRender()) continue;
            overlay.prepareRender(&rendering);
            overlay.handler.onDidRender();
        }
        for (self.view_parts.items) |part| {
            if (!part.handler.shouldRender()) continue;
            part.prepareRender(&rendering);
        }
    }

    /// Port of upstream `View._flushAccumulatedAndRenderNow` for the terminal
    /// host: notify parts before rendering, render the text lines when dirty,
    /// then prepare and render the parts collected after the text pass.
    pub fn renderText(self: *View, viewport: *const ViewportData, sb: *StringBuilder) !void {
        for (self.view_parts.items) |part| {
            if (part.handler.shouldRender()) part.onBeforeRender(viewport);
        }

        if (self.view_lines.shouldRender()) {
            try self.view_lines.renderText(viewport, sb);
            self.view_lines.onDidRender();
        }

        const parts = try self.getViewPartsToRender(self.allocator);
        defer self.allocator.free(parts);

        var rendering = RenderingContext.init(self.context.view_layout, viewport, self.view_lines.interface());
        for (self.content_overlays.items) |overlay| {
            if (!overlay.handler.shouldRender()) continue;
            overlay.prepareRender(&rendering);
            overlay.handler.onDidRender();
        }
        for (parts) |part| part.prepareRender(&rendering);

        var restricted = RestrictedRenderingContext.init(self.context.view_layout, viewport);
        for (parts) |part| {
            part.render(&restricted);
            part.handler.onDidRender();
        }
    }

    // --- begin event fan-out

    pub fn onConfigurationChanged(self: *View, event: *const view_events.ViewConfigurationChangedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onConfigurationChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onConfigurationChanged(event) or should_render;
        return should_render;
    }

    pub fn onCursorStateChanged(self: *View, event: *const view_events.ViewCursorStateChangedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onCursorStateChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onCursorStateChanged(event) or should_render;
        return should_render;
    }

    pub fn onDecorationsChanged(self: *View, event: *const view_events.ViewDecorationsChangedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onDecorationsChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onDecorationsChanged(event) or should_render;
        return should_render;
    }

    pub fn onFlushed(self: *View, event: *const view_events.ViewFlushedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onFlushed(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onFlushed(event) or should_render;
        return should_render;
    }

    pub fn onLinesChanged(self: *View, event: *const view_events.ViewLinesChangedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onLinesChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onLinesChanged(event) or should_render;
        return should_render;
    }

    pub fn onLinesDeleted(self: *View, event: *const view_events.ViewLinesDeletedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onLinesDeleted(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onLinesDeleted(event) or should_render;
        return should_render;
    }

    pub fn onLinesInserted(self: *View, event: *const view_events.ViewLinesInsertedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onLinesInserted(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onLinesInserted(event) or should_render;
        return should_render;
    }

    pub fn onScrollChanged(self: *View, event: *const view_events.ViewScrollChangedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onScrollChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onScrollChanged(event) or should_render;
        return should_render;
    }

    pub fn onTokensChanged(self: *View, event: *const view_events.ViewTokensChangedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onTokensChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onTokensChanged(event) or should_render;
        return should_render;
    }

    pub fn onZonesChanged(self: *View, event: *const view_events.ViewZonesChangedEvent) bool {
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onZonesChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onZonesChanged(event) or should_render;
        return should_render;
    }

    pub fn onThemeChanged(self: *View, event: *const view_events.ViewThemeChangedEvent) bool {
        self.context.theme.update(event.theme);
        var should_render = false;
        for (self.view_parts.items) |part| should_render = part.handler.onThemeChanged(event) or should_render;
        for (self.content_overlays.items) |overlay| should_render = overlay.handler.onThemeChanged(event) or should_render;
        return should_render;
    }

    // --- end event fan-out

    /// View event callbacks. Upstream `View` extends `ViewEventHandler`; the Zig
    /// port uses the callback table and marks the view dirty on every event.
    fn handlerCallbacks() view_event_handler.EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = markDirtyConfiguration,
            .onCursorStateChanged = markDirtyCursor,
            .onDecorationsChanged = markDirtyDecorations,
            .onFlushed = markDirtyFlushed,
            .onFocusChanged = markDirtyFocus,
            .onLinesChanged = markDirtyLines,
            .onLinesDeleted = markDirtyLinesDeleted,
            .onLinesInserted = markDirtyLinesInserted,
            .onScrollChanged = markDirtyScroll,
            .onThemeChanged = markDirtyTheme,
            .onTokensChanged = markDirtyTokens,
            .onZonesChanged = markDirtyZones,
        };
    }

    fn markDirty(context: *anyopaque) *View {
        const view: *View = @ptrCast(@alignCast(context));
        view.should_render = true;
        return view;
    }

    fn markDirtyConfiguration(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyCursor(context: *anyopaque, _: *const view_events.ViewCursorStateChangedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyDecorations(context: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyFocus(context: *anyopaque, event: *const view_events.ViewFocusChangedEvent) bool {
        const view = markDirty(context);
        view.is_focused = event.isFocused;
        return false;
    }
    fn markDirtyLines(context: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyLinesDeleted(context: *anyopaque, _: *const view_events.ViewLinesDeletedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyLinesInserted(context: *anyopaque, _: *const view_events.ViewLinesInsertedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyScroll(context: *anyopaque, _: *const view_events.ViewScrollChangedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyTheme(context: *anyopaque, event: *const view_events.ViewThemeChangedEvent) bool {
        const view = markDirty(context);
        view.context.theme.update(event.theme.*);
        return false;
    }
    fn markDirtyTokens(context: *anyopaque, _: *const view_events.ViewTokensChangedEvent) bool {
        _ = markDirty(context);
        return false;
    }
    fn markDirtyZones(context: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        _ = markDirty(context);
        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const editor_configuration = @import("../common/config/editorConfiguration.zig");
const browser_config = @import("./config/editorConfiguration.zig");
const actions = @import("../../platform/actions/common/actions.zig");
const test_stubs = @import("../test/common/viewModelTestStubs.zig");
const view_model = @import("../common/viewModel.zig");
const languages = @import("../common/languages.zig");
const line_tokens = @import("../common/tokens/lineTokens.zig");
const Range = @import("../common/core/range.zig").Range;
const TextDirection = @import("../common/standalone/standaloneEnums.zig").TextDirection;
const LanguageIdCodec = languages.LanguageIdCodec;
const ViewLineRenderingData = view_model.ViewLineRenderingData;
const IViewLineTokens = line_tokens.IViewLineTokens;

const Fixture = struct {
    allocator: Allocator,
    codec: LanguageIdCodec,
    tokens: line_tokens.LineTokens,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: ViewContext,
    offsets: [1]f64 = .{0},
    viewport: ViewportData,

    fn init(self: *Fixture, allocator: Allocator, content: []const u8) !void {
        self.allocator = allocator;
        self.codec = try LanguageIdCodec.init(allocator);
        errdefer self.codec.deinit();
        var owned_content = std.array_list.Managed(u8).init(allocator);
        errdefer owned_content.deinit();
        try owned_content.appendSlice(content);
        self.tokens = try line_tokens.LineTokens.createEmpty(allocator, owned_content, &self.codec);
        errdefer self.tokens.deinit();

        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.view_line_data = ViewLineRenderingData.init(
            1,
            content.len + 1,
            content,
            false,
            false,
            false,
            IViewLineTokens.init(&self.tokens),
            &.{},
            4,
            0,
            TextDirection.LTR,
            false,
        );
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.context = ViewContext.init(&self.configuration, test_stubs.TestColorTheme.dark(), self.view_model.interface());
        self.viewport = .{
            .selections = &.{},
            .startLineNumber = 1,
            .endLineNumber = 1,
            .relativeVerticalOffset = &self.offsets,
            .visibleRange = Range.init(1, 1, 1, content.len + 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 19,
            ._model = self.view_model.interface(),
        };
    }

    fn deinit(self: *Fixture) void {
        self.tokens.deinit();
        self.codec.deinit();
    }
};

const FakePart = struct {
    base: ViewPart,
    prepared: usize = 0,
    rendered: usize = 0,
    configurations: usize = 0,
    focus_events: usize = 0,
    render_wanted: bool = true,

    fn prepare(part: *ViewPart, _: *RenderingContext) void {
        const self: *FakePart = @fieldParentPtr("base", part);
        self.prepared += 1;
    }

    fn render(part: *ViewPart, _: *RestrictedRenderingContext) void {
        const self: *FakePart = @fieldParentPtr("base", part);
        self.rendered += 1;
    }

    fn onConfigurationChanged(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *FakePart = @ptrCast(@alignCast(context));
        self.configurations += 1;
        return self.render_wanted;
    }

    fn onFocusChanged(context: *anyopaque, _: *const view_events.ViewFocusChangedEvent) bool {
        const self: *FakePart = @ptrCast(@alignCast(context));
        self.focus_events += 1;
        return true;
    }
};

const FakeOverlay = struct {
    base: DynamicViewOverlay,
    prepared: usize = 0,

    fn prepare(overlay: *DynamicViewOverlay, _: *const RenderingContext) void {
        const self: *FakeOverlay = @fieldParentPtr("base", overlay);
        self.prepared += 1;
    }

    fn render(_: *DynamicViewOverlay, _: usize, _: usize) []const u8 {
        return "";
    }
};

test "view renders lines and drives view parts" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "hello");
    defer fixture.deinit();

    var view: View = undefined;
    view.init(allocator, &fixture.context);
    defer view.deinit();

    var part = FakePart{ .base = undefined };
    part.base.initWithHandlerContext(&fixture.context, &part, .{
        .onConfigurationChanged = FakePart.onConfigurationChanged,
        .onFocusChanged = FakePart.onFocusChanged,
    }, FakePart.prepare, FakePart.render);
    try view.addViewPart(&part.base);

    var sb = try StringBuilder.init(allocator, 16);
    defer sb.deinit();
    try view.renderText(&fixture.viewport, &sb);
    try testing.expectEqualStrings("hello", sb.build());
    try testing.expectEqual(@as(usize, 1), part.prepared);
    try testing.expectEqual(@as(usize, 1), part.rendered);

    // A second render only renders parts that ask for it; the text view lines
    // were marked rendered and do not append their text again.
    sb.reset();
    try view.renderText(&fixture.viewport, &sb);
    try testing.expectEqualStrings("", sb.build());
    try testing.expectEqual(@as(usize, 1), part.prepared);

    view.view_lines.forceShouldRender();
    try view.renderText(&fixture.viewport, &sb);
    try testing.expectEqualStrings("hello", sb.build());
}

test "view fans configuration and focus events out to parts and overlays" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "x");
    defer fixture.deinit();

    var view: View = undefined;
    view.init(allocator, &fixture.context);
    defer view.deinit();

    var part = FakePart{ .base = undefined };
    part.base.initWithHandlerContext(&fixture.context, &part, .{
        .onConfigurationChanged = FakePart.onConfigurationChanged,
        .onFocusChanged = FakePart.onFocusChanged,
    }, FakePart.prepare, FakePart.render);
    try view.addViewPart(&part.base);

    var overlay = FakeOverlay{ .base = undefined };
    overlay.base.init(&fixture.context, .{}, FakeOverlay.prepare, FakeOverlay.render);
    try view.addContentOverlay(&overlay.base);

    const editor_options = @import("../common/config/editorOptions.zig");
    const option_count = @typeInfo(editor_options.EditorOption).@"enum".field_names.len;
    var values: [option_count]bool = @splat(false);
    const configuration_event = view_events.ViewConfigurationChangedEvent.init(
        editor_options.ConfigurationChangedEvent.init(&values),
    );
    try testing.expect(view.onConfigurationChanged(&configuration_event));
    try testing.expectEqual(@as(usize, 1), part.configurations);

    try testing.expect(view.setFocused(true));
    try testing.expect(view.hasFocus());
    try testing.expectEqual(@as(usize, 1), part.focus_events);
}

test "view exposes line widths, cell offsets and width cache reset" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "a\tb");
    defer fixture.deinit();

    var view: View = undefined;
    view.init(allocator, &fixture.context);
    defer view.deinit();

    var sb = try StringBuilder.init(allocator, 16);
    defer sb.deinit();

    try testing.expect(view.getOffsetForColumn(1, 3) == null);
    try view.renderText(&fixture.viewport, &sb);
    try testing.expectEqual(@as(usize, 5), view.getLineWidth(1));
    try testing.expectEqual(@as(f64, 4), view.getOffsetForColumn(1, 3).?);

    view.resetLineWidthCaches();
    try testing.expectEqual(@as(usize, 5), view.getLineWidth(1));

    try testing.expect(view.isFocused() == false);
    view.focus();
    try testing.expect(view.isFocused());

    const parts = try view.getViewPartsToRender(allocator);
    defer allocator.free(parts);
    try testing.expectEqual(@as(usize, 0), parts.len);
}

test "view is a view event handler and schedules render on events" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "x");
    defer fixture.deinit();

    var view: View = undefined;
    view.init(allocator, &fixture.context);
    defer view.deinit();

    try testing.expect(fixture.view_model.added_handlers >= 1);
    try testing.expect(view.shouldRender());
    view.onDidRender();
    try testing.expect(!view.shouldRender());

    view.handleEvents(&[_]ViewEvent{
        .{ .ViewFocusChanged = .{ .isFocused = true } },
    });
    try testing.expect(view.shouldRender());
    try testing.expect(view.hasFocus());
}

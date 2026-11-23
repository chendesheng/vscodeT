// Port of `src/vs/editor/browser/viewParts/currentLineHighlight/currentLineHighlight.ts`.
//
// Terminal adaptation: upstream subclasses `AbstractLineHighlightOverlay` twice
// (content and margin) and renders positioned `<div>` HTML. Zig has no
// inheritance, so one `AbstractLineHighlightOverlay` carries a `kind` and
// `prepareRender` produces structured per-view-line flags
// (`highlight`/`in_content`/`in_margin`/`exact`). The terminal compositor owns
// the cells and colors; the part keeps the upstream decisions: which line is
// highlighted, whether the content and/or gutter is highlighted, the
// focus-only and empty-selection rules, and the word-wrap first pass.
const std = @import("std");
const Allocator = std.mem.Allocator;

const dynamic_overlay = @import("../../view/dynamicViewOverlay.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const view_model = @import("../../../common/viewModel.zig");
const editor_options = @import("../../../common/config/editorOptions.zig");
const Position = @import("../../../common/core/position.zig").Position;
const Selection = @import("../../../common/core/selection.zig").Selection;

const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const RenderingContext = rendering_context.RenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const RenderLineHighlight = editor_options.RenderLineHighlight;

/// Which of the two upstream overlays this instance represents.
pub const Kind = enum { content, margin };

/// The terminal rendering data for one view line.
pub const LineHighlightRenderData = struct {
    /// The line is a cursor line and the overlay rendered something for it.
    highlight: bool = false,
    /// The content part of the line is highlighted (`current-line`).
    in_content: bool = false,
    /// The gutter/margin part of the line is highlighted (`current-line-margin`).
    in_margin: bool = false,
    /// The line is the exact cursor line, not a wrapped continuation.
    exact: bool = false,
};

/// Port of `AbstractLineHighlightOverlay` plus both concrete overlays.
///
/// `CurrentLineHighlightOverlay` and `CurrentLineMarginHighlightOverlay` share
/// this storage; construct them with `initContent`/`initMargin`.
pub const AbstractLineHighlightOverlay = struct {
    base: DynamicViewOverlay,
    allocator: Allocator,
    context: *ViewContext,
    kind: Kind,

    render_line_highlight: RenderLineHighlight,
    word_wrap: bool,
    content_left: f64,
    content_width: f64,
    selection_is_empty: bool,
    render_line_highlight_only_when_focus: bool,
    focused: bool,
    /// Unique sorted view line numbers which have cursors sitting on them.
    cursor_line_numbers: std.array_list.Managed(usize),
    selections: []const Selection,
    render_result: ?[]LineHighlightRenderData,
    render_start_line_number: usize,

    pub fn initContent(self: *AbstractLineHighlightOverlay, allocator: Allocator, context: *ViewContext) void {
        self.init(allocator, context, .content);
    }

    pub fn initMargin(self: *AbstractLineHighlightOverlay, allocator: Allocator, context: *ViewContext) void {
        self.init(allocator, context, .margin);
    }

    fn init(self: *AbstractLineHighlightOverlay, allocator: Allocator, context: *ViewContext, kind: Kind) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .kind = kind,
            .render_line_highlight = .line,
            .word_wrap = false,
            .content_left = 0,
            .content_width = 0,
            .selection_is_empty = true,
            .render_line_highlight_only_when_focus = false,
            .focused = false,
            .cursor_line_numbers = std.array_list.Managed(usize).init(allocator),
            .selections = &.{},
            .render_result = null,
            .render_start_line_number = 1,
        };
        self.cursor_line_numbers.append(1) catch {};
        self.readConfig();
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *AbstractLineHighlightOverlay) void {
        self.base.deinit();
        self.cursor_line_numbers.deinit();
        self.clearRenderResult();
    }

    fn readConfig(self: *AbstractLineHighlightOverlay) void {
        const options = self.context.configuration.options.?;
        const layout_info = options.get(.layoutInfo);
        self.render_line_highlight = options.get(.renderLineHighlight);
        self.render_line_highlight_only_when_focus = options.get(.renderLineHighlightOnlyWhenFocus);
        self.word_wrap = layout_info.is_viewport_wrapping;
        self.content_left = layout_info.content_left;
        self.content_width = layout_info.content_width;
    }

    fn readFromSelections(self: *AbstractLineHighlightOverlay) bool {
        var has_changed = false;

        // Unique, sorted cursor view line numbers.
        var line_numbers = std.array_list.Managed(usize).init(self.allocator);
        defer line_numbers.deinit();
        for (self.selections) |selection| {
            const line_number = selection.positionLineNumber;
            var found = false;
            for (line_numbers.items) |existing| {
                if (existing == line_number) {
                    found = true;
                    break;
                }
            }
            if (!found) line_numbers.append(line_number) catch {};
        }
        std.mem.sort(usize, line_numbers.items, {}, std.sort.asc(usize));
        if (!std.mem.eql(usize, self.cursor_line_numbers.items, line_numbers.items)) {
            self.cursor_line_numbers.clearRetainingCapacity();
            self.cursor_line_numbers.appendSlice(line_numbers.items) catch {};
            has_changed = true;
        }

        var all_empty = true;
        for (self.selections) |selection| {
            if (!selection.isEmpty()) {
                all_empty = false;
                break;
            }
        }
        if (self.selection_is_empty != all_empty) {
            self.selection_is_empty = all_empty;
            has_changed = true;
        }

        return has_changed;
    }

    // --- begin event handlers

    fn onThemeChanged(context: *anyopaque, _: *const view_events.ViewThemeChangedEvent) bool {
        const self: *AbstractLineHighlightOverlay = @ptrCast(@alignCast(context));
        return self.readFromSelections();
    }

    fn onConfigurationChanged(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *AbstractLineHighlightOverlay = @ptrCast(@alignCast(context));
        self.readConfig();
        return true;
    }

    fn onCursorStateChanged(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *AbstractLineHighlightOverlay = @ptrCast(@alignCast(context));
        self.selections = event.selections;
        return self.readFromSelections();
    }

    fn onFlushed(_: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        return true;
    }

    fn onLinesDeleted(_: *anyopaque, _: *const view_events.ViewLinesDeletedEvent) bool {
        return true;
    }

    fn onLinesInserted(_: *anyopaque, _: *const view_events.ViewLinesInsertedEvent) bool {
        return true;
    }

    fn onScrollChanged(_: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        return event.scrollWidthChanged or event.scrollTopChanged;
    }

    fn onZonesChanged(_: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        return true;
    }

    fn onFocusChanged(context: *anyopaque, event: *const view_events.ViewFocusChangedEvent) bool {
        const self: *AbstractLineHighlightOverlay = @ptrCast(@alignCast(context));
        if (!self.render_line_highlight_only_when_focus) {
            return false;
        }
        self.focused = event.isFocused;
        return true;
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onThemeChanged = onThemeChanged,
            .onConfigurationChanged = onConfigurationChanged,
            .onCursorStateChanged = onCursorStateChanged,
            .onFlushed = onFlushed,
            .onLinesDeleted = onLinesDeleted,
            .onLinesInserted = onLinesInserted,
            .onScrollChanged = onScrollChanged,
            .onZonesChanged = onZonesChanged,
            .onFocusChanged = onFocusChanged,
        };
    }

    // --- end event handlers

    fn shouldRenderInMargin(self: *const AbstractLineHighlightOverlay) bool {
        return (self.render_line_highlight == .gutter or self.render_line_highlight == .all) and
            (!self.render_line_highlight_only_when_focus or self.focused);
    }

    fn shouldRenderInContent(self: *const AbstractLineHighlightOverlay) bool {
        return (self.render_line_highlight == .line or self.render_line_highlight == .all) and
            self.selection_is_empty and
            (!self.render_line_highlight_only_when_focus or self.focused);
    }

    fn shouldRenderThis(self: *const AbstractLineHighlightOverlay) bool {
        return switch (self.kind) {
            .content => self.shouldRenderInContent(),
            .margin => true,
        };
    }

    fn shouldRenderOther(self: *const AbstractLineHighlightOverlay) bool {
        return switch (self.kind) {
            .content => self.shouldRenderInMargin(),
            .margin => self.shouldRenderInContent(),
        };
    }

    fn renderOne(self: *const AbstractLineHighlightOverlay, exact: bool) LineHighlightRenderData {
        return switch (self.kind) {
            .content => .{
                .highlight = self.shouldRenderInContent(),
                .in_content = self.shouldRenderInContent(),
                .in_margin = self.shouldRenderInMargin(),
                .exact = exact,
            },
            .margin => .{
                .highlight = true,
                .in_margin = self.shouldRenderInMargin(),
                .in_content = self.shouldRenderOther(),
                .exact = exact and self.shouldRenderInMargin(),
            },
        };
    }

    fn firstViewLineOfModelLine(self: *const AbstractLineHighlightOverlay, model_line_number: usize) usize {
        const converter = self.context.view_model.coordinates_converter;
        return converter.convertModelPositionToViewPosition(
            converter.context,
            Position.init(model_line_number, 1),
            .None,
            false,
            false,
        ).lineNumber;
    }

    fn lastViewLineOfModelLine(self: *const AbstractLineHighlightOverlay, model_line_number: usize) usize {
        const converter = self.context.view_model.coordinates_converter;
        const max_column = self.context.view_model.lineMaxColumn(model_line_number);
        return converter.convertModelPositionToViewPosition(
            converter.context,
            Position.init(model_line_number, max_column),
            .None,
            false,
            false,
        ).lineNumber;
    }

    fn prepareRenderCallback(overlay: *DynamicViewOverlay, context: *const RenderingContext) void {
        const self: *AbstractLineHighlightOverlay = @alignCast(@fieldParentPtr("base", overlay));
        self.prepareRender(context);
    }

    fn renderCallback(overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8 {
        const self: *AbstractLineHighlightOverlay = @alignCast(@fieldParentPtr("base", overlay));
        _ = start_line_number;
        const data = self.renderedLine(line_number) orelse return "";
        if (!data.highlight) return "";
        return "current-line";
    }

    pub fn prepareRender(self: *AbstractLineHighlightOverlay, context: *const RenderingContext) void {
        self.clearRenderResult();
        if (!self.shouldRenderThis()) {
            return;
        }
        const visible_start_line_number = context.restricted.visibleRange.startLineNumber;
        const visible_end_line_number = context.restricted.visibleRange.endLineNumber;
        if (visible_end_line_number < visible_start_line_number) return;

        const line_count = visible_end_line_number - visible_start_line_number + 1;
        const render_data = self.allocator.alloc(LineHighlightRenderData, line_count) catch return;
        for (render_data) |*entry| entry.* = .{};

        if (self.word_wrap) {
            // First pass: render wrapped lines.
            const rendered_line_wrapped = self.renderOne(false);
            for (self.cursor_line_numbers.items) |cursor_line_number| {
                const converter = self.context.view_model.coordinates_converter;
                const model_line_number = converter.convertViewPositionToModelPosition(
                    converter.context,
                    Position.init(cursor_line_number, 1),
                ).lineNumber;
                const first_view_line_number = self.firstViewLineOfModelLine(model_line_number);
                const last_view_line_number = self.lastViewLineOfModelLine(model_line_number);
                const first_line = @max(first_view_line_number, visible_start_line_number);
                const last_line = @min(last_view_line_number, visible_end_line_number);
                var line_number = first_line;
                while (line_number <= last_line) : (line_number += 1) {
                    render_data[line_number - visible_start_line_number] = rendered_line_wrapped;
                }
            }
        }

        // Second pass: render exact lines.
        const rendered_line_exact = self.renderOne(true);
        for (self.cursor_line_numbers.items) |cursor_line_number| {
            if (cursor_line_number < visible_start_line_number or cursor_line_number > visible_end_line_number) {
                continue;
            }
            render_data[cursor_line_number - visible_start_line_number] = rendered_line_exact;
        }

        self.render_result = render_data;
        self.render_start_line_number = visible_start_line_number;
    }

    /// The terminal compositor queries the structured data of a view line.
    pub fn renderedLine(self: *const AbstractLineHighlightOverlay, line_number: usize) ?*const LineHighlightRenderData {
        const result = self.render_result orelse return null;
        if (line_number < self.render_start_line_number) return null;
        const line_index = line_number - self.render_start_line_number;
        if (line_index >= result.len) return null;
        return &result[line_index];
    }

    fn clearRenderResult(self: *AbstractLineHighlightOverlay) void {
        const result = self.render_result orelse return;
        self.allocator.free(result);
        self.render_result = null;
    }
};

/// Upstream subclass names: both are the same storage distinguished by `kind`.
pub const CurrentLineHighlightOverlay = AbstractLineHighlightOverlay;
pub const CurrentLineMarginHighlightOverlay = AbstractLineHighlightOverlay;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const browser_config = @import("../../config/editorConfiguration.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const view_lines_viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const Range = @import("../../../common/core/range.zig").Range;
const coordinates = @import("../../../common/coordinatesConverter.zig");

const Harness = struct {
    allocator: Allocator,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    converter: ?coordinates.ICoordinatesConverter = null,
    context: ViewContext,
    overlay: AbstractLineHighlightOverlay,
    viewport: view_lines_viewport_data.ViewportData,
    rendering: RenderingContext,

    fn init(
        self: *Harness,
        allocator: Allocator,
        kind: Kind,
        line_count: usize,
        selections: []const Selection,
        converter: ?coordinates.ICoordinatesConverter,
    ) !void {
        self.allocator = allocator;
        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.line_count = line_count;
        const line_lengths = try allocator.alloc(usize, line_count);
        errdefer allocator.free(line_lengths);
        @memset(line_lengths, 1);
        self.view_model.line_lengths = line_lengths;
        self.converter = converter;
        const theme = test_stubs.TestColorTheme.dark();
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.context = ViewContext.init(&self.configuration, theme, self.view_model.interface());
        if (self.converter) |custom| {
            // The view model stub always exposes the identity converter; swap the
            // converter used by the overlay through a custom view model wrapper.
            self.context.view_model.coordinates_converter = custom;
        }
        self.overlay = undefined;
        if (kind == .content) {
            self.overlay.initContent(allocator, &self.context);
        } else {
            self.overlay.initMargin(allocator, &self.context);
        }
        errdefer self.overlay.deinit();
        self.overlay.selections = selections;
        _ = self.overlay.readFromSelections();

        const offsets = try allocator.alloc(f64, line_count);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);
        self.viewport = .{
            .selections = selections,
            .startLineNumber = 1,
            .endLineNumber = line_count,
            .relativeVerticalOffset = offsets,
            .visibleRange = Range.init(1, 1, line_count, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 1,
            ._model = self.context.view_model,
        };
        const view_lines = rendering_context.IViewLines{
            .context = @ptrFromInt(@alignOf(usize)),
            .lines_visible_ranges_for_range = struct {
                fn f(_: *anyopaque, _: Range, _: bool) ?[]const rendering_context.LineVisibleRanges {
                    return null;
                }
            }.f,
            .visible_range_for_position = struct {
                fn f(_: *anyopaque, _: Position) ?rendering_context.HorizontalPosition {
                    return null;
                }
            }.f,
        };
        self.rendering = RenderingContext.init(self.layout.interface(), &self.viewport, view_lines);
    }

    fn deinit(self: *Harness) void {
        self.overlay.deinit();
        self.allocator.free(self.viewport.relativeVerticalOffset);
        self.allocator.free(@constCast(self.view_model.line_lengths));
    }
};

test "current line highlight: content follows empty selections" {
    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(2, 1, 2, 1)};
    try harness.init(testing.allocator, .content, 4, &selections, null);
    defer harness.deinit();

    harness.overlay.prepareRender(&harness.rendering);
    try testing.expect(harness.overlay.renderedLine(2).?.highlight);
    try testing.expect(harness.overlay.renderedLine(2).?.in_content);
    try testing.expect(!harness.overlay.renderedLine(2).?.in_margin);
    try testing.expect(harness.overlay.renderedLine(2).?.exact);
    try testing.expect(!harness.overlay.renderedLine(1).?.highlight);
    try testing.expect(!harness.overlay.renderedLine(3).?.highlight);
}

test "current line highlight: non-empty selections disable the content highlight" {
    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(2, 1, 2, 3)};
    try harness.init(testing.allocator, .content, 4, &selections, null);
    defer harness.deinit();

    harness.overlay.prepareRender(&harness.rendering);
    try std.testing.expect(harness.overlay.render_result == null);

    // The margin overlay still renders the cursor line for a selection.
    var margin: Harness = undefined;
    try margin.init(testing.allocator, .margin, 4, &selections, null);
    defer margin.deinit();
    margin.overlay.prepareRender(&margin.rendering);
    try testing.expect(margin.overlay.renderedLine(2).?.highlight);
    try testing.expect(!margin.overlay.renderedLine(2).?.in_content);
}

test "current line highlight: gutter mode highlights only the margin" {
    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(3, 1, 3, 1)};
    try harness.init(testing.allocator, .margin, 4, &selections, null);
    defer harness.deinit();

    harness.options.set(.renderLineHighlight, .gutter);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);
    try testing.expect(harness.overlay.renderedLine(3).?.in_margin);
    try testing.expect(!harness.overlay.renderedLine(3).?.in_content);

    harness.options.set(.renderLineHighlight, .all);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);
    try testing.expect(harness.overlay.renderedLine(3).?.in_margin);
    try testing.expect(harness.overlay.renderedLine(3).?.in_content);
}

test "current line highlight: focus-only highlighting waits for focus" {
    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(2, 1, 2, 1)};
    try harness.init(testing.allocator, .content, 4, &selections, null);
    defer harness.deinit();

    harness.options.set(.renderLineHighlightOnlyWhenFocus, true);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);
    try testing.expect(harness.overlay.render_result == null);

    _ = harness.overlay.base.handler.onFocusChanged(&.{ .isFocused = true });
    harness.overlay.prepareRender(&harness.rendering);
    try testing.expect(harness.overlay.renderedLine(2).?.in_content);
}

test "current line highlight: wrapped lines are highlighted without being exact" {
    const WrapConverter = struct {
        fn viewToModel(_: *anyopaque, position: Position) Position {
            return position;
        }
        fn viewRange(_: *anyopaque, range: Range) Range {
            return range;
        }
        fn validatePosition(_: *anyopaque, view_position: Position, _: Position) Position {
            return view_position;
        }
        fn validateRange(_: *anyopaque, view_range: Range, _: Range) Range {
            return view_range;
        }
        fn modelToView(_: *anyopaque, model_position: Position, _: @import("../../../common/model.zig").PositionAffinity, _: bool, _: bool) Position {
            // Model line 2 occupies view lines 2 through 4.
            if (model_position.lineNumber == 2) {
                if (model_position.column <= 1) return Position.init(2, 1);
                return Position.init(4, 1);
            }
            return model_position;
        }
        fn modelRange(_: *anyopaque, model_range: Range, _: @import("../../../common/model.zig").PositionAffinity) Range {
            return model_range;
        }
        fn modelPositionIsVisible(_: *anyopaque, _: Position) bool {
            return true;
        }
        fn getModelLineViewLineCount(_: *anyopaque, _: usize) usize {
            return 3;
        }
        fn getViewLineNumberOfModelPosition(_: *anyopaque, _: usize, _: usize) usize {
            return 2;
        }
        fn interface() coordinates.ICoordinatesConverter {
            return .{
                .context = @ptrFromInt(@alignOf(usize)),
                .convertViewPositionToModelPosition = viewToModel,
                .convertViewRangeToModelRange = viewRange,
                .validateViewPosition = validatePosition,
                .validateViewRange = validateRange,
                .convertModelPositionToViewPosition = modelToView,
                .convertModelRangeToViewRange = modelRange,
                .modelPositionIsVisible = modelPositionIsVisible,
                .getModelLineViewLineCount = getModelLineViewLineCount,
                .getViewLineNumberOfModelPosition = getViewLineNumberOfModelPosition,
            };
        }
    };

    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(2, 1, 2, 1)};
    try harness.init(testing.allocator, .content, 4, &selections, WrapConverter.interface());
    defer harness.deinit();
    harness.options.set(.renderLineHighlight, .line);
    var layout_info = harness.options.get(.layoutInfo);
    layout_info.is_viewport_wrapping = true;
    harness.options.set(.layoutInfo, layout_info);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);

    // View lines 2..4 are the wrapped model line: all highlighted, only the
    // first one is exact.
    try testing.expect(harness.overlay.renderedLine(2).?.in_content);
    try testing.expect(harness.overlay.renderedLine(2).?.exact);
    try testing.expect(harness.overlay.renderedLine(3).?.in_content);
    try testing.expect(!harness.overlay.renderedLine(3).?.exact);
    try testing.expect(harness.overlay.renderedLine(4).?.in_content);
    try testing.expect(!harness.overlay.renderedLine(4).?.exact);
}

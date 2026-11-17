// Port of `src/vs/editor/browser/viewParts/wordWrapIndicator/wordWrapIndicator.ts`.
//
// Terminal adaptation: a cell grid cannot position a floating glyph mid-cell, so
// `prepareRender` produces per-view-line indicator data (`left` in the same
// pixel coordinates the wrapping column uses, and the view line height) instead
// of `<div>` HTML. The terminal maps `left` to the cell at the wrapping column.
// Variable line heights come from line-height decorations in the browser; the
// terminal takes the height from the view layout (one row per view line).
const std = @import("std");
const Allocator = std.mem.Allocator;

const dynamic_overlay = @import("../../view/dynamicViewOverlay.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");

const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const RenderingContext = rendering_context.RenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const IEditorConfiguration = editor_configuration.IEditorConfiguration;

/// U+21A9 - LEFTWARDS ARROW WITH HOOK.
pub const WORD_WRAP_INDICATOR_CHAR_CODE: u21 = 0x21A9;

/// The options the overlay reads, snapshotted so a configuration change can be
/// told apart from one that leaves the rendered result untouched.
pub const WordWrapIndicatorOptions = struct {
    word_wrap_indicator: bool,
    is_wrapping: bool,
    indicator_left: f64,

    pub fn init(config: *const IEditorConfiguration) WordWrapIndicatorOptions {
        const options = config.options.?;
        const font_info = options.get(.fontInfo);
        const wrapping_column = options.get(.wrappingInfo).wrapping_column;
        return .{
            .word_wrap_indicator = options.get(.wordWrapIndicator),
            .is_wrapping = wrapping_column != -1,
            .indicator_left = wrapping_column * font_info.typicalHalfwidthCharacterWidth,
        };
    }

    pub fn equals(self: WordWrapIndicatorOptions, other: WordWrapIndicatorOptions) bool {
        return self.word_wrap_indicator == other.word_wrap_indicator and
            self.is_wrapping == other.is_wrapping and
            self.indicator_left == other.indicator_left;
    }
};

/// Per-view-line indicator data.
pub const Indicator = struct {
    left: f64,
    height: f64,
};

/// Port of `WordWrapIndicatorOverlay`.
pub const WordWrapIndicatorOverlay = struct {
    base: DynamicViewOverlay,
    allocator: Allocator,
    context: *ViewContext,
    options: WordWrapIndicatorOptions,
    render_result: ?[]?Indicator,
    render_start_line_number: usize,

    pub fn init(self: *WordWrapIndicatorOverlay, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .options = undefined,
            .render_result = null,
            .render_start_line_number = 1,
        };
        self.options = WordWrapIndicatorOptions.init(self.context.configuration);
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *WordWrapIndicatorOverlay) void {
        self.base.deinit();
        self.clearRenderResult();
    }

    /// Whether the overlay paints anything at all.
    pub fn isEnabled(self: *const WordWrapIndicatorOverlay) bool {
        return self.options.word_wrap_indicator and self.options.is_wrapping;
    }

    // --- begin event handlers

    fn onConfigurationChanged(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        const was_enabled = self.isEnabled();
        const new_options = WordWrapIndicatorOptions.init(self.context.configuration);
        const options_changed = !self.options.equals(new_options);
        self.options = new_options;
        return (was_enabled or self.isEnabled()) and options_changed;
    }

    fn onDecorationsChanged(context: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled();
    }

    fn onFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled();
    }

    fn onLineMappingChanged(context: *anyopaque, _: *const view_events.ViewLineMappingChangedEvent) bool {
        // Which lines continue with a wrapped line is decided by the line mapping.
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled();
    }

    fn onLinesChanged(context: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled();
    }

    fn onLinesDeleted(context: *anyopaque, _: *const view_events.ViewLinesDeletedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled();
    }

    fn onLinesInserted(context: *anyopaque, _: *const view_events.ViewLinesInsertedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled();
    }

    fn onScrollChanged(context: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled() and event.scrollTopChanged;
    }

    fn onTokensChanged(_: *anyopaque, _: *const view_events.ViewTokensChangedEvent) bool {
        return false;
    }

    fn onZonesChanged(context: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        const self: *WordWrapIndicatorOverlay = @ptrCast(@alignCast(context));
        return self.isEnabled();
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = onConfigurationChanged,
            .onDecorationsChanged = onDecorationsChanged,
            .onFlushed = onFlushed,
            .onLineMappingChanged = onLineMappingChanged,
            .onLinesChanged = onLinesChanged,
            .onLinesDeleted = onLinesDeleted,
            .onLinesInserted = onLinesInserted,
            .onScrollChanged = onScrollChanged,
            .onTokensChanged = onTokensChanged,
            .onZonesChanged = onZonesChanged,
        };
    }

    // --- end event handlers

    fn prepareRenderCallback(overlay: *DynamicViewOverlay, context: *const RenderingContext) void {
        const self: *WordWrapIndicatorOverlay = @fieldParentPtr("base", overlay);
        self.prepareRender(context);
    }

    fn renderCallback(overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8 {
        const self: *WordWrapIndicatorOverlay = @fieldParentPtr("base", overlay);
        return self.render(start_line_number, line_number);
    }

    pub fn prepareRender(self: *WordWrapIndicatorOverlay, context: *const RenderingContext) void {
        self.clearRenderResult();
        if (!self.isEnabled()) return;

        const start_line_number = context.restricted.viewportData.startLineNumber;
        const end_line_number = context.restricted.viewportData.endLineNumber;
        if (end_line_number < start_line_number) return;

        const line_count = end_line_number - start_line_number + 1;
        const result = self.allocator.alloc(?Indicator, line_count) catch return;
        var line_number = start_line_number;
        while (line_number <= end_line_number) : (line_number += 1) {
            const line_index = line_number - start_line_number;
            if (!context.restricted.viewportData.getViewLineContinuesWithWrappedLine(line_number)) {
                // The line ends with a real line break, or is the last line of the model.
                result[line_index] = null;
                continue;
            }
            result[line_index] = .{
                .left = self.options.indicator_left,
                .height = context.restricted.getLineHeightForLineNumber(line_number),
            };
        }
        self.render_result = result;
        self.render_start_line_number = start_line_number;
    }

    pub fn render(self: *WordWrapIndicatorOverlay, start_line_number: usize, line_number: usize) []const u8 {
        if (self.indicatorFor(start_line_number, line_number) != null) {
            return "\u{21A9}";
        }
        return "";
    }

    /// The terminal compositor queries the indicator data of a view line.
    pub fn indicatorFor(self: *const WordWrapIndicatorOverlay, start_line_number: usize, line_number: usize) ?Indicator {
        const result = self.render_result orelse return null;
        if (line_number < start_line_number) return null;
        const line_index = line_number - start_line_number;
        if (line_index >= result.len) return null;
        return result[line_index];
    }

    fn clearRenderResult(self: *WordWrapIndicatorOverlay) void {
        const result = self.render_result orelse return;
        self.allocator.free(result);
        self.render_result = null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const browser_config = @import("../../config/editorConfiguration.zig");
const editor_ops = @import("../../../common/config/editorOptions.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;

const LINE_HEIGHT = 19.0;
const INDICATOR_LEFT = 60.0;

const Harness = struct {
    allocator: Allocator,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: ViewContext,
    overlay: WordWrapIndicatorOverlay,
    viewport: viewport_data.ViewportData,
    rendering: RenderingContext,

    fn init(
        self: *Harness,
        allocator: Allocator,
        line_count: usize,
        wrapped_lines: []const bool,
        start_line_number: usize,
        end_line_number: usize,
        line_heights: []const f64,
        wrapping_column: f64,
        indicator_enabled: bool,
    ) !void {
        self.allocator = allocator;
        self.options = browser_config.ComputedEditorOptions.init();
        var font_info = self.options.get(.fontInfo);
        font_info.typicalHalfwidthCharacterWidth = 10;
        self.options.set(.fontInfo, font_info);
        self.options.set(.wordWrapIndicator, indicator_enabled);
        self.options.set(.wrappingInfo, .{ .wrapping_column = wrapping_column });

        self.layout = .{ .line_height = LINE_HEIGHT, .line_heights = line_heights };
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.line_count = line_count;
        self.view_model.wrapped_lines = wrapped_lines;
        const line_lengths = try allocator.alloc(usize, line_count);
        errdefer allocator.free(line_lengths);
        @memset(line_lengths, 80);
        self.view_model.line_lengths = line_lengths;

        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.context = ViewContext.init(&self.configuration, test_stubs.TestColorTheme.dark(), self.view_model.interface());
        self.overlay = undefined;
        self.overlay.init(allocator, &self.context);
        errdefer self.overlay.deinit();

        const viewport_line_count = end_line_number - start_line_number + 1;
        const offsets = try allocator.alloc(f64, viewport_line_count);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);
        self.viewport = .{
            .selections = &.{},
            .startLineNumber = start_line_number,
            .endLineNumber = end_line_number,
            .relativeVerticalOffset = offsets,
            .visibleRange = Range.init(start_line_number, 1, end_line_number, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = LINE_HEIGHT,
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
                fn f(_: *anyopaque, _: @import("../../../common/core/position.zig").Position) ?rendering_context.HorizontalPosition {
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

    fn prepare(self: *Harness) void {
        self.overlay.prepareRender(&self.rendering);
    }

    fn indicator(self: *Harness, line_number: usize) ?Indicator {
        return self.overlay.indicatorFor(self.viewport.startLineNumber, line_number);
    }

    fn updateInvalidates(self: *Harness, mutate: *const fn (*browser_config.ComputedEditorOptions) void) bool {
        self.overlay.base.handler.onDidRender();
        mutate(&self.options);
        const configuration_event = view_events.ViewConfigurationChangedEvent.init(editor_ops.ConfigurationChangedEvent.init(&.{}));
        const changed = self.overlay.base.handler.onConfigurationChanged(&configuration_event);
        if (changed) self.overlay.base.handler.setShouldRender();
        return self.overlay.base.handler.shouldRender();
    }
};

const WRAPPED_LINES = [_]bool{ true, true, false, false, true, false };

fn initDefault(
    harness: *Harness,
    allocator: Allocator,
    wrapped_lines: []const bool,
    start_line_number: usize,
    end_line_number: usize,
    line_heights: []const f64,
    indicator_enabled: bool,
) !void {
    try harness.init(
        allocator,
        wrapped_lines.len,
        wrapped_lines,
        start_line_number,
        end_line_number,
        line_heights,
        6,
        indicator_enabled,
    );
}

fn enableIndicator(options: *browser_config.ComputedEditorOptions) void {
    options.set(.wordWrapIndicator, true);
}

fn disableIndicator(options: *browser_config.ComputedEditorOptions) void {
    options.set(.wordWrapIndicator, false);
}

fn enableAndChangeColumn(options: *browser_config.ComputedEditorOptions) void {
    options.set(.wordWrapIndicator, true);
    options.set(.wrappingInfo, .{ .wrapping_column = 7 });
}

fn turnLineNumbersOff(options: *browser_config.ComputedEditorOptions) void {
    options.set(.lineNumbers, .{ .render_type = .Off, .render_fn = null });
}

fn solidCursor(options: *browser_config.ComputedEditorOptions) void {
    options.set(.cursorBlinking, .Solid);
}

test "word wrap indicator: renders for every soft wrapped view line" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, true);
    defer harness.deinit();
    harness.prepare();

    try testing.expect(harness.indicator(1) != null);
    try testing.expect(harness.indicator(2) != null);
    try testing.expect(harness.indicator(3) == null);
    try testing.expect(harness.indicator(4) == null);
    try testing.expect(harness.indicator(5) != null);
    try testing.expect(harness.indicator(6) == null);
    try testing.expectEqual(INDICATOR_LEFT, harness.indicator(1).?.left);
    try testing.expectEqual(LINE_HEIGHT, harness.indicator(1).?.height);
    try testing.expectEqualStrings("\u{21A9}", harness.overlay.render(1, 1));
}

test "word wrap indicator: does not construct line rendering data" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expectEqual(@as(usize, 0), harness.view_model.viewport_data_calls);
}

test "word wrap indicator: renders nothing when disabled or the setting is default" {
    var disabled: Harness = undefined;
    try initDefault(&disabled, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, false);
    defer disabled.deinit();
    disabled.prepare();
    for (1..7) |line_number| try testing.expect(disabled.indicator(line_number) == null);

    var default_off: Harness = undefined;
    try initDefault(&default_off, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, false);
    defer default_off.deinit();
    default_off.prepare();
    for (1..7) |line_number| try testing.expect(default_off.indicator(line_number) == null);
}

test "word wrap indicator: renders nothing when word wrap is off" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 3, &.{ false, false, false }, 1, 3, &.{}, -1, true);
    defer harness.deinit();
    harness.prepare();
    for (1..4) |line_number| try testing.expect(harness.indicator(line_number) == null);
}

test "word wrap indicator: renders nothing for the last view line of the model" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &.{false}, 1, 1, &.{}, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expect(harness.indicator(1) == null);
}

test "word wrap indicator: positions the indicator at the wrapping column" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 3, &.{ true, true, false }, 1, 3, &.{}, 5, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expectEqual(@as(f64, 50), harness.indicator(1).?.left);
    try testing.expectEqual(@as(f64, 50), harness.indicator(2).?.left);
}

test "word wrap indicator: wrapping column wider than the viewport" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 2, &.{ true, false }, 1, 2, &.{}, 12, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expectEqual(@as(f64, 120), harness.indicator(1).?.left);
}

test "word wrap indicator: renders only the view lines inside the viewport" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 2, 4, &.{}, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expect(harness.indicator(1) == null);
    // Line 2 is the first painted line; it continues with a wrapped line.
    try testing.expect(harness.indicator(2) != null);
    try testing.expect(harness.indicator(3) == null);
    try testing.expect(harness.indicator(5) == null);
}

test "word wrap indicator: renders nothing before prepare render has run" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, true);
    defer harness.deinit();
    for (1..7) |line_number| try testing.expect(harness.indicator(line_number) == null);
}

test "word wrap indicator: sizes the indicator to the height of its view line" {
    const heights = [_]f64{ 2 * LINE_HEIGHT, 2 * LINE_HEIGHT, 2 * LINE_HEIGHT, LINE_HEIGHT, LINE_HEIGHT, LINE_HEIGHT };
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &heights, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expectEqual(2 * LINE_HEIGHT, harness.indicator(1).?.height);
    try testing.expectEqual(2 * LINE_HEIGHT, harness.indicator(2).?.height);
    try testing.expectEqual(LINE_HEIGHT, harness.indicator(5).?.height);
}

test "word wrap indicator: keeps the indicator at the wrapping column while scrolled" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expectEqual(INDICATOR_LEFT, harness.indicator(1).?.left);
    harness.layout.viewport.left = 20;
    harness.prepare();
    try testing.expectEqual(INDICATOR_LEFT, harness.indicator(1).?.left);
}

test "word wrap indicator: asks for a rerender on every event that can affect an indicator" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, true);
    defer harness.deinit();
    harness.prepare();

    try testing.expect(harness.overlay.base.handler.onDecorationsChanged(&.{
        .affectsMinimap = false,
        .affectsOverviewRuler = false,
        .affectsGlyphMargin = false,
        .affectsLineNumber = false,
    }));
    try testing.expect(harness.overlay.base.handler.onFlushed(&.{}));
    try testing.expect(harness.overlay.base.handler.onLineMappingChanged(&.{}));
    try testing.expect(harness.overlay.base.handler.onLinesChanged(&.{ .fromLineNumber = 1, .count = 1 }));
    try testing.expect(harness.overlay.base.handler.onLinesDeleted(&.{ .fromLineNumber = 1, .toLineNumber = 1 }));
    try testing.expect(harness.overlay.base.handler.onLinesInserted(&.{ .fromLineNumber = 1, .toLineNumber = 1 }));
    try testing.expect(!harness.overlay.base.handler.onTokensChanged(&.{ .ranges = &.{} }));
    try testing.expect(harness.overlay.base.handler.onZonesChanged(&.{}));
    try testing.expect(harness.overlay.base.handler.onScrollChanged(&scrollEvent(true, false)));
    try testing.expect(!harness.overlay.base.handler.onScrollChanged(&scrollEvent(false, true)));
}

test "word wrap indicator: asks for no rerender while it renders nothing" {
    var disabled: Harness = undefined;
    try initDefault(&disabled, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, false);
    defer disabled.deinit();
    disabled.prepare();
    try testing.expect(!disabled.overlay.base.handler.onDecorationsChanged(&.{
        .affectsMinimap = false,
        .affectsOverviewRuler = false,
        .affectsGlyphMargin = false,
        .affectsLineNumber = false,
    }));
    try testing.expect(!disabled.overlay.base.handler.onFlushed(&.{}));
    try testing.expect(!disabled.overlay.base.handler.onLineMappingChanged(&.{}));
    try testing.expect(!disabled.overlay.base.handler.onScrollChanged(&scrollEvent(true, false)));
}

test "word wrap indicator: ignores token changes" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, true);
    defer harness.deinit();
    harness.prepare();
    try testing.expect(!harness.overlay.base.handler.onTokensChanged(&.{ .ranges = &.{} }));
}

test "word wrap indicator: renders after being re-enabled on the same overlay" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, false);
    defer harness.deinit();

    harness.prepare();
    try testing.expect(harness.indicator(1) == null);

    try testing.expect(harness.updateInvalidates(enableIndicator));
    harness.prepare();
    try testing.expect(harness.indicator(1) != null);

    try testing.expect(harness.updateInvalidates(disableIndicator));
    harness.prepare();
    try testing.expect(harness.indicator(1) == null);

    try testing.expect(harness.updateInvalidates(enableIndicator));
    harness.prepare();
    try testing.expect(harness.indicator(1) != null);
}

test "word wrap indicator: asks for a rerender only on configuration changes that matter" {
    var harness: Harness = undefined;
    try initDefault(&harness, testing.allocator, &WRAPPED_LINES, 1, 6, &.{}, false);
    defer harness.deinit();

    try testing.expect(harness.updateInvalidates(enableIndicator));

    try testing.expect(harness.updateInvalidates(disableIndicator));

    try testing.expect(harness.updateInvalidates(enableAndChangeColumn));

    try testing.expect(!harness.updateInvalidates(turnLineNumbersOff));

    try testing.expect(!harness.updateInvalidates(solidCursor));
}

fn scrollEvent(scroll_top_changed: bool, scroll_left_changed: bool) view_events.ViewScrollChangedEvent {
    return .{
        .scrollWidth = 0,
        .scrollLeft = 0,
        .scrollHeight = 0,
        .scrollTop = 0,
        .scrollWidthChanged = false,
        .scrollLeftChanged = scroll_left_changed,
        .scrollHeightChanged = false,
        .scrollTopChanged = scroll_top_changed,
    };
}

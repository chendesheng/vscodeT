// Port of `src/vs/editor/browser/viewParts/viewCursors/viewCursors.ts`.
//
// Terminal adaptation: there are no DOM cursor nodes and no blink timers. The
// part keeps the upstream blinking-style resolution, visibility, plurality,
// selection-empty and token-invalidation rules; the terminal host drives the
// blink animation (`shouldBlink`) and paints the hardware cursor from
// `getLastRenderData()`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_part = @import("../../view/viewPart.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const editor_options = @import("../../../common/config/editorOptions.zig");
const view_cursor = @import("./viewCursor.zig");
const Position = @import("../../../common/core/position.zig").Position;
const Selection = @import("../../../common/core/selection.zig").Selection;

const ViewPart = view_part.ViewPart;
const RenderingContext = rendering_context.RenderingContext;
const RestrictedRenderingContext = rendering_context.RestrictedRenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const ViewCursor = view_cursor.ViewCursor;
const CursorPlurality = view_cursor.CursorPlurality;
const ViewCursorRenderData = view_cursor.ViewCursorRenderData;
const TextEditorCursorBlinkingStyle = editor_options.TextEditorCursorBlinkingStyle;
const TextEditorCursorStyle = editor_options.TextEditorCursorStyle;
const CursorSmoothCaretAnimation = editor_options.CursorSmoothCaretAnimation;

pub const CursorClassName = struct {
    has_selection: bool,
    cursor_style: TextEditorCursorStyle,
    blinking_style: TextEditorCursorBlinkingStyle,
    smooth_caret_animation: bool,
};

/// Port of `ViewCursors`.
pub const ViewCursors = struct {
    /// Upstream `ViewCursors.BLINK_INTERVAL`; the terminal host uses it when it
    /// drives the blink animation.
    pub const BLINK_INTERVAL: u64 = 500;

    base: ViewPart,
    allocator: Allocator,
    context: *ViewContext,

    read_only: bool,
    cursor_blinking: TextEditorCursorBlinkingStyle,
    cursor_style: TextEditorCursorStyle,
    cursor_smooth_caret_animation: CursorSmoothCaretAnimation,
    edit_context_enabled: bool,
    selection_is_empty: bool,
    is_composing_input: bool,

    is_visible: bool,
    blinking_style: TextEditorCursorBlinkingStyle,
    should_blink: bool,

    editor_has_focus: bool,

    primary_cursor: ViewCursor,
    secondary_cursors: std.array_list.Managed(ViewCursor),
    render_data: std.array_list.Managed(ViewCursorRenderData),

    pub fn init(self: *ViewCursors, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .read_only = false,
            .cursor_blinking = .Blink,
            .cursor_style = .Line,
            .cursor_smooth_caret_animation = .off,
            .edit_context_enabled = false,
            .selection_is_empty = true,
            .is_composing_input = false,
            .is_visible = false,
            .blinking_style = .Blink,
            .should_blink = false,
            .editor_has_focus = false,
            .primary_cursor = undefined,
            .secondary_cursors = std.array_list.Managed(ViewCursor).init(allocator),
            .render_data = std.array_list.Managed(ViewCursorRenderData).init(allocator),
        };
        self.readConfig();
        self.primary_cursor = ViewCursor.init(context, .single);
        self.updateBlinking();
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *ViewCursors) void {
        self.base.deinit();
        self.secondary_cursors.deinit();
        self.render_data.deinit();
    }

    fn readConfig(self: *ViewCursors) void {
        const options = self.context.configuration.options.?;
        self.read_only = options.get(.readOnly);
        self.cursor_blinking = options.get(.cursorBlinking);
        self.cursor_style = options.get(.effectiveCursorStyle);
        self.cursor_smooth_caret_animation = options.get(.cursorSmoothCaretAnimation);
        self.edit_context_enabled = options.get(.effectiveEditContext);
    }

    // --- begin event handlers

    fn onCompositionStart(context: *anyopaque, _: *const view_events.ViewCompositionStartEvent) bool {
        const self: *ViewCursors = @ptrCast(@alignCast(context));
        self.is_composing_input = true;
        self.updateBlinking();
        return true;
    }

    fn onCompositionEnd(context: *anyopaque, _: *const view_events.ViewCompositionEndEvent) bool {
        const self: *ViewCursors = @ptrCast(@alignCast(context));
        self.is_composing_input = false;
        self.updateBlinking();
        return true;
    }

    fn onConfigurationChanged(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *ViewCursors = @ptrCast(@alignCast(context));
        self.readConfig();
        _ = self.primary_cursor.onConfigurationChanged();
        for (self.secondary_cursors.items) |*cursor| _ = cursor.onConfigurationChanged();
        self.updateBlinking();
        return true;
    }

    fn onCursorStateChanged(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *ViewCursors = @ptrCast(@alignCast(context));
        if (event.selections.len == 0) return false;

        const secondary_count = event.selections.len - 1;
        while (self.secondary_cursors.items.len < secondary_count) {
            self.secondary_cursors.append(ViewCursor.init(self.context, .multi_secondary)) catch return false;
        }
        while (self.secondary_cursors.items.len > secondary_count) {
            _ = self.secondary_cursors.pop();
        }

        self.primary_cursor.setPlurality(if (secondary_count > 0) .multi_primary else .single);
        _ = self.primary_cursor.onCursorPositionChanged(event.selections[0].getPosition());
        for (event.selections[1..], 0..) |selection, index| {
            _ = self.secondary_cursors.items[index].onCursorPositionChanged(selection.getPosition());
        }

        self.selection_is_empty = event.selections[0].isEmpty();
        self.updateBlinking();
        return true;
    }

    fn onDecorationsChanged(_: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        // Inline decorations can relayout the text.
        return true;
    }

    fn onFlushed(_: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        return true;
    }

    fn onFocusChanged(context: *anyopaque, event: *const view_events.ViewFocusChangedEvent) bool {
        const self: *ViewCursors = @ptrCast(@alignCast(context));
        self.editor_has_focus = event.isFocused;
        self.updateBlinking();
        return false;
    }

    fn onLinesChanged(_: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
        return true;
    }

    fn onLinesDeleted(_: *anyopaque, _: *const view_events.ViewLinesDeletedEvent) bool {
        return true;
    }

    fn onLinesInserted(_: *anyopaque, _: *const view_events.ViewLinesInsertedEvent) bool {
        return true;
    }

    fn onScrollChanged(_: *anyopaque, _: *const view_events.ViewScrollChangedEvent) bool {
        return true;
    }

    fn onTokensChanged(context: *anyopaque, event: *const view_events.ViewTokensChangedEvent) bool {
        const self: *ViewCursors = @ptrCast(@alignCast(context));
        if (lineIsCovered(self.primary_cursor.position.lineNumber, event.ranges)) return true;
        for (self.secondary_cursors.items) |cursor| {
            if (lineIsCovered(cursor.position.lineNumber, event.ranges)) return true;
        }
        return false;
    }

    fn onZonesChanged(_: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        return true;
    }

    fn lineIsCovered(line_number: usize, ranges: []const view_events.ViewTokensChangedRange) bool {
        for (ranges) |range| {
            if (range.fromLineNumber <= line_number and line_number <= range.toLineNumber) return true;
        }
        return false;
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onCompositionStart = onCompositionStart,
            .onCompositionEnd = onCompositionEnd,
            .onConfigurationChanged = onConfigurationChanged,
            .onCursorStateChanged = onCursorStateChanged,
            .onDecorationsChanged = onDecorationsChanged,
            .onFlushed = onFlushed,
            .onFocusChanged = onFocusChanged,
            .onLinesChanged = onLinesChanged,
            .onLinesDeleted = onLinesDeleted,
            .onLinesInserted = onLinesInserted,
            .onScrollChanged = onScrollChanged,
            .onTokensChanged = onTokensChanged,
            .onZonesChanged = onZonesChanged,
        };
    }

    // --- end event handlers

    /// Port of `_getCursorBlinking`.
    pub fn getCursorBlinking(self: *const ViewCursors) TextEditorCursorBlinkingStyle {
        if (self.is_composing_input and !self.edit_context_enabled) {
            // Avoid double cursors while composing without the edit context.
            return .Hidden;
        }
        if (!self.editor_has_focus) {
            return .Hidden;
        }
        if (self.read_only) {
            return .Solid;
        }
        return self.cursor_blinking;
    }

    fn updateBlinking(self: *ViewCursors) void {
        const blinking_style = self.getCursorBlinking();
        self.blinking_style = blinking_style;
        self.is_visible = blinking_style != .Hidden;
        self.should_blink = switch (blinking_style) {
            .Blink, .Smooth, .Phase, .Expand => true,
            .Hidden, .Solid => false,
        };
        if (self.is_visible) {
            self.primary_cursor.show();
            for (self.secondary_cursors.items) |*cursor| cursor.show();
        } else {
            self.primary_cursor.hide();
            for (self.secondary_cursors.items) |*cursor| cursor.hide();
        }
    }

    /// The terminal host reads the class-name decision as data.
    pub fn className(self: *const ViewCursors) CursorClassName {
        return .{
            .has_selection = !self.selection_is_empty,
            .cursor_style = self.cursor_style,
            .blinking_style = if (self.should_blink) self.blinking_style else .Solid,
            .smooth_caret_animation = self.cursor_smooth_caret_animation != .off,
        };
    }

    pub fn prepareRenderCallback(part: *ViewPart, context: *const RenderingContext) void {
        const self: *ViewCursors = @alignCast(@fieldParentPtr("base", part));
        self.prepareRender(context);
    }

    pub fn renderCallback(part: *ViewPart, restricted: *RestrictedRenderingContext) void {
        const self: *ViewCursors = @alignCast(@fieldParentPtr("base", part));
        self.render(restricted);
    }

    pub fn prepareRender(self: *ViewCursors, context: *const RenderingContext) void {
        self.primary_cursor.prepareRender(context);
        for (self.secondary_cursors.items) |*cursor| cursor.prepareRender(context);
    }

    pub fn render(self: *ViewCursors, context: *const RestrictedRenderingContext) void {
        self.render_data.clearRetainingCapacity();
        if (self.primary_cursor.render(context)) |data| {
            self.render_data.append(data) catch {};
        }
        for (self.secondary_cursors.items) |*cursor| {
            if (cursor.render(context)) |data| {
                self.render_data.append(data) catch {};
            }
        }
    }

    pub fn getLastRenderData(self: *const ViewCursors) []const ViewCursorRenderData {
        return self.render_data.items;
    }

    pub fn secondaryCursorCount(self: *const ViewCursors) usize {
        return self.secondary_cursors.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const browser_config = @import("../../config/editorConfiguration.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const Range = @import("../../../common/core/range.zig").Range;

const ViewLinesState = struct {
    hidden_line: ?usize = null,

    fn lineHeight(_: *anyopaque, _: usize) f64 {
        return 1;
    }

    fn linesVisibleRangesForRange(_: *anyopaque, _: Range, _: bool) ?[]const rendering_context.LineVisibleRanges {
        return null;
    }

    fn visibleRangeForPosition(context: *anyopaque, position: Position) ?rendering_context.HorizontalPosition {
        const self: *ViewLinesState = @ptrCast(@alignCast(context));
        if (self.hidden_line) |line| {
            if (position.lineNumber == line) return null;
        }
        return rendering_context.HorizontalPosition.init(false, 5);
    }
};

const Harness = struct {
    allocator: Allocator,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: ViewContext,
    cursors: ViewCursors,
    viewport: viewport_data.ViewportData,
    rendering: RenderingContext,
    restricted: RestrictedRenderingContext,
    view_lines_state: ViewLinesState,

    fn init(self: *Harness, allocator: Allocator, line_count: usize) !void {
        self.allocator = allocator;
        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.line_count = line_count;
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
        self.cursors = undefined;
        self.cursors.init(allocator, &self.context);
        errdefer self.cursors.deinit();

        const offsets = try allocator.alloc(f64, line_count);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);
        self.viewport = .{
            .selections = &.{},
            .startLineNumber = 1,
            .endLineNumber = line_count,
            .relativeVerticalOffset = offsets,
            .visibleRange = Range.init(1, 1, line_count, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 1,
            ._model = self.context.view_model,
        };
        self.view_lines_state = .{};
        const view_lines = rendering_context.IViewLines{
            .context = &self.view_lines_state,
            .lines_visible_ranges_for_range = ViewLinesState.linesVisibleRangesForRange,
            .visible_range_for_position = ViewLinesState.visibleRangeForPosition,
        };
        self.rendering = RenderingContext.init(self.layout.interface(), &self.viewport, view_lines);
        self.restricted = self.rendering.restricted;
    }

    fn deinit(self: *Harness) void {
        self.cursors.deinit();
        self.allocator.free(self.viewport.relativeVerticalOffset);
        self.allocator.free(@constCast(self.view_model.line_lengths));
    }

    fn focus(self: *Harness, is_focused: bool) void {
        _ = self.cursors.base.handler.onFocusChanged(&.{ .isFocused = is_focused });
    }

    fn setSelections(self: *Harness, selections: []const Selection) void {
        _ = self.cursors.base.handler.onCursorStateChanged(&.{
            .selections = selections,
            .modelSelections = selections,
            .reason = .NotSet,
        });
    }

    fn renderNow(self: *Harness) void {
        self.cursors.prepareRender(&self.rendering);
        self.cursors.render(&self.restricted);
    }
};

test "view cursors: unfocused cursors are hidden" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 4);
    defer harness.deinit();
    const selections = [_]Selection{Selection.init(2, 1, 2, 1)};
    harness.setSelections(&selections);

    try testing.expect(!harness.cursors.is_visible);
    try testing.expectEqual(TextEditorCursorBlinkingStyle.Hidden, harness.cursors.getCursorBlinking());
    harness.renderNow();
    try testing.expectEqual(@as(usize, 1), harness.cursors.getLastRenderData().len);
    try testing.expect(!harness.cursors.getLastRenderData()[0].visible);
}

test "view cursors: focus enables the configured blinking style" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 4);
    defer harness.deinit();
    const selections = [_]Selection{Selection.init(2, 1, 2, 1)};
    harness.setSelections(&selections);
    harness.focus(true);

    try testing.expect(harness.cursors.is_visible);
    try testing.expect(harness.cursors.should_blink);
    try testing.expectEqual(TextEditorCursorBlinkingStyle.Blink, harness.cursors.getCursorBlinking());
    try testing.expectEqual(TextEditorCursorBlinkingStyle.Blink, harness.cursors.className().blinking_style);
}

test "view cursors: read-only cursors are solid" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 4);
    defer harness.deinit();
    const selections = [_]Selection{Selection.init(2, 1, 2, 1)};
    harness.setSelections(&selections);
    harness.focus(true);

    harness.options.set(.readOnly, true);
    harness.cursors.readConfig();
    harness.cursors.updateBlinking();
    try testing.expectEqual(TextEditorCursorBlinkingStyle.Solid, harness.cursors.getCursorBlinking());
    try testing.expect(harness.cursors.is_visible);
    try testing.expect(!harness.cursors.should_blink);
    try testing.expectEqual(TextEditorCursorBlinkingStyle.Solid, harness.cursors.className().blinking_style);
}

test "view cursors: composing hides the cursor without the edit context" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 4);
    defer harness.deinit();
    const selections = [_]Selection{Selection.init(2, 1, 2, 1)};
    harness.setSelections(&selections);
    harness.focus(true);

    _ = harness.cursors.base.handler.onCompositionStart(&.{});
    try testing.expectEqual(TextEditorCursorBlinkingStyle.Hidden, harness.cursors.getCursorBlinking());
    try testing.expect(!harness.cursors.is_visible);

    _ = harness.cursors.base.handler.onCompositionEnd(&.{});
    try testing.expect(harness.cursors.is_visible);
}

test "view cursors: primary and secondary cursors follow the selections" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 6);
    defer harness.deinit();
    const selections = [_]Selection{
        Selection.init(2, 1, 2, 3),
        Selection.init(4, 1, 4, 1),
        Selection.init(5, 2, 5, 2),
    };
    harness.setSelections(&selections);

    try testing.expectEqual(@as(usize, 2), harness.cursors.secondaryCursorCount());
    try testing.expectEqual(CursorPlurality.multi_primary, harness.cursors.primary_cursor.plurality);
    try testing.expectEqual(CursorPlurality.multi_secondary, harness.cursors.secondary_cursors.items[0].plurality);
    try testing.expect(!harness.cursors.selection_is_empty);
    try testing.expect(harness.cursors.className().has_selection);
    try testing.expectEqual(@as(usize, 5), harness.cursors.secondary_cursors.items[1].position.lineNumber);

    // Shrinking the selection set removes secondary cursors.
    const single = [_]Selection{Selection.init(1, 1, 1, 1)};
    harness.setSelections(&single);
    try testing.expectEqual(@as(usize, 0), harness.cursors.secondaryCursorCount());
    try testing.expectEqual(CursorPlurality.single, harness.cursors.primary_cursor.plurality);
    try testing.expect(harness.cursors.selection_is_empty);
}

test "view cursors: token changes only invalidate when a cursor line is covered" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 6);
    defer harness.deinit();
    const selections = [_]Selection{
        Selection.init(2, 1, 2, 1),
        Selection.init(5, 1, 5, 1),
    };
    harness.setSelections(&selections);

    const unrelated = [_]view_events.ViewTokensChangedRange{.{ .fromLineNumber = 1, .toLineNumber = 1 }};
    try testing.expect(!harness.cursors.base.handler.onTokensChanged(&.{ .ranges = &unrelated }));

    const primary = [_]view_events.ViewTokensChangedRange{.{ .fromLineNumber = 2, .toLineNumber = 2 }};
    try testing.expect(harness.cursors.base.handler.onTokensChanged(&.{ .ranges = &primary }));

    const secondary = [_]view_events.ViewTokensChangedRange{.{ .fromLineNumber = 4, .toLineNumber = 6 }};
    try testing.expect(harness.cursors.base.handler.onTokensChanged(&.{ .ranges = &secondary }));
}

test "view cursors: render data skips cursors outside the viewport" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 6);
    defer harness.deinit();
    const selections = [_]Selection{
        Selection.init(2, 1, 2, 1),
        Selection.init(5, 1, 5, 1),
    };
    harness.setSelections(&selections);
    harness.focus(true);
    harness.view_lines_state.hidden_line = 5;

    harness.renderNow();
    try testing.expectEqual(@as(usize, 1), harness.cursors.getLastRenderData().len);
    try testing.expectEqual(@as(usize, 2), harness.cursors.getLastRenderData()[0].position.lineNumber);
    try testing.expectEqual(@as(usize, 5), harness.cursors.getLastRenderData()[0].left);
    try testing.expect(harness.cursors.getLastRenderData()[0].visible);
}

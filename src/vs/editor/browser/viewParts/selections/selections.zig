// Port of `src/vs/editor/browser/viewParts/selections/selections.ts`.
//
// Terminal adaptation: upstream renders selection pieces as positioned `<div>`
// elements with rounded-corner background pieces. A cell grid has no rounded
// corners, so the part keeps the upstream range/style computation and produces
// per-view-line styled ranges (with the multi-selection top/bottom insets)
// instead of HTML. The inner-corner background pieces are DOM/CSS-only and are
// not generated; the terminal paints the selection cells from the ranges.
const std = @import("std");
const Allocator = std.mem.Allocator;

const dynamic_overlay = @import("../../view/dynamicViewOverlay.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const Selection = @import("../../../common/core/selection.zig").Selection;
const Range = @import("../../../common/core/range.zig").Range;

const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const RenderingContext = rendering_context.RenderingContext;
const LineVisibleRanges = rendering_context.LineVisibleRanges;
const HorizontalRange = rendering_context.HorizontalRange;
const Range_mod = @import("../../../common/core/range.zig");
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;

pub const CornerStyle = enum { extern_corner, intern, flat };

pub const EndPointStyle = struct {
    top: CornerStyle = .extern_corner,
    bottom: CornerStyle = .extern_corner,
};

/// A visible selection range on one view line, in the pixel coordinates the
/// ported view-lines layer reports. Corner styles are kept for parity even
/// though the terminal cannot paint rounded corners.
pub const StyledRange = struct {
    left: i32,
    width: i32,
    start_style: ?EndPointStyle = null,
    end_style: ?EndPointStyle = null,
    /// Upstream inset (0 or 1) used by multiple selections so they do not touch.
    top_inset: i32 = 0,
    bottom_inset: i32 = 0,
};

pub const LineVisibleRangesWithStyle = struct {
    line_number: usize,
    ranges: []StyledRange,
};

pub const LineSelectionRender = struct {
    line_number: usize,
    ranges: []StyledRange,
};

fn absF64(value: f64) f64 {
    return if (value < 0) -value else value;
}

fn absI32(value: i32) i32 {
    return if (value < 0) -value else value;
}

/// Port of `SelectionsOverlay`.
pub const SelectionsOverlay = struct {
    base: DynamicViewOverlay,
    allocator: Allocator,
    context: *ViewContext,

    rounded_selection: bool,
    typical_halfwidth_character_width: f64,
    selections: std.array_list.Managed(Selection),
    render_result: ?[]LineSelectionRender,
    render_start_line_number: usize,
    previous_frame_visible_ranges_with_style: std.array_list.Managed(?[]LineVisibleRangesWithStyle),

    pub fn init(self: *SelectionsOverlay, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .rounded_selection = true,
            .typical_halfwidth_character_width = 0,
            .selections = std.array_list.Managed(Selection).init(allocator),
            .render_result = null,
            .render_start_line_number = 1,
            .previous_frame_visible_ranges_with_style = std.array_list.Managed(?[]LineVisibleRangesWithStyle).init(allocator),
        };
        self.readConfig();
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *SelectionsOverlay) void {
        self.base.deinit();
        self.clearRenderResult();
        self.clearPreviousFrames();
        self.selections.deinit();
        self.previous_frame_visible_ranges_with_style.deinit();
    }

    fn readConfig(self: *SelectionsOverlay) void {
        const options = self.context.configuration.options.?;
        self.rounded_selection = options.get(.roundedSelection);
        self.typical_halfwidth_character_width = options.get(.fontInfo).typicalHalfwidthCharacterWidth;
    }

    // --- begin event handlers

    fn onConfigurationChanged(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *SelectionsOverlay = @ptrCast(@alignCast(context));
        self.readConfig();
        return true;
    }

    /// Feeds the current selections when the host does not dispatch view
    /// events through the view model.
    pub fn setSelections(self: *SelectionsOverlay, selections: []const Selection) void {
        self.selections.clearRetainingCapacity();
        self.selections.appendSlice(selections) catch {};
    }

    fn onCursorStateChanged(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *SelectionsOverlay = @ptrCast(@alignCast(context));
        self.setSelections(event.selections);
        return true;
    }

    fn onDecorationsChanged(_: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        // Any decoration can relayout the text.
        return true;
    }

    fn onFlushed(_: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
        return true;
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

    fn onScrollChanged(_: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        return event.scrollTopChanged;
    }

    fn onZonesChanged(_: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        return true;
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = onConfigurationChanged,
            .onCursorStateChanged = onCursorStateChanged,
            .onDecorationsChanged = onDecorationsChanged,
            .onFlushed = onFlushed,
            .onLinesChanged = onLinesChanged,
            .onLinesDeleted = onLinesDeleted,
            .onLinesInserted = onLinesInserted,
            .onScrollChanged = onScrollChanged,
            .onZonesChanged = onZonesChanged,
        };
    }

    // --- end event handlers

    fn visibleRangesHaveGaps(lines_visible_ranges: []const LineVisibleRangesWithStyle) bool {
        for (lines_visible_ranges) |line_visible_ranges| {
            if (line_visible_ranges.ranges.len > 1) {
                // There are two ranges on the same line.
                return true;
            }
        }
        return false;
    }

    fn toStyledRange(range: HorizontalRange) StyledRange {
        return .{ .left = range.left, .width = range.width };
    }

    fn toStyled(allocator: Allocator, item: LineVisibleRanges) !LineVisibleRangesWithStyle {
        const ranges = try allocator.alloc(StyledRange, item.ranges.len);
        for (item.ranges, 0..) |range, index| {
            ranges[index] = toStyledRange(range);
        }
        return .{ .line_number = item.lineNumber, .ranges = ranges };
    }

    fn topOfStyledRange(range: *const StyledRange) CornerStyle {
        return if (range.start_style) |style| style.top else .extern_corner;
    }

    fn bottomOfStyledRange(range: *const StyledRange) CornerStyle {
        return if (range.start_style) |style| style.bottom else .extern_corner;
    }

    fn endTopOfStyledRange(range: *const StyledRange) CornerStyle {
        return if (range.end_style) |style| style.top else .extern_corner;
    }

    fn endBottomOfStyledRange(range: *const StyledRange) CornerStyle {
        return if (range.end_style) |style| style.bottom else .extern_corner;
    }

    fn findFrameRange(frame: []const LineVisibleRangesWithStyle, line_number: usize) ?*const StyledRange {
        for (frame) |*line_ranges| {
            if (line_ranges.line_number == line_number and line_ranges.ranges.len > 0) {
                return &line_ranges.ranges[0];
            }
        }
        return null;
    }

    fn enrichVisibleRangesWithStyle(
        self: *SelectionsOverlay,
        viewport: Range,
        lines_visible_ranges: []LineVisibleRangesWithStyle,
        previous_frame: ?[]LineVisibleRangesWithStyle,
    ) void {
        const epsilon = self.typical_halfwidth_character_width / 4;
        var previous_frame_top: ?*const StyledRange = null;
        var previous_frame_bottom: ?*const StyledRange = null;

        if (previous_frame) |frame| {
            if (frame.len > 0 and lines_visible_ranges.len > 0) {
                const top_line_number = lines_visible_ranges[0].line_number;
                if (top_line_number == viewport.startLineNumber) {
                    previous_frame_top = findFrameRange(frame, top_line_number);
                }

                const bottom_line_number = lines_visible_ranges[lines_visible_ranges.len - 1].line_number;
                if (bottom_line_number == viewport.endLineNumber) {
                    previous_frame_bottom = findFrameRange(frame, bottom_line_number);
                }

                if (previous_frame_top) |top| {
                    if (top.start_style == null) previous_frame_top = null;
                }
                if (previous_frame_bottom) |bottom| {
                    if (bottom.start_style == null) previous_frame_bottom = null;
                }
            }
        }

        for (lines_visible_ranges, 0..) |*line_visible_ranges, index| {
            // We know for a fact that there is precisely one range on each line.
            const cur_line_range = &line_visible_ranges.ranges[0];
            const cur_left: f64 = @floatFromInt(cur_line_range.left);
            const cur_right: f64 = @floatFromInt(cur_line_range.left + cur_line_range.width);

            var start_style = EndPointStyle{ .top = .extern_corner, .bottom = .extern_corner };
            var end_style = EndPointStyle{ .top = .extern_corner, .bottom = .extern_corner };

            if (index > 0) {
                // Look above.
                const prev = &lines_visible_ranges[index - 1].ranges[0];
                const prev_left: f64 = @floatFromInt(prev.left);
                const prev_right: f64 = @floatFromInt(prev.left + prev.width);

                if (absF64(cur_left - prev_left) < epsilon) {
                    start_style.top = .flat;
                } else if (cur_left > prev_left) {
                    start_style.top = .intern;
                }

                if (absF64(cur_right - prev_right) < epsilon) {
                    end_style.top = .flat;
                } else if (prev_left < cur_right and cur_right < prev_right) {
                    end_style.top = .intern;
                }
            } else if (previous_frame_top) |top| {
                // Accept some hiccups near the viewport edges to save on repaints.
                start_style.top = topOfStyledRange(top);
                end_style.top = endTopOfStyledRange(top);
            }

            if (index + 1 < lines_visible_ranges.len) {
                // Look below.
                const next = &lines_visible_ranges[index + 1].ranges[0];
                const next_left: f64 = @floatFromInt(next.left);
                const next_right: f64 = @floatFromInt(next.left + next.width);

                if (absF64(cur_left - next_left) < epsilon) {
                    start_style.bottom = .flat;
                } else if (next_left < cur_left and cur_left < next_right) {
                    start_style.bottom = .intern;
                }

                if (absF64(cur_right - next_right) < epsilon) {
                    end_style.bottom = .flat;
                } else if (cur_right < next_right) {
                    end_style.bottom = .intern;
                }
            } else if (previous_frame_bottom) |bottom| {
                // Accept some hiccups near the viewport edges to save on repaints.
                start_style.bottom = bottomOfStyledRange(bottom);
                end_style.bottom = endBottomOfStyledRange(bottom);
            }

            cur_line_range.start_style = start_style;
            cur_line_range.end_style = end_style;
        }
    }

    fn getVisibleRangesWithStyle(
        self: *SelectionsOverlay,
        selection: Selection,
        context: *const RenderingContext,
        previous_frame: ?[]LineVisibleRangesWithStyle,
    ) ![]LineVisibleRangesWithStyle {
        const selection_range = Range.init(
            selection.startLineNumber,
            selection.startColumn,
            selection.endLineNumber,
            selection.endColumn,
        );
        const lines = context.linesVisibleRangesForRange(selection_range, true) orelse &.{};
        const lines_visible_ranges = try self.allocator.alloc(LineVisibleRangesWithStyle, lines.len);
        var filled: usize = 0;
        errdefer {
            for (lines_visible_ranges[0..filled]) |frame| self.allocator.free(frame.ranges);
            self.allocator.free(lines_visible_ranges);
        }
        for (lines, 0..) |line, index| {
            lines_visible_ranges[index] = try toStyled(self.allocator, line);
            filled += 1;
        }

        const visible_ranges_have_gaps = visibleRangesHaveGaps(lines_visible_ranges);
        if (!visible_ranges_have_gaps and self.rounded_selection) {
            self.enrichVisibleRangesWithStyle(
                context.restricted.visibleRange,
                lines_visible_ranges,
                previous_frame,
            );
        }

        return lines_visible_ranges;
    }

    fn freeFrame(self: *SelectionsOverlay, frame: []LineVisibleRangesWithStyle) void {
        for (frame) |line| self.allocator.free(line.ranges);
        self.allocator.free(frame);
    }

    fn clearPreviousFrames(self: *SelectionsOverlay) void {
        for (self.previous_frame_visible_ranges_with_style.items) |maybe_frame| {
            if (maybe_frame) |frame| self.freeFrame(frame);
        }
        self.previous_frame_visible_ranges_with_style.clearRetainingCapacity();
    }

    fn actualRenderOneSelection(
        self: *SelectionsOverlay,
        output: []std.array_list.Managed(StyledRange),
        visible_start_line_number: usize,
        has_multiple_selections: bool,
        visible_ranges: []const LineVisibleRangesWithStyle,
    ) void {
        _ = self;
        if (visible_ranges.len == 0) return;

        const first_line_number = visible_ranges[0].line_number;
        const last_line_number = visible_ranges[visible_ranges.len - 1].line_number;

        for (visible_ranges) |line_visible_ranges| {
            const line_number = line_visible_ranges.line_number;
            if (line_number < visible_start_line_number) continue;
            const line_index = line_number - visible_start_line_number;
            if (line_index >= output.len) continue;

            const top: i32 = if (has_multiple_selections and line_number == first_line_number) 1 else 0;
            const bottom: i32 = if (has_multiple_selections and line_number != first_line_number and line_number == last_line_number) 1 else 0;

            for (line_visible_ranges.ranges) |range| {
                output[line_index].append(.{
                    .left = range.left,
                    .width = range.width,
                    .start_style = range.start_style,
                    .end_style = range.end_style,
                    .top_inset = top,
                    .bottom_inset = bottom,
                }) catch {};
            }
        }
    }

    fn prepareRenderCallback(overlay: *DynamicViewOverlay, context: *const RenderingContext) void {
        const self: *SelectionsOverlay = @fieldParentPtr("base", overlay);
        self.prepareRender(context);
    }

    fn renderCallback(overlay: *DynamicViewOverlay, _: usize, _: usize) []const u8 {
        _ = overlay;
        return "";
    }

    fn buildRenderResult(self: *SelectionsOverlay, context: *const RenderingContext) !void {
        const visible_start_line_number = context.restricted.visibleRange.startLineNumber;
        const visible_end_line_number = context.restricted.visibleRange.endLineNumber;
        if (visible_end_line_number < visible_start_line_number) return;

        const line_count = visible_end_line_number - visible_start_line_number + 1;
        const line_ranges = try self.allocator.alloc(std.array_list.Managed(StyledRange), line_count);
        var initialized: usize = 0;
        errdefer {
            for (line_ranges[0..initialized]) |*ranges| ranges.deinit();
            self.allocator.free(line_ranges);
        }
        for (line_ranges) |*ranges| {
            ranges.* = std.array_list.Managed(StyledRange).init(self.allocator);
            initialized += 1;
        }

        var this_frame = std.array_list.Managed(?[]LineVisibleRangesWithStyle).init(self.allocator);
        defer this_frame.deinit();
        errdefer {
            for (this_frame.items) |maybe_frame| {
                if (maybe_frame) |frame| self.freeFrame(frame);
            }
        }

        for (self.selections.items) |selection| {
            if (selection.isEmpty()) {
                try this_frame.append(null);
                continue;
            }
            const previous = if (self.previous_frame_visible_ranges_with_style.items.len > this_frame.items.len)
                self.previous_frame_visible_ranges_with_style.items[this_frame.items.len]
            else
                null;
            const visible_ranges_with_style = try self.getVisibleRangesWithStyle(selection, context, previous);
            try this_frame.append(visible_ranges_with_style);
            self.actualRenderOneSelection(
                line_ranges,
                visible_start_line_number,
                self.selections.items.len > 1,
                visible_ranges_with_style,
            );
        }

        // Replace the previous frame with this one.
        self.clearPreviousFrames();
        try self.previous_frame_visible_ranges_with_style.appendSlice(this_frame.items);

        const result = try self.allocator.alloc(LineSelectionRender, line_count);
        var filled: usize = 0;
        errdefer {
            for (result[0..filled]) |entry| self.allocator.free(entry.ranges);
            self.allocator.free(result);
        }
        for (line_ranges, 0..) |*ranges, index| {
            result[index] = .{
                .line_number = visible_start_line_number + index,
                .ranges = try ranges.toOwnedSlice(),
            };
            filled += 1;
            ranges.deinit();
        }
        self.allocator.free(line_ranges);

        self.render_result = result;
        self.render_start_line_number = visible_start_line_number;
    }

    pub fn prepareRender(self: *SelectionsOverlay, context: *const RenderingContext) void {
        self.clearRenderResult();
        self.buildRenderResult(context) catch {
            self.clearRenderResult();
        };
    }

    pub fn render(self: *SelectionsOverlay, start_line_number: usize, line_number: usize) []const u8 {
        _ = self;
        _ = start_line_number;
        _ = line_number;
        return "";
    }

    /// The terminal compositor queries the styled selection ranges of a view line.
    pub fn renderedLine(self: *const SelectionsOverlay, line_number: usize) ?*const LineSelectionRender {
        const result = self.render_result orelse return null;
        if (line_number < self.render_start_line_number) return null;
        const line_index = line_number - self.render_start_line_number;
        if (line_index >= result.len) return null;
        return &result[line_index];
    }

    fn clearRenderResult(self: *SelectionsOverlay) void {
        const result = self.render_result orelse return;
        for (result) |entry| self.allocator.free(entry.ranges);
        self.allocator.free(result);
        self.render_result = null;
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

const RangeType = Range_mod.Range;

const ViewLinesState = struct {
    lines: []const LineVisibleRanges = &.{},
    requested_ranges: std.array_list.Managed(RangeType),

    fn linesVisibleRangesForRange(context: *anyopaque, range: RangeType, _: bool) ?[]const LineVisibleRanges {
        const self: *ViewLinesState = @ptrCast(@alignCast(context));
        self.requested_ranges.append(range) catch {};
        return self.lines;
    }

    fn visibleRangeForPosition(_: *anyopaque, _: @import("../../../common/core/position.zig").Position) ?rendering_context.HorizontalPosition {
        return null;
    }
};

const Harness = struct {
    allocator: Allocator,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: ViewContext,
    overlay: SelectionsOverlay,
    viewport: viewport_data.ViewportData,
    rendering: RenderingContext,
    view_lines_state: ViewLinesState,

    fn init(self: *Harness, allocator: Allocator, line_count: usize, selections: []const Selection) !void {
        self.allocator = allocator;
        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.line_count = line_count;
        const line_lengths = try allocator.alloc(usize, line_count);
        errdefer allocator.free(line_lengths);
        @memset(line_lengths, 80);
        self.view_model.line_lengths = line_lengths;
        const theme = test_stubs.TestColorTheme.dark();
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.context = ViewContext.init(&self.configuration, theme, self.view_model.interface());
        self.overlay = undefined;
        self.overlay.init(allocator, &self.context);
        errdefer self.overlay.deinit();
        self.overlay.selections.clearRetainingCapacity();
        try self.overlay.selections.appendSlice(selections);

        const offsets = try allocator.alloc(f64, line_count);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);
        self.viewport = .{
            .selections = selections,
            .startLineNumber = 1,
            .endLineNumber = line_count,
            .relativeVerticalOffset = offsets,
            .visibleRange = RangeType.init(1, 1, line_count, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 1,
            ._model = self.context.view_model,
        };
        self.view_lines_state = .{ .requested_ranges = std.array_list.Managed(RangeType).init(allocator) };
        const view_lines = rendering_context.IViewLines{
            .context = &self.view_lines_state,
            .lines_visible_ranges_for_range = ViewLinesState.linesVisibleRangesForRange,
            .visible_range_for_position = ViewLinesState.visibleRangeForPosition,
        };
        self.rendering = RenderingContext.init(self.layout.interface(), &self.viewport, view_lines);
    }

    fn deinit(self: *Harness) void {
        self.overlay.deinit();
        self.view_lines_state.requested_ranges.deinit();
        self.allocator.free(self.viewport.relativeVerticalOffset);
        self.allocator.free(@constCast(self.view_model.line_lengths));
    }
};

const RangeEntry = struct {
    line: usize,
    ranges: []const HorizontalRange,
};

fn makeRanges(allocator: Allocator, entries: []const RangeEntry) ![]LineVisibleRanges {
    const result = try allocator.alloc(LineVisibleRanges, entries.len);
    for (entries, 0..) |entry, index| {
        result[index] = .{
            .outsideRenderedLine = false,
            .lineNumber = entry.line,
            .ranges = entry.ranges,
            .continuesOnNextLine = false,
        };
    }
    return result;
}

test "selections: single selection ranges are reported per view line" {
    const allocator = testing.allocator;
    const ranges_line2 = [_]HorizontalRange{.{ .left = 10, .width = 30 }};
    const ranges_line3 = [_]HorizontalRange{.{ .left = 20, .width = 10 }};
    const entries = [_]RangeEntry{
        .{ .line = 2, .ranges = &ranges_line2 },
        .{ .line = 3, .ranges = &ranges_line3 },
    };
    const ranges = try makeRanges(allocator, &entries);
    defer allocator.free(ranges);

    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(2, 1, 3, 5)};
    try harness.init(allocator, 4, &selections);
    defer harness.deinit();
    harness.view_lines_state.lines = ranges;
    harness.options.set(.roundedSelection, false);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(2).?.ranges.len);
    try testing.expectEqual(@as(i32, 10), harness.overlay.renderedLine(2).?.ranges[0].left);
    try testing.expectEqual(@as(i32, 30), harness.overlay.renderedLine(2).?.ranges[0].width);
    try testing.expectEqual(@as(i32, 20), harness.overlay.renderedLine(3).?.ranges[0].left);
    try testing.expectEqual(@as(usize, 0), harness.overlay.renderedLine(1).?.ranges.len);
    try testing.expectEqual(@as(usize, 1), harness.view_lines_state.requested_ranges.items.len);
}

test "selections: rounded selection styles follow the neighbouring lines" {
    const allocator = testing.allocator;
    const ranges_line2 = [_]HorizontalRange{.{ .left = 10, .width = 30 }};
    const ranges_line3 = [_]HorizontalRange{.{ .left = 10, .width = 30 }};
    const ranges_line4 = [_]HorizontalRange{.{ .left = 40, .width = 20 }};
    const entries = [_]RangeEntry{
        .{ .line = 2, .ranges = &ranges_line2 },
        .{ .line = 3, .ranges = &ranges_line3 },
        .{ .line = 4, .ranges = &ranges_line4 },
    };
    const ranges = try makeRanges(allocator, &entries);
    defer allocator.free(ranges);

    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(2, 1, 4, 3)};
    try harness.init(allocator, 5, &selections);
    defer harness.deinit();
    harness.view_lines_state.lines = ranges;
    var font_info = harness.options.get(.fontInfo);
    font_info.typicalHalfwidthCharacterWidth = 8;
    harness.options.set(.fontInfo, font_info);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);

    // Line 2: no line above, the line below is identical => flat bottom.
    try testing.expectEqual(CornerStyle.extern_corner, harness.overlay.renderedLine(2).?.ranges[0].start_style.?.top);
    try testing.expectEqual(CornerStyle.flat, harness.overlay.renderedLine(2).?.ranges[0].start_style.?.bottom);
    // Line 3: identical on both sides => flat top and bottom.
    try testing.expectEqual(CornerStyle.flat, harness.overlay.renderedLine(3).?.ranges[0].start_style.?.top);
    try testing.expectEqual(CornerStyle.intern, harness.overlay.renderedLine(3).?.ranges[0].end_style.?.bottom);
    // Line 4: starts inside the line above (intern), no line below.
    try testing.expectEqual(CornerStyle.intern, harness.overlay.renderedLine(4).?.ranges[0].start_style.?.top);
    try testing.expectEqual(CornerStyle.extern_corner, harness.overlay.renderedLine(4).?.ranges[0].start_style.?.bottom);
}

test "selections: gaps disable rounded corner styles" {
    const allocator = testing.allocator;
    const ranges_line2 = [_]HorizontalRange{ .{ .left = 5, .width = 10 }, .{ .left = 40, .width = 10 } };
    const ranges_line3 = [_]HorizontalRange{.{ .left = 5, .width = 10 }};
    const entries = [_]RangeEntry{
        .{ .line = 2, .ranges = &ranges_line2 },
        .{ .line = 3, .ranges = &ranges_line3 },
    };
    const ranges = try makeRanges(allocator, &entries);
    defer allocator.free(ranges);

    var harness: Harness = undefined;
    const selections = [_]Selection{Selection.init(2, 1, 3, 5)};
    try harness.init(allocator, 4, &selections);
    defer harness.deinit();
    harness.view_lines_state.lines = ranges;
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expect(harness.overlay.renderedLine(2).?.ranges[0].start_style == null);
    try testing.expect(harness.overlay.renderedLine(2).?.ranges[1].start_style == null);
}

test "selections: multiple selections inset the first and last line" {
    const allocator = testing.allocator;
    const ranges_line2 = [_]HorizontalRange{.{ .left = 10, .width = 10 }};
    const ranges_line4 = [_]HorizontalRange{.{ .left = 10, .width = 10 }};
    const entries = [_]RangeEntry{
        .{ .line = 2, .ranges = &ranges_line2 },
        .{ .line = 4, .ranges = &ranges_line4 },
    };
    const ranges = try makeRanges(allocator, &entries);
    defer allocator.free(ranges);

    var harness: Harness = undefined;
    const selections = [_]Selection{
        Selection.init(2, 1, 2, 3),
        Selection.init(4, 1, 4, 3),
    };
    try harness.init(allocator, 5, &selections);
    defer harness.deinit();
    harness.view_lines_state.lines = ranges;
    harness.options.set(.roundedSelection, false);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqual(@as(i32, 1), harness.overlay.renderedLine(2).?.ranges[0].top_inset);
    try testing.expectEqual(@as(i32, 0), harness.overlay.renderedLine(2).?.ranges[0].bottom_inset);
    try testing.expectEqual(@as(i32, 0), harness.overlay.renderedLine(4).?.ranges[0].top_inset);
    try testing.expectEqual(@as(i32, 1), harness.overlay.renderedLine(4).?.ranges[0].bottom_inset);
}

test "selections: empty selections are skipped" {
    const allocator = testing.allocator;
    const ranges_line2 = [_]HorizontalRange{.{ .left = 10, .width = 10 }};
    const entries = [_]RangeEntry{
        .{ .line = 2, .ranges = &ranges_line2 },
    };
    const ranges = try makeRanges(allocator, &entries);
    defer allocator.free(ranges);

    var harness: Harness = undefined;
    const selections = [_]Selection{
        Selection.init(2, 1, 2, 1),
        Selection.init(2, 1, 2, 3),
    };
    try harness.init(allocator, 3, &selections);
    defer harness.deinit();
    harness.view_lines_state.lines = ranges;
    harness.options.set(.roundedSelection, false);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);

    // Only the non-empty selection requested visible ranges.
    try testing.expectEqual(@as(usize, 1), harness.view_lines_state.requested_ranges.items.len);
    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(2).?.ranges.len);
}

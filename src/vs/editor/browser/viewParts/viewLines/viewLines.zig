// Port of the terminal subset of
// `src/vs/editor/browser/viewParts/viewLines/viewLines.ts`.
//
// Terminal adaptation: upstream is a DOM view part that measures rendered
// spans; the terminal version renders the visible line window into a
// `StringBuilder` (`renderText`) and implements `IViewLines` with cell-column
// ranges derived from `CursorColumns` instead of DOM reading. The reveal,
// sticky-scroll, GPU and line-width bookkeeping are browser/layout concerns and
// are not ported here.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_part = @import("../../view/viewPart.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_layer = @import("../../view/viewLayer.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const viewport_data = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const view_line = @import("./viewLine.zig");
const view_line_options = @import("./viewLineOptions.zig");
const StringBuilder = @import("../../../common/core/stringBuilder.zig").StringBuilder;
const CursorColumns = @import("../../../common/core/cursorColumns.zig").CursorColumns;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;

const ViewPart = view_part.ViewPart;
const RenderingContext = rendering_context.RenderingContext;
const RestrictedRenderingContext = rendering_context.RestrictedRenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const ViewportData = viewport_data.ViewportData;
const ViewLine = view_line.ViewLine;
const ViewLineOptions = view_line_options.ViewLineOptions;
const LineVisibleRanges = rendering_context.LineVisibleRanges;
const HorizontalRange = rendering_context.HorizontalRange;
const HorizontalPosition = rendering_context.HorizontalPosition;
const IViewLines = rendering_context.IViewLines;

/// Port of `ViewLines` (terminal rendering subset).
pub const ViewLines = struct {
    base: ViewPart,
    allocator: Allocator,
    context: *ViewContext,
    view_line_options: ViewLineOptions,
    line_factory: LineFactory,
    visible_lines: view_layer.VisibleLinesCollection(ViewLine),
    last_viewport: ?*const ViewportData = null,
    last_visible_range: Range = Range.init(1, 1, 1, 1),
    scratch: std.heap.ArenaAllocator,

    const LineFactory = struct {
        allocator: Allocator,
        context: *ViewContext,
        options: ViewLineOptions,

        fn create(pointer: *anyopaque) anyerror!ViewLine {
            const self: *LineFactory = @ptrCast(@alignCast(pointer));
            return ViewLine.init(self.allocator, self.context, self.options);
        }
    };

    pub fn init(self: *ViewLines, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .view_line_options = ViewLineOptions.init(context.configuration, context.theme.getType()),
            .line_factory = undefined,
            .visible_lines = undefined,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
        self.line_factory = .{
            .allocator = allocator,
            .context = context,
            .options = self.view_line_options,
        };
        self.visible_lines = view_layer.VisibleLinesCollection(ViewLine).init(
            allocator,
            context.view_layout,
            .{ .context = &self.line_factory, .create = LineFactory.create },
        );
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *ViewLines) void {
        self.base.deinit();
        _ = self.visible_lines.onFlushed(&.{});
        self.visible_lines.deinit();
        self.scratch.deinit();
    }

    // --- begin view event handlers

    fn onConfigurationChanged(context: *anyopaque, event: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        _ = self.visible_lines.onConfigurationChanged(event);
        _ = self.updateOptions();
        return true;
    }

    fn onCursorStateChanged(context: *anyopaque, _: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        var should_render = false;
        const start = self.visible_lines.getStartLineNumber();
        const end = self.visible_lines.getEndLineNumber();
        if (end >= start) {
            var line_number = start;
            while (line_number <= end) : (line_number += 1) {
                should_render = self.visible_lines.getVisibleLine(line_number).onSelectionChanged() or should_render;
            }
        }
        return should_render;
    }

    fn onDecorationsChanged(context: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        const start = self.visible_lines.getStartLineNumber();
        const end = self.visible_lines.getEndLineNumber();
        if (end >= start) {
            var line_number = start;
            while (line_number <= end) : (line_number += 1) {
                self.visible_lines.getVisibleLine(line_number).onDecorationsChanged();
            }
        }
        return true;
    }

    fn onFlushed(context: *anyopaque, event: *const view_events.ViewFlushedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visible_lines.onFlushed(event);
    }

    fn onLinesChanged(context: *anyopaque, event: *const view_events.ViewLinesChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visible_lines.onLinesChanged(event);
    }

    fn onLinesDeleted(context: *anyopaque, event: *const view_events.ViewLinesDeletedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visible_lines.onLinesDeleted(event) catch false;
    }

    fn onLinesInserted(context: *anyopaque, event: *const view_events.ViewLinesInsertedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visible_lines.onLinesInserted(event) catch false;
    }

    fn onScrollChanged(context: *anyopaque, event: *const view_events.ViewScrollChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visible_lines.onScrollChanged(event) or event.scrollLeftChanged;
    }

    fn onTokensChanged(context: *anyopaque, event: *const view_events.ViewTokensChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visible_lines.onTokensChanged(event);
    }

    fn onZonesChanged(context: *anyopaque, event: *const view_events.ViewZonesChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visible_lines.onZonesChanged(event);
    }

    fn onThemeChanged(context: *anyopaque, _: *const view_events.ViewThemeChangedEvent) bool {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.updateOptions();
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
            .onTokensChanged = onTokensChanged,
            .onZonesChanged = onZonesChanged,
            .onThemeChanged = onThemeChanged,
        };
    }

    // --- end view event handlers

    fn updateOptions(self: *ViewLines) bool {
        const new_options = ViewLineOptions.init(self.context.configuration, self.context.theme.getType());
        if (self.view_line_options.equals(new_options)) return false;
        self.view_line_options = new_options;
        self.line_factory.options = new_options;
        const start = self.visible_lines.getStartLineNumber();
        const end = self.visible_lines.getEndLineNumber();
        if (end >= start) {
            var line_number = start;
            while (line_number <= end) : (line_number += 1) {
                self.visible_lines.getVisibleLine(line_number).onOptionsChanged(new_options);
            }
        }
        return true;
    }

    fn prepareRenderCallback(part: *ViewPart, _: *RenderingContext) void {
        _ = part;
    }

    fn renderCallback(part: *ViewPart, _: *RestrictedRenderingContext) void {
        _ = part;
    }

    /// Renders the visible line window. Upstream calls this from `renderText`;
    /// the terminal `View` orchestrator will use it the same way.
    pub fn renderText(self: *ViewLines, viewport: *const ViewportData, sb: *StringBuilder) !void {
        self.last_viewport = viewport;
        self.last_visible_range = viewport.visibleRange;
        try self.visible_lines.renderLines(viewport, sb);
    }

    /// The current viewport data, once `renderText` has run.
    pub fn getLastRenderedViewportData(self: *const ViewLines) ?*const ViewportData {
        return self.last_viewport;
    }

    /// Port of upstream `ViewLines.getCurrentVisibleRange`.
    pub fn getCurrentVisibleRange(self: *const ViewLines) Range {
        return self.last_visible_range;
    }

    /// Port of upstream `ViewLines.getLineWidth`, in terminal cells.
    pub fn getLineWidth(self: *const ViewLines, line_number: usize) usize {
        if (self.visible_lines.getStartLineNumber() == 0 or
            line_number < self.visible_lines.getStartLineNumber() or
            line_number > self.visible_lines.getEndLineNumber())
        {
            return 0;
        }
        return self.visible_lines.getVisibleLine(line_number).getWidth();
    }

    // --- begin IViewLines

    pub fn interface(self: *ViewLines) IViewLines {
        return .{
            .context = self,
            .lines_visible_ranges_for_range = linesVisibleRangesForRangeThunk,
            .visible_range_for_position = visibleRangeForPositionThunk,
        };
    }

    fn linesVisibleRangesForRangeThunk(context: *anyopaque, range: Range, include_new_lines: bool) ?[]const LineVisibleRanges {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.linesVisibleRangesForRange(range, include_new_lines);
    }

    /// The cell-column ranges covered by `range` on the rendered lines.
    pub fn linesVisibleRangesForRange(self: *ViewLines, range: Range, include_new_lines: bool) ?[]const LineVisibleRanges {
        _ = include_new_lines;
        const intersection = Range.intersectRanges(&range, &self.last_visible_range) orelse return null;
        const viewport = self.last_viewport orelse return null;

        _ = self.scratch.reset(.retain_capacity);
        const allocator = self.scratch.allocator();
        var result = std.array_list.Managed(LineVisibleRanges).init(allocator);

        var line_number = intersection.startLineNumber;
        while (line_number <= intersection.endLineNumber) : (line_number += 1) {
            const line_data = viewport.getViewLineRenderingData(line_number) catch continue;
            const start_column = if (line_number == intersection.startLineNumber)
                @max(intersection.startColumn, line_data.minColumn)
            else
                line_data.minColumn;
            const end_column = if (line_number == intersection.endLineNumber)
                @min(intersection.endColumn, line_data.maxColumn)
            else
                line_data.maxColumn;

            const start_visible = visibleColumnFor(line_data, start_column);
            const end_visible = @max(start_visible, visibleColumnFor(line_data, end_column));
            const ranges = allocator.alloc(HorizontalRange, 1) catch return null;
            ranges[0] = HorizontalRange.init(
                @floatFromInt(start_visible),
                @floatFromInt(end_visible - start_visible),
            );
            result.append(.{
                .outsideRenderedLine = false,
                .lineNumber = line_number,
                .ranges = ranges,
                .continuesOnNextLine = false,
            }) catch return null;
        }

        if (result.items.len == 0) return null;
        return result.toOwnedSlice() catch null;
    }

    fn visibleRangeForPositionThunk(context: *anyopaque, position: Position) ?HorizontalPosition {
        const self: *ViewLines = @ptrCast(@alignCast(context));
        return self.visibleRangeForPosition(position);
    }

    /// The cell-column range of `position`, or null when the line is not
    /// rendered in the current viewport.
    pub fn visibleRangeForPosition(self: *ViewLines, position: Position) ?HorizontalPosition {
        const viewport = self.last_viewport orelse return null;
        if (position.lineNumber < self.last_visible_range.startLineNumber or
            position.lineNumber > self.last_visible_range.endLineNumber)
        {
            return null;
        }
        const line_data = viewport.getViewLineRenderingData(position.lineNumber) catch return null;
        const column = @min(@max(position.column, line_data.minColumn), line_data.maxColumn);
        return HorizontalPosition.init(false, @floatFromInt(visibleColumnFor(line_data, column)));
    }

    fn visibleColumnFor(line_data: anytype, column: usize) usize {
        const visible = CursorColumns.visibleColumnFromColumn(line_data.content, column, line_data.tabSize);
        // Wrapped continuation lines start at a non-zero visible column and are
        // indented by their first model column.
        const indent = line_data.minColumn - 1;
        return (visible -| line_data.startVisibleColumn) + indent;
    }

    // --- end IViewLines
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const view_model = @import("../../../common/viewModel.zig");
const editor_configuration = @import("../../../common/config/editorConfiguration.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const languages = @import("../../../common/languages.zig");
const line_tokens = @import("../../../common/tokens/lineTokens.zig");
const TextDirection = @import("../../../common/standalone/standaloneEnums.zig").TextDirection;
const LanguageIdCodec = languages.LanguageIdCodec;
const ViewLineRenderingData = view_model.ViewLineRenderingData;
const IViewLineTokens = line_tokens.IViewLineTokens;

const Fixture = struct {
    allocator: Allocator,
    codec: LanguageIdCodec,
    tokens: line_tokens.LineTokens,
    options: @import("../../config/editorConfiguration.zig").ComputedEditorOptions,
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

        self.options = @import("../../config/editorConfiguration.zig").ComputedEditorOptions.init();
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

test "view lines renders the viewport and maps cell ranges" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "a\tb");
    defer fixture.deinit();

    var lines: ViewLines = undefined;
    lines.init(allocator, &fixture.context);
    defer lines.deinit();

    var sb = try StringBuilder.init(allocator, 16);
    defer sb.deinit();
    try lines.renderText(&fixture.viewport, &sb);
    try testing.expectEqualStrings("a   b", sb.build());
    try testing.expectEqual(@as(usize, 5), lines.getLineWidth(1));
    try testing.expectEqual(@as(usize, 0), lines.getLineWidth(2));
    try testing.expectEqual(@as(usize, 1), lines.getCurrentVisibleRange().startLineNumber);

    const ranges = lines.linesVisibleRangesForRange(Range.init(1, 2, 1, 4), false).?;
    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(@as(i32, 1), ranges[0].ranges[0].left);
    try testing.expectEqual(@as(i32, 4), ranges[0].ranges[0].width);

    const position = lines.visibleRangeForPosition(Position.init(1, 3)).?;
    try testing.expectEqual(@as(i32, 4), position.left);
    try testing.expect(!position.outsideRenderedLine);
}

test "view lines clips ranges to the rendered viewport" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "hello");
    defer fixture.deinit();

    var lines: ViewLines = undefined;
    lines.init(allocator, &fixture.context);
    defer lines.deinit();

    // Before rendering, there is no viewport data.
    try testing.expect(lines.linesVisibleRangesForRange(Range.init(1, 1, 1, 2), false) == null);

    var sb = try StringBuilder.init(allocator, 16);
    defer sb.deinit();
    try lines.renderText(&fixture.viewport, &sb);

    try testing.expect(lines.linesVisibleRangesForRange(Range.init(2, 1, 2, 2), false) == null);
    try testing.expect(lines.visibleRangeForPosition(Position.init(2, 1)) == null);
}

// Port of `src/vs/editor/browser/viewParts/decorations/decorations.ts`.
//
// Terminal adaptation: upstream `prepareRender` emits positioned `<div class="cdr
// ...">` HTML for whole-line and range decorations. The terminal has no CSS and
// no DOM positions, so this overlay produces per-visible-line decoration class
// lists (`class_name` + `whole_line`) plus, for regular decorations, the cell
// range returned by `RenderingContext.linesVisibleRangesForRange` (upstream
// `_renderNormalDecoration`). The terminal view maps whole-line classes to row
// backgrounds and range classes to cell flags/styles; marker squiggles and the
// Problems range highlight use the same path. Exact DOM clipping stays at the
// paint boundary, and the `shouldFillLineOnLineBreak` wrap decoration is not
// representable as cells and is not ported. The header of this file and
// `docs/terminal-ui.md` document that substitution.
const std = @import("std");
const Allocator = std.mem.Allocator;

const dynamic_overlay = @import("../../view/dynamicViewOverlay.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const view_model_decoration = @import("../../../common/viewModel/viewModelDecoration.zig");
const range_mod = @import("../../../common/core/range.zig");
const Range = range_mod.Range;

const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const RenderingContext = rendering_context.RenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const ViewModelDecoration = view_model_decoration.ViewModelDecoration;

/// A half-open range of terminal cells on one rendered line. `start` and `end`
/// are 0-based cell columns, matching `ViewLine`'s paint flags.
pub const CellRange = struct {
    start: usize,
    end: usize,
};

/// One class applied to a visible line.
pub const LineDecoration = struct {
    /// The class name of the decoration. Borrowed from the model decoration
    /// options; valid until the next decoration change.
    class_name: []const u8,
    /// Whether the decoration covers the whole line (`isWholeLine`).
    whole_line: bool,
    /// Visible cells for a regular decoration. Null for whole-line
    /// decorations (and when the range has no visible cells).
    cell_range: ?CellRange = null,
};

const LineDecorations = std.array_list.Managed(LineDecoration);

/// Port of the `DecorationsOverlay` render-data subset.
pub const DecorationsOverlay = struct {
    base: DynamicViewOverlay,
    allocator: Allocator,
    context: *ViewContext,
    render_result: ?[]LineDecorations,
    render_start_line_number: usize,

    pub fn init(self: *DecorationsOverlay, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .render_result = null,
            .render_start_line_number = 1,
        };
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *DecorationsOverlay) void {
        self.base.deinit();
        self.clearRenderResult();
    }

    // --- begin event handlers

    fn onConfigurationChanged(_: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        return true;
    }

    fn onDecorationsChanged(_: *anyopaque, _: *const view_events.ViewDecorationsChangedEvent) bool {
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
        return event.scrollTopChanged or event.scrollWidthChanged;
    }

    fn onZonesChanged(_: *anyopaque, _: *const view_events.ViewZonesChangedEvent) bool {
        return true;
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = onConfigurationChanged,
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

    fn prepareRenderCallback(overlay: *DynamicViewOverlay, context: *const RenderingContext) void {
        const self: *DecorationsOverlay = @fieldParentPtr("base", overlay);
        self.prepareRender(context);
    }

    fn renderCallback(_: *DynamicViewOverlay, _: usize, _: usize) []const u8 {
        return "";
    }

    /// Port of `DecorationsOverlay.prepareRender`: keep decorations with a
    /// `className`, sort them by `zIndex`, class name and range start, then
    /// emit whole-line decorations before range decorations.
    pub fn prepareRender(self: *DecorationsOverlay, context: *const RenderingContext) void {
        self.clearRenderResult();

        const visible_start = context.restricted.visibleRange.startLineNumber;
        const visible_end = context.restricted.visibleRange.endLineNumber;
        if (visible_end < visible_start) return;

        const collected = context.restricted.viewportData.getDecorationsInViewport(self.allocator) catch return;
        defer self.allocator.free(collected);

        var decorations = std.array_list.Managed(ViewModelDecoration).init(self.allocator);
        defer decorations.deinit();
        for (collected) |decoration| {
            if (decoration.options.className != null) decorations.append(decoration) catch return;
        }
        std.mem.sort(ViewModelDecoration, decorations.items, {}, lessThan);

        const line_count = visible_end - visible_start + 1;
        const output = self.allocator.alloc(LineDecorations, line_count) catch return;
        for (output) |*line| line.* = LineDecorations.init(self.allocator);
        errdefer {
            for (output) |*line| line.deinit();
            self.allocator.free(output);
        }

        self.renderWholeLineDecorations(decorations.items, visible_start, visible_end, output);
        self.renderNormalDecorations(context, decorations.items, visible_start, output);

        self.render_result = output;
        self.render_start_line_number = visible_start;
    }

    fn lessThan(_: void, a: ViewModelDecoration, b: ViewModelDecoration) bool {
        const a_z = a.options.zIndex orelse 0;
        const b_z = b.options.zIndex orelse 0;
        if (a_z != b_z) return a_z < b_z;
        const a_class = a.options.className.?;
        const b_class = b.options.className.?;
        const order = std.mem.order(u8, a_class, b_class);
        if (order != .eq) return order == .lt;
        return range_mod.compareRangesUsingStarts(&a.range, &b.range) < 0;
    }

    fn renderWholeLineDecorations(
        _: *DecorationsOverlay,
        decorations: []const ViewModelDecoration,
        visible_start: usize,
        visible_end: usize,
        output: []LineDecorations,
    ) void {
        for (decorations) |decoration| {
            if (!(decoration.options.isWholeLine orelse false)) continue;
            const class_name = decoration.options.className.?;
            const start_line = @max(decoration.range.startLineNumber, visible_start);
            const end_line = @min(decoration.range.endLineNumber, visible_end);
            var line = start_line;
            while (line <= end_line) : (line += 1) {
                output[line - visible_start].append(.{
                    .class_name = class_name,
                    .whole_line = true,
                }) catch return;
            }
        }
    }

    /// Port of `_renderNormalDecorations`/`_renderNormalDecoration`: identical
    /// classes on touching ranges merge, then each merged range is mapped to
    /// the visible cell ranges on every line it intersects. The cell mapping is
    /// the same `linesVisibleRangesForRange` call the browser overlay uses.
    fn renderNormalDecorations(
        self: *DecorationsOverlay,
        context: *const RenderingContext,
        decorations: []const ViewModelDecoration,
        visible_start: usize,
        output: []LineDecorations,
    ) void {
        var prev_class: ?[]const u8 = null;
        var prev_show_if_collapsed = false;
        var prev_range: ?Range = null;

        for (decorations) |decoration| {
            if (decoration.options.isWholeLine orelse false) continue;
            const class_name = decoration.options.className.?;
            const show_if_collapsed = decoration.options.showIfCollapsed orelse false;
            var range = decoration.range;
            if (show_if_collapsed and range.endColumn == 1 and range.endLineNumber != range.startLineNumber) {
                range = Range.init(
                    range.startLineNumber,
                    range.startColumn,
                    range.endLineNumber - 1,
                    self.context.view_model.lineMaxColumn(range.endLineNumber - 1),
                );
            }

            if (prev_class != null and std.mem.eql(u8, prev_class.?, class_name) and
                prev_show_if_collapsed == show_if_collapsed and
                range_mod.areIntersectingOrTouching(&prev_range.?, &range))
            {
                prev_range = Range.plusRange(&prev_range.?, &range);
                continue;
            }
            if (prev_class != null) {
                renderNormalDecoration(context, prev_range.?, prev_class.?, prev_show_if_collapsed, visible_start, output);
            }
            prev_class = class_name;
            prev_show_if_collapsed = show_if_collapsed;
            prev_range = range;
        }
        if (prev_class != null) {
            renderNormalDecoration(context, prev_range.?, prev_class.?, prev_show_if_collapsed, visible_start, output);
        }
    }

    fn renderNormalDecoration(
        context: *const RenderingContext,
        range: Range,
        class_name: []const u8,
        show_if_collapsed: bool,
        visible_start: usize,
        output: []LineDecorations,
    ) void {
        const lines = context.linesVisibleRangesForRange(range, std.mem.eql(u8, class_name, "findMatch")) orelse return;
        for (lines) |line| {
            if (line.outsideRenderedLine) continue;
            if (line.lineNumber < visible_start) continue;
            const line_index = line.lineNumber - visible_start;
            if (line_index >= output.len) continue;
            for (line.ranges) |horizontal| {
                const start: usize = @intCast(@max(horizontal.left, 0));
                var end: usize = start + @as(usize, @intCast(@max(horizontal.width, 0)));
                if (show_if_collapsed and line.ranges.len == 1 and end <= start) {
                    // Upstream expands a collapsed range so the decoration is
                    // still visible; the terminal equivalent is one cell.
                    end = start + 1;
                }
                output[line_index].append(.{
                    .class_name = class_name,
                    .whole_line = false,
                    .cell_range = if (end > start) CellRange{ .start = start, .end = end } else null,
                }) catch return;
            }
        }
    }

    /// The classes applied to a view line, or an empty slice when the line is
    /// outside the last prepared visible range.
    pub fn renderedLine(self: *const DecorationsOverlay, line_number: usize) []const LineDecoration {
        const result = self.render_result orelse return &.{};
        if (line_number < self.render_start_line_number) return &.{};
        const index = line_number - self.render_start_line_number;
        if (index >= result.len) return &.{};
        return result[index].items;
    }

    /// Whether any whole-line decoration covers the line.
    pub fn isWholeLine(self: *const DecorationsOverlay, line_number: usize) bool {
        for (self.renderedLine(line_number)) |decoration| {
            if (decoration.whole_line) return true;
        }
        return false;
    }

    /// The class names for a line, joined with spaces in render order. The
    /// caller owns the returned slice.
    pub fn classNames(self: *const DecorationsOverlay, allocator: Allocator, line_number: usize) ![]u8 {
        var out = std.array_list.Managed(u8).init(allocator);
        errdefer out.deinit();
        for (self.renderedLine(line_number), 0..) |decoration, index| {
            if (index != 0) try out.append(' ');
            try out.appendSlice(decoration.class_name);
        }
        return out.toOwnedSlice();
    }

    fn clearRenderResult(self: *DecorationsOverlay) void {
        const result = self.render_result orelse return;
        for (result) |*line| line.deinit();
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
const model = @import("../../../common/model.zig");
const ViewLineRenderingData = @import("../../../common/viewModel.zig").ViewLineRenderingData;
const languages = @import("../../../common/languages.zig");
const line_tokens = @import("../../../common/tokens/lineTokens.zig");
const TextDirection = @import("../../../common/standalone/standaloneEnums.zig").TextDirection;

const Harness = struct {
    allocator: Allocator,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: ViewContext,
    overlay: DecorationsOverlay,
    viewport: viewport_data.ViewportData,
    rendering: RenderingContext,
    line_lengths: []usize,
    offsets: []f64,
    tokens: line_tokens.LineTokens,
    codec: languages.LanguageIdCodec,
    /// Fixed buffers for the test `IViewLines` adapter. The real view lines
    /// return scratch-owned slices; the tests only need one range per line.
    stub_ranges: [16]rendering_context.HorizontalRange = undefined,
    stub_lines: [16]rendering_context.LineVisibleRanges = undefined,

    fn init(
        self: *Harness,
        allocator: Allocator,
        line_count: usize,
        start_line_number: usize,
        end_line_number: usize,
        decorations: []const ViewModelDecoration,
    ) !void {
        self.allocator = allocator;
        self.codec = try languages.LanguageIdCodec.init(allocator);
        errdefer self.codec.deinit();
        var content = std.array_list.Managed(u8).init(allocator);
        try content.appendSlice("line");
        self.tokens = try line_tokens.LineTokens.createEmpty(allocator, content, &self.codec);
        errdefer self.tokens.deinit();

        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.line_count = line_count;
        self.view_model.decorations = decorations;
        self.line_lengths = try allocator.alloc(usize, line_count);
        errdefer allocator.free(self.line_lengths);
        @memset(self.line_lengths, 80);
        self.view_model.line_lengths = self.line_lengths;
        self.view_model.view_line_data = ViewLineRenderingData.init(
            1,
            5,
            "line",
            false,
            false,
            false,
            line_tokens.IViewLineTokens.init(&self.tokens),
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
        self.overlay = undefined;
        self.overlay.init(allocator, &self.context);
        errdefer self.overlay.deinit();

        const viewport_line_count = end_line_number - start_line_number + 1;
        self.offsets = try allocator.alloc(f64, viewport_line_count);
        errdefer allocator.free(self.offsets);
        @memset(self.offsets, 0);
        self.viewport = .{
            .selections = &.{},
            .startLineNumber = start_line_number,
            .endLineNumber = end_line_number,
            .relativeVerticalOffset = self.offsets,
            .visibleRange = Range.init(start_line_number, 1, end_line_number, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 1,
            ._model = self.context.view_model,
        };
        self.rendering = RenderingContext.init(self.layout.interface(), &self.viewport, .{
            .context = self,
            .lines_visible_ranges_for_range = linesVisibleRangesForRange,
            .visible_range_for_position = returnsNullPosition,
        });
    }

    fn deinit(self: *Harness) void {
        self.overlay.deinit();
        self.allocator.free(self.offsets);
        self.allocator.free(self.line_lengths);
        self.tokens.deinit();
        self.codec.deinit();
    }

    fn linesVisibleRangesForRange(
        context: *anyopaque,
        range: Range,
        _: bool,
    ) ?[]const rendering_context.LineVisibleRanges {
        const self: *Harness = @ptrCast(@alignCast(context));
        const visible = self.viewport.visibleRange;
        const start_line = @max(range.startLineNumber, visible.startLineNumber);
        const end_line = @min(range.endLineNumber, visible.endLineNumber);
        if (end_line < start_line) return null;

        var count: usize = 0;
        var line = start_line;
        while (line <= end_line and count < self.stub_lines.len) : (line += 1) {
            const line_start = if (line == range.startLineNumber) range.startColumn else 1;
            const line_end = if (line == range.endLineNumber) range.endColumn else self.line_lengths[line - 1] + 1;
            const width: i32 = if (line_end > line_start) @intCast(line_end - line_start) else 0;
            self.stub_ranges[count] = .{
                .left = @intCast(line_start - 1),
                .width = width,
            };
            self.stub_lines[count] = .{
                .outsideRenderedLine = false,
                .lineNumber = line,
                .ranges = self.stub_ranges[count .. count + 1],
                .continuesOnNextLine = false,
            };
            count += 1;
        }
        return if (count == 0) null else self.stub_lines[0..count];
    }

    fn returnsNullPosition(_: *anyopaque, _: @import("../../../common/core/position.zig").Position) ?rendering_context.HorizontalPosition {
        return null;
    }
};

test "decorations: whole-line classes are filtered, sorted and clipped" {
    var low = model.ModelDecorationOptions.init("low", .AlwaysGrowsWhenTypingAtEdges);
    low.className = "line-insert";
    low.isWholeLine = true;
    low.zIndex = 1;
    var high = model.ModelDecorationOptions.init("high", .AlwaysGrowsWhenTypingAtEdges);
    high.className = "line-delete";
    high.isWholeLine = true;
    high.zIndex = 5;
    var without_class = model.ModelDecorationOptions.init("plain", .AlwaysGrowsWhenTypingAtEdges);
    without_class.isWholeLine = true;

    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 1, 10, 1), .options = &high },
        .{ .range = Range.init(2, 1, 3, 1), .options = &low },
        .{ .range = Range.init(1, 1, 10, 1), .options = &without_class },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 10, 2, 4, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    // zIndex sorts ascending: the higher-z class comes later and wins.
    const line2 = harness.overlay.renderedLine(2);
    try testing.expectEqual(@as(usize, 2), line2.len);
    try testing.expectEqualStrings("line-insert", line2[0].class_name);
    try testing.expectEqualStrings("line-delete", line2[1].class_name);
    try testing.expect(line2[0].whole_line and line2[1].whole_line);
    // The range class ends on line 3; line 4 keeps only the whole-line class.
    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(4).len);
    try testing.expectEqualStrings("line-delete", harness.overlay.renderedLine(4)[0].class_name);
    // Outside the visible range there is no data.
    try testing.expectEqual(@as(usize, 0), harness.overlay.renderedLine(1).len);
    try testing.expectEqual(@as(usize, 0), harness.overlay.renderedLine(5).len);
    try testing.expect(harness.overlay.isWholeLine(2));
}

test "decorations: range decorations merge touching ranges of the same class" {
    var options = model.ModelDecorationOptions.init("range", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "char-insert";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 2, 1, 5), .options = &options },
        .{ .range = Range.init(1, 5, 2, 2), .options = &options },
        .{ .range = Range.init(3, 1, 3, 2), .options = &options },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 3, 1, 3, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(1).len);
    try testing.expect(!harness.overlay.renderedLine(1)[0].whole_line);
    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(2).len);
    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(3).len);
    try testing.expectEqualStrings("char-insert", harness.overlay.renderedLine(3)[0].class_name);
}

test "decorations: range decorations expose visible cell ranges" {
    var options = model.ModelDecorationOptions.init("range", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "squiggly-error";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 3, 1, 7), .options = &options },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 2, 1, 2, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    const line = harness.overlay.renderedLine(1);
    try testing.expectEqual(@as(usize, 1), line.len);
    try testing.expectEqualStrings("squiggly-error", line[0].class_name);
    try testing.expect(!line[0].whole_line);
    const range = line[0].cell_range.?;
    try testing.expectEqual(@as(usize, 2), range.start);
    try testing.expectEqual(@as(usize, 6), range.end);
}

test "decorations: collapsed range expands to one visible cell" {
    var options = model.ModelDecorationOptions.init("range", .AlwaysGrowsWhenTypingAtEdges);
    options.className = "squiggly-error";
    options.showIfCollapsed = true;
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 3, 1, 3), .options = &options },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 1, 1, 1, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    const line = harness.overlay.renderedLine(1);
    try testing.expectEqual(@as(usize, 1), line.len);
    const range = line[0].cell_range.?;
    try testing.expectEqual(@as(usize, 2), range.start);
    try testing.expectEqual(@as(usize, 3), range.end);
}

test "decorations: class list joins in render order" {
    var first = model.ModelDecorationOptions.init("a", .AlwaysGrowsWhenTypingAtEdges);
    first.className = "line-insert";
    first.isWholeLine = true;
    var second = model.ModelDecorationOptions.init("b", .AlwaysGrowsWhenTypingAtEdges);
    second.className = "diff-filler";
    second.isWholeLine = true;
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 1, 1, 1), .options = &second },
        .{ .range = Range.init(1, 1, 1, 1), .options = &first },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 1, 1, 1, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    // "diff-filler" sorts before "line-insert".
    const names = try harness.overlay.classNames(testing.allocator, 1);
    defer testing.allocator.free(names);
    try testing.expectEqualStrings("diff-filler line-insert", names);
}

test "decorations: invalidates on decoration, line and zone events" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 1, 1, 1, &.{});
    defer harness.deinit();

    try testing.expect(harness.overlay.base.handler.onDecorationsChanged(&.{
        .affectsMinimap = false,
        .affectsOverviewRuler = false,
        .affectsGlyphMargin = false,
        .affectsLineNumber = false,
    }));
    try testing.expect(harness.overlay.base.handler.onZonesChanged(&.{}));
    try testing.expect(harness.overlay.base.handler.onScrollChanged(&.{
        .scrollWidth = 0,
        .scrollLeft = 0,
        .scrollHeight = 0,
        .scrollTop = 0,
        .scrollWidthChanged = false,
        .scrollLeftChanged = false,
        .scrollHeightChanged = false,
        .scrollTopChanged = false,
    }) == false);
}

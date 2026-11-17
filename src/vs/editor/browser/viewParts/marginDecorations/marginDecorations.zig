// Port of `src/vs/editor/browser/viewParts/marginDecorations/marginDecorations.ts`.
//
// Terminal adaptation: `prepareRender` produces per-view-line decoration data
// instead of `<div>` HTML. The terminal paints the class identifiers in the
// gutter cells.
const std = @import("std");
const Allocator = std.mem.Allocator;

const dynamic_overlay = @import("../../view/dynamicViewOverlay.zig");
const rendering_context = @import("../../view/renderingContext.zig");
const view_context = @import("../../../common/viewModel/viewContext.zig");
const view_events = @import("../../../common/viewEvents.zig");
const view_event_handler = @import("../../../common/viewEventHandler.zig");
const glyph_margin = @import("../glyphMargin/glyphMargin.zig");

const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const RenderingContext = rendering_context.RenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const DecorationToRender = glyph_margin.DecorationToRender;
const VisibleLineDecorationsToRender = glyph_margin.VisibleLineDecorationsToRender;

/// Port of `MarginViewLineDecorationsOverlay`.
pub const MarginViewLineDecorationsOverlay = struct {
    base: DynamicViewOverlay,
    allocator: Allocator,
    context: *ViewContext,
    render_result: ?[]VisibleLineDecorationsToRender,
    render_start_line_number: usize,

    pub fn init(self: *MarginViewLineDecorationsOverlay, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .render_result = null,
            .render_start_line_number = 1,
        };
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *MarginViewLineDecorationsOverlay) void {
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
        return event.scrollTopChanged;
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

    fn collectDecorations(self: *MarginViewLineDecorationsOverlay, context: *const RenderingContext) ![]DecorationToRender {
        const decorations = try context.restricted.viewportData.getDecorationsInViewport(self.allocator);
        defer self.allocator.free(decorations);

        var result = std.array_list.Managed(DecorationToRender).init(self.allocator);
        errdefer result.deinit();
        for (decorations) |decoration| {
            if (decoration.options.marginClassName) |class_name| {
                try result.append(.{
                    .start_line_number = decoration.range.startLineNumber,
                    .end_line_number = decoration.range.endLineNumber,
                    .class_name = class_name,
                    .tooltip = null,
                    .z_index = if (decoration.options.zIndex) |value| @intCast(value) else 0,
                });
            }
        }
        return result.toOwnedSlice();
    }

    fn prepareRenderCallback(overlay: *DynamicViewOverlay, context: *const RenderingContext) void {
        const self: *MarginViewLineDecorationsOverlay = @fieldParentPtr("base", overlay);
        self.prepareRender(context);
    }

    fn renderCallback(overlay: *DynamicViewOverlay, _: usize, _: usize) []const u8 {
        _ = overlay;
        return "";
    }

    pub fn prepareRender(self: *MarginViewLineDecorationsOverlay, context: *const RenderingContext) void {
        self.clearRenderResult();
        const visible_start = context.restricted.visibleRange.startLineNumber;
        const visible_end = context.restricted.visibleRange.endLineNumber;
        const decorations = self.collectDecorations(context) catch return;
        defer self.allocator.free(decorations);
        const result = glyph_margin.renderVisibleLineDecorations(
            self.allocator,
            visible_start,
            visible_end,
            decorations,
        ) catch return;
        self.render_result = result;
        self.render_start_line_number = visible_start;
    }

    pub fn render(self: *MarginViewLineDecorationsOverlay, start_line_number: usize, line_number: usize) []const u8 {
        _ = self;
        _ = start_line_number;
        _ = line_number;
        return "";
    }

    /// The terminal compositor queries the decorations of a view line.
    pub fn renderedLine(self: *const MarginViewLineDecorationsOverlay, line_number: usize) ?*const VisibleLineDecorationsToRender {
        const result = self.render_result orelse return null;
        if (line_number < self.render_start_line_number) return null;
        const line_index = line_number - self.render_start_line_number;
        if (line_index >= result.len) return null;
        return &result[line_index];
    }

    fn clearRenderResult(self: *MarginViewLineDecorationsOverlay) void {
        const result = self.render_result orelse return;
        glyph_margin.freeVisibleLineDecorations(self.allocator, result);
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
const Range = @import("../../../common/core/range.zig").Range;
const ViewModelDecoration = @import("../../../common/viewModel.zig").ViewModelDecoration;

const Harness = struct {
    allocator: Allocator,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: ViewContext,
    overlay: MarginViewLineDecorationsOverlay,
    viewport: viewport_data.ViewportData,
    rendering: RenderingContext,

    fn init(
        self: *Harness,
        allocator: Allocator,
        line_count: usize,
        start_line_number: usize,
        end_line_number: usize,
        decorations: []const ViewModelDecoration,
    ) !void {
        self.allocator = allocator;
        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.line_count = line_count;
        self.view_model.decorations = decorations;
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
            .lineHeight = 19,
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
};

test "margin decorations: renders the margin class for covered lines" {
    var options = model.ModelDecorationOptions.init("test", .AlwaysGrowsWhenTypingAtEdges);
    options.marginClassName = "margin-class";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(2, 1, 3, 1), .options = &options },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 4, 1, 4, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqual(@as(usize, 0), harness.overlay.renderedLine(1).?.getDecorations().len);
    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(2).?.getDecorations().len);
    try testing.expectEqualStrings("margin-class", harness.overlay.renderedLine(2).?.getDecorations()[0].class_name);
    try testing.expectEqualStrings("margin-class", harness.overlay.renderedLine(3).?.getDecorations()[0].class_name);
    try testing.expectEqual(@as(usize, 0), harness.overlay.renderedLine(4).?.getDecorations().len);
}

test "margin decorations: deduplicates overlapping ranges of the same class" {
    var options = model.ModelDecorationOptions.init("test", .AlwaysGrowsWhenTypingAtEdges);
    options.marginClassName = "same";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 1, 3, 1), .options = &options },
        .{ .range = Range.init(2, 1, 4, 1), .options = &options },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 4, 1, 4, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    for (1..5) |line_number| {
        try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(line_number).?.getDecorations().len);
    }
}

test "margin decorations: ignores decorations without a margin class" {
    var with_class = model.ModelDecorationOptions.init("with", .AlwaysGrowsWhenTypingAtEdges);
    with_class.marginClassName = "class";
    var without_class = model.ModelDecorationOptions.init("without", .AlwaysGrowsWhenTypingAtEdges);
    without_class.linesDecorationsClassName = "line";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 1, 2, 1), .options = &without_class },
        .{ .range = Range.init(1, 1, 2, 1), .options = &with_class },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 2, 1, 2, &decorations);
    defer harness.deinit();
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqual(@as(usize, 1), harness.overlay.renderedLine(1).?.getDecorations().len);
    try testing.expectEqualStrings("class", harness.overlay.renderedLine(1).?.getDecorations()[0].class_name);
}

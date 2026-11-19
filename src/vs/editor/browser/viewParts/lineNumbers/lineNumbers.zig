// Port of `src/vs/editor/browser/viewParts/lineNumbers/lineNumbers.ts`.
//
// Terminal adaptation: `prepareRender` produces per-view-line line-number data
// (text, active/dimmed/relative flags and the decoration class names) instead
// of positioned `<div>` HTML. The terminal compositor owns the cell column and
// the styling; the view part owns the upstream decisions: relative/interval
// numbering, custom renderers, the final-newline handling, active-line and
// `lineNumberClassName` decorations.
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
const range_mod = @import("../../../common/core/range.zig");
const Range = range_mod.Range;

const DynamicViewOverlay = dynamic_overlay.DynamicViewOverlay;
const RenderingContext = rendering_context.RenderingContext;
const ViewContext = view_context.ViewContext;
const EventHandlerCallbacks = view_event_handler.EventHandlerCallbacks;
const RenderLineNumbersType = editor_options.RenderLineNumbersType;
const RenderLineNumberFn = editor_options.RenderLineNumberFn;
const RenderFinalNewline = editor_options.RenderFinalNewline;
const ViewModelDecoration = view_model.ViewModelDecoration;

/// The terminal rendering data for one view line. `text` and
/// `extra_class_names` are owned by the overlay.
pub const RenderedLineNumber = struct {
    text: []u8,
    active: bool,
    dimmed: bool,
    /// Upstream wraps the current relative line number in
    /// `<span class="relative-current-line-number">`; the terminal keeps the
    /// flag so the compositor can emphasize it.
    relative_current: bool,
    /// Space-separated `lineNumberClassName` values of the decorations that
    /// cover the line, as upstream concatenates them.
    extra_class_names: []u8,
};

const LineNumberText = struct {
    text: []u8,
    relative_current: bool,
};

/// Port of `LineNumbersOverlay`.
pub const LineNumbersOverlay = struct {
    base: DynamicViewOverlay,
    allocator: Allocator,
    context: *ViewContext,

    line_height: f64,
    render_line_numbers: RenderLineNumbersType,
    render_custom_line_numbers: ?RenderLineNumberFn,
    render_final_newline: RenderFinalNewline,
    line_numbers_left: f64,
    line_numbers_width: f64,
    last_cursor_model_position: Position,
    render_result: ?[]RenderedLineNumber,
    render_start_line_number: usize,
    active_model_line_number: usize,

    pub fn init(self: *LineNumbersOverlay, allocator: Allocator, context: *ViewContext) void {
        self.* = .{
            .base = undefined,
            .allocator = allocator,
            .context = context,
            .line_height = 0,
            .render_line_numbers = .On,
            .render_custom_line_numbers = null,
            .render_final_newline = .on,
            .line_numbers_left = 0,
            .line_numbers_width = 0,
            .last_cursor_model_position = Position.init(1, 1),
            .render_result = null,
            .render_start_line_number = 1,
            .active_model_line_number = 1,
        };
        self.readConfig();
        self.base.initWithHandlerContext(context, self, callbacks(), prepareRenderCallback, renderCallback);
    }

    pub fn deinit(self: *LineNumbersOverlay) void {
        self.base.deinit();
        self.clearRenderResult();
    }

    fn readConfig(self: *LineNumbersOverlay) void {
        const options = self.context.configuration.options.?;
        self.line_height = options.get(.lineHeight);
        const line_numbers = options.get(.lineNumbers);
        self.render_line_numbers = line_numbers.render_type;
        self.render_custom_line_numbers = line_numbers.render_fn;
        self.render_final_newline = options.get(.renderFinalNewline);
        const layout_info = options.get(.layoutInfo);
        self.line_numbers_left = layout_info.line_numbers_left;
        self.line_numbers_width = layout_info.line_numbers_width;
    }

    // --- begin event handlers

    fn onConfigurationChanged(context: *anyopaque, _: *const view_events.ViewConfigurationChangedEvent) bool {
        const self: *LineNumbersOverlay = @ptrCast(@alignCast(context));
        self.readConfig();
        return true;
    }

    fn onCursorStateChanged(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
        const self: *LineNumbersOverlay = @ptrCast(@alignCast(context));
        if (event.selections.len == 0) return false;
        const primary_view_position = event.selections[0].getPosition();
        const converter = self.context.view_model.coordinates_converter;
        self.last_cursor_model_position = converter.convertViewPositionToModelPosition(converter.context, primary_view_position);

        var should_render = false;
        if (self.active_model_line_number != self.last_cursor_model_position.lineNumber) {
            self.active_model_line_number = self.last_cursor_model_position.lineNumber;
            should_render = true;
        }
        if (self.render_line_numbers == .Relative or self.render_line_numbers == .Interval) {
            should_render = true;
        }
        return should_render;
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

    fn onDecorationsChanged(_: *anyopaque, event: *const view_events.ViewDecorationsChangedEvent) bool {
        return event.affectsLineNumber;
    }

    fn callbacks() EventHandlerCallbacks {
        return .{
            .onConfigurationChanged = onConfigurationChanged,
            .onCursorStateChanged = onCursorStateChanged,
            .onFlushed = onFlushed,
            .onLinesChanged = onLinesChanged,
            .onLinesDeleted = onLinesDeleted,
            .onLinesInserted = onLinesInserted,
            .onScrollChanged = onScrollChanged,
            .onZonesChanged = onZonesChanged,
            .onDecorationsChanged = onDecorationsChanged,
        };
    }

    // --- end event handlers

    fn formatNumber(self: *LineNumbersOverlay, line_number: usize) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{d}", .{line_number});
    }

    fn getLineRenderLineNumber(self: *LineNumbersOverlay, view_line_number: usize) !?LineNumberText {
        const converter = self.context.view_model.coordinates_converter;
        const model_position = converter.convertViewPositionToModelPosition(converter.context, Position.init(view_line_number, 1));
        if (model_position.column != 1) {
            return null;
        }
        const model_line_number = model_position.lineNumber;

        if (self.render_custom_line_numbers) |render_fn| {
            return .{
                .text = try self.allocator.dupe(u8, render_fn(model_line_number)),
                .relative_current = false,
            };
        }

        switch (self.render_line_numbers) {
            .Relative => {
                const diff = if (self.last_cursor_model_position.lineNumber > model_line_number)
                    self.last_cursor_model_position.lineNumber - model_line_number
                else
                    model_line_number - self.last_cursor_model_position.lineNumber;
                if (diff == 0) {
                    return .{ .text = try self.formatNumber(model_line_number), .relative_current = true };
                }
                return .{ .text = try self.formatNumber(diff), .relative_current = false };
            },
            .Interval => {
                if (self.last_cursor_model_position.lineNumber == model_line_number) {
                    return .{ .text = try self.formatNumber(model_line_number), .relative_current = false };
                }
                if (model_line_number % 10 == 0) {
                    return .{ .text = try self.formatNumber(model_line_number), .relative_current = false };
                }
                const final_line_number = self.context.view_model.lineCount();
                if (model_line_number == final_line_number) {
                    return .{ .text = try self.formatNumber(model_line_number), .relative_current = false };
                }
                return null;
            },
            else => return .{ .text = try self.formatNumber(model_line_number), .relative_current = false },
        }
    }

    fn prepareRenderCallback(overlay: *DynamicViewOverlay, context: *const RenderingContext) void {
        const self: *LineNumbersOverlay = @fieldParentPtr("base", overlay);
        self.prepareRender(context);
    }

    fn renderCallback(overlay: *DynamicViewOverlay, start_line_number: usize, line_number: usize) []const u8 {
        const self: *LineNumbersOverlay = @fieldParentPtr("base", overlay);
        return self.render(start_line_number, line_number);
    }

    fn buildLine(
        self: *LineNumbersOverlay,
        line_number: usize,
        model_line_number: usize,
        decorations: []const ViewModelDecoration,
        decoration_start_index: *usize,
    ) !RenderedLineNumber {
        var relative_current = false;
        var text: []u8 = undefined;
        if (try self.getLineRenderLineNumber(line_number)) |result| {
            text = result.text;
            relative_current = result.relative_current;
        } else {
            text = try self.allocator.dupe(u8, "");
        }
        errdefer self.allocator.free(text);

        // Skip decorations whose end positions we have already passed.
        while (decoration_start_index.* < decorations.len and
            decorations[decoration_start_index.*].range.endLineNumber < line_number)
        {
            decoration_start_index.* += 1;
        }
        var extra = std.array_list.Managed(u8).init(self.allocator);
        defer extra.deinit();
        for (decorations[decoration_start_index.*..]) |decoration| {
            if (decoration.range.startLineNumber <= line_number) {
                if (decoration.options.lineNumberClassName) |class_name| {
                    try extra.append(' ');
                    try extra.appendSlice(class_name);
                }
            }
        }
        const extra_class_names = try extra.toOwnedSlice();
        errdefer self.allocator.free(extra_class_names);

        var active = false;
        var dimmed = false;
        if (text.len == 0 and extra_class_names.len == 0) {
            return .{
                .text = text,
                .active = false,
                .dimmed = false,
                .relative_current = relative_current,
                .extra_class_names = extra_class_names,
            };
        }

        if (line_number == self.context.view_model.lineCount() and
            self.context.view_model.lineLength(line_number) == 0)
        {
            // The last line.
            switch (self.render_final_newline) {
                .off => {
                    self.allocator.free(text);
                    text = try self.allocator.dupe(u8, "");
                },
                .dimmed => dimmed = true,
                .on => {},
            }
        }
        if (model_line_number == self.active_model_line_number) {
            active = true;
        }

        return .{
            .text = text,
            .active = active,
            .dimmed = dimmed,
            .relative_current = relative_current,
            .extra_class_names = extra_class_names,
        };
    }

    fn buildRenderResult(self: *LineNumbersOverlay, context: *const RenderingContext) !void {
        const visible_start_line_number = context.restricted.visibleRange.startLineNumber;
        const visible_end_line_number = context.restricted.visibleRange.endLineNumber;
        if (visible_end_line_number < visible_start_line_number) return;

        var line_no_decorations = std.array_list.Managed(ViewModelDecoration).init(self.allocator);
        defer line_no_decorations.deinit();
        const all_decorations = try self.context.view_model.getDecorationsInViewport(
            self.context.view_model.context,
            context.restricted.visibleRange,
            self.allocator,
        );
        defer self.allocator.free(all_decorations);
        for (all_decorations) |decoration| {
            if (decoration.options.lineNumberClassName != null) {
                try line_no_decorations.append(decoration);
            }
        }
        std.mem.sort(ViewModelDecoration, line_no_decorations.items, {}, struct {
            fn lessThan(_: void, a: ViewModelDecoration, b: ViewModelDecoration) bool {
                return range_mod.compareRangesUsingEnds(&a.range, &b.range) < 0;
            }
        }.lessThan);

        const line_count = visible_end_line_number - visible_start_line_number + 1;
        const output = try self.allocator.alloc(RenderedLineNumber, line_count);
        var filled: usize = 0;
        errdefer {
            for (output[0..filled]) |entry| {
                self.allocator.free(entry.text);
                self.allocator.free(entry.extra_class_names);
            }
            self.allocator.free(output);
        }

        var decoration_start_index: usize = 0;
        var line_number = visible_start_line_number;
        while (line_number <= visible_end_line_number) : (line_number += 1) {
            const converter = self.context.view_model.coordinates_converter;
            const model_position = converter.convertViewPositionToModelPosition(converter.context, Position.init(line_number, 1));
            output[filled] = try self.buildLine(
                line_number,
                model_position.lineNumber,
                line_no_decorations.items,
                &decoration_start_index,
            );
            filled += 1;
        }

        self.render_result = output;
        self.render_start_line_number = visible_start_line_number;
    }

    pub fn prepareRender(self: *LineNumbersOverlay, context: *const RenderingContext) void {
        self.clearRenderResult();
        if (self.render_line_numbers == .Off) {
            return;
        }
        self.buildRenderResult(context) catch {
            self.clearRenderResult();
        };
    }

    pub fn render(self: *LineNumbersOverlay, start_line_number: usize, line_number: usize) []const u8 {
        const result = self.render_result orelse return "";
        if (line_number < start_line_number) return "";
        const line_index = line_number - start_line_number;
        if (line_index >= result.len) return "";
        return result[line_index].text;
    }

    /// The terminal view asks for the structured render data of a view line.
    pub fn renderedLine(self: *const LineNumbersOverlay, line_number: usize) ?*const RenderedLineNumber {
        const result = self.render_result orelse return null;
        if (line_number < self.render_start_line_number) return null;
        const line_index = line_number - self.render_start_line_number;
        if (line_index >= result.len) return null;
        return &result[line_index];
    }

    fn clearRenderResult(self: *LineNumbersOverlay) void {
        const result = self.render_result orelse return;
        for (result) |entry| {
            self.allocator.free(entry.text);
            self.allocator.free(entry.extra_class_names);
        }
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
const view_model_layout = @import("../../../common/viewLayout/viewLinesViewportData.zig");
const test_stubs = @import("../../../test/common/viewModelTestStubs.zig");
const model = @import("../../../common/model.zig");
const Selection = @import("../../../common/core/selection.zig").Selection;
const TrackedRangeStickiness = model.TrackedRangeStickiness;

const Harness = struct {
    allocator: Allocator,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,
    layout: test_stubs.TestViewLayout,
    view_model: test_stubs.TestViewModel,
    context: ViewContext,
    overlay: LineNumbersOverlay,
    viewport: view_model_layout.ViewportData,
    rendering: RenderingContext,

    fn init(
        self: *Harness,
        allocator: Allocator,
        line_count: usize,
        line_lengths: []const usize,
        decorations: []const ViewModelDecoration,
    ) !void {
        self.allocator = allocator;
        self.options = browser_config.ComputedEditorOptions.init();
        self.layout = .{};
        self.view_model = test_stubs.TestViewModel.init(self.layout.interface());
        self.view_model.line_count = line_count;
        self.view_model.line_lengths = line_lengths;
        self.view_model.decorations = decorations;
        const theme = test_stubs.TestColorTheme.dark();
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        self.context = ViewContext.init(&self.configuration, theme, self.view_model.interface());
        self.overlay = undefined;
        self.overlay.init(allocator, &self.context);

        const offsets = try allocator.alloc(f64, line_count);
        errdefer allocator.free(offsets);
        for (offsets) |*offset| offset.* = 0;
        self.viewport = .{
            .selections = &.{},
            .startLineNumber = 1,
            .endLineNumber = line_count,
            .relativeVerticalOffset = offsets,
            .visibleRange = Range.init(1, 1, line_count, 1),
            .bigNumbersDelta = 0,
            .whitespaceViewportData = &.{},
            .lineHeight = 1,
            ._model = self.view_model.interface(),
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
        self.overlay.prepareRender(&self.rendering);
    }

    fn deinit(self: *Harness) void {
        self.overlay.deinit();
        self.allocator.free(self.viewport.relativeVerticalOffset);
    }
};

test "line numbers: absolute numbering, active line and final newline" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 3, &.{ 1, 2, 0 }, &.{});
    defer harness.deinit();

    // Pin the host-dependent default so the assertion is stable.
    harness.options.set(.renderFinalNewline, .dimmed);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqualStrings("1", harness.overlay.renderedLine(1).?.text);
    try testing.expectEqualStrings("2", harness.overlay.renderedLine(2).?.text);
    try testing.expectEqualStrings("3", harness.overlay.renderedLine(3).?.text);
    try testing.expect(harness.overlay.renderedLine(1).?.active);

    // The final empty line is dimmed with the Linux default (`dimmed`) and
    // hidden when `renderFinalNewline` is `off`.
    try testing.expect(harness.overlay.renderedLine(3).?.dimmed);

    harness.options.set(.renderFinalNewline, .off);
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);
    try testing.expectEqualStrings("", harness.overlay.renderedLine(3).?.text);
    try testing.expect(!harness.overlay.renderedLine(3).?.dimmed);
}

test "line numbers: relative numbering follows the active model line" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 7, &.{ 1, 1, 1, 1, 1, 1, 1 }, &.{});
    defer harness.deinit();

    harness.options.set(.lineNumbers, .{ .render_type = .Relative, .render_fn = null });
    harness.overlay.readConfig();
    var selections = [_]Selection{Selection.init(5, 1, 5, 1)};
    _ = harness.overlay.base.handler.onCursorStateChanged(&.{ .selections = &selections, .modelSelections = &selections, .reason = .NotSet });
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqualStrings("4", harness.overlay.renderedLine(1).?.text);
    try testing.expectEqualStrings("2", harness.overlay.renderedLine(3).?.text);
    try testing.expectEqualStrings("5", harness.overlay.renderedLine(5).?.text);
    try testing.expect(harness.overlay.renderedLine(5).?.relative_current);
    try testing.expect(harness.overlay.renderedLine(5).?.active);
    try testing.expectEqualStrings("2", harness.overlay.renderedLine(7).?.text);
}

test "line numbers: interval numbering keeps cursor, multiples of ten and the last line" {
    var harness: Harness = undefined;
    const line_lengths: [23]usize = @splat(1);
    try harness.init(testing.allocator, 23, &line_lengths, &.{});
    defer harness.deinit();

    harness.options.set(.lineNumbers, .{ .render_type = .Interval, .render_fn = null });
    harness.overlay.readConfig();
    var selections = [_]Selection{Selection.init(3, 1, 3, 1)};
    _ = harness.overlay.base.handler.onCursorStateChanged(&.{ .selections = &selections, .modelSelections = &selections, .reason = .NotSet });
    harness.overlay.prepareRender(&harness.rendering);

    try testing.expectEqualStrings("", harness.overlay.renderedLine(1).?.text);
    try testing.expectEqualStrings("3", harness.overlay.renderedLine(3).?.text);
    try testing.expectEqualStrings("10", harness.overlay.renderedLine(10).?.text);
    try testing.expectEqualStrings("20", harness.overlay.renderedLine(20).?.text);
    try testing.expectEqualStrings("", harness.overlay.renderedLine(21).?.text);
    try testing.expectEqualStrings("23", harness.overlay.renderedLine(23).?.text);
}

test "line numbers: off renders nothing and custom renderers return their text" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 2, &.{ 1, 1 }, &.{});
    defer harness.deinit();

    harness.options.set(.lineNumbers, .{ .render_type = .Off, .render_fn = null });
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);
    try testing.expect(harness.overlay.renderedLine(1) == null);

    const Render = struct {
        fn fn_(line_number: usize) []const u8 {
            return if (line_number == 1) "one" else "two";
        }
    };
    harness.options.set(.lineNumbers, .{ .render_type = .Custom, .render_fn = Render.fn_ });
    harness.overlay.readConfig();
    harness.overlay.prepareRender(&harness.rendering);
    try testing.expectEqualStrings("one", harness.overlay.renderedLine(1).?.text);
    try testing.expectEqualStrings("two", harness.overlay.renderedLine(2).?.text);
}

test "line numbers: lineNumberClassName decorations apply to covered lines" {
    var options = model.ModelDecorationOptions.init("test", TrackedRangeStickiness.AlwaysGrowsWhenTypingAtEdges);
    options.lineNumberClassName = "my-line-number";
    const decorations = [_]ViewModelDecoration{
        .{ .range = Range.init(1, 1, 2, 1), .options = &options },
    };

    var harness: Harness = undefined;
    try harness.init(testing.allocator, 3, &.{ 1, 1, 1 }, &decorations);
    defer harness.deinit();

    try testing.expectEqualStrings(" my-line-number", harness.overlay.renderedLine(1).?.extra_class_names);
    try testing.expectEqualStrings(" my-line-number", harness.overlay.renderedLine(2).?.extra_class_names);
    try testing.expectEqualStrings("", harness.overlay.renderedLine(3).?.extra_class_names);
}

test "line numbers: scroll top changes request a render" {
    var harness: Harness = undefined;
    try harness.init(testing.allocator, 1, &.{1}, &.{});
    defer harness.deinit();

    const scroll_event = view_events.ViewScrollChangedEvent{
        .scrollWidth = 0,
        .scrollLeft = 0,
        .scrollHeight = 0,
        .scrollTop = 0,
        .scrollWidthChanged = false,
        .scrollLeftChanged = false,
        .scrollHeightChanged = false,
        .scrollTopChanged = true,
    };
    try testing.expect(harness.overlay.base.handler.onScrollChanged(&scroll_event));
    var decorations_event = view_events.ViewDecorationsChangedEvent{
        .affectsMinimap = false,
        .affectsOverviewRuler = false,
        .affectsGlyphMargin = false,
        .affectsLineNumber = false,
    };
    try testing.expect(!harness.overlay.base.handler.onDecorationsChanged(&decorations_event));
    decorations_event.affectsLineNumber = true;
    try testing.expect(harness.overlay.base.handler.onDecorationsChanged(&decorations_event));
}

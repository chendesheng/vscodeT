// Terminal subset of `src/vs/editor/common/viewModel/viewModelImpl.ts`.
//
// The terminal view model owns the projected lines, coordinates converter and
// selections, and exposes the `IViewModel` surface the ported view parts read.
// The browser cursor controller, view-model event dispatcher, glyph lanes,
// minimap and view-zone machinery are not ported; selections/focus/viewport are
// updated explicitly by the host. `ViewModelDecorations` is wired for the
// inline-decoration viewport data; decoration-change events are host-driven
// (the event dispatcher is not ported).
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_model = @import("../viewModel.zig");
const editor_configuration = @import("../config/editorConfiguration.zig");
const editor_options = @import("../config/editorOptions.zig");
const text_model = @import("../model/textModel.zig");
const view_model_lines = @import("./viewModelLines.zig");
const glyph_lanes = @import("./glyphLanesModel.zig");
const coordinates_converter = @import("../coordinatesConverter.zig");
const view_model_decorations = @import("./viewModelDecorations.zig");
const CoordinatesConverter = view_model_lines.CoordinatesConverter;
const Selection = @import("../core/selection.zig").Selection;
const Range = @import("../core/range.zig").Range;
const Position = @import("../core/position.zig").Position;
const Viewport = view_model.Viewport;
const TextDirection = @import("../standalone/standaloneEnums.zig").TextDirection;

const IViewModel = view_model.IViewModel;
const IViewLayout = view_model.IViewLayout;
const ICoordinatesConverter = coordinates_converter.ICoordinatesConverter;
const ViewLineData = view_model.ViewLineData;
const ViewLineRenderingData = view_model.ViewLineRenderingData;
const ViewModelDecoration = @import("./viewModelDecoration.zig").ViewModelDecoration;
const IActiveIndentGuideInfo = @import("../textModelGuides.zig").IActiveIndentGuideInfo;
const BracketGuideOptions = @import("../textModelGuides.zig").BracketGuideOptions;
const LineGuides = @import("../textModelGuides.zig").LineGuides;
const ModelDecoration = @import("../model.zig").ModelDecoration;
const InternalModelContentChangeEvent = @import("../textModelEvents.zig").InternalModelContentChangeEvent;
const view_events = @import("../viewEvents.zig");
const ViewEventHandler = @import("../viewEventHandler.zig").ViewEventHandler;
const ViewModelEventDispatcher = @import("../viewModelEventDispatcher.zig").ViewModelEventDispatcher;

pub const ViewModel = struct {
    allocator: Allocator,
    model: *text_model.TextModel,
    configuration: *const editor_configuration.IEditorConfiguration,
    lines: view_model_lines.ProjectedViewModelLines,
    converter: CoordinatesConverter,
    decorations: *view_model_decorations.ViewModelDecorations,
    lines_adapter: LinesAdapter,
    event_dispatcher: ViewModelEventDispatcher,
    selections: std.array_list.Managed(Selection),
    focus: bool = false,
    viewport: Viewport = Viewport.init(0, 0, 0, 0),
    viewport_start_line: usize = 1,
    viewport_end_line: usize = 0,
    glyph_lanes: glyph_lanes.GlyphMarginLanesModel,
    layout: Layout,

    const LinesAdapter = struct {
        view_model: *ViewModel,
        scratch: []ModelDecoration = &.{},

        fn deinit(self: *LinesAdapter) void {
            if (self.scratch.len > 0) self.view_model.model.getAllocator().free(self.scratch);
            self.scratch = &.{};
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
            if (self.scratch.len > 0) self.view_model.model.getAllocator().free(self.scratch);
            self.scratch = &.{};
            const converter = self.view_model.converter.interface();
            const model_range = converter.convertViewRangeToModelRange(converter.context, view_range);
            const model = self.view_model.model;
            self.scratch = model.getDecorationsInRange(
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
            return self.view_model.lines.getLineMinColumn(line_number);
        }

        fn getViewLineMaxColumn(context: *anyopaque, line_number: usize) usize {
            const self: *LinesAdapter = @ptrCast(@alignCast(context));
            return self.view_model.lines.getLineMaxColumn(line_number);
        }

        fn interface(self: *LinesAdapter) view_model_decorations.IViewModelLines {
            return .{
                .context = self,
                .getDecorationsInRange = getDecorationsInRange,
                .getViewLineMinColumn = getViewLineMinColumn,
                .getViewLineMaxColumn = getViewLineMaxColumn,
            };
        }
    };

    const Layout = struct {
        view_model: *ViewModel,
        max_line_width: f64 = 0,

        fn getScrollWidth(context: *anyopaque) f64 {
            _ = context;
            return 0;
        }
        fn getScrollHeight(context: *anyopaque) f64 {
            const self: *Layout = @ptrCast(@alignCast(context));
            return @as(f64, @floatFromInt(self.view_model.lines.getViewLineCount())) *
                self.view_model.lineHeight();
        }
        fn getCurrentViewport(context: *anyopaque) Viewport {
            const self: *Layout = @ptrCast(@alignCast(context));
            return self.view_model.viewport;
        }
        fn getVerticalOffsetForLineNumber(context: *anyopaque, line_number: usize, _: bool) f64 {
            const self: *Layout = @ptrCast(@alignCast(context));
            return @as(f64, @floatFromInt(line_number -| 1)) * self.view_model.lineHeight();
        }
        fn getVerticalOffsetAfterLineNumber(context: *anyopaque, line_number: usize, _: bool) f64 {
            const self: *Layout = @ptrCast(@alignCast(context));
            return @as(f64, @floatFromInt(line_number)) * self.view_model.lineHeight();
        }
        fn getLineHeightForLineNumber(context: *anyopaque, _: usize) f64 {
            const self: *Layout = @ptrCast(@alignCast(context));
            return self.view_model.lineHeight();
        }
        fn setMaxLineWidth(context: *anyopaque, max_line_width: f64) void {
            const self: *Layout = @ptrCast(@alignCast(context));
            self.max_line_width = max_line_width;
        }

        fn interface(self: *Layout) IViewLayout {
            return .{
                .context = self,
                .get_scroll_width = getScrollWidth,
                .get_scroll_height = getScrollHeight,
                .get_current_viewport = getCurrentViewport,
                .get_vertical_offset_for_line_number = getVerticalOffsetForLineNumber,
                .get_vertical_offset_after_line_number = getVerticalOffsetAfterLineNumber,
                .get_line_height_for_line_number = getLineHeightForLineNumber,
                .set_max_line_width = setMaxLineWidth,
            };
        }
    };

    pub fn init(
        allocator: Allocator,
        editor_id: i32,
        configuration: *const editor_configuration.IEditorConfiguration,
        model: *text_model.TextModel,
        wrapping_column: usize,
    ) !*ViewModel {
        const self = try allocator.create(ViewModel);
        errdefer allocator.destroy(self);
        const tab_size = model.getOptions().tabSize;
        self.* = .{
            .allocator = allocator,
            .model = model,
            .configuration = configuration,
            .lines = try view_model_lines.ProjectedViewModelLines.init(
                allocator,
                model,
                wrapping_column,
                tab_size,
                .Same,
                .normal,
            ),
            .converter = undefined,
            .decorations = undefined,
            .glyph_lanes = try glyph_lanes.GlyphMarginLanesModel.init(allocator, model.getLineCount()),
            .lines_adapter = undefined,
            .event_dispatcher = ViewModelEventDispatcher.init(allocator),
            .selections = std.array_list.Managed(Selection).init(allocator),
            .layout = undefined,
        };
        errdefer {
            self.lines.deinit();
            self.glyph_lanes.deinit();
            self.event_dispatcher.deinit();
            self.selections.deinit();
        }
        self.converter = CoordinatesConverter.init(&self.lines);
        self.lines_adapter = .{ .view_model = self };
        self.decorations = try view_model_decorations.ViewModelDecorations.create(
            allocator,
            editor_id,
            model,
            self.configuration.is_simple_widget,
            false,
            self.lines_adapter.interface(),
            self.converter.interface(),
        );
        self.layout = .{ .view_model = self };
        errdefer self.decorations.destroy();
        try model.onDidChangeContentWithContext(self, onModelContentChanged);
        self.updateGlyphMarginLanes();
        return self;
    }

    pub fn deinit(self: *ViewModel) void {
        self.decorations.destroy();
        self.lines_adapter.deinit();
        self.lines.deinit();
        self.glyph_lanes.deinit();
        self.event_dispatcher.deinit();
        self.selections.deinit();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *ViewModel) IViewModel {
        return .{
            .context = self,
            .view_layout = self.layout.interface(),
            .coordinates_converter = self.converter.interface(),
            .add_view_event_handler = addViewEventHandlerFn,
            .remove_view_event_handler = removeViewEventHandlerFn,
            .get_selections = getSelectionsFn,
            .getLineMinColumn = getLineMinColumnFn,
            .getLineMaxColumn = getLineMaxColumnFn,
            .getLineCount = getLineCountFn,
            .getLineLength = getLineLengthFn,
            .getViewportViewLineRenderingData = getViewportViewLineRenderingDataFn,
            .getViewLineContinuesWithWrappedLine = getViewLineContinuesWithWrappedLineFn,
            .getDecorationsInViewport = getDecorationsInViewportFn,
            .getIndentSize = getIndentSizeFn,
            .getActiveIndentGuide = getActiveIndentGuideFn,
            .getLinesIndentGuides = getLinesIndentGuidesFn,
            .getBracketGuidesInRangeByLine = getBracketGuidesInRangeByLineFn,
        };
    }

    fn onModelContentChanged(event: InternalModelContentChangeEvent, self: *ViewModel) anyerror!void {
        try self.lines.applyRawChanges(&event.rawContentChangedEvent);
        self.decorations.onLineMappingChanged();
        self.decorations.onModelDecorationsChanged();
        self.updateGlyphMarginLanes();

        // The terminal view dispatches a conservative full flush/token change;
        // parts re-render the small viewport window.
        const collector = self.event_dispatcher.beginEmitViewEvents();
        collector.emitViewEvent(.{ .ViewFlushed = .{} }) catch {};
        collector.emitViewEvent(.{ .ViewLineMappingChanged = .{} }) catch {};
        collector.emitViewEvent(.{ .ViewLinesChanged = .{
            .fromLineNumber = 1,
            .count = self.lines.getViewLineCount(),
        } }) catch {};
        collector.emitViewEvent(.{ .ViewDecorationsChanged = view_events.ViewDecorationsChangedEvent.init(null) }) catch {};
        var token_ranges = [_]view_events.ViewTokensChangedRange{.{
            .fromLineNumber = 1,
            .toLineNumber = self.lines.getViewLineCount(),
        }};
        collector.emitViewEvent(.{ .ViewTokensChanged = .{ .ranges = &token_ranges } }) catch {};
        self.event_dispatcher.endEmitViewEvents();
    }

    /// Recomputes the glyph-margin lanes from model decorations that carry
    /// `glyphMargin` options. The terminal model uses the full document rather
    /// than a viewport window because the lane model is tiny.
    pub fn updateGlyphMarginLanes(self: *ViewModel) void {
        self.glyph_lanes.reset(self.model.getLineCount()) catch return;
        const line_count = self.model.getLineCount();
        if (line_count == 0) return;
        const all = self.model.getDecorationsInRange(
            Range.init(1, 1, line_count, self.model.getLineMaxColumn(line_count)),
            0,
            false,
            false,
            false,
        ) catch return;
        defer self.model.getAllocator().free(all);

        const converter = self.converter.interface();
        for (all) |decoration| {
            const glyph_options = decoration.options.glyphMargin orelse continue;
            const view_range = converter.convertModelRangeToViewRange(converter.context, decoration.range, .None);
            self.glyph_lanes.push(glyph_options.position, view_range, glyph_options.persistLane orelse false);
        }
    }

    pub fn getGlyphLanesAtLine(self: *ViewModel, allocator: Allocator, line_number: usize) ![]@import("../model.zig").GlyphMarginLane {
        return self.glyph_lanes.getLanesAtLine(allocator, line_number);
    }

    pub fn requiredGlyphLanes(self: *const ViewModel) usize {
        return self.glyph_lanes.requiredLanes();
    }

    pub fn addViewEventHandler(self: *ViewModel, handler: *ViewEventHandler) void {
        self.event_dispatcher.addViewEventHandler(handler);
    }

    pub fn removeViewEventHandler(self: *ViewModel, handler: *ViewEventHandler) void {
        self.event_dispatcher.removeViewEventHandler(handler);
    }

    fn addViewEventHandlerFn(context: *anyopaque, handler: *anyopaque) void {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        self.addViewEventHandler(@ptrCast(@alignCast(handler)));
    }

    fn removeViewEventHandlerFn(context: *anyopaque, handler: *anyopaque) void {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        self.removeViewEventHandler(@ptrCast(@alignCast(handler)));
    }

    pub fn lineHeight(self: *const ViewModel) f64 {
        const options = self.configuration.options orelse return 19;
        const height = options.get(.lineHeight);
        return if (height > 0) height else 19;
    }

    pub fn setSelections(self: *ViewModel, selections: []const Selection) !void {
        self.selections.clearRetainingCapacity();
        try self.selections.appendSlice(selections);

        const converter = self.converter.interface();
        var model_selections = std.array_list.Managed(Selection).init(self.allocator);
        defer model_selections.deinit();
        for (selections) |selection| {
            const start = converter.convertViewPositionToModelPosition(converter.context, Position.init(selection.startLineNumber, selection.startColumn));
            const end = converter.convertViewPositionToModelPosition(converter.context, Position.init(selection.endLineNumber, selection.endColumn));
            try model_selections.append(Selection.init(start.lineNumber, start.column, end.lineNumber, end.column));
        }

        self.event_dispatcher.emitSingleViewEvent(.{ .ViewCursorStateChanged = .{
            .selections = self.selections.items,
            .modelSelections = model_selections.items,
            .reason = .Explicit,
        } });
    }

    pub fn getSelections(self: *const ViewModel) []const Selection {
        return self.selections.items;
    }

    pub fn setFocus(self: *ViewModel, focused: bool) void {
        self.focus = focused;
        self.event_dispatcher.emitSingleViewEvent(.{ .ViewFocusChanged = .{ .isFocused = focused } });
    }

    pub fn hasFocus(self: *const ViewModel) bool {
        return self.focus;
    }

    pub fn setViewport(self: *ViewModel, start_line: usize, end_line: usize, centered_line: usize, viewport: Viewport) void {
        _ = centered_line;
        self.viewport_start_line = start_line;
        self.viewport_end_line = end_line;
        self.viewport = viewport;
    }

    pub fn viewportStartLine(self: *const ViewModel) usize {
        return self.viewport_start_line;
    }

    pub fn getViewLineData(self: *ViewModel, line_number: usize) !ViewLineData {
        return self.lines.getViewLineData(line_number);
    }

    fn getSelectionsFn(context: *anyopaque) []const Selection {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.selections.items;
    }

    fn getLineMinColumnFn(context: *anyopaque, line_number: usize) usize {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.lines.getLineMinColumn(line_number);
    }

    fn getLineMaxColumnFn(context: *anyopaque, line_number: usize) usize {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.lines.getLineMaxColumn(line_number);
    }

    fn getLineCountFn(context: *anyopaque) usize {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.lines.getViewLineCount();
    }

    fn getLineLengthFn(context: *anyopaque, line_number: usize) usize {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.lines.getLineMaxColumn(line_number) - 1;
    }

    fn getViewportViewLineRenderingDataFn(context: *anyopaque, visible_range: Range, line_number: usize) anyerror!ViewLineRenderingData {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        const data = try self.lines.getViewLineData(line_number);

        var inline_decorations: []const @import("./inlineDecorations.zig").InlineDecoration = &.{};
        var has_variable_fonts = false;
        if (self.decorations.getDecorationsViewportData(visible_range) catch null) |collection| {
            const line_index = line_number -| visible_range.startLineNumber;
            if (line_index < collection.inlineDecorations.len) {
                inline_decorations = collection.inlineDecorations[line_index];
            }
            if (line_index < collection.hasVariableFonts.len) {
                has_variable_fonts = collection.hasVariableFonts[line_index];
            }
        }

        return ViewLineRenderingData.init(
            data.minColumn,
            data.maxColumn,
            data.content,
            data.continuesWithWrappedLine,
            false,
            false,
            data.tokens,
            inline_decorations,
            self.model.getOptions().tabSize,
            data.startVisibleColumn,
            TextDirection.LTR,
            has_variable_fonts,
        );
    }

    fn getViewLineContinuesWithWrappedLineFn(context: *anyopaque, line_number: usize) bool {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        const data = self.lines.getViewLineData(line_number) catch return false;
        return data.continuesWithWrappedLine;
    }

    fn getDecorationsInViewportFn(context: *anyopaque, view_range: Range, allocator: Allocator) anyerror![]ViewModelDecoration {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        const converter = self.converter.interface();
        const model_range = converter.convertViewRangeToModelRange(converter.context, view_range);
        const model_decorations = try self.model.getDecorationsInRange(model_range, 0, false, false, false);
        defer self.model.getAllocator().free(model_decorations);

        const result = try allocator.alloc(ViewModelDecoration, model_decorations.len);
        errdefer allocator.free(result);
        for (model_decorations, 0..) |decoration, index| {
            result[index] = .{
                .range = converter.convertModelRangeToViewRange(converter.context, decoration.range, .None),
                .options = decoration.options,
            };
        }
        return result;
    }

    fn getIndentSizeFn(context: *anyopaque) usize {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.model.getOptions().indentSize;
    }

    fn getActiveIndentGuideFn(context: *anyopaque, line_number: usize, min_line_number: usize, max_line_number: usize) anyerror!IActiveIndentGuideInfo {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.lines.getActiveIndentGuide(line_number, min_line_number, max_line_number);
    }

    fn getLinesIndentGuidesFn(context: *anyopaque, start_line_number: usize, end_line_number: usize, allocator: Allocator) anyerror![]usize {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.lines.getViewLinesIndentGuides(allocator, start_line_number, end_line_number);
    }

    fn getBracketGuidesInRangeByLineFn(
        context: *anyopaque,
        start_line_number: usize,
        end_line_number: usize,
        active_position: ?Position,
        options: BracketGuideOptions,
        allocator: Allocator,
    ) anyerror![]LineGuides {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        return self.lines.getViewLinesBracketGuides(
            allocator,
            start_line_number,
            end_line_number,
            active_position,
            options,
        );
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_support = @import("../../test/common/port/testSupport.zig");
const browser_config = @import("../../browser/config/editorConfiguration.zig");
const actions = @import("../../../platform/actions/common/actions.zig");

const Fixture = struct {
    allocator: Allocator,
    model: test_support.TestModel,
    options: browser_config.ComputedEditorOptions,
    configuration: editor_configuration.IEditorConfiguration,

    fn init(self: *Fixture, allocator: Allocator, text: []const u8, wrapping_column: usize) !*ViewModel {
        self.allocator = allocator;
        self.model = try test_support.TestModel.init(allocator, text, "plaintext");
        self.options = browser_config.ComputedEditorOptions.init();
        self.configuration = .{
            .is_simple_widget = false,
            .context_menu_id = actions.menu_ids.EditorContext,
            .options = self.options.interface(),
        };
        return ViewModel.init(allocator, 1, &self.configuration, self.model.model, wrapping_column);
    }

    fn deinit(self: *Fixture) void {
        self.model.deinit();
    }
};

test "view model: lines, rendering data and coordinates" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const view_model_instance = try fixture.init(allocator, "hello\nworld", 80);
    defer {
        view_model_instance.deinit();
        fixture.deinit();
    }

    const vm = view_model_instance.interface();
    try testing.expectEqual(@as(usize, 2), vm.lineCount());
    try testing.expectEqual(@as(usize, 6), vm.lineMaxColumn(1));
    try testing.expectEqual(@as(usize, 5), vm.lineLength(1));

    const rendering = try vm.viewportViewLineRenderingData(Range.init(1, 1, 2, 1), 2);
    try testing.expectEqualStrings("world", rendering.content);
    try testing.expectEqual(@as(usize, 4), rendering.tabSize);
    try testing.expect(!vm.viewLineContinuesWithWrappedLine(1));

    const model_position = view_model_instance.converter.interface().convertViewPositionToModelPosition(
        view_model_instance.converter.interface().context,
        Position.init(2, 3),
    );
    try testing.expectEqual(@as(usize, 2), model_position.lineNumber);
    try testing.expectEqual(@as(usize, 3), model_position.column);
}

test "view model: selections, focus and viewport" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const instance = try fixture.init(allocator, "one\ntwo\nthree", 80);
    defer {
        instance.deinit();
        fixture.deinit();
    }

    const selection = Selection.init(2, 1, 2, 4);
    try instance.setSelections(&.{selection});
    try testing.expectEqual(@as(usize, 1), instance.getSelections().len);
    try testing.expectEqual(@as(usize, 2), instance.getSelections()[0].startLineNumber);

    instance.setFocus(true);
    try testing.expect(instance.hasFocus());

    instance.setViewport(2, 3, 2, Viewport.init(0, 0, 80, 40));
    try testing.expectEqual(@as(usize, 2), instance.viewportStartLine());
    try testing.expectEqual(@as(f64, 19), instance.lineHeight());
}

test "view model: maps model decorations into the viewport" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const instance = try fixture.init(allocator, "line one\nline two", 80);
    defer {
        instance.deinit();
        fixture.deinit();
    }

    var options = std.mem.zeroes(@import("../model.zig").ModelDecorationOptions);
    options.className = "test-decoration";
    options.inlineClassName = "test-inline";
    const decoration = @import("../model.zig").ModelDeltaDecoration{
        .range = Range.init(1, 1, 1, 4),
        .options = &options,
    };
    const ids = try fixture.model.model.deltaDecorations(&.{}, &.{decoration}, 0);
    defer {
        const removed = fixture.model.model.deltaDecorations(ids, &.{}, 0) catch &[_]u64{};
        if (removed.len > 0) allocator.free(removed);
        allocator.free(ids);
    }

    const decorations = try instance.interface().decorationsInViewport(Range.init(1, 1, 2, 1), allocator);
    defer allocator.free(decorations);
    try testing.expectEqual(@as(usize, 1), decorations.len);
    try testing.expectEqual(@as(usize, 1), decorations[0].range.startLineNumber);
    try testing.expectEqual(@as(usize, 4), decorations[0].range.endColumn);

    const rendering = try instance.interface().viewportViewLineRenderingData(Range.init(1, 1, 2, 1), 1);
    try testing.expectEqual(@as(usize, 1), rendering.inlineDecorations.len);
    try testing.expectEqualStrings("test-inline", rendering.inlineDecorations[0].inlineClassName);
    try testing.expect(!rendering.hasVariableFonts);
}

test "view model integrates with the terminal view" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const instance = try fixture.init(allocator, "hello\nworld", 80);
    defer {
        instance.deinit();
        fixture.deinit();
    }
    fixture.options.set(.lineHeight, 19);

    var context = @import("./viewContext.zig").ViewContext.init(&fixture.configuration, @import("../../test/common/viewModelTestStubs.zig").TestColorTheme.dark(), instance.interface());
    var view: @import("../../browser/view.zig").View = undefined;
    view.init(allocator, &context);
    defer view.deinit();

    const rendering = try instance.interface().viewportViewLineRenderingData(Range.init(1, 1, 2, 6), 1);
    var rendered = try @import("../viewLayout/viewLineRenderer.zig").renderLine(allocator, .{
        .content = rendering.content,
        .tokens = rendering.tokens,
        .tab_size = rendering.tabSize,
        .start_visible_column = rendering.startVisibleColumn,
    });
    defer rendered.deinit(allocator);
    try testing.expectEqualStrings("hello", rendered.bytes);

    const Opts = @import("../../browser/viewParts/viewLines/viewLineOptions.zig").ViewLineOptions;
    const VL = @import("../../browser/viewParts/viewLines/viewLine.zig").ViewLine;
    const Factory = struct {
        allocator: Allocator,
        context: *@import("./viewContext.zig").ViewContext,
        options: Opts,
        fn create(ctx: *anyopaque) anyerror!VL {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return VL.init(self.allocator, self.context, self.options);
        }
    };
    var factory = Factory{ .allocator = allocator, .context = &context, .options = Opts.init(&fixture.configuration, .DARK) };
    var collection = @import("../../browser/view/viewLayer.zig").VisibleLinesCollection(VL).init(allocator, context.view_layout, .{ .context = &factory, .create = Factory.create });
    defer collection.deinit();
    const selections = [_]Selection{Selection.init(1, 1, 1, 1)};
    const offsets = [_]f64{ 0, 19 };
    var viewport = @import("../viewLayout/viewLinesViewportData.zig").ViewportData{
        .selections = &selections,
        .startLineNumber = 1,
        .endLineNumber = 2,
        .relativeVerticalOffset = &offsets,
        .visibleRange = Range.init(1, 1, 2, 6),
        .bigNumbersDelta = 0,
        .whitespaceViewportData = &.{},
        .lineHeight = 19,
        ._model = instance.interface(),
    };
    var sb = try @import("../core/stringBuilder.zig").StringBuilder.init(allocator, 16);
    defer sb.deinit();
    try collection.renderLines(&viewport, &sb);
    try testing.expectEqualStrings("helloworld", sb.build());
    _ = collection.onFlushed(&.{});

    _ = view.setFocused(true);
    try testing.expect(view.hasFocus());
    try testing.expectEqual(@as(usize, 2), instance.lines.getViewLineCount());
}

test "view model applies model content changes" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const instance = try fixture.init(allocator, "hello", 80);
    defer {
        instance.deinit();
        fixture.deinit();
    }

    try fixture.model.applyEdit(Range.init(1, 1, 1, 1), "X");
    const first = try instance.lines.getViewLineData(1);
    try testing.expectEqualStrings("Xhello", first.content);

    try fixture.model.applyEdit(Range.init(1, 1, 1, 1), "a\nb");
    try testing.expectEqual(@as(usize, 2), instance.lines.getViewLineCount());
    const second = try instance.lines.getViewLineData(2);
    try testing.expectEqualStrings("bXhello", second.content);
}

test "view model dispatches view events to registered handlers" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const instance = try fixture.init(allocator, "hello", 80);
    defer {
        instance.deinit();
        fixture.deinit();
    }

    const State = struct {
        flushes: usize = 0,
        line_changes: usize = 0,
        focus_changes: usize = 0,

        fn onFlushed(context: *anyopaque, _: *const view_events.ViewFlushedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.flushes += 1;
            return true;
        }
        fn onLinesChanged(context: *anyopaque, _: *const view_events.ViewLinesChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.line_changes += 1;
            return true;
        }
        fn onFocusChanged(context: *anyopaque, _: *const view_events.ViewFocusChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.focus_changes += 1;
            return true;
        }
    };
    var state = State{};
    var handler = @import("../viewEventHandler.zig").ViewEventHandler.init(&state, .{
        .onFlushed = State.onFlushed,
        .onLinesChanged = State.onLinesChanged,
        .onFocusChanged = State.onFocusChanged,
    });
    instance.addViewEventHandler(&handler);

    instance.setFocus(true);
    try testing.expectEqual(@as(usize, 1), state.focus_changes);

    try fixture.model.applyEdit(Range.init(1, 1, 1, 1), "X");
    try testing.expectEqual(@as(usize, 1), state.flushes);
    try testing.expectEqual(@as(usize, 1), state.line_changes);

    instance.removeViewEventHandler(&handler);
    try fixture.model.applyEdit(Range.init(1, 1, 1, 1), "Y");
    try testing.expectEqual(@as(usize, 1), state.flushes);
}

test "view model computes glyph margin lanes from decorations" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const instance = try fixture.init(allocator, "one\ntwo", 80);
    defer {
        instance.deinit();
        fixture.deinit();
    }

    const GlyphMarginLane = @import("../model.zig").GlyphMarginLane;
    var center_options = std.mem.zeroes(@import("../model.zig").ModelDecorationOptions);
    center_options.glyphMarginClassName = "center";
    center_options.glyphMargin = .{ .position = .Center, .persistLane = false };
    var right_options = std.mem.zeroes(@import("../model.zig").ModelDecorationOptions);
    right_options.glyphMarginClassName = "right";
    right_options.glyphMargin = .{ .position = .Right, .persistLane = false };

    const new_decorations = [_]@import("../model.zig").ModelDeltaDecoration{
        .{ .range = Range.init(1, 1, 1, 2), .options = &center_options },
        .{ .range = Range.init(1, 1, 1, 2), .options = &right_options },
    };
    const ids = try fixture.model.model.deltaDecorations(&.{}, &new_decorations, 0);
    defer {
        const removed = fixture.model.model.deltaDecorations(ids, &.{}, 0) catch &[_]u64{};
        if (removed.len > 0) allocator.free(removed);
        allocator.free(ids);
    }

    instance.updateGlyphMarginLanes();
    try testing.expectEqual(@as(usize, 2), instance.requiredGlyphLanes());
    const lanes = try instance.getGlyphLanesAtLine(allocator, 1);
    defer allocator.free(lanes);
    try testing.expectEqual(@as(usize, 2), lanes.len);
    try testing.expectEqual(GlyphMarginLane.Center, lanes[0]);
    try testing.expectEqual(GlyphMarginLane.Right, lanes[1]);
}

test "view model dispatches cursor state changes" {
    const allocator = testing.allocator;
    var fixture: Fixture = undefined;
    const instance = try fixture.init(allocator, "hello\nworld", 80);
    defer {
        instance.deinit();
        fixture.deinit();
    }

    const State = struct {
        count: usize = 0,
        start_column: usize = 0,

        fn onCursorStateChanged(context: *anyopaque, event: *const view_events.ViewCursorStateChangedEvent) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            if (event.selections.len > 0) self.start_column = event.selections[0].startColumn;
            return true;
        }
    };
    var state = State{};
    var handler = @import("../viewEventHandler.zig").ViewEventHandler.init(&state, .{
        .onCursorStateChanged = State.onCursorStateChanged,
    });
    instance.addViewEventHandler(&handler);

    try instance.setSelections(&.{Selection.init(1, 2, 1, 4)});
    try testing.expectEqual(@as(usize, 1), state.count);
    try testing.expectEqual(@as(usize, 2), state.start_column);
}

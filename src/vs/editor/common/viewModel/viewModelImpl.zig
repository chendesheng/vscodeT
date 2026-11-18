// Terminal subset of `src/vs/editor/common/viewModel/viewModelImpl.ts`.
//
// The terminal view model owns the projected lines, coordinates converter and
// selections, and exposes the `IViewModel` surface the ported view parts read.
// The browser cursor controller, view-model event dispatcher, glyph lanes,
// minimap and view-zone machinery are not ported; selections/focus/viewport are
// updated explicitly by the host. Inline/decoration viewport data is empty
// until the terminal `ViewModelDecorations` adapter is wired (the terminal
// view's first pass does not consume inline decoration ranges).
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_model = @import("../viewModel.zig");
const editor_configuration = @import("../config/editorConfiguration.zig");
const editor_options = @import("../config/editorOptions.zig");
const text_model = @import("../model/textModel.zig");
const view_model_lines = @import("./viewModelLines.zig");
const coordinates_converter = @import("../coordinatesConverter.zig");
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

pub const ViewModel = struct {
    allocator: Allocator,
    model: *text_model.TextModel,
    configuration: *const editor_configuration.IEditorConfiguration,
    lines: view_model_lines.ProjectedViewModelLines,
    converter: CoordinatesConverter,
    selections: std.array_list.Managed(Selection),
    focus: bool = false,
    viewport: Viewport = Viewport.init(0, 0, 0, 0),
    viewport_start_line: usize = 1,
    viewport_end_line: usize = 0,
    layout: Layout,

    const Layout = struct {
        view_model: *ViewModel,

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

        fn interface(self: *Layout) IViewLayout {
            return .{
                .context = self,
                .get_scroll_width = getScrollWidth,
                .get_scroll_height = getScrollHeight,
                .get_current_viewport = getCurrentViewport,
                .get_vertical_offset_for_line_number = getVerticalOffsetForLineNumber,
                .get_vertical_offset_after_line_number = getVerticalOffsetAfterLineNumber,
                .get_line_height_for_line_number = getLineHeightForLineNumber,
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
            .selections = std.array_list.Managed(Selection).init(allocator),
            .layout = undefined,
        };
        self.converter = CoordinatesConverter.init(&self.lines);
        self.layout = .{ .view_model = self };
        _ = editor_id;
        return self;
    }

    pub fn deinit(self: *ViewModel) void {
        self.lines.deinit();
        self.selections.deinit();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *ViewModel) IViewModel {
        return .{
            .context = self,
            .view_layout = self.layout.interface(),
            .coordinates_converter = self.converter.interface(),
            .getLineMinColumn = getLineMinColumnFn,
            .getLineMaxColumn = getLineMaxColumnFn,
            .getLineCount = getLineCountFn,
            .getLineLength = getLineLengthFn,
            .getViewportViewLineRenderingData = getViewportViewLineRenderingDataFn,
            .getViewLineContinuesWithWrappedLine = getViewLineContinuesWithWrappedLineFn,
            .getDecorationsInViewport = getDecorationsInViewportFn,
        };
    }

    pub fn lineHeight(self: *const ViewModel) f64 {
        const options = self.configuration.options orelse return 19;
        const height = options.get(.lineHeight);
        return if (height > 0) height else 19;
    }

    pub fn setSelections(self: *ViewModel, selections: []const Selection) !void {
        self.selections.clearRetainingCapacity();
        try self.selections.appendSlice(selections);
    }

    pub fn getSelections(self: *const ViewModel) []const Selection {
        return self.selections.items;
    }

    pub fn setFocus(self: *ViewModel, focused: bool) void {
        self.focus = focused;
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

    fn getViewportViewLineRenderingDataFn(context: *anyopaque, _: Range, line_number: usize) anyerror!ViewLineRenderingData {
        const self: *ViewModel = @ptrCast(@alignCast(context));
        const data = try self.lines.getViewLineData(line_number);
        return ViewLineRenderingData.init(
            data.minColumn,
            data.maxColumn,
            data.content,
            data.continuesWithWrappedLine,
            false,
            false,
            data.tokens,
            &.{},
            self.model.getOptions().tabSize,
            data.startVisibleColumn,
            TextDirection.LTR,
            false,
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

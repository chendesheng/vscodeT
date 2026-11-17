// Port of `src/vs/editor/common/viewLayout/viewLinesViewportData.ts`

const std = @import("std");
const Allocator = std.mem.Allocator;

const Range = @import("../core/range.zig").Range;
const Selection = @import("../core/selection.zig").Selection;
const viewModel = @import("../viewModel.zig");

const IPartialViewLinesViewportData = viewModel.IPartialViewLinesViewportData;
const IViewWhitespaceViewportData = viewModel.IViewWhitespaceViewportData;
const IViewModel = viewModel.IViewModel;
const ViewLineRenderingData = viewModel.ViewLineRenderingData;
const ViewModelDecoration = viewModel.ViewModelDecoration;

/// Contains all data needed to render at a specific viewport.
///
/// All slices are borrowed: `relativeVerticalOffset` comes from the layout's
/// `LinesViewportData`, `whitespaceViewportData` and `selections` from the
/// caller.
pub const ViewportData = struct {
    selections: []const Selection,

    /// The line number at which to start rendering (inclusive).
    startLineNumber: usize,
    /// The line number at which to end rendering (inclusive).
    endLineNumber: usize,
    /// `relativeVerticalOffset[i]` is the `top` position for the line at
    /// `i + startLineNumber`.
    relativeVerticalOffset: []const f64,
    /// The viewport as a range
    /// `(startLineNumber, 1) -> (endLineNumber, maxColumn(endLineNumber))`.
    visibleRange: Range,
    /// Value to be subtracted from `scrollTop` (in order to keep vertical offset
    /// numbers below one million).
    bigNumbersDelta: f64,
    /// Positioning information about gap whitespaces.
    whitespaceViewportData: []const IViewWhitespaceViewportData,
    lineHeight: f64,

    _model: IViewModel,

    pub fn init(
        selections: []const Selection,
        partialData: IPartialViewLinesViewportData,
        whitespaceViewportData: []const IViewWhitespaceViewportData,
        model: IViewModel,
    ) ViewportData {
        return .{
            .selections = selections,
            .startLineNumber = partialData.startLineNumber,
            .endLineNumber = partialData.endLineNumber,
            .relativeVerticalOffset = partialData.relativeVerticalOffset,
            .bigNumbersDelta = @trunc(partialData.bigNumbersDelta),
            .lineHeight = @trunc(partialData.lineHeight),
            .whitespaceViewportData = whitespaceViewportData,
            .visibleRange = Range.init(
                partialData.startLineNumber,
                model.lineMinColumn(partialData.startLineNumber),
                partialData.endLineNumber,
                model.lineMaxColumn(partialData.endLineNumber),
            ),
            ._model = model,
        };
    }

    pub fn getViewLineRenderingData(self: *const ViewportData, lineNumber: usize) !ViewLineRenderingData {
        return self._model.viewportViewLineRenderingData(self.visibleRange, lineNumber);
    }

    pub fn getViewLineContinuesWithWrappedLine(self: *const ViewportData, lineNumber: usize) bool {
        return self._model.viewLineContinuesWithWrappedLine(lineNumber);
    }

    /// The returned array is owned by the caller.
    pub fn getDecorationsInViewport(self: *const ViewportData, allocator: Allocator) ![]ViewModelDecoration {
        return self._model.decorationsInViewport(self.visibleRange, allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_stubs = @import("../../test/common/viewModelTestStubs.zig");
const Position = @import("../core/position.zig").Position;
const TextDirection = @import("../standalone/standaloneEnums.zig").TextDirection;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const lineTokens = @import("../tokens/lineTokens.zig");

const TestModel = struct {
    var decoder: LanguageIdCodec = undefined;
    var tokens: lineTokens.LineTokens = undefined;
    var decoration_count: usize = 0;

    fn lineMinColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }

    fn lineMaxColumn(_: *anyopaque, line_number: usize) usize {
        return if (line_number == 1) 6 else 11;
    }

    fn viewportViewLineRenderingData(context: *anyopaque, visible_range: Range, line_number: usize) anyerror!ViewLineRenderingData {
        _ = context;
        _ = visible_range;
        return ViewLineRenderingData.init(
            1,
            if (line_number == 1) 6 else 11,
            if (line_number == 1) "hello" else "worldwide!",
            false,
            false,
            false,
            lineTokens.IViewLineTokens.init(&tokens),
            &.{},
            4,
            0,
            TextDirection.LTR,
            false,
        );
    }

    fn viewLineContinuesWithWrappedLine(_: *anyopaque, line_number: usize) bool {
        return line_number == 1;
    }

    fn decorationsInViewport(_: *anyopaque, visible_range: Range, allocator: Allocator) anyerror![]ViewModelDecoration {
        _ = visible_range;
        const decorations = try allocator.alloc(ViewModelDecoration, decoration_count);
        return decorations;
    }

    fn layoutScrollWidth(_: *anyopaque) f64 {
        return 0;
    }
    fn layoutScrollHeight(_: *anyopaque) f64 {
        return 0;
    }
    fn layoutViewport(_: *anyopaque) @import("../viewModel.zig").Viewport {
        return .{ .top = 0, .left = 0, .width = 0, .height = 0 };
    }
    fn layoutVerticalOffset(_: *anyopaque, _: usize, _: bool) f64 {
        return 0;
    }
    fn layoutLineHeight(_: *anyopaque, _: usize) f64 {
        return 1;
    }
    fn testLayout() @import("../viewModel.zig").IViewLayout {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .get_scroll_width = layoutScrollWidth,
            .get_scroll_height = layoutScrollHeight,
            .get_current_viewport = layoutViewport,
            .get_vertical_offset_for_line_number = layoutVerticalOffset,
            .get_vertical_offset_after_line_number = layoutVerticalOffset,
            .get_line_height_for_line_number = layoutLineHeight,
        };
    }

    fn interface() IViewModel {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .view_layout = testLayout(),
            .coordinates_converter = test_stubs.TestCoordinatesConverter.interface(),
            .getLineCount = struct {
                fn f(_: *anyopaque) usize {
                    return 2;
                }
            }.f,
            .getLineLength = struct {
                fn f(_: *anyopaque, line_number: usize) usize {
                    return if (line_number == 1) 5 else 10;
                }
            }.f,
            .getLineMinColumn = lineMinColumn,
            .getLineMaxColumn = lineMaxColumn,
            .getViewportViewLineRenderingData = viewportViewLineRenderingData,
            .getViewLineContinuesWithWrappedLine = viewLineContinuesWithWrappedLine,
            .getDecorationsInViewport = decorationsInViewport,
        };
    }
};

fn setup() !void {
    TestModel.decoder = try LanguageIdCodec.init(testing.allocator);
    var content = std.array_list.Managed(u8).init(testing.allocator);
    try content.appendSlice("hello");
    TestModel.tokens = try lineTokens.LineTokens.createEmpty(testing.allocator, content, &TestModel.decoder);
}

fn teardown() void {
    TestModel.tokens.deinit();
    TestModel.decoder.deinit();
}

test "ViewportData derives the visible range from the view model" {
    try setup();
    defer teardown();

    const partial = IPartialViewLinesViewportData{
        .bigNumbersDelta = 0,
        .startLineNumber = 1,
        .endLineNumber = 2,
        .relativeVerticalOffset = &.{ 0, 20, 40.5 },
        .centeredLineNumber = 1,
        .completelyVisibleStartLineNumber = 1,
        .completelyVisibleEndLineNumber = 2,
        .lineHeight = 20.9,
    };
    const whitespaces = [_]IViewWhitespaceViewportData{};

    const viewport = ViewportData.init(&.{}, partial, &whitespaces, TestModel.interface());

    try testing.expectEqual(@as(usize, 1), viewport.startLineNumber);
    try testing.expectEqual(@as(usize, 2), viewport.endLineNumber);
    // `| 0` truncation of bigNumbersDelta and lineHeight.
    try testing.expectEqual(@as(f64, 20), viewport.lineHeight);
    try testing.expectEqual(@as(usize, 3), viewport.relativeVerticalOffset.len);
    try testing.expectEqual(@as(f64, 40.5), viewport.relativeVerticalOffset[2]);

    // visibleRange spans (1, minColumn) -> (2, maxColumn).
    try testing.expectEqual(@as(usize, 1), viewport.visibleRange.startLineNumber);
    try testing.expectEqual(@as(usize, 1), viewport.visibleRange.startColumn);
    try testing.expectEqual(@as(usize, 2), viewport.visibleRange.endLineNumber);
    try testing.expectEqual(@as(usize, 11), viewport.visibleRange.endColumn);
}

test "ViewportData delegates rendering queries to the view model" {
    try setup();
    defer teardown();

    const partial = IPartialViewLinesViewportData{
        .bigNumbersDelta = 0,
        .startLineNumber = 1,
        .endLineNumber = 2,
        .relativeVerticalOffset = &.{ 0, 20 },
        .centeredLineNumber = 1,
        .completelyVisibleStartLineNumber = 1,
        .completelyVisibleEndLineNumber = 2,
        .lineHeight = 20,
    };
    const viewport = ViewportData.init(&.{}, partial, &.{}, TestModel.interface());

    const first = try viewport.getViewLineRenderingData(1);
    try testing.expectEqualStrings("hello", first.content);
    try testing.expectEqual(@as(usize, 6), first.maxColumn);
    try testing.expect(first.isBasicASCII);

    const second = try viewport.getViewLineRenderingData(2);
    try testing.expectEqualStrings("worldwide!", second.content);

    try testing.expect(viewport.getViewLineContinuesWithWrappedLine(1));
    try testing.expect(!viewport.getViewLineContinuesWithWrappedLine(2));

    TestModel.decoration_count = 3;
    const decorations = try viewport.getDecorationsInViewport(testing.allocator);
    defer testing.allocator.free(decorations);
    try testing.expectEqual(@as(usize, 3), decorations.len);
}

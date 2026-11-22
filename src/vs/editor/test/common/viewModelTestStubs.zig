// Test helper: an identity `ICoordinatesConverter` for the ported view-model
// stubs.
//
// Upstream view tests construct a real view model (and therefore a real
// converter). The ported view scaffolding tests never convert coordinates, so
// a round-tripping converter is enough to satisfy the interface. There is no
// upstream file counterpart; this only exists to keep the stubs small.
const std = @import("std");
const coordinates = @import("../../common/coordinatesConverter.zig");
const view_model = @import("../../common/viewModel.zig");
const theme_service = @import("../../../platform/theme/common/themeService.zig");
const Color = @import("../../../base/common/color.zig").Color;
const Position = @import("../../common/core/position.zig").Position;
const Range = @import("../../common/core/range.zig").Range;
const PositionAffinity = @import("../../common/model.zig").PositionAffinity;
const text_model_guides = @import("../../common/textModelGuides.zig");

pub const TestCoordinatesConverter = struct {
    pub fn interface() coordinates.ICoordinatesConverter {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .convertViewPositionToModelPosition = convertViewPositionToModelPosition,
            .convertViewRangeToModelRange = convertViewRangeToModelRange,
            .validateViewPosition = validateViewPosition,
            .validateViewRange = validateViewRange,
            .convertModelPositionToViewPosition = convertModelPositionToViewPosition,
            .convertModelRangeToViewRange = convertModelRangeToViewRange,
            .modelPositionIsVisible = modelPositionIsVisible,
            .getModelLineViewLineCount = getModelLineViewLineCount,
            .getViewLineNumberOfModelPosition = getViewLineNumberOfModelPosition,
        };
    }

    fn convertViewPositionToModelPosition(_: *anyopaque, view_position: Position) Position {
        return view_position;
    }
    fn convertViewRangeToModelRange(_: *anyopaque, view_range: Range) Range {
        return view_range;
    }
    fn validateViewPosition(_: *anyopaque, view_position: Position, _: Position) Position {
        return view_position;
    }
    fn validateViewRange(_: *anyopaque, view_range: Range, _: Range) Range {
        return view_range;
    }
    fn convertModelPositionToViewPosition(_: *anyopaque, model_position: Position, _: PositionAffinity, _: bool, _: bool) Position {
        return model_position;
    }
    fn convertModelRangeToViewRange(_: *anyopaque, model_range: Range, _: PositionAffinity) Range {
        return model_range;
    }
    fn modelPositionIsVisible(_: *anyopaque, _: Position) bool {
        return true;
    }
    fn getModelLineViewLineCount(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn getViewLineNumberOfModelPosition(_: *anyopaque, model_line_number: usize, _: usize) usize {
        return model_line_number;
    }
};

/// A test color theme: no colors, no token styles.
pub const TestColorTheme = struct {
    const vtable = theme_service.IColorTheme.VTable{
        .getColor = getColor,
        .defines = defines,
        .getTokenStyleMetadata = getTokenStyleMetadata,
    };

    pub fn dark() theme_service.IColorTheme {
        return theme_service.IColorTheme.init(.DARK, "test", @ptrFromInt(@alignOf(usize)), &vtable);
    }

    fn getColor(_: *anyopaque, _: []const u8, _: bool) ?Color {
        return null;
    }
    fn defines(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn getTokenStyleMetadata(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) ?theme_service.ITokenStyle {
        return null;
    }
};

/// A test view layout with configurable viewport and line height.
pub const TestViewLayout = struct {
    scroll_width: f64 = 0,
    scroll_height: f64 = 0,
    viewport: view_model.Viewport = .{ .top = 0, .left = 0, .width = 80, .height = 24 },
    line_height: f64 = 1,
    line_heights: []const f64 = &.{},
    max_line_width: f64 = 0,

    pub fn interface(self: *TestViewLayout) view_model.IViewLayout {
        return .{
            .context = self,
            .get_scroll_width = getScrollWidth,
            .get_scroll_height = getScrollHeight,
            .get_current_viewport = getCurrentViewport,
            .get_vertical_offset_for_line_number = getVerticalOffset,
            .get_vertical_offset_after_line_number = getVerticalOffset,
            .get_line_height_for_line_number = getLineHeight,
            .set_max_line_width = setMaxLineWidth,
        };
    }

    fn setMaxLineWidth(context: *anyopaque, width: f64) void {
        @as(*TestViewLayout, @ptrCast(@alignCast(context))).max_line_width = width;
    }

    fn getScrollWidth(self: *anyopaque) f64 {
        return @as(*TestViewLayout, @ptrCast(@alignCast(self))).scroll_width;
    }
    fn getScrollHeight(self: *anyopaque) f64 {
        return @as(*TestViewLayout, @ptrCast(@alignCast(self))).scroll_height;
    }
    fn getCurrentViewport(self: *anyopaque) view_model.Viewport {
        return @as(*TestViewLayout, @ptrCast(@alignCast(self))).viewport;
    }
    fn getVerticalOffset(_: *anyopaque, _: usize, _: bool) f64 {
        return 0;
    }
    fn getLineHeight(self: *anyopaque, line_number: usize) f64 {
        const layout: *TestViewLayout = @ptrCast(@alignCast(self));
        if (line_number == 0 or line_number > layout.line_heights.len) return layout.line_height;
        return layout.line_heights[line_number - 1];
    }
};

/// A configurable `IViewModel` stub for view-part tests.
pub const TestViewModel = struct {
    view_layout: view_model.IViewLayout,
    line_count: usize = 1,
    line_lengths: []const usize = &.{},
    decorations: []const view_model.ViewModelDecoration = &.{},
    wrapped_lines: []const bool = &.{},
    view_line_data: ?view_model.ViewLineRenderingData = null,
    viewport_data_calls: usize = 0,
    added_handlers: usize = 0,
    removed_handlers: usize = 0,

    pub fn init(view_layout: view_model.IViewLayout) TestViewModel {
        return .{ .view_layout = view_layout };
    }

    pub fn lineLengthAt(self: *const TestViewModel, line_number: usize) usize {
        if (line_number == 0 or line_number > self.line_lengths.len) return 0;
        return self.line_lengths[line_number - 1];
    }

    pub fn interface(self: *TestViewModel) view_model.IViewModel {
        return .{
            .context = self,
            .view_layout = self.view_layout,
            .coordinates_converter = TestCoordinatesConverter.interface(),
            .getLineMinColumn = getLineMinColumn,
            .getLineMaxColumn = getLineMaxColumn,
            .getLineCount = getLineCount,
            .getLineLength = getLineLength,
            .getViewportViewLineRenderingData = getViewportViewLineRenderingData,
            .getViewLineContinuesWithWrappedLine = getViewLineContinuesWithWrappedLine,
            .getDecorationsInViewport = getDecorationsInViewport,
            .getIndentSize = getIndentSize,
            .getActiveIndentGuide = getActiveIndentGuide,
            .getLinesIndentGuides = getLinesIndentGuides,
            .getBracketGuidesInRangeByLine = getBracketGuidesInRangeByLine,
            .add_view_event_handler = addViewEventHandler,
            .remove_view_event_handler = removeViewEventHandler,
        };
    }

    fn getIndentSize(_: *anyopaque) usize {
        return 4;
    }

    fn getActiveIndentGuide(_: *anyopaque, line_number: usize, _: usize, _: usize) anyerror!text_model_guides.IActiveIndentGuideInfo {
        return .{ .startLineNumber = line_number, .endLineNumber = line_number, .indent = 0 };
    }

    fn getLinesIndentGuides(_: *anyopaque, start_line_number: usize, end_line_number: usize, allocator: std.mem.Allocator) anyerror![]usize {
        const result = try allocator.alloc(usize, end_line_number - start_line_number + 1);
        @memset(result, 0);
        return result;
    }

    fn getBracketGuidesInRangeByLine(
        _: *anyopaque,
        start_line_number: usize,
        end_line_number: usize,
        _: ?Position,
        _: text_model_guides.BracketGuideOptions,
        allocator: std.mem.Allocator,
    ) anyerror![]text_model_guides.LineGuides {
        const result = try allocator.alloc(text_model_guides.LineGuides, end_line_number - start_line_number + 1);
        for (result) |*line| line.* = text_model_guides.LineGuides.init(allocator);
        return result;
    }

    fn getLineMinColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }
    fn getLineMaxColumn(self: *anyopaque, line_number: usize) usize {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        return model.lineLengthAt(line_number) + 1;
    }
    fn getLineCount(self: *anyopaque) usize {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        return model.line_count;
    }
    fn getLineLength(self: *anyopaque, line_number: usize) usize {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        return model.lineLengthAt(line_number);
    }
    fn getViewportViewLineRenderingData(self: *anyopaque, _: Range, _: usize) anyerror!view_model.ViewLineRenderingData {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        model.viewport_data_calls += 1;
        return model.view_line_data orelse error.Unsupported;
    }
    fn getViewLineContinuesWithWrappedLine(self: *anyopaque, line_number: usize) bool {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        if (line_number == 0 or line_number > model.wrapped_lines.len) return false;
        return model.wrapped_lines[line_number - 1];
    }
    fn getDecorationsInViewport(self: *anyopaque, _: Range, allocator: std.mem.Allocator) anyerror![]view_model.ViewModelDecoration {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        return allocator.dupe(view_model.ViewModelDecoration, model.decorations);
    }
    fn addViewEventHandler(self: *anyopaque, _: *anyopaque) void {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        model.added_handlers += 1;
    }
    fn removeViewEventHandler(self: *anyopaque, _: *anyopaque) void {
        const model: *TestViewModel = @ptrCast(@alignCast(self));
        model.removed_handlers += 1;
    }
};

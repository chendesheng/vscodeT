// Port of `src/vs/editor/browser/view/renderingContext.ts`.
//
// Terminal adaptations:
// - `RenderingContext.linesVisibleRangesForRange` keeps the view-lines result
//   as a borrowed slice; the optional GPU view-lines merge is not ported (the
//   terminal has no GPU renderer).
// - `IViewLines` returns borrowed slices owned by the view-lines implementation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const position_mod = @import("../../common/core/position.zig");
const range_mod = @import("../../common/core/range.zig");
const viewport_data = @import("../../common/viewLayout/viewLinesViewportData.zig");
const view_model = @import("../../common/viewModel.zig");
const view_model_decoration = @import("../../common/viewModel/viewModelDecoration.zig");

pub const Position = position_mod.Position;
pub const Range = range_mod.Range;
pub const ViewportData = viewport_data.ViewportData;
pub const IViewLayout = view_model.IViewLayout;
pub const ViewModelDecoration = view_model_decoration.ViewModelDecoration;

pub const FloatHorizontalRange = struct {
    left: f64,
    width: f64,

    pub fn compare(a: FloatHorizontalRange, b: FloatHorizontalRange) i32 {
        if (a.left < b.left) return -1;
        if (a.left > b.left) return 1;
        return 0;
    }
};

pub const HorizontalRange = struct {
    left: i32,
    width: i32,

    pub fn init(left: f64, width: f64) HorizontalRange {
        return .{ .left = roundToI32(left), .width = roundToI32(width) };
    }

    pub fn from(allocator: Allocator, ranges: []const FloatHorizontalRange) ![]HorizontalRange {
        const result = try allocator.alloc(HorizontalRange, ranges.len);
        for (ranges, 0..) |range, index| {
            result[index] = HorizontalRange.init(range.left, range.width);
        }
        return result;
    }
};

fn roundToI32(value: f64) i32 {
    return @intFromFloat(@round(value));
}

pub const HorizontalPosition = struct {
    outsideRenderedLine: bool,
    left: i32,
    originalLeft: f64,

    pub fn init(outside_rendered_line: bool, left: f64) HorizontalPosition {
        return .{
            .outsideRenderedLine = outside_rendered_line,
            .originalLeft = left,
            .left = roundToI32(left),
        };
    }
};

pub const VisibleRanges = struct {
    outsideRenderedLine: bool,
    ranges: []const FloatHorizontalRange,
};

pub const LineVisibleRanges = struct {
    outsideRenderedLine: bool,
    lineNumber: usize,
    ranges: []const HorizontalRange,
    /// The requested range continues on the next line.
    continuesOnNextLine: bool,

    /// Returns the entry with the smallest line number.
    pub fn firstLine(ranges: ?[]const LineVisibleRanges) ?LineVisibleRanges {
        const entries = ranges orelse return null;
        var result: ?LineVisibleRanges = null;
        for (entries) |entry| {
            if (result == null or entry.lineNumber < result.?.lineNumber) result = entry;
        }
        return result;
    }

    /// Returns the entry with the largest line number.
    pub fn lastLine(ranges: ?[]const LineVisibleRanges) ?LineVisibleRanges {
        const entries = ranges orelse return null;
        var result: ?LineVisibleRanges = null;
        for (entries) |entry| {
            if (result == null or entry.lineNumber > result.?.lineNumber) result = entry;
        }
        return result;
    }
};

pub const IViewLines = struct {
    context: *anyopaque,
    lines_visible_ranges_for_range: *const fn (context: *anyopaque, range: Range, include_new_lines: bool) ?[]const LineVisibleRanges,
    visible_range_for_position: *const fn (context: *anyopaque, position: Position) ?HorizontalPosition,

    pub fn linesVisibleRangesForRange(self: IViewLines, range: Range, include_new_lines: bool) ?[]const LineVisibleRanges {
        return self.lines_visible_ranges_for_range(self.context, range, include_new_lines);
    }

    pub fn visibleRangeForPosition(self: IViewLines, position: Position) ?HorizontalPosition {
        return self.visible_range_for_position(self.context, position);
    }
};

pub const RestrictedRenderingContext = struct {
    viewportData: *const ViewportData,
    scrollWidth: f64,
    scrollHeight: f64,
    visibleRange: Range,
    bigNumbersDelta: f64,
    scrollTop: f64,
    scrollLeft: f64,
    viewportWidth: f64,
    viewportHeight: f64,
    viewLayout: IViewLayout,

    pub fn init(view_layout: IViewLayout, viewport: *const ViewportData) RestrictedRenderingContext {
        const viewport_info = view_layout.getCurrentViewport();
        return .{
            .viewportData = viewport,
            .scrollWidth = view_layout.getScrollWidth(),
            .scrollHeight = view_layout.getScrollHeight(),
            .visibleRange = viewport.visibleRange,
            .bigNumbersDelta = viewport.bigNumbersDelta,
            .scrollTop = @floatFromInt(viewport_info.top),
            .scrollLeft = @floatFromInt(viewport_info.left),
            .viewportWidth = @floatFromInt(viewport_info.width),
            .viewportHeight = @floatFromInt(viewport_info.height),
            .viewLayout = view_layout,
        };
    }

    pub fn getScrolledTopFromAbsoluteTop(self: *const RestrictedRenderingContext, absolute_top: f64) f64 {
        return absolute_top - self.scrollTop;
    }

    pub fn getVerticalOffsetForLineNumber(self: *const RestrictedRenderingContext, line_number: usize, include_view_zones: bool) f64 {
        return self.viewLayout.getVerticalOffsetForLineNumber(line_number, include_view_zones);
    }

    pub fn getVerticalOffsetAfterLineNumber(self: *const RestrictedRenderingContext, line_number: usize, include_view_zones: bool) f64 {
        return self.viewLayout.getVerticalOffsetAfterLineNumber(line_number, include_view_zones);
    }

    pub fn getLineHeightForLineNumber(self: *const RestrictedRenderingContext, line_number: usize) f64 {
        return self.viewLayout.getLineHeightForLineNumber(line_number);
    }

    pub fn getDecorationsInViewport(self: *const RestrictedRenderingContext, allocator: Allocator) ![]ViewModelDecoration {
        return self.viewportData.getDecorationsInViewport(allocator);
    }
};

pub const RenderingContext = struct {
    restricted: RestrictedRenderingContext,
    viewLines: IViewLines,

    pub fn init(view_layout: IViewLayout, viewport: *const ViewportData, view_lines: IViewLines) RenderingContext {
        return .{
            .restricted = RestrictedRenderingContext.init(view_layout, viewport),
            .viewLines = view_lines,
        };
    }

    pub fn linesVisibleRangesForRange(self: *const RenderingContext, range: Range, include_new_lines: bool) ?[]const LineVisibleRanges {
        return self.viewLines.linesVisibleRangesForRange(range, include_new_lines);
    }

    pub fn visibleRangeForPosition(self: *const RenderingContext, position: Position) ?HorizontalPosition {
        return self.viewLines.visibleRangeForPosition(position);
    }
};

const TestLayout = struct {
    viewport: view_model.Viewport,

    fn interface(self: *TestLayout) IViewLayout {
        return .{
            .context = self,
            .get_scroll_width = getScrollWidth,
            .get_scroll_height = getScrollHeight,
            .get_current_viewport = getCurrentViewport,
            .get_vertical_offset_for_line_number = getVerticalOffset,
            .get_vertical_offset_after_line_number = getVerticalOffsetAfter,
            .get_line_height_for_line_number = getLineHeight,
        };
    }

    fn getScrollWidth(_: *anyopaque) f64 {
        return 800;
    }
    fn getScrollHeight(_: *anyopaque) f64 {
        return 1200;
    }
    fn getCurrentViewport(context: *anyopaque) view_model.Viewport {
        const self: *TestLayout = @ptrCast(@alignCast(context));
        return self.viewport;
    }
    fn getVerticalOffset(_: *anyopaque, line_number: usize, _: bool) f64 {
        return @as(f64, @floatFromInt(line_number - 1)) * 19;
    }
    fn getVerticalOffsetAfter(_: *anyopaque, line_number: usize, _: bool) f64 {
        return @as(f64, @floatFromInt(line_number)) * 19;
    }
    fn getLineHeight(_: *anyopaque, _: usize) f64 {
        return 19;
    }
};

fn testViewportData() ViewportData {
    return .{
        .selections = &.{},
        .startLineNumber = 2,
        .endLineNumber = 10,
        .relativeVerticalOffset = &.{},
        .visibleRange = Range.init(2, 1, 10, 1),
        .bigNumbersDelta = 32,
        .whitespaceViewportData = &.{},
        .lineHeight = 19,
        ._model = undefined,
    };
}

test "restricted rendering context copies viewport and layout data" {
    var layout = TestLayout{ .viewport = view_model.Viewport{ .top = 50, .left = 10, .width = 700, .height = 400 } };
    const viewport = testViewportData();
    const context = RestrictedRenderingContext.init(layout.interface(), &viewport);

    try std.testing.expectEqual(@as(f64, 800), context.scrollWidth);
    try std.testing.expectEqual(@as(f64, 1200), context.scrollHeight);
    try std.testing.expectEqual(@as(f64, 50), context.scrollTop);
    try std.testing.expectEqual(@as(f64, 10), context.scrollLeft);
    try std.testing.expectEqual(@as(f64, 400), context.viewportHeight);
    try std.testing.expectEqual(@as(f64, 32), context.bigNumbersDelta);
    try std.testing.expectEqual(@as(f64, 25), context.getScrolledTopFromAbsoluteTop(75));
    try std.testing.expectEqual(@as(f64, 38), context.getVerticalOffsetForLineNumber(3, false));
    try std.testing.expectEqual(@as(f64, 57), context.getVerticalOffsetAfterLineNumber(3, false));
    try std.testing.expectEqual(@as(f64, 19), context.getLineHeightForLineNumber(9));
}

test "horizontal ranges round and line helpers pick extremes" {
    const allocator = std.testing.allocator;

    const floats = [_]FloatHorizontalRange{
        .{ .left = 1.4, .width = 2.6 },
        .{ .left = 7.5, .width = 0.5 },
    };
    const ranges = try HorizontalRange.from(allocator, &floats);
    defer allocator.free(ranges);
    try std.testing.expectEqual(@as(i32, 1), ranges[0].left);
    try std.testing.expectEqual(@as(i32, 3), ranges[0].width);
    try std.testing.expectEqual(@as(i32, 8), ranges[1].left);

    const position = HorizontalPosition.init(false, 3.6);
    try std.testing.expectEqual(@as(i32, 4), position.left);

    const entries = [_]LineVisibleRanges{
        .{ .outsideRenderedLine = false, .lineNumber = 4, .ranges = &.{}, .continuesOnNextLine = false },
        .{ .outsideRenderedLine = false, .lineNumber = 2, .ranges = &.{}, .continuesOnNextLine = true },
        .{ .outsideRenderedLine = true, .lineNumber = 9, .ranges = &.{}, .continuesOnNextLine = false },
    };
    try std.testing.expectEqual(@as(usize, 2), LineVisibleRanges.firstLine(&entries).?.lineNumber);
    try std.testing.expectEqual(@as(usize, 9), LineVisibleRanges.lastLine(&entries).?.lineNumber);
    try std.testing.expect(LineVisibleRanges.firstLine(null) == null);
}

test "rendering context delegates to view lines" {
    var layout = TestLayout{ .viewport = view_model.Viewport{ .top = 0, .left = 0, .width = 10, .height = 10 } };
    const viewport = testViewportData();

    const ViewLines = struct {
        fn ranges(_: *anyopaque, _: Range, _: bool) ?[]const LineVisibleRanges {
            return null;
        }
        fn positionFor(_: *anyopaque, position: Position) ?HorizontalPosition {
            return HorizontalPosition.init(false, @floatFromInt(position.column));
        }
    };

    const view_lines = IViewLines{
        .context = @ptrFromInt(1),
        .lines_visible_ranges_for_range = ViewLines.ranges,
        .visible_range_for_position = ViewLines.positionFor,
    };

    const context = RenderingContext.init(layout.interface(), &viewport, view_lines);
    try std.testing.expect(context.linesVisibleRangesForRange(Range.init(1, 1, 2, 1), false) == null);
    try std.testing.expectEqual(@as(i32, 5), context.visibleRangeForPosition(Position.init(1, 5)).?.left);
}

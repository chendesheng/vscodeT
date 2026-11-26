// Port of the terminal subset of
// `src/vs/editor/common/viewLayout/viewLayout.ts`.
//
// Terminal adaptation: the scroll offset is measured in whole view lines
// instead of pixels (uniform line height 1, no padding), because a cell grid
// cannot paint sub-line scroll offsets. The dimension validation, clamping,
// viewport-data computation and `onDidScroll` event flow follow upstream;
// smooth scrolling is applied immediately by the local `Scrollable` port.
const std = @import("std");
const Allocator = std.mem.Allocator;

const lines_layout_mod = @import("./linesLayout.zig");
const view_model = @import("../viewModel.zig");
const scrollable_mod = @import("../../../base/common/scrollable.zig");
const event = @import("../../../base/common/event.zig");

const LinesLayout = lines_layout_mod.LinesLayout;
const LinesViewportData = lines_layout_mod.LinesViewportData;
const Scrollable = scrollable_mod.Scrollable;
const ScrollEvent = scrollable_mod.ScrollEvent;
const INewScrollPosition = scrollable_mod.INewScrollPosition;
const IScrollPosition = scrollable_mod.IScrollPosition;
const Viewport = view_model.Viewport;
const IPartialViewLinesViewportData = view_model.IPartialViewLinesViewportData;

/// Port of upstream `ViewLayout`, line-granular. One instance owns the vertical
/// scroll state of one editor and emits `ScrollEvent`s when it changes.
pub const ViewLayout = struct {
    allocator: Allocator,
    lines_layout: LinesLayout,
    scrollable: Scrollable,
    viewport_width: f64 = 0,
    viewport_height: f64 = 0,
    max_line_width: f64 = 0,

    pub fn init(allocator: Allocator, line_count: usize, width: usize, height: usize) !ViewLayout {
        var lines_layout = try LinesLayout.init(allocator, @max(line_count, 1), 1, 0, 0, &.{});
        errdefer lines_layout.deinit();

        var scrollable = try Scrollable.init(allocator, true);
        errdefer scrollable.deinit();

        var self = ViewLayout{
            .allocator = allocator,
            .lines_layout = lines_layout,
            .scrollable = scrollable,
            .viewport_width = @floatFromInt(@max(width, 1)),
            .viewport_height = @floatFromInt(@max(height, 1)),
        };
        self.applyDimensions(false);
        return self;
    }

    pub fn deinit(self: *ViewLayout) void {
        self.scrollable.deinit();
        self.lines_layout.deinit();
    }

    pub fn onDidScroll(self: *ViewLayout) *event.Emitter(ScrollEvent) {
        return &self.scrollable.on_scroll;
    }

    /// Updates the viewport size and revalidates the scroll height. The
    /// scroll position is clamped by `Scrollable`, like upstream's
    /// `setScrollDimensions`.
    pub fn setViewport(self: *ViewLayout, width: usize, height: usize) void {
        self.viewport_width = @floatFromInt(@max(width, 1));
        self.viewport_height = @floatFromInt(@max(height, 1));
        self.applyDimensions(true);
    }

    /// Updates the content height after a line-count change.
    pub fn onHeightMaybeChanged(self: *ViewLayout) void {
        self.applyDimensions(true);
    }

    fn applyDimensions(self: *ViewLayout, use_raw_scroll_positions: bool) void {
        const content_height = self.lines_layout.getLinesTotalHeight() catch @as(f64, @floatFromInt(self.lines_layout.getLineCount()));
        self.scrollable.setScrollDimensions(.{
            .width = self.viewport_width,
            .height = self.viewport_height,
            .scrollWidth = @max(self.viewport_width, self.max_line_width),
            .scrollHeight = @max(self.viewport_height, content_height),
        }, use_raw_scroll_positions);
    }

    pub fn setMaxLineWidth(self: *ViewLayout, max_line_width: f64) void {
        if (self.max_line_width == max_line_width) return;
        self.max_line_width = max_line_width;
        self.applyDimensions(true);
    }

    pub fn getMaxLineWidth(self: *const ViewLayout) f64 {
        return self.max_line_width;
    }

    pub fn setScrollPosition(self: *ViewLayout, position: INewScrollPosition, immediate: bool) void {
        if (immediate) {
            self.scrollable.setScrollPositionNow(position);
        } else {
            self.scrollable.setScrollPositionSmooth(position);
        }
    }

    pub fn setScrollPositionNow(self: *ViewLayout, position: INewScrollPosition) void {
        self.scrollable.setScrollPositionNow(position);
    }

    pub fn setScrollPositionSmooth(self: *ViewLayout, position: INewScrollPosition) void {
        self.scrollable.setScrollPositionSmooth(position);
    }

    pub fn deltaScrollNow(self: *ViewLayout, delta_scroll_left: f64, delta_scroll_top: f64) void {
        const current = self.scrollable.getCurrentScrollPosition();
        self.scrollable.setScrollPositionNow(.{
            .scrollLeft = current.scrollLeft + delta_scroll_left,
            .scrollTop = current.scrollTop + delta_scroll_top,
        });
    }

    pub fn validateScrollPosition(self: *const ViewLayout, position: INewScrollPosition) IScrollPosition {
        return self.scrollable.validateScrollPosition(position);
    }

    pub fn getCurrentScrollTop(self: *const ViewLayout) f64 {
        return self.scrollable.getCurrentScrollPosition().scrollTop;
    }

    pub fn getCurrentScrollLeft(self: *const ViewLayout) f64 {
        return self.scrollable.getCurrentScrollPosition().scrollLeft;
    }

    pub fn getCurrentViewport(self: *const ViewLayout) Viewport {
        const dimensions = self.scrollable.getScrollDimensions();
        const position = self.scrollable.getCurrentScrollPosition();
        return Viewport.init(position.scrollTop, position.scrollLeft, dimensions.width, dimensions.height);
    }

    pub fn getScrollWidth(self: *const ViewLayout) f64 {
        return self.scrollable.getScrollDimensions().scrollWidth;
    }

    pub fn getScrollHeight(self: *const ViewLayout) f64 {
        return self.scrollable.getScrollDimensions().scrollHeight;
    }

    /// The visible viewport as upstream `IPartialViewLinesViewportData`
    /// (relative offsets are owned by the returned value).
    pub fn getLinesViewportData(self: *ViewLayout, allocator: Allocator) !LinesViewportData {
        const viewport = self.getCurrentViewport();
        const top = @as(f64, @floatFromInt(viewport.top));
        const bottom = top + @as(f64, @floatFromInt(viewport.height));
        return self.lines_layout.getLinesViewportData(allocator, top, bottom);
    }

    pub fn getLinesViewportDataAtScrollTop(self: *ViewLayout, allocator: Allocator, scroll_top: f64) !LinesViewportData {
        const dimensions = self.scrollable.getScrollDimensions();
        var top = scroll_top;
        if (top + dimensions.height > dimensions.scrollHeight) top = dimensions.scrollHeight - dimensions.height;
        if (top < 0) top = 0;
        return self.lines_layout.getLinesViewportData(allocator, top, top + dimensions.height);
    }

    /// Upstream whitespace transaction. Commit layout changes before notifying
    /// the view model, including the new scroll dimensions.
    pub fn changeWhitespace(
        self: *ViewLayout,
        context: anytype,
        comptime callback: fn (@TypeOf(context), view_model.IWhitespaceChangeAccessor) anyerror!void,
    ) !bool {
        const had_change = self.lines_layout.changeWhitespace(context, callback) catch |err| {
            // A fallible Zig callback may leave successfully queued changes.
            self.onHeightMaybeChanged();
            return err;
        };
        if (had_change) self.onHeightMaybeChanged();
        return had_change;
    }

    pub fn getWhitespaceAtVerticalOffset(self: *ViewLayout, vertical_offset: f64) !?view_model.IViewWhitespaceViewportData {
        return self.lines_layout.getWhitespaceAtVerticalOffset(vertical_offset);
    }

    pub fn getWhitespaceViewportData(self: *ViewLayout, allocator: Allocator) ![]view_model.IViewWhitespaceViewportData {
        const viewport = self.getCurrentViewport();
        const top: f64 = @floatFromInt(viewport.top);
        return self.lines_layout.getWhitespaceViewportData(allocator, top, top + @as(f64, @floatFromInt(viewport.height)));
    }

    pub fn getWhitespaces(self: *const ViewLayout, allocator: Allocator) ![]view_model.IEditorWhitespace {
        return self.lines_layout.getWhitespaces(allocator);
    }

    pub fn getVerticalOffsetForLineNumber(self: *ViewLayout, line_number: usize, include_view_zones: bool) f64 {
        return self.lines_layout.getVerticalOffsetForLineNumber(line_number, include_view_zones) catch @floatFromInt(line_number -| 1);
    }

    pub fn getVerticalOffsetAfterLineNumber(self: *ViewLayout, line_number: usize, include_view_zones: bool) f64 {
        return self.lines_layout.getVerticalOffsetAfterLineNumber(line_number, include_view_zones) catch @floatFromInt(line_number);
    }

    pub fn getLineHeightForLineNumber(self: *ViewLayout, line_number: usize) f64 {
        _ = self;
        _ = line_number;
        return 1;
    }

    pub fn getLineNumberAtVerticalOffset(self: *ViewLayout, vertical_offset: f64) usize {
        return self.lines_layout.getLineNumberAtOrAfterVerticalOffset(vertical_offset) catch 1;
    }

    pub fn hasPendingScrollAnimation(self: *const ViewLayout) bool {
        return self.scrollable.hasPendingScrollAnimation();
    }

    pub fn getLineCount(self: *const ViewLayout) usize {
        return self.lines_layout.getLineCount();
    }

    // --- begin view event equivalents

    pub fn onFlushed(self: *ViewLayout, line_count: usize) void {
        const clamped = @max(line_count, 1);
        if (self.lines_layout.getLineCount() == clamped) return;
        self.lines_layout.onFlushed(clamped, &.{}) catch return;
        self.onHeightMaybeChanged();
    }

    pub fn onLinesInserted(self: *ViewLayout, from_line_number: usize, to_line_number: usize) void {
        self.lines_layout.onLinesInserted(from_line_number, to_line_number) catch return;
        self.onHeightMaybeChanged();
    }

    pub fn onLinesDeleted(self: *ViewLayout, from_line_number: usize, to_line_number: usize) void {
        self.lines_layout.onLinesDeleted(from_line_number, to_line_number) catch return;
        self.onHeightMaybeChanged();
    }

    // --- end view event equivalents
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "view layout: dimensions, clamping and scroll events" {
    const allocator = testing.allocator;
    var layout = try ViewLayout.init(allocator, 100, 80, 20);
    defer layout.deinit();

    try testing.expectEqual(@as(f64, 0), layout.getCurrentScrollTop());
    try testing.expectEqual(@as(f64, 100), layout.getScrollHeight());

    layout.setScrollPositionNow(.{ .scrollTop = 50 });
    try testing.expectEqual(@as(f64, 50), layout.getCurrentScrollTop());

    // 100 lines - 20 viewport rows = 80 is the last valid first-line offset.
    layout.setScrollPositionNow(.{ .scrollTop = 1000 });
    try testing.expectEqual(@as(f64, 80), layout.getCurrentScrollTop());

    layout.setScrollPositionNow(.{ .scrollTop = -5 });
    try testing.expectEqual(@as(f64, 0), layout.getCurrentScrollTop());
}

test "view layout: short documents clamp to the first line and report the viewport height" {
    const allocator = testing.allocator;
    var layout = try ViewLayout.init(allocator, 4, 80, 20);
    defer layout.deinit();

    try testing.expectEqual(@as(f64, 20), layout.getScrollHeight());
    layout.setScrollPositionNow(.{ .scrollTop = 5 });
    try testing.expectEqual(@as(f64, 0), layout.getCurrentScrollTop());
}

test "view layout: viewport data covers the visible lines" {
    const allocator = testing.allocator;
    var layout = try ViewLayout.init(allocator, 100, 80, 20);
    defer layout.deinit();

    layout.setScrollPositionNow(.{ .scrollTop = 10 });
    var data = try layout.getLinesViewportData(allocator);
    defer data.deinit();

    try testing.expectEqual(@as(usize, 11), data.data.startLineNumber);
    try testing.expectEqual(@as(usize, 30), data.data.endLineNumber);
    // `LinesLayout` reports absolute line offsets (bigNumbersDelta is only
    // used to keep large documents exact), like upstream viewport data.
    try testing.expectEqual(@as(f64, 10), data.data.relativeVerticalOffset[0]);
    try testing.expectEqual(@as(f64, 29), data.data.relativeVerticalOffset[19]);
    try testing.expectEqual(@as(f64, 1), data.data.lineHeight);
}

test "view layout: line insert/delete keeps the scroll position valid" {
    const allocator = testing.allocator;
    var layout = try ViewLayout.init(allocator, 100, 80, 20);
    defer layout.deinit();

    layout.setScrollPositionNow(.{ .scrollTop = 80 });
    layout.onLinesDeleted(1, 90);
    // 10 lines remain; the viewport clamps back to the first line.
    try testing.expectEqual(@as(f64, 0), layout.getCurrentScrollTop());
    try testing.expectEqual(@as(f64, 20), layout.getScrollHeight());

    layout.onLinesInserted(1, 100);
    try testing.expectEqual(@as(f64, 110), layout.getScrollHeight());
    layout.onFlushed(5);
    try testing.expectEqual(@as(f64, 20), layout.getScrollHeight());
    try testing.expectEqual(@as(f64, 0), layout.getCurrentScrollTop());
}

test "view layout: smooth scrolling is immediate in the terminal" {
    const allocator = testing.allocator;
    var layout = try ViewLayout.init(allocator, 100, 80, 20);
    defer layout.deinit();

    layout.setScrollPositionSmooth(.{ .scrollTop = 40 });
    try testing.expectEqual(@as(f64, 40), layout.getCurrentScrollTop());
    try testing.expect(!layout.hasPendingScrollAnimation());
}

test "view layout: whitespace transactions update scroll dimensions and viewport data" {
    const allocator = testing.allocator;
    var layout = try ViewLayout.init(allocator, 10, 80, 4);
    defer layout.deinit();
    var id: []const u8 = undefined;
    const Accessor = view_model.IWhitespaceChangeAccessor;
    try testing.expect(try layout.changeWhitespace(&id, struct {
        fn run(out: *[]const u8, accessor: Accessor) anyerror!void {
            out.* = try accessor.insert(2, 0, 5, 0);
        }
    }.run));
    try testing.expectEqual(@as(f64, 15), layout.getScrollHeight());
    try testing.expectEqual(@as(f64, 7), layout.getVerticalOffsetForLineNumber(3, false));
    const zone = (try layout.getWhitespaceAtVerticalOffset(4)).?;
    try testing.expectEqualStrings(id, zone.id);
    try testing.expectEqual(@as(f64, 2), zone.verticalOffset);
    layout.setScrollPositionNow(.{ .scrollTop = 4 });
    const visible = try layout.getWhitespaceViewportData(allocator);
    defer allocator.free(visible);
    try testing.expectEqual(@as(usize, 1), visible.len);
    try testing.expectEqualStrings(id, visible[0].id);
    try testing.expect(try layout.changeWhitespace(id, struct {
        fn run(zone_id: []const u8, accessor: Accessor) anyerror!void {
            try accessor.changeOne(zone_id, 3, 2);
        }
    }.run));
    try testing.expectEqual(@as(f64, 12), layout.getScrollHeight());
    layout.setScrollPositionNow(.{ .scrollTop = 11 });
    try testing.expect(try layout.changeWhitespace(id, struct {
        fn run(zone_id: []const u8, accessor: Accessor) anyerror!void {
            try accessor.remove(zone_id);
        }
    }.run));
    try testing.expectEqual(@as(f64, 10), layout.getScrollHeight());
    try testing.expectEqual(@as(f64, 6), layout.getCurrentScrollTop());
    try testing.expect(!try layout.changeWhitespace({}, struct {
        fn run(_: void, _: Accessor) anyerror!void {}
    }.run));
}

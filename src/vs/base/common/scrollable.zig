const std = @import("std");

pub const ScrollbarVisibility = enum(u8) {
    Auto = 1,
    Hidden = 2,
    Visible = 3,
};

pub const ScrollEvent = struct {
    inSmoothScrolling: bool,

    oldWidth: f64,
    oldScrollWidth: f64,
    oldScrollLeft: f64,

    width: f64,
    scrollWidth: f64,
    scrollLeft: f64,

    oldHeight: f64,
    oldScrollHeight: f64,
    oldScrollTop: f64,

    height: f64,
    scrollHeight: f64,
    scrollTop: f64,

    widthChanged: bool,
    scrollWidthChanged: bool,
    scrollLeftChanged: bool,

    heightChanged: bool,
    scrollHeightChanged: bool,
    scrollTopChanged: bool,
};

pub const IScrollDimensions = struct {
    width: f64,
    scrollWidth: f64,
    height: f64,
    scrollHeight: f64,
};

pub const INewScrollDimensions = struct {
    width: ?f64 = null,
    scrollWidth: ?f64 = null,
    height: ?f64 = null,
    scrollHeight: ?f64 = null,
};

pub const IScrollPosition = struct {
    scrollLeft: f64,
    scrollTop: f64,
};

pub const ISmoothScrollPosition = struct {
    scrollLeft: f64,
    scrollTop: f64,
    width: f64,
    height: f64,
};

pub const INewScrollPosition = struct {
    scrollLeft: ?f64 = null,
    scrollTop: ?f64 = null,
};

pub const ScrollState = struct {
    forceIntegerValues: bool,

    rawScrollLeft: f64,
    rawScrollTop: f64,

    width: f64,
    scrollWidth: f64,
    scrollLeft: f64,
    height: f64,
    scrollHeight: f64,
    scrollTop: f64,

    pub fn init(
        forceIntegerValues: bool,
        width_: f64,
        scrollWidth_: f64,
        scrollLeft_: f64,
        height_: f64,
        scrollHeight_: f64,
        scrollTop_: f64,
    ) ScrollState {
        var width = width_;
        var scrollWidth = scrollWidth_;
        var scrollLeft = scrollLeft_;
        var height = height_;
        var scrollHeight = scrollHeight_;
        var scrollTop = scrollTop_;

        if (forceIntegerValues) {
            width = @trunc(width);
            scrollWidth = @trunc(scrollWidth);
            scrollLeft = @trunc(scrollLeft);
            height = @trunc(height);
            scrollHeight = @trunc(scrollHeight);
            scrollTop = @trunc(scrollTop);
        }

        const rawScrollLeft = scrollLeft;
        const rawScrollTop = scrollTop;

        if (width < 0) {
            width = 0;
        }
        if (scrollLeft + width > scrollWidth) {
            scrollLeft = scrollWidth - width;
        }
        if (scrollLeft < 0) {
            scrollLeft = 0;
        }

        if (height < 0) {
            height = 0;
        }
        if (scrollTop + height > scrollHeight) {
            scrollTop = scrollHeight - height;
        }
        if (scrollTop < 0) {
            scrollTop = 0;
        }

        return .{
            .forceIntegerValues = forceIntegerValues,
            .rawScrollLeft = rawScrollLeft,
            .rawScrollTop = rawScrollTop,
            .width = width,
            .scrollWidth = scrollWidth,
            .scrollLeft = scrollLeft,
            .height = height,
            .scrollHeight = scrollHeight,
            .scrollTop = scrollTop,
        };
    }

    pub fn equals(self: ScrollState, other: ScrollState) bool {
        return self.rawScrollLeft == other.rawScrollLeft and
            self.rawScrollTop == other.rawScrollTop and
            self.width == other.width and
            self.scrollWidth == other.scrollWidth and
            self.scrollLeft == other.scrollLeft and
            self.height == other.height and
            self.scrollHeight == other.scrollHeight and
            self.scrollTop == other.scrollTop;
    }

    pub fn withScrollDimensions(self: ScrollState, update: INewScrollDimensions, useRawScrollPositions: bool) ScrollState {
        return ScrollState.init(
            self.forceIntegerValues,
            update.width orelse self.width,
            update.scrollWidth orelse self.scrollWidth,
            if (useRawScrollPositions) self.rawScrollLeft else self.scrollLeft,
            update.height orelse self.height,
            update.scrollHeight orelse self.scrollHeight,
            if (useRawScrollPositions) self.rawScrollTop else self.scrollTop,
        );
    }

    pub fn withScrollPosition(self: ScrollState, update: INewScrollPosition) ScrollState {
        return ScrollState.init(
            self.forceIntegerValues,
            self.width,
            self.scrollWidth,
            update.scrollLeft orelse self.rawScrollLeft,
            self.height,
            self.scrollHeight,
            update.scrollTop orelse self.rawScrollTop,
        );
    }

    pub fn createScrollEvent(self: ScrollState, previous: ScrollState, inSmoothScrolling: bool) ScrollEvent {
        return .{
            .inSmoothScrolling = inSmoothScrolling,

            .oldWidth = previous.width,
            .oldScrollWidth = previous.scrollWidth,
            .oldScrollLeft = previous.scrollLeft,

            .width = self.width,
            .scrollWidth = self.scrollWidth,
            .scrollLeft = self.scrollLeft,

            .oldHeight = previous.height,
            .oldScrollHeight = previous.scrollHeight,
            .oldScrollTop = previous.scrollTop,

            .height = self.height,
            .scrollHeight = self.scrollHeight,
            .scrollTop = self.scrollTop,

            .widthChanged = self.width != previous.width,
            .scrollWidthChanged = self.scrollWidth != previous.scrollWidth,
            .scrollLeftChanged = self.scrollLeft != previous.scrollLeft,

            .heightChanged = self.height != previous.height,
            .scrollHeightChanged = self.scrollHeight != previous.scrollHeight,
            .scrollTopChanged = self.scrollTop != previous.scrollTop,
        };
    }
};

/// Port of upstream `Scrollable` (`src/vs/base/common/scrollable.ts`).
///
/// Terminal adaptation: this port keeps the state, dimension validation and
/// scroll-event flow. Smooth scrolling is a no-op that applies the target
/// immediately — a terminal cell grid cannot paint sub-line scroll offsets, so
/// the caller sees one whole-line position per frame. `onScroll` therefore
/// never reports `inSmoothScrolling = true`.
pub const Scrollable = struct {
    allocator: std.mem.Allocator,
    force_integer_values: bool,
    state: ScrollState,
    on_scroll: @import("./event.zig").Emitter(ScrollEvent),
    smooth_scroll_duration: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, force_integer_values: bool) !Scrollable {
        return .{
            .allocator = allocator,
            .force_integer_values = force_integer_values,
            .state = ScrollState.init(force_integer_values, 0, 0, 0, 0, 0, 0),
            .on_scroll = @import("./event.zig").Emitter(ScrollEvent).init(allocator),
        };
    }

    pub fn deinit(self: *Scrollable) void {
        self.on_scroll.deinit();
    }

    pub fn setSmoothScrollDuration(self: *Scrollable, smooth_scroll_duration: f64) void {
        self.smooth_scroll_duration = smooth_scroll_duration;
    }

    pub fn validateScrollPosition(self: *const Scrollable, update: INewScrollPosition) IScrollPosition {
        const state = self.state.withScrollPosition(update);
        return .{ .scrollLeft = state.scrollLeft, .scrollTop = state.scrollTop };
    }

    pub fn getScrollDimensions(self: *const Scrollable) IScrollDimensions {
        return .{
            .width = self.state.width,
            .scrollWidth = self.state.scrollWidth,
            .height = self.state.height,
            .scrollHeight = self.state.scrollHeight,
        };
    }

    pub fn setScrollDimensions(self: *Scrollable, dimensions: INewScrollDimensions, use_raw_scroll_positions: bool) void {
        const new_state = self.state.withScrollDimensions(dimensions, use_raw_scroll_positions);
        self.setState(new_state, false);
    }

    pub fn getFutureScrollPosition(self: *const Scrollable) IScrollPosition {
        return .{ .scrollLeft = self.state.scrollLeft, .scrollTop = self.state.scrollTop };
    }

    pub fn getCurrentScrollPosition(self: *const Scrollable) IScrollPosition {
        return .{ .scrollLeft = self.state.scrollLeft, .scrollTop = self.state.scrollTop };
    }

    pub fn setScrollPositionNow(self: *Scrollable, update: INewScrollPosition) void {
        const new_state = self.state.withScrollPosition(update);
        self.setState(new_state, false);
    }

    /// Upstream animates over `smooth_scroll_duration`; the terminal applies
    /// the whole-line target immediately (see the type comment).
    pub fn setScrollPositionSmooth(self: *Scrollable, update: INewScrollPosition) void {
        self.setScrollPositionNow(update);
    }

    pub fn hasPendingScrollAnimation(self: *const Scrollable) bool {
        _ = self;
        return false;
    }

    fn setState(self: *Scrollable, new_state: ScrollState, in_smooth_scrolling: bool) void {
        const old_state = self.state;
        if (old_state.equals(new_state)) return;
        self.state = new_state;
        self.on_scroll.fire(new_state.createScrollEvent(old_state, in_smooth_scrolling)) catch {};
    }
};

test "scrollable: scrollable emits state changes and clamps" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var scrollable = try Scrollable.init(allocator, true);
    defer scrollable.deinit();

    const events = struct {
        var count: usize = 0;
        var last_top: f64 = 0;
        fn onScroll(event: ScrollEvent, _: void) anyerror!void {
            count += 1;
            last_top = event.scrollTop;
        }
    };
    _ = try scrollable.on_scroll.listen({}, events.onScroll);

    scrollable.setScrollDimensions(.{ .width = 80, .height = 40, .scrollWidth = 80, .scrollHeight = 1000 }, false);
    try testing.expectEqual(@as(usize, 1), events.count);

    scrollable.setScrollPositionNow(.{ .scrollTop = 500 });
    try testing.expectEqual(@as(f64, 500), scrollable.getCurrentScrollPosition().scrollTop);
    try testing.expectEqual(@as(f64, 500), events.last_top);

    // Clamps to `scrollHeight - height`, like upstream.
    scrollable.setScrollPositionNow(.{ .scrollTop = 5000 });
    try testing.expectEqual(@as(f64, 960), scrollable.getCurrentScrollPosition().scrollTop);

    // Raw positions differ, so upstream `ScrollState.equals` still fires;
    // repeating the same raw position changes nothing.
    const after_clamp = events.count;
    scrollable.setScrollPositionNow(.{ .scrollTop = 960 });
    try testing.expectEqual(after_clamp + 1, events.count);
    const settled = events.count;
    scrollable.setScrollPositionNow(.{ .scrollTop = 960 });
    try testing.expectEqual(settled, events.count);

    // Smooth scrolling is applied immediately in the terminal.
    scrollable.setScrollPositionSmooth(.{ .scrollTop = 10 });
    try testing.expectEqual(@as(f64, 10), scrollable.getCurrentScrollPosition().scrollTop);
    try testing.expect(!scrollable.hasPendingScrollAnimation());
}

test "scrollable: scroll state validates dimensions and position" {
    const state = ScrollState.init(false, 100, 1000, 950, 200, 2000, 1900);
    try std.testing.expectEqual(@as(f64, 100), state.width);
    try std.testing.expectEqual(@as(f64, 950), state.rawScrollLeft);
    try std.testing.expectEqual(@as(f64, 900), state.scrollLeft);
    try std.testing.expectEqual(@as(f64, 1900), state.rawScrollTop);
    try std.testing.expectEqual(@as(f64, 1800), state.scrollTop);

    const negative = ScrollState.init(false, -10, 100, -5, -20, 200, -30);
    try std.testing.expectEqual(@as(f64, 0), negative.width);
    try std.testing.expectEqual(@as(f64, 0), negative.scrollLeft);
    try std.testing.expectEqual(@as(f64, 0), negative.height);
    try std.testing.expectEqual(@as(f64, 0), negative.scrollTop);
}

test "scrollable: force integer values" {
    const state = ScrollState.init(true, 10.9, 100.8, 5.7, 20.6, 200.5, 7.4);
    try std.testing.expectEqual(@as(f64, 10), state.width);
    try std.testing.expectEqual(@as(f64, 100), state.scrollWidth);
    try std.testing.expectEqual(@as(f64, 5), state.scrollLeft);
    try std.testing.expectEqual(@as(f64, 20), state.height);
    try std.testing.expectEqual(@as(f64, 200), state.scrollHeight);
    try std.testing.expectEqual(@as(f64, 7), state.scrollTop);
}

test "scrollable: derived states and scroll event" {
    const previous = ScrollState.init(false, 100, 1000, 10, 200, 2000, 20);
    const resized = previous.withScrollDimensions(.{ .width = 120, .scrollHeight = 2200 }, false);
    try std.testing.expectEqual(@as(f64, 120), resized.width);
    try std.testing.expectEqual(@as(f64, 2200), resized.scrollHeight);
    try std.testing.expectEqual(@as(f64, 10), resized.scrollLeft);

    const moved = resized.withScrollPosition(.{ .scrollLeft = 30, .scrollTop = 50 });
    try std.testing.expectEqual(@as(f64, 30), moved.scrollLeft);
    try std.testing.expectEqual(@as(f64, 50), moved.scrollTop);

    const event = moved.createScrollEvent(previous, true);
    try std.testing.expect(event.inSmoothScrolling);
    try std.testing.expect(event.widthChanged);
    try std.testing.expect(event.heightChanged == false);
    try std.testing.expect(event.scrollLeftChanged);
    try std.testing.expect(event.scrollTopChanged);
    try std.testing.expect(event.scrollWidthChanged == false);
    try std.testing.expect(event.scrollHeightChanged);
    try std.testing.expectEqual(@as(f64, 100), event.oldWidth);
    try std.testing.expectEqual(@as(f64, 30), event.scrollLeft);
}

test "scrollable: equals uses raw positions" {
    const a = ScrollState.init(false, 100, 1000, 950, 200, 2000, 1900);
    const b = ScrollState.init(false, 100, 1000, 960, 200, 2000, 1910);
    // Both clamp to the same effective position, but the raw values differ.
    try std.testing.expectEqual(a.scrollLeft, b.scrollLeft);
    try std.testing.expect(!a.equals(b));
    try std.testing.expect(a.equals(a));
}

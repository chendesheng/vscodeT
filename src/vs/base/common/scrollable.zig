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

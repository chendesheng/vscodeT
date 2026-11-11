// Port of `src/vs/base/test/browser/ui/scrollbar/scrollbarState.test.ts`.
//
// The terminal adaptation additionally covers the one-cell minimum slider used
// by the editor scrollbar.

const std = @import("std");
const ScrollbarState = @import("../../../../browser/ui/scrollbar/scrollbarState.zig").ScrollbarState;

const testing = std.testing;

test "ScrollbarState: inflates slider size" {
    var actual = ScrollbarState.init(0, 14, 0, 339, 42423, 32787);

    try testing.expectEqual(@as(f64, 0), actual.getArrowSize());
    try testing.expectEqual(@as(f64, 32787), actual.getScrollPosition());
    try testing.expectEqual(@as(f64, 339), actual.getRectangleLargeSize());
    try testing.expectEqual(@as(f64, 14), actual.getRectangleSmallSize());
    try testing.expect(actual.isNeeded());
    try testing.expectEqual(@as(f64, 20), actual.getSliderSize());
    try testing.expectEqual(@as(f64, 249), actual.getSliderPosition());

    try testing.expectEqual(@as(f64, 32849), actual.getDesiredScrollPositionFromOffset(259));

    // 259 is greater than 230 so page down: 32787 + 339 = 33126.
    try testing.expectEqual(@as(f64, 33126), actual.getDesiredScrollPositionFromOffsetPaged(259));

    _ = actual.setScrollPosition(32849);
    try testing.expectEqual(@as(f64, 0), actual.getArrowSize());
    try testing.expectEqual(@as(f64, 32849), actual.getScrollPosition());
    try testing.expectEqual(@as(f64, 339), actual.getRectangleLargeSize());
    try testing.expectEqual(@as(f64, 14), actual.getRectangleSmallSize());
    try testing.expect(actual.isNeeded());
    try testing.expectEqual(@as(f64, 20), actual.getSliderSize());
    try testing.expectEqual(@as(f64, 249), actual.getSliderPosition());
}

test "ScrollbarState: inflates slider size with arrows" {
    var actual = ScrollbarState.init(12, 14, 0, 339, 42423, 32787);

    try testing.expectEqual(@as(f64, 12), actual.getArrowSize());
    try testing.expectEqual(@as(f64, 32787), actual.getScrollPosition());
    try testing.expectEqual(@as(f64, 339), actual.getRectangleLargeSize());
    try testing.expectEqual(@as(f64, 14), actual.getRectangleSmallSize());
    try testing.expect(actual.isNeeded());
    try testing.expectEqual(@as(f64, 20), actual.getSliderSize());
    try testing.expectEqual(@as(f64, 230), actual.getSliderPosition());

    try testing.expectEqual(@as(f64, 32811), actual.getDesiredScrollPositionFromOffset(240 + 12));

    // 240 + 12 = 252; greater than 230 so page down: 32787 + 339 = 33126.
    try testing.expectEqual(@as(f64, 33126), actual.getDesiredScrollPositionFromOffsetPaged(240 + 12));

    _ = actual.setScrollPosition(32811);
    try testing.expectEqual(@as(f64, 12), actual.getArrowSize());
    try testing.expectEqual(@as(f64, 32811), actual.getScrollPosition());
    try testing.expectEqual(@as(f64, 339), actual.getRectangleLargeSize());
    try testing.expectEqual(@as(f64, 14), actual.getRectangleSmallSize());
    try testing.expect(actual.isNeeded());
    try testing.expectEqual(@as(f64, 20), actual.getSliderSize());
    try testing.expectEqual(@as(f64, 230), actual.getSliderPosition());
}

test "ScrollbarState: terminal one-cell slider" {
    var actual = ScrollbarState.initWithMinimumSliderSize(0, 1, 0, 10, 100, 0, 1);

    try testing.expect(actual.isNeeded());
    try testing.expectEqual(@as(f64, 1), actual.getSliderSize());
    try testing.expectEqual(@as(f64, 0), actual.getSliderPosition());
    try testing.expectEqual(@as(f64, 50), actual.getDesiredScrollPositionFromDelta(5));

    _ = actual.setScrollPosition(90);
    try testing.expectEqual(@as(f64, 90), actual.getScrollPosition());
    try testing.expectEqual(@as(f64, 9), actual.getSliderPosition());

    const paged = actual.getDesiredScrollPositionFromOffsetPaged(0);
    try testing.expectEqual(@as(f64, 80), paged);
}

test "ScrollbarState: not needed when content fits" {
    var actual = ScrollbarState.initWithMinimumSliderSize(0, 1, 0, 10, 10, 0, 1);

    try testing.expect(!actual.isNeeded());
    try testing.expectEqual(@as(f64, 0), actual.getDesiredScrollPositionFromOffset(5));
    try testing.expectEqual(@as(f64, 0), actual.getDesiredScrollPositionFromDelta(5));
}

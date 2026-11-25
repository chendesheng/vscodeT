const std = @import("std");
const ScrollWindow = @import("ui").scroll.ScrollWindow;

test "scroll window clamps and scrolls" {
    const testing = std.testing;
    var window = ScrollWindow.init(10, 30, 0);
    try testing.expectEqual(@as(usize, 20), window.maxOffset());
    try testing.expect(!window.scrollBy(0));
    try testing.expect(window.scrollBy(5));
    try testing.expectEqual(@as(usize, 5), window.offset);
    try testing.expect(window.scrollBy(100));
    try testing.expectEqual(@as(usize, 20), window.offset);
    try testing.expect(!window.scrollBy(1));
    try testing.expect(window.scrollTo(0));
    try testing.expectEqual(@as(usize, 0), window.offset);

    window.setExtents(10, 4);
    try testing.expectEqual(@as(usize, 0), window.maxOffset());
    try testing.expectEqual(@as(usize, 0), window.offset);
    try testing.expect(!window.scrollTo(10));
}

test "scroll window ensures a range is visible" {
    const testing = std.testing;
    const window_viewport = 10;

    var window = ScrollWindow.init(window_viewport, 40, 0);
    try testing.expect(!window.ensureVisible(0, 1, 1));
    try testing.expect(!window.ensureVisible(1, 8, 1));
    // Reaching the right edge scrolls the minimum amount.
    try testing.expect(window.ensureVisible(9, 10, 1));
    try testing.expectEqual(@as(usize, 1), window.offset);
    // A range before the viewport scrolls back.
    try testing.expect(window.ensureVisible(0, 2, 1));
    try testing.expectEqual(@as(usize, 0), window.offset);
    // A range that cannot fit reveals its start.
    try testing.expect(window.ensureVisible(20, 40, 1));
    try testing.expectEqual(@as(usize, 19), window.offset);
    // No change when the range is already visible.
    try testing.expect(!window.ensureVisible(24, 26, 1));
}

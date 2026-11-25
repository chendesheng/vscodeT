const std = @import("std");
const Frame = @import("ui").frame.Frame;

test "Frame begin after swap skips the clear but still clears a dirty buffer" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, 3, 1);
    defer frame.deinit();

    frame.begin();
    frame.next.putCodepoint(0, 0, 'x', 1, .{});
    frame.swap();
    try std.testing.expectEqual(@as(u32, 'x'), frame.present().cluster[0]);
    try std.testing.expectEqual(@as(u32, 0), frame.next.cluster[0]);

    // A begin right after swap skips the redundant clear, but the buffer must
    // really be blank and new writes must reach the presented frame.
    frame.begin();
    frame.next.putCodepoint(1, 0, 'y', 1, .{});
    frame.swap();
    try std.testing.expectEqual(@as(u32, 'y'), frame.present().cluster[1]);
    try std.testing.expectEqual(@as(u32, 0), frame.present().cluster[0]);

    // Two begins without an intervening swap: the second still clears the
    // dirty buffer instead of silently reusing it.
    frame.begin();
    frame.next.putCodepoint(2, 0, 'z', 1, .{});
    frame.begin();
    try std.testing.expectEqual(@as(u32, 0), frame.next.cluster[2]);
    try std.testing.expectEqual(@as(u32, 'y'), frame.present().cluster[1]);

    frame.next.putCodepoint(2, 0, 'z', 1, .{});
    frame.swap();
    try std.testing.expectEqual(@as(u32, 'z'), frame.present().cluster[2]);
    try std.testing.expectEqual(@as(u32, 0), frame.present().cluster[0]);
}

test "Frame exposes the painted grid for terminal graphics overlays" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, 2, 1);
    defer frame.deinit();

    frame.begin();
    frame.next.putCodepoint(0, 0, 'x', 1, .{});
    frame.swap();
    frame.presentMut().putCodepoint(1, 0, 'y', 1, .{});
    try std.testing.expectEqual(@as(u32, 'y'), frame.present().cluster[1]);
}

test "Frame swaps buffers and keeps the presented grid" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, 4, 1);
    defer frame.deinit();

    frame.begin();
    frame.next.putCodepoint(0, 0, 'x', 1, .{});
    try std.testing.expectEqual(@as(u32, 'x'), frame.next.cluster[0]);
    frame.swap();
    try std.testing.expectEqual(@as(u32, 'x'), frame.present().cluster[0]);
    try std.testing.expectEqual(@as(u32, 0), frame.next.cluster[0]);
}

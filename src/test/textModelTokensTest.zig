const std = @import("std");
const ArrayList = std.array_list.Managed;
const RangePriorityQueue = @import("../basics/rangePriorityQueue.zig").RangePriorityQueue;
const OffsetRange = @import("../basics/offsetRange.zig").OffsetRange;

const RangePriorityQueueImplTests = struct {
    const allocator = std.testing.allocator;

    fn assertOffsetRanges(actual: *const ArrayList(OffsetRange), expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, actual.items.len);
        for (actual.items, 0..) |range, i| {
            const str = try range.toString(allocator);
            defer allocator.free(str);
            try std.testing.expectEqualStrings(expected[i], str);
        }
    }
    test "addRange" {
        var ranges: ArrayList(OffsetRange) = ArrayList(OffsetRange).init(allocator);
        defer ranges.deinit();

        try OffsetRange.addRange(.init(0, 2), &ranges);
        try OffsetRange.addRange(.init(10, 13), &ranges);
        try OffsetRange.addRange(.init(20, 24), &ranges);

        try assertOffsetRanges(&ranges, &[_][]const u8{ "[0, 2)", "[10, 13)", "[20, 24)" });

        try OffsetRange.addRange(.init(2, 10), &ranges);

        try assertOffsetRanges(&ranges, &[_][]const u8{ "[0, 13)", "[20, 24)" });

        try OffsetRange.addRange(.init(14, 19), &ranges);

        try assertOffsetRanges(&ranges, &[_][]const u8{ "[0, 13)", "[14, 19)", "[20, 24)" });

        try OffsetRange.addRange(.init(10, 22), &ranges);

        try assertOffsetRanges(&ranges, &[_][]const u8{"[0, 24)"});

        try OffsetRange.addRange(.init(-1, 29), &ranges);

        try assertOffsetRanges(&ranges, &[_][]const u8{"[-1, 29)"});

        try OffsetRange.addRange(.init(-10, -5), &ranges);

        try assertOffsetRanges(&ranges, &[_][]const u8{ "[-10, -5)", "[-1, 29)" });
    }

    test "addRangeAndResize" {
        var queue = RangePriorityQueue.init(allocator);
        defer queue.deinit();

        try queue.addRange(.init(0, 20));
        try queue.addRange(.init(100, 120));
        try queue.addRange(.init(200, 220));

        // disjoint
        try queue.addRangeAndResize(.init(25, 27), 0);

        try assertOffsetRanges(queue.getRanges(), &[_][]const u8{ "[0, 20)", "[98, 118)", "[198, 218)" });

        try queue.addRangeAndResize(.init(19, 20), 0);

        try assertOffsetRanges(queue.getRanges(), &[_][]const u8{ "[0, 19)", "[97, 117)", "[197, 217)" });

        try queue.addRangeAndResize(.init(19, 97), 0);

        try assertOffsetRanges(queue.getRanges(), &[_][]const u8{ "[0, 39)", "[119, 139)" });

        try queue.addRangeAndResize(.init(-1000, 1000), 0);

        try assertOffsetRanges(queue.getRanges(), &[_][]const u8{});
    }
};

test "textModelTokens" {
    _ = RangePriorityQueueImplTests{};
}

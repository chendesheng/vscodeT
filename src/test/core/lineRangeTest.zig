const std = @import("std");
const io = std.io;
const LineRange = @import("../../basics/lineRange.zig").LineRange;
const LineRangeSet = @import("../../basics/lineRange.zig").LineRangeSet;

const LineRangeTests = struct {
    test "contains" {
        const r = LineRange.init(2, 3);
        try std.testing.expect(!r.contains(1));
        try std.testing.expect(r.contains(2));
        try std.testing.expect(!r.contains(3));
        try std.testing.expect(!r.contains(4));
    }
};

const LineRangeSetTests = struct {
    const allocator = std.testing.allocator;
    test "addRange" {
        var set = LineRangeSet.empty(allocator);
        defer set.deinit();
        try set.addRange(LineRange.init(2, 3));
        try set.addRange(LineRange.init(3, 4));
        try set.addRange(LineRange.init(10, 20));

        var buf: [1024]u8 = undefined;
        var writer = io.Writer.fixed(&buf);
        try set.toString(&writer);
        try std.testing.expectEqualStrings("[2,4), [10,20)", buf[0..writer.end]);

        try set.addRange(LineRange.init(3, 21));

        writer.end = 0;
        try set.toString(&writer);
        try std.testing.expectEqualStrings("[2,21)", buf[0..writer.end]);
    }

    test "getUnion" {
        const set1 = try LineRangeSet.fromSlice(allocator, &[_]LineRange{
            LineRange.init(2, 3),
            LineRange.init(5, 7),
            LineRange.init(10, 20),
        });
        defer set1.deinit();
        const set2 = try LineRangeSet.fromSlice(allocator, &[_]LineRange{
            LineRange.init(3, 4),
            LineRange.init(6, 8),
            LineRange.init(9, 11),
        });
        defer set2.deinit();

        const un = try set1.getUnion(set2);
        defer un.deinit();

        var buf: [1024]u8 = undefined;
        var writer = io.Writer.fixed(&buf);
        try un.toString(&writer);
        try std.testing.expectEqualStrings("[2,4), [5,8), [9,20)", buf[0..writer.end]);
    }

    test "intersects" {
        var set1 = try LineRangeSet.fromSlice(allocator, &[_]LineRange{
            LineRange.init(2, 3),
            LineRange.init(5, 7),
            LineRange.init(10, 20),
        });
        defer set1.deinit();

        try std.testing.expect(!set1.intersects(LineRange.init(1, 2)));
        try std.testing.expect(set1.intersects(LineRange.init(1, 3)));
        try std.testing.expect(!set1.intersects(LineRange.init(3, 5)));
    }
};

test "lineRange" {
    _ = LineRangeTests{};
    _ = LineRangeSetTests{};
}

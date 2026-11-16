// Port of `src/vs/base/test/browser/ui/list/rangeMap.test.ts`.

const std = @import("std");
const testing = std.testing;
const range = @import("../../../../common/range.zig");
const range_map = @import("../../../../browser/ui/list/rangeMap.zig");
const RangeMap = range_map.RangeMap;
const Item = range_map.Item;
const RangedGroup = range_map.RangedGroup;

fn expectGroups(expected: []const RangedGroup, actual: []const RangedGroup) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try testing.expectEqual(want.range.start, got.range.start);
        try testing.expectEqual(want.range.end, got.range.end);
        try testing.expectEqual(want.size, got.size);
    }
}

fn expectRange(expected: range.Range, actual: range.Range) !void {
    try testing.expectEqual(expected.start, actual.start);
    try testing.expectEqual(expected.end, actual.end);
}

test "RangeMap: intersection" {
    try expectRange(.{ .start = 0, .end = 0 }, range.intersect(.{ .start = 0, .end = 0 }, .{ .start = 0, .end = 0 }));
    try expectRange(.{ .start = 0, .end = 0 }, range.intersect(.{ .start = 0, .end = 1 }, .{ .start = 5, .end = 6 }));
    try expectRange(.{ .start = 0, .end = 0 }, range.intersect(.{ .start = 0, .end = 5 }, .{ .start = 2, .end = 2 }));
    try expectRange(.{ .start = 0, .end = 5 }, range.intersect(.{ .start = 0, .end = 10 }, .{ .start = 0, .end = 5 }));
    try expectRange(.{ .start = 5, .end = 10 }, range.intersect(.{ .start = 0, .end = 10 }, .{ .start = 5, .end = 15 }));
}

test "RangeMap: multiIntersect" {
    const allocator = testing.allocator;

    {
        const got = try range_map.groupIntersect(allocator, .{ .start = 0, .end = 0 }, &.{
            .{ .range = .{ .start = 0, .end = 10 }, .size = 1 },
        });
        defer allocator.free(got);
        try expectGroups(&.{}, got);
    }
    {
        const got = try range_map.groupIntersect(allocator, .{ .start = 10, .end = 20 }, &.{
            .{ .range = .{ .start = 0, .end = 10 }, .size = 1 },
        });
        defer allocator.free(got);
        try expectGroups(&.{}, got);
    }
    {
        const got = try range_map.groupIntersect(allocator, .{ .start = 2, .end = 18 }, &.{
            .{ .range = .{ .start = 0, .end = 10 }, .size = 1 },
            .{ .range = .{ .start = 10, .end = 20 }, .size = 5 },
        });
        defer allocator.free(got);
        try expectGroups(&.{
            .{ .range = .{ .start = 2, .end = 10 }, .size = 1 },
            .{ .range = .{ .start = 10, .end = 18 }, .size = 5 },
        }, got);
    }
    {
        const got = try range_map.groupIntersect(allocator, .{ .start = 2, .end = 28 }, &.{
            .{ .range = .{ .start = 0, .end = 10 }, .size = 1 },
            .{ .range = .{ .start = 10, .end = 20 }, .size = 5 },
            .{ .range = .{ .start = 20, .end = 30 }, .size = 10 },
        });
        defer allocator.free(got);
        try expectGroups(&.{
            .{ .range = .{ .start = 2, .end = 10 }, .size = 1 },
            .{ .range = .{ .start = 10, .end = 20 }, .size = 5 },
            .{ .range = .{ .start = 20, .end = 28 }, .size = 10 },
        }, got);
    }
}

test "RangeMap: consolidate" {
    const allocator = testing.allocator;
    {
        const got = try range_map.consolidate(allocator, &.{});
        defer allocator.free(got);
        try expectGroups(&.{}, got);
    }
    {
        const got = try range_map.consolidate(allocator, &.{
            .{ .range = .{ .start = 0, .end = 10 }, .size = 1 },
            .{ .range = .{ .start = 10, .end = 20 }, .size = 1 },
        });
        defer allocator.free(got);
        try expectGroups(&.{.{ .range = .{ .start = 0, .end = 20 }, .size = 1 }}, got);
    }
    {
        const got = try range_map.consolidate(allocator, &.{
            .{ .range = .{ .start = 0, .end = 10 }, .size = 1 },
            .{ .range = .{ .start = 10, .end = 20 }, .size = 2 },
            .{ .range = .{ .start = 20, .end = 100 }, .size = 2 },
        });
        defer allocator.free(got);
        try expectGroups(&.{
            .{ .range = .{ .start = 0, .end = 10 }, .size = 1 },
            .{ .range = .{ .start = 10, .end = 100 }, .size = 2 },
        }, got);
    }
}

fn item(size: f64) Item {
    return .{ .size = size };
}

fn splice(map: *RangeMap, index: usize, delete_count: usize, items: []const Item) !void {
    try map.splice(index, delete_count, items);
}

test "RangeMap: length, count, insert and delete" {
    var map = RangeMap.init(testing.allocator, 0);
    defer map.deinit();

    try testing.expectEqual(@as(f64, 0), map.size());
    try testing.expectEqual(@as(usize, 0), map.count());

    try splice(&map, 0, 0, &.{ item(1), item(1), item(1), item(1), item(1) });
    try testing.expectEqual(@as(f64, 5), map.size());
    try testing.expectEqual(@as(usize, 5), map.count());

    try splice(&map, 5, 0, &.{ item(10), item(10) });
    try testing.expectEqual(@as(f64, 25), map.size());
    try testing.expectEqual(@as(usize, 7), map.count());

    try splice(&map, 2, 6, &.{});
    try testing.expectEqual(@as(f64, 2), map.size());
    try testing.expectEqual(@as(usize, 2), map.count());
}

test "RangeMap: indexAt and positionAt" {
    var map = RangeMap.init(testing.allocator, 0);
    defer map.deinit();

    try testing.expectEqual(@as(i64, 0), map.indexAt(0));
    try testing.expectEqual(@as(i64, 0), map.indexAt(10));
    try testing.expectEqual(@as(i64, -1), map.indexAt(-1));
    try testing.expectEqual(@as(f64, -1), map.positionAt(0));

    try splice(&map, 0, 0, &.{ item(10), item(10), item(10), item(10), item(10) });
    try testing.expectEqual(@as(i64, 0), map.indexAt(0));
    try testing.expectEqual(@as(i64, 0), map.indexAt(9));
    try testing.expectEqual(@as(i64, 1), map.indexAt(10));
    try testing.expectEqual(@as(f64, 0), map.positionAt(0));
    try testing.expectEqual(@as(f64, 10), map.positionAt(1));
    try testing.expectEqual(@as(f64, 40), map.positionAt(4));
    try testing.expectEqual(@as(f64, -1), map.positionAt(5));

    try splice(&map, 2, 2, &.{});
    try testing.expectEqual(@as(i64, 2), map.indexAt(20));
    try testing.expectEqual(@as(f64, 20), map.positionAt(2));
    try testing.expectEqual(@as(f64, -1), map.positionAt(3));
}

test "RangeMap: top padding" {
    var map = RangeMap.init(testing.allocator, 10);
    defer map.deinit();

    try testing.expectEqual(@as(f64, 10), map.size());
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expectEqual(@as(i64, 0), map.indexAt(0));
    try testing.expectEqual(@as(f64, -1), map.positionAt(0));

    try splice(&map, 0, 0, &.{ item(5), item(5) });
    try testing.expectEqual(@as(f64, 20), map.size());
    try testing.expectEqual(@as(f64, 10), map.positionAt(0));
    try testing.expectEqual(@as(f64, 15), map.positionAt(1));
    try testing.expectEqual(@as(i64, 0), map.indexAt(10));
    try testing.expectEqual(@as(i64, 1), map.indexAt(15));

    map.setPaddingTop(0);
    try testing.expectEqual(@as(f64, 10), map.size());
    try testing.expectEqual(@as(f64, 0), map.positionAt(0));
}

test "RangeMap: zero sizes" {
    var map = RangeMap.init(testing.allocator, 0);
    defer map.deinit();
    try splice(&map, 0, 0, &.{ item(0), item(0) });
    try testing.expectEqual(@as(f64, 0), map.size());
    try testing.expectEqual(@as(usize, 2), map.count());
    // A zero-height group contributes no distance; indexAt skips the whole
    // group and returns the count, matching upstream's arithmetic.
    try testing.expectEqual(@as(i64, 2), map.indexAt(0));
    try testing.expectEqual(@as(f64, 0), map.positionAt(0));
    try testing.expectEqual(@as(f64, 0), map.positionAt(1));
}

const std = @import("std");
const Stats = @import("bench_harness").Stats;
const CountingAllocator = @import("bench_harness").CountingAllocator;

test "stats keep the first sample and compute percentiles" {
    const samples = [_]i64{ 9, 1, 5, 3, 7 };
    const stats = try Stats.fromSamples(std.testing.allocator, &samples);
    try std.testing.expectEqual(@as(i64, 9), stats.first);
    try std.testing.expectEqual(@as(i64, 1), stats.min);
    try std.testing.expectEqual(@as(i64, 5), stats.p50);
    try std.testing.expectEqual(@as(i64, 7), stats.p90);
    try std.testing.expectEqual(@as(i64, 9), stats.max);
}

test "counting allocator reports requested bytes" {
    const page = std.heap.page_allocator;
    var counting = CountingAllocator{ .child = page };
    const allocator = counting.allocator();
    const memory = try allocator.alloc(u8, 64);
    defer allocator.free(memory);
    try std.testing.expectEqual(@as(usize, 64), counting.total);
    try std.testing.expectEqual(@as(usize, 64), counting.live);
    counting.reset();
    try std.testing.expectEqual(@as(usize, 0), counting.total);
    try std.testing.expectEqual(@as(usize, 64), counting.live);
}

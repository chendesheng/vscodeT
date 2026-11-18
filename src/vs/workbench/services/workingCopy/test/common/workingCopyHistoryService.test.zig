// Terminal tests for the in-memory working-copy history subset.
const std = @import("std");
const testing = std.testing;
const service_mod = @import("../../common/workingCopyHistoryService.zig");

test "working copy history service: caps, orders, removes and clears entries" {
    const allocator = testing.allocator;
    var service = service_mod.WorkingCopyHistoryService.init(allocator, 2);
    defer service.deinit();

    var events: usize = 0;
    _ = try service.on_did_change.listen(&events, struct {
        fn onChange(_: []const u8, count: *usize) anyerror!void {
            count.* += 1;
        }
    }.onChange);

    try service.addEntry("/file.txt", "text", 1, "one");
    try service.addEntry("/file.txt", "text", 2, "two");
    try service.addEntry("/file.txt", "text", 3, "three");
    try testing.expectEqual(@as(usize, 2), service.entryCount());
    try testing.expectEqual(@as(usize, 3), events);

    const entries = try service.getEntries("/file.txt", allocator);
    defer allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(i64, 3), entries[0].timestamp);
    try testing.expectEqualStrings("three", entries[0].content);
    try testing.expectEqual(@as(i64, 2), entries[1].timestamp);

    try testing.expect(service.removeEntry("/file.txt", "text", 3));
    try testing.expectEqual(@as(usize, 1), service.entryCount());
    try testing.expectEqual(@as(usize, 4), events);

    try service.addEntry("/other.txt", "text", 4, "other");
    service.clear("/file.txt");
    try testing.expectEqual(@as(usize, 1), service.entryCount());
    service.clear(null);
    try testing.expectEqual(@as(usize, 0), service.entryCount());
}

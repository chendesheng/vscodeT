// Adapted editor-history cases for the TUI quick-open history subset.

const std = @import("std");
const history = @import("../../common/history.zig");

test "historyService: most recent first and deduplicated" {
    var service = history.HistoryService.init(std.testing.allocator);
    defer service.deinit();

    try service.add("/a");
    try service.add("/b");
    try service.add("/a");
    try std.testing.expectEqual(@as(usize, 2), service.getHistory().len);
    try std.testing.expectEqualStrings("/a", service.getHistory()[0]);
    try std.testing.expectEqualStrings("/b", service.getHistory()[1]);
}

test "historyService: caps the history and supports removal" {
    var service = history.HistoryService.init(std.testing.allocator);
    defer service.deinit();
    service.max = 2;

    try service.add("/a");
    try service.add("/b");
    try service.add("/c");
    try std.testing.expectEqual(@as(usize, 2), service.getHistory().len);
    try std.testing.expectEqualStrings("/c", service.getHistory()[0]);

    service.remove("/c");
    try std.testing.expectEqual(@as(usize, 1), service.getHistory().len);
    try std.testing.expectEqualStrings("/b", service.getHistory()[0]);
}

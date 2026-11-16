// Port of the formatting contract of
// `src/vs/platform/files/node/watcher/watcherStats.ts`.

const std = @import("std");
const stats = @import("../../node/watcher/watcherStats.zig");
const universal_mod = @import("../../node/watcher/watcher.zig");
const common = @import("../../common/watcher.zig");

test "watcherStats: summary contains request and watcher sections" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = try allocator.dupe(u8, path_buffer[0..root_len]);
    defer allocator.free(root);

    var watcher = try universal_mod.UniversalWatcher.init(allocator, io);
    defer watcher.deinit();

    const requests = [_]common.WatchRequest{
        .{ .path = root, .recursive = true },
        .{ .path = root, .recursive = false },
    };
    const summary = try stats.computeStats(allocator, &requests, 0, watcher.recursive, watcher.non_recursive);
    defer allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "[Summary]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Recursive Requests") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Non-Recursive Watchers") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, root) != null);
}

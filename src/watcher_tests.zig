// Watcher-only test root, used by `zig build test-watcher` so the watcher can
// be compiled and tested for targets that do not build the POSIX TUI.
comptime {
    _ = @import("./vs/platform/files/common/files.zig");
    _ = @import("./vs/platform/files/common/watcher.zig");
    _ = @import("./vs/base/common/async.zig");
    _ = @import("./vs/base/common/glob.zig");
    _ = @import("./vs/platform/files/node/watcher/parcel/watcherLib/event.zig");
    _ = @import("./vs/platform/files/node/watcher/parcel/watcherLib/dirTree.zig");
    _ = @import("./vs/platform/files/node/watcher/parcel/watcherLib/ignore.zig");
    _ = @import("./vs/platform/files/node/watcher/parcel/watcherLib/watcher.zig");
    _ = @import("./vs/platform/files/node/watcher/parcel/watcherLib/root.zig");
}
comptime {
    _ = @import("./vs/platform/files/node/watcher/baseWatcher.zig");
    _ = @import("./vs/platform/files/node/watcher/parcel/parcelWatcher.zig");
}
comptime {
    _ = @import("./vs/platform/files/node/watcher/nodejs/nodejsWatcherLib.zig");
    _ = @import("./vs/platform/files/node/watcher/nodejs/nodejsWatcher.zig");
    _ = @import("./vs/platform/files/node/watcher/watcher.zig");
}

const std = @import("std");
const universal_mod = @import("./vs/platform/files/node/watcher/watcher.zig");
const common = @import("./vs/platform/files/common/watcher.zig");
const files = @import("./vs/platform/files/common/files.zig");

const ChangeCounter = struct {
    count: usize = 0,
    last: files.FileChangeType = .UPDATED,
};

fn countChange(changes: []const files.FileChange, counter: *ChangeCounter) !void {
    counter.count += changes.len;
    if (changes.len > 0) counter.last = changes[0].type;
}

test "UniversalWatcher: recursive and non-recursive inotify events" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "settings.json", .{});
    try file.writeStreamingAll(io, "{}");
    file.close(io);
    try tmp.dir.createDirPath(io, "workspace");
    var watched = try tmp.dir.createFile(io, "workspace/a.txt", .{});
    try watched.writeStreamingAll(io, "a");
    watched.close(io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];
    const settings = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{root});
    defer allocator.free(settings);
    const workspace = try std.fmt.allocPrint(allocator, "{s}/workspace", .{root});
    defer allocator.free(workspace);

    var watcher = try universal_mod.UniversalWatcher.init(allocator, io);
    defer watcher.deinit();

    var counter = ChangeCounter{};
    _ = try watcher.on_change.listen(&counter, countChange);

    try watcher.watch(&.{
        .{ .path = settings, .recursive = false },
        .{ .path = workspace, .recursive = true },
    });

    var file_write = try tmp.dir.createFile(io, "settings.json", .{ .truncate = true });
    try file_write.writeStreamingAll(io, "{\"editor.tabSize\": 4}");
    file_write.close(io);

    var nested = try tmp.dir.createFile(io, "workspace/b.txt", .{});
    try nested.writeStreamingAll(io, "b");
    nested.close(io);

    const deadline = common_now() + 3000;
    while (common_now() < deadline and counter.count < 2) {
        _ = try watcher.poll(common_now());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(counter.count >= 2);
}

fn common_now() i64 {
    return std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}
comptime {
    _ = @import("./vs/platform/files/node/watcher/watcherStats.zig");
}
comptime {
    _ = @import("./tui/settingsWatcher.zig");
}

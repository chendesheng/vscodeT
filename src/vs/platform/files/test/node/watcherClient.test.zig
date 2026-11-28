// Integration coverage for the async universal watcher client and the
// refcounted watch subset of `FileService`. The watcher runs on its worker
// thread, so `watch()` returns before the recursive scan completes; these
// tests exercise the queue handoff and the request refcounting.

const std = @import("std");
const files = @import("../../common/files.zig");
const client_mod = @import("../../node/watcher/watcherClient.zig");
const service_mod = @import("../../node/watcher/fileWatcherService.zig");

const Counter = struct {
    count: usize = 0,

    fn onChange(changes: []const files.FileChange, self: *Counter) !void {
        self.count += changes.len;
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
}

test "watcher client: deep changes arrive from the worker" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "deep/nested");
    var seed = try tmp.dir.createFile(io, "deep/nested/seed.txt", .{});
    seed.close(io);

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var client = try client_mod.UniversalWatcherClient.init(allocator);
    defer client.deinit();

    var counter = Counter{};
    _ = try client.on_change.listen(&counter, Counter.onChange);

    try client.watch(&.{.{ .path = root, .recursive = true }});

    // Wait until the worker has applied the request; `watch()` only queues it.
    const ready_deadline = nowMs() + 3000;
    while (nowMs() < ready_deadline and !client.isReady()) {
        _ = client.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    counter.count = 0;

    var created = try tmp.dir.createFile(io, "deep/nested/changed.txt", .{});
    try created.writeStreamingAll(io, "changed");
    created.close(io);

    const deadline = nowMs() + 3000;
    while (nowMs() < deadline and counter.count == 0) {
        _ = client.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(counter.count > 0);
}

test "file watcher service: identical requests share one watch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const service = try service_mod.FileWatcherService.init(allocator, io);
    defer service.deinit();

    const first = try service.watch(root, .{});
    const second = try service.watch(root, .{});
    try std.testing.expectEqual(@as(usize, 1), service.watchedCount());

    const flat = try service.watch(root, .{ .recursive = false, .includes = &.{.{ .string = "*.txt" }} });
    try std.testing.expectEqual(@as(usize, 2), service.watchedCount());
    first.dispose();
    try std.testing.expectEqual(@as(usize, 2), service.watchedCount());
    second.dispose();
    try std.testing.expectEqual(@as(usize, 1), service.watchedCount());
    flat.dispose();
    try std.testing.expectEqual(@as(usize, 0), service.watchedCount());
}

test "file watcher service: changes reach the main-thread poll" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const service = try service_mod.FileWatcherService.init(allocator, io);
    defer service.deinit();

    var counter = Counter{};
    _ = try service.on_did_change.listen(&counter, Counter.onChange);
    const handle = try service.watch(root, .{});
    defer handle.dispose();

    const ready_deadline = nowMs() + 3000;
    while (nowMs() < ready_deadline and !service.isReady()) {
        _ = service.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    counter.count = 0;

    var created = try tmp.dir.createFile(io, "changed.txt", .{});
    try created.writeStreamingAll(io, "changed");
    created.close(io);

    const deadline = nowMs() + 3000;
    while (nowMs() < deadline and counter.count == 0) {
        _ = service.poll();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(counter.count > 0);
}

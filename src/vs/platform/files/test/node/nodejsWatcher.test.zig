// Port of representative cases from
// `src/vs/platform/files/test/node/nodejsWatcher.test.ts`, adapted to the
// terminal's poll-driven inotify implementation.

const std = @import("std");
const files = @import("../../common/files.zig");
const nodejs_mod = @import("../../node/watcher/nodejs/nodejsWatcherLib.zig");

const Recorder = struct {
    changes: std.array_list.Managed(files.FileChange),

    fn onChange(changes: []const files.FileChange, self: *Recorder) !void {
        for (changes) |change| try self.changes.append(change);
    }
};

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}

fn waitFor(allocator: std.mem.Allocator, io: std.Io, watcher: *nodejs_mod.NodeJSWatcher, recorder: *Recorder, count: usize) !void {
    const deadline = nowMs() + 3000;
    while (nowMs() < deadline and recorder.changes.items.len < count) {
        _ = try watcher.poll(nowMs());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    _ = allocator;
}

test "nodejs watcher: file update and atomic save" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(io, "settings.json", .{});
    try file.writeStreamingAll(io, "{}");
    file.close(io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{path_buffer[0..root_len]});
    defer allocator.free(path);

    var watcher = try nodejs_mod.NodeJSWatcher.init(allocator, io, .{});
    defer watcher.deinit();
    var recorder = Recorder{ .changes = std.array_list.Managed(files.FileChange).init(allocator) };
    defer recorder.changes.deinit();
    _ = try watcher.on_change.listen(&recorder, Recorder.onChange);

    try watcher.watch(&.{.{ .path = path, .recursive = false }});

    var write = try tmp.dir.createFile(io, "settings.json", .{ .truncate = true });
    try write.writeStreamingAll(io, "{\"a\":1}");
    write.close(io);
    try waitFor(allocator, io, watcher, &recorder, 1);
    try std.testing.expect(recorder.changes.items.len >= 1);

    // Delete and recreate, the atomic-save shape used by many editors.
    try tmp.dir.deleteFile(io, "settings.json");
    var recreated = try tmp.dir.createFile(io, "settings.json", .{});
    try recreated.writeStreamingAll(io, "{\"a\":2}");
    recreated.close(io);
    try waitFor(allocator, io, watcher, &recorder, 2);
    try std.testing.expect(recorder.changes.items.len >= 2);
}

test "nodejs watcher: folder events, correlation and filter" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = try allocator.dupe(u8, path_buffer[0..root_len]);
    defer allocator.free(root);

    var watcher = try nodejs_mod.NodeJSWatcher.init(allocator, io, .{});
    defer watcher.deinit();
    var recorder = Recorder{ .changes = std.array_list.Managed(files.FileChange).init(allocator) };
    defer recorder.changes.deinit();
    _ = try watcher.on_change.listen(&recorder, Recorder.onChange);

    try watcher.watch(&.{.{
        .path = root,
        .recursive = false,
        .correlationId = 42,
        .filter = files.FileChangeFilter.ADDED,
    }});

    var file = try tmp.dir.createFile(io, "created.txt", .{});
    file.close(io);
    try waitFor(allocator, io, watcher, &recorder, 1);
    try std.testing.expect(recorder.changes.items.len >= 1);
    try std.testing.expectEqual(@as(?u32, 42), recorder.changes.items[0].cId);
    try std.testing.expectEqual(files.FileChangeType.ADDED, recorder.changes.items[0].type);
}

test "nodejs watcher: missing file is suspended and resumes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/missing.json", .{path_buffer[0..root_len]});
    defer allocator.free(path);

    var watcher = try nodejs_mod.NodeJSWatcher.init(allocator, io, .{});
    defer watcher.deinit();
    watcher.base.suspended_polling_interval_ms = 25;

    var recorder = Recorder{ .changes = std.array_list.Managed(files.FileChange).init(allocator) };
    defer recorder.changes.deinit();
    _ = try watcher.on_change.listen(&recorder, Recorder.onChange);

    try watcher.watch(&.{.{ .path = path, .recursive = false }});
    try std.testing.expect(watcher.isSuspended(&watcher.base.requests.?.requests[0]) == .suspended);

    var created = try tmp.dir.createFile(io, "missing.json", .{});
    try created.writeStreamingAll(io, "{}");
    created.close(io);

    try waitFor(allocator, io, watcher, &recorder, 1);
    try std.testing.expect(recorder.changes.items.len >= 1);
    try std.testing.expectEqual(files.FileChangeType.ADDED, recorder.changes.items[0].type);
}

const ContentsRecorder = struct {
    allocator: std.mem.Allocator,
    data: std.array_list.Managed(u8),
    ready: bool = false,

    fn onData(ctx: *anyopaque, chunk: []const u8) void {
        const self: *ContentsRecorder = @ptrCast(@alignCast(ctx));
        self.data.appendSlice(chunk) catch {};
    }
    fn onReady(ctx: *anyopaque) void {
        const self: *ContentsRecorder = @ptrCast(@alignCast(ctx));
        self.ready = true;
    }
};

test "watchFileContents: delivers appended data" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "log.txt", .{});
    try file.writeStreamingAll(io, "one");
    file.close(io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/log.txt", .{path_buffer[0..root_len]});
    defer allocator.free(path);

    var recorder = ContentsRecorder{ .allocator = allocator, .data = std.array_list.Managed(u8).init(allocator) };
    defer recorder.data.deinit();
    var handle = try nodejs_mod.watchFileContents(
        allocator,
        io,
        path,
        &recorder,
        ContentsRecorder.onData,
        &recorder,
        ContentsRecorder.onReady,
        8,
    );
    defer handle.deinit();
    try std.testing.expect(recorder.ready);

    var append = try tmp.dir.createFile(io, "log.txt", .{ .truncate = false });
    try append.writeStreamingAll(io, "two");
    append.close(io);

    const deadline = nowMs() + 3000;
    while (nowMs() < deadline and recorder.data.items.len < 6) {
        _ = try handle.poll(nowMs());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(std.mem.indexOf(u8, recorder.data.items, "two") != null);
}

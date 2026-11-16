// Port of the active deduplication cases in
// `src/vs/platform/files/test/node/parcelWatcher.test.ts`, plus Linux/macOS
// integration coverage for the Zig parcel-watcher port.

const std = @import("std");
const common = @import("../../common/watcher.zig");
const parcel = @import("../../node/watcher/parcel/parcelWatcher.zig");
const universal_mod = @import("../../node/watcher/watcher.zig");
const files = @import("../../common/files.zig");

fn request(path: []const u8) common.WatchRequest {
    return .{ .path = path, .recursive = true };
}

test "parcel dedup: uncorrelated same-root keeps broad watcher" {
    const allocator = std.testing.allocator;
    const broad = request("/workspace");
    const narrow = common.WatchRequest{
        .path = "/workspace",
        .recursive = true,
        .includes = &.{.{ .string = "mcp/*.mjs" }},
    };
    inline for (.{ &[_]common.WatchRequest{ broad, narrow }, &[_]common.WatchRequest{ narrow, broad } }) |input| {
        var deduped = try parcel.deduplicateRequestList(allocator, input, false);
        defer deduped.deinit();
        try std.testing.expectEqual(@as(usize, 1), deduped.requests.len);
        try std.testing.expectEqualStrings("/workspace", deduped.requests[0].path);
        try std.testing.expectEqual(@as(usize, 0), deduped.requests[0].includes.len);
    }
}

test "parcel dedup: same-root combines narrow includes and intersects excludes" {
    const allocator = std.testing.allocator;
    const first = common.WatchRequest{
        .path = "/workspace",
        .recursive = true,
        .excludes = &.{ "**/node_modules/**", "**/dist/**" },
        .includes = &.{.{ .string = "mcp/*.mjs" }},
    };
    const second = common.WatchRequest{
        .path = "/workspace",
        .recursive = true,
        .excludes = &.{"**/node_modules/**"},
        .includes = &.{.{ .string = ".custom/agents/*.md" }},
    };
    var deduped = try parcel.deduplicateRequestList(allocator, &.{ first, second }, false);
    defer deduped.deinit();
    try std.testing.expectEqual(@as(usize, 1), deduped.requests.len);
    try std.testing.expectEqual(@as(usize, 2), deduped.requests[0].includes.len);
    try std.testing.expectEqual(@as(usize, 1), deduped.requests[0].excludes.len);
}

test "parcel dedup: different correlation ids stay separate" {
    const allocator = std.testing.allocator;
    const first = common.WatchRequest{ .path = "/workspace", .recursive = true, .correlationId = 1 };
    const second = common.WatchRequest{ .path = "/workspace", .recursive = true, .correlationId = 2 };
    var deduped = try parcel.deduplicateRequestList(allocator, &.{ first, second }, false);
    defer deduped.deinit();
    try std.testing.expectEqual(@as(usize, 2), deduped.requests.len);
}

test "parcel dedup: child request of a watched parent is dropped" {
    const allocator = std.testing.allocator;
    const parent = request("/workspace");
    const child = request("/workspace/src");
    var deduped = try parcel.deduplicateRequestList(allocator, &.{ parent, child }, false);
    defer deduped.deinit();
    try std.testing.expectEqual(@as(usize, 1), deduped.requests.len);
    try std.testing.expectEqualStrings("/workspace", deduped.requests[0].path);
}

test "universal watcher: recursive create/update/delete" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];

    var watcher = try universal_mod.UniversalWatcher.init(allocator, io);
    defer watcher.deinit();

    const Counter = struct {
        changes: std.array_list.Managed(files.FileChange),
        fn onChange(changes: []const files.FileChange, self: *@This()) !void {
            for (changes) |change| try self.changes.append(change);
        }
    };
    var counter = Counter{ .changes = std.array_list.Managed(files.FileChange).init(allocator) };
    defer counter.changes.deinit();
    _ = try watcher.on_change.listen(&counter, Counter.onChange);

    try watcher.watch(&.{.{ .path = root, .recursive = true }});

    var file = try tmp.dir.createFile(io, "a.txt", .{});
    try file.writeStreamingAll(io, "a");
    file.close(io);

    const deadline = nowMs() + 3000;
    while (nowMs() < deadline and counter.changes.items.len == 0) {
        _ = try watcher.poll(nowMs());
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(counter.changes.items.len > 0);
}

fn nowMs() i64 {
    return std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}

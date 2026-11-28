// Native consumer-side regression for
// `src/vs/workbench/api/browser/mainThreadFileSystem.ts`.
const std = @import("std");
const actor_mod = @import("../../browser/mainThreadFileSystem.zig");
const file_service = @import("../../../../platform/files/common/fileService.zig");
const disk = @import("../../../../platform/files/node/diskFileSystemProvider.zig");
const std_uri = @import("../../../../base/common/stdUri.zig");
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");

fn resource(arena: std.mem.Allocator, root: []const u8, name: []const u8) !rpc.Arg {
    const path = try std.fs.path.join(arena, &.{ root, name });
    return .{ .json = try std_uri.jsonComponents(arena, .{ .scheme = "file", .path = .{ .raw = path } }) };
}

test "MainThreadFileSystem: local workspace.fs operations preserve URI and binary data" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var provider = disk.DiskFileSystemProvider.init(allocator, io);
    defer provider.deinit();
    var service = file_service.ProviderFileService.init(allocator);
    defer service.deinit();
    const registration = try service.registerProvider("file", provider.interface());
    defer registration.dispose();
    const actor = actor_mod.MainThreadFileSystem{ .service = service.interface() };
    const folder = try resource(arena, root, "nested");
    const source = try resource(arena, root, "nested/a #.bin");
    const copied = try resource(arena, root, "nested/copied.bin");
    const renamed = try resource(arena, root, "nested/renamed.bin");
    const bytes = &[_]u8{ 0, 255, 42 };
    try std.testing.expect((try actor.invoke("$mkdir", &.{folder}, arena)) == .empty);
    try std.testing.expect((try actor.invoke("$writeFile", &.{ source, .{ .buffer = bytes } }, arena)) == .empty);
    const stat = try actor.invoke("$stat", &.{source}, arena);
    try std.testing.expectEqual(@as(i64, 3), stat.json.object.get("size").?.integer);
    try std.testing.expectEqual(@as(i64, 1), stat.json.object.get("type").?.integer);
    try std.testing.expect(stat.json.object.get("mtime").?.integer > 0);
    try std.testing.expect(stat.json.object.get("mtime").?.integer < 9_999_999_999_999);
    const result = try actor.invoke("$readFile", &.{source}, arena);
    try std.testing.expectEqualSlices(u8, bytes, result.buffer);
    const entries = (try actor.invoke("$readdir", &.{folder}, arena)).json.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("a #.bin", entries[0].array.items[0].string);
    const opts = rpc.Arg{ .json = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"overwrite\":false}", .{}) };
    try std.testing.expect((try actor.invoke("$copy", &.{ source, copied, opts }, arena)) == .empty);
    try std.testing.expectEqualStrings("EntryExists", (try actor.invoke("$copy", &.{ source, copied, opts }, arena)).err.name);
    try std.testing.expect((try actor.invoke("$rename", &.{ copied, renamed, opts }, arena)) == .empty);
    try std.testing.expectEqualSlices(u8, bytes, (try actor.invoke("$readFile", &.{renamed}, arena)).buffer);
    const delete_opts = rpc.Arg{ .json = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"recursive\":true,\"useTrash\":false}", .{}) };
    try std.testing.expect((try actor.invoke("$delete", &.{ folder, delete_opts }, arena)) == .empty);
    try std.testing.expectEqualStrings("EntryNotFound", (try actor.invoke("$stat", &.{source}, arena)).err.name);
}

test "MainThreadFileSystem: deferred file RPC owns its arguments and publishes changes on the window" {
    const allocation = std.testing.allocator;
    const io = std.testing.io;
    const Window = @import("../../../../base/common/windowDispatch.zig");
    var scheduler = try @import("ui").WindowIo.init(allocation, io);
    defer scheduler.deinit();
    var window = Window.Queue{ .io = scheduler.io(), .scheduler = &scheduler };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider = disk.DiskFileSystemProvider.init(allocation, io);
    defer provider.deinit();
    provider.attachWindow(&window);
    var service = file_service.ProviderFileService.init(allocation);
    defer service.deinit();
    const registration = try service.registerProvider("file", provider.interface());
    defer registration.dispose();

    const Probe = struct {
        thread: std.Thread.Id,
        event_count: usize = 0,
        received_reply: bool = false,
        failed: bool = false,

        fn change(context: *anyopaque, _: []const @import("../../../../platform/files/common/files.zig").IFileChange) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.failed = self.failed or self.thread != std.Thread.getCurrentId();
            self.event_count += 1;
        }

        fn send(context: *anyopaque, payload: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.failed = self.failed or self.thread != std.Thread.getCurrentId();
            self.received_reply = payload.len > 0 and payload[0] == 7; // ReplyOKEmpty
        }
    };
    var probe = Probe{ .thread = std.Thread.getCurrentId() };
    provider.addChangeListener(.{ .context = &probe, .callback = Probe.change });
    var client = rpc.RpcProtocol.init(allocation, std.testing.io, .{ .context = &probe, .send_fn = Probe.send });
    defer client.deinit();
    var actor = actor_mod.MainThreadFileSystem{ .service = service.interface(), .window = &window, .allocator = allocation };
    defer actor.deinit();

    // Neither the request decoder's arena nor its original binary payload
    // survives the dispatch turn.
    var borrowed = std.heap.ArenaAllocator.init(allocation);
    const reply = blk: {
        defer borrowed.deinit();
        const a = borrowed.allocator();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        var bytes = [_]u8{ 0, 255, 42 };
        const pending = try actor.invokeAsync("$writeFile", &.{ try resource(a, root, "deferred.bin"), .{ .buffer = &bytes } }, a);
        bytes[1] = 0;
        break :blk pending;
    };
    try std.testing.expect(reply == .deferred);
    reply.deferred.start(reply.deferred.context, &client, 42);
    try std.testing.expect(!probe.received_reply);
    try std.testing.expectEqual(@as(usize, 0), probe.event_count);
    _ = window.dispatch(0);
    // The first fiber turn suspends in native stat; the reply and events
    // cannot be emitted until the detached operation completes.
    try std.testing.expect(!probe.received_reply);
    try std.testing.expectEqual(@as(usize, 0), probe.event_count);
    for (0..2000) |_| {
        _ = window.dispatch(0);
        if (probe.received_reply) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(probe.received_reply);
    try std.testing.expect(!probe.failed);
    try std.testing.expectEqual(@as(usize, 1), probe.event_count);
    const contents = try tmp.dir.readFileAlloc(io, "deferred.bin", allocation, .unlimited);
    defer allocation.free(contents);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 42 }, contents);
}

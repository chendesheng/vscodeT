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

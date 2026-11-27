// Regression for the local workspace data sent by
// `src/vs/workbench/api/browser/mainThreadWorkspace.ts`.
const std = @import("std");
const workspace_actor = @import("../../browser/mainThreadWorkspace.zig");
const WorkspaceContext = @import("../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const rpc = @import("../../../services/extensions/common/rpcProtocol.zig");
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const uri = @import("../../../../base/common/stdUri.zig");

test "MainThreadWorkspace: empty and multi-root workspace data" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const io = std.testing.io;
    const workspace = try WorkspaceContext.initEmpty(a, "workspace-test");
    defer workspace.deinit();
    try std.testing.expect((try workspace_actor.workspaceData(scratch, io, workspace)) == .null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "first");
    try tmp.dir.createDirPath(io, "second");
    const first = try tmp.dir.realPathFileAlloc(io, "first", scratch);
    const second = try tmp.dir.realPathFileAlloc(io, "second", scratch);
    try workspace.addFolder(first);
    try workspace.addFolder(second);
    const data = try workspace_actor.workspaceData(scratch, io, workspace);
    const folders = data.object.get("folders").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), folders.len);
    for (folders, [_][]const u8{ first, second }, 0..) |folder, path, index| {
        try std.testing.expectEqual(@as(i64, @intCast(index)), folder.object.get("index").?.integer);
        try std.testing.expectEqualStrings(std.fs.path.basename(path), folder.object.get("name").?.string);
        const wire = try std.Uri.parse(try uri.encodedResourceFromJson(scratch, folder.object.get("uri").?));
        try std.testing.expectEqualStrings(path, try uri.fsPath(wire, scratch));
    }
    // Cancellation short-circuits the same workspaceContains query contract.
    const args = [_]rpc.Arg{ .{ .json = .{ .array = std.json.Array.init(scratch) } }, .{ .json = .{ .array = std.json.Array.init(scratch) } } };
    try std.testing.expect(!try workspace_actor.checkExists(io, a, scratch, &args, CancellationToken.Cancelled));
}

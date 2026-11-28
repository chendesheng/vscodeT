// Port of workspace recommendation validation and ignored-recommendation
// filtering in `src/vs/workbench/contrib/extensions/browser/workspaceRecommendations.ts`.
const std = @import("std");
const recommendations = @import("../../browser/workspaceRecommendations.zig");
const Workspace = @import("../../../../../platform/workspace/common/workspace.zig").Workspace;

test "WorkspaceRecommendations: combine workspace files and exclude ignored IDs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".vscode");
    try tmp.dir.writeFile(io, .{ .sub_path = ".vscode/extensions.json", .data = "{\"recommendations\":[\"Pub.One\",\"pub.two\",\"bad.id.dot\"]}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "example.code-workspace", .data = "{\"extensions\":{\"recommendations\":[\"pub.one\",\"other.three\"],\"unwantedRecommendations\":[\"PUB.TWO\"]}}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var workspace = try Workspace.init(allocator, "example");
    defer workspace.deinit();
    _ = try workspace.addFolder(root, "example");
    const path = try std.fs.path.join(allocator, &.{ root, "example.code-workspace" });
    defer allocator.free(path);
    try workspace.setConfiguration(path);
    const ids = try recommendations.read(allocator, io, &workspace);
    defer {
        for (ids) |id| allocator.free(id);
        allocator.free(ids);
    }
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("pub.one", ids[0]);
    try std.testing.expectEqualStrings("other.three", ids[1]);
}

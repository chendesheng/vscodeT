// Port of `src/vs/workbench/contrib/files/test/browser/explorerModel.test.ts`.
//
// Adapted to the terminal model: paths are strings and children are resolved
// from the local filesystem instead of a test file service.

const std = @import("std");
const explorer = @import("../../common/explorerModel.zig");
const ExplorerItem = explorer.ExplorerItem;
const ExplorerModel = explorer.ExplorerModel;
const workspace_context = @import("../../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;

test "ExplorerItem: properties, children and find" {
    const allocator = std.testing.allocator;
    const root = try ExplorerItem.create(allocator, "/", "/", null, true);
    defer root.destroy();

    const path = try ExplorerItem.create(allocator, "/path", "path", root, true);
    try root.addChild(path);
    const to = try ExplorerItem.create(allocator, "/path/to", "to", path, true);
    try path.addChild(to);
    const file = try ExplorerItem.create(allocator, "/path/to/file.txt", "file.txt", to, false);
    try to.addChild(file);

    try std.testing.expect(root.getChild("path") == path);
    try std.testing.expect(root.find("/path/to/file.txt") == file);
    try std.testing.expect(root.find("/missing") == null);
    try std.testing.expectEqual(@as(usize, 1), path.children.items.len);
}

test "ExplorerItem: move and rename update paths" {
    const allocator = std.testing.allocator;
    const root = try ExplorerItem.create(allocator, "/", "/", null, true);
    defer root.destroy();
    const one = try ExplorerItem.create(allocator, "/one", "one", root, true);
    try root.addChild(one);
    const two = try ExplorerItem.create(allocator, "/two", "two", root, true);
    try root.addChild(two);
    const item = try ExplorerItem.create(allocator, "/one/item", "item", one, false);
    try one.addChild(item);

    try item.move(two);
    try std.testing.expectEqualStrings("/two/item", item.resource);
    try std.testing.expect(two.getChild("item") == item);

    try item.rename("renamed.txt");
    try std.testing.expectEqualStrings("renamed.txt", item.name);
    try std.testing.expectEqualStrings("/two/renamed.txt", item.resource);
    try std.testing.expect(two.getChild("renamed.txt") == item);
}

test "ExplorerModel: finds and resolves children with directories first" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "zdir");
    var file = try tmp.dir.createFile(io, "a.txt", .{});
    file.close(io);

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const model = try ExplorerModel.init(allocator, io, context);
    defer model.deinit();

    const item = model.findClosest(root).?;
    try item.fetchChildren(io, .FilesFirst);
    try std.testing.expectEqual(@as(usize, 2), item.children.items.len);
    try std.testing.expectEqualStrings("zdir", item.children.items[0].name);
    try std.testing.expectEqualStrings("a.txt", item.children.items[1].name);

    const found = try model.findAll(allocator, item.children.items[1].resource);
    defer allocator.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

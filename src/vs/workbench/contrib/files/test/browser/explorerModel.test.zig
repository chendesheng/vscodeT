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
    const root_path = if (std.fs.path.sep == '/') "/" else "C:\\";
    const root = try ExplorerItem.create(allocator, root_path, root_path, null, true);
    defer root.destroy();

    const path_path = try std.fs.path.join(allocator, &.{ root_path, "path" });
    defer allocator.free(path_path);
    const to_path = try std.fs.path.join(allocator, &.{ path_path, "to" });
    defer allocator.free(to_path);
    const file_path = try std.fs.path.join(allocator, &.{ to_path, "file.txt" });
    defer allocator.free(file_path);

    const path = try ExplorerItem.create(allocator, path_path, "path", root, true);
    try root.addChild(path);
    const to = try ExplorerItem.create(allocator, to_path, "to", path, true);
    try path.addChild(to);
    const file = try ExplorerItem.create(allocator, file_path, "file.txt", to, false);
    try to.addChild(file);

    try std.testing.expect(root.getChild("path") == path);
    try std.testing.expect(root.find(file_path) == file);
    try std.testing.expect(root.find("missing") == null);
    try std.testing.expectEqual(@as(usize, 1), path.children.items.len);
}

test "ExplorerItem: move and rename update paths" {
    const allocator = std.testing.allocator;
    const root_path = if (std.fs.path.sep == '/') "/" else "C:\\";
    const one_path = try std.fs.path.join(allocator, &.{ root_path, "one" });
    defer allocator.free(one_path);
    const two_path = try std.fs.path.join(allocator, &.{ root_path, "two" });
    defer allocator.free(two_path);
    const item_path = try std.fs.path.join(allocator, &.{ one_path, "item" });
    defer allocator.free(item_path);
    const moved_path = try std.fs.path.join(allocator, &.{ two_path, "item" });
    defer allocator.free(moved_path);
    const renamed_path = try std.fs.path.join(allocator, &.{ two_path, "renamed.txt" });
    defer allocator.free(renamed_path);

    const root = try ExplorerItem.create(allocator, root_path, root_path, null, true);
    defer root.destroy();
    const one = try ExplorerItem.create(allocator, one_path, "one", root, true);
    try root.addChild(one);
    const two = try ExplorerItem.create(allocator, two_path, "two", root, true);
    try root.addChild(two);
    const item = try ExplorerItem.create(allocator, item_path, "item", one, false);
    try one.addChild(item);

    try item.move(two);
    try std.testing.expectEqualStrings(moved_path, item.resource);
    try std.testing.expect(two.getChild("item") == item);

    try item.rename("renamed.txt");
    try std.testing.expectEqualStrings("renamed.txt", item.name);
    try std.testing.expectEqualStrings(renamed_path, item.resource);
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

test "ExplorerItem: fetchChildren resolves symbolic link targets" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "real");
    var inner = try tmp.dir.createFile(io, "real/inner.txt", .{});
    try inner.writeStreamingAll(io, "inside");
    inner.close(io);
    var real_file = try tmp.dir.createFile(io, "real.txt", .{});
    try real_file.writeStreamingAll(io, "file");
    real_file.close(io);
    try tmp.dir.symLink(io, "real", "dir_link", .{ .is_directory = true });
    try tmp.dir.symLink(io, "real.txt", "file_link", .{});
    try tmp.dir.symLink(io, "missing", "dangling_link", .{});

    const root_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root_path);
    const root = try ExplorerItem.create(allocator, root_path, root_path, null, true);
    defer root.destroy();

    try root.fetchChildren(io, .FilesFirst);

    // Upstream `DiskFileSystemProvider.readdir` resolves a link to its target
    // and keeps the SymbolicLink flag, so the Explorer treats it as a folder.
    const dir_link = root.getChild("dir_link").?;
    try std.testing.expect(dir_link.is_directory);
    try std.testing.expect(dir_link.is_symbolic_link);
    try std.testing.expect(!dir_link.unknown);
    try std.testing.expectEqualStrings("dir_link", std.fs.path.basename(dir_link.resource));

    // Files reached through the linked directory keep the link path.
    try dir_link.fetchChildren(io, .FilesFirst);
    const inner_child = dir_link.getChild("inner.txt").?;
    try std.testing.expect(!inner_child.is_directory);
    try std.testing.expect(!inner_child.is_symbolic_link);
    const expected_resource = try std.fs.path.join(allocator, &.{ root_path, "dir_link", "inner.txt" });
    defer allocator.free(expected_resource);
    try std.testing.expectEqualStrings(expected_resource, inner_child.resource);

    const file_link = root.getChild("file_link").?;
    try std.testing.expect(!file_link.is_directory);
    try std.testing.expect(file_link.is_symbolic_link);
    try std.testing.expect(!file_link.unknown);

    // A dangling link keeps the link itself as an unknown file type.
    const dangling = root.getChild("dangling_link").?;
    try std.testing.expect(!dangling.is_directory);
    try std.testing.expect(dangling.is_symbolic_link);
    try std.testing.expect(dangling.unknown);
}

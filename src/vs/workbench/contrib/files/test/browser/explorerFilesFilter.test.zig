// Port of `src/vs/workbench/contrib/files/test/browser/explorerFilesFilter.test.ts`.
//
// Adapted to the terminal model: `ExplorerItem` resources are path strings and
// the filter reads ignore files through `std.Io.Dir`. The browser test services
// (`TestConfigurationService`, `TestFileService`) are replaced by a real
// temporary configuration file and a temporary workspace folder.

const std = @import("std");
const Io = std.Io;
const explorer = @import("../../common/explorerModel.zig");
const ExplorerItem = explorer.ExplorerItem;
const explorer_viewer = @import("../../browser/views/explorerViewer.zig");
const FilesFilter = explorer_viewer.FilesFilter;
const tree = @import("../../../../../base/browser/ui/tree/tree.zig");
const TreeVisibility = tree.TreeVisibility;
const workspace_context = @import("../../../../services/workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;
const configuration_mod = @import("../../../../services/configuration/browser/configurationService.zig");
const ConfigurationService = configuration_mod.ConfigurationService;

fn writeFile(tmp: *std.testing.TmpDir, io: Io, path: []const u8, contents: []const u8) !void {
    var file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn absoluteRoot(tmp: *std.testing.TmpDir, io: Io, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(io, buffer);
    return buffer[0..len];
}

fn createChild(
    allocator: std.mem.Allocator,
    parent: *ExplorerItem,
    name: []const u8,
    is_directory: bool,
) !*ExplorerItem {
    const resource = try std.fs.path.join(allocator, &.{ parent.resource, name });
    defer allocator.free(resource);
    const item = try ExplorerItem.create(allocator, resource, name, parent, is_directory);
    errdefer item.destroy();
    try parent.addChild(item);
    return item;
}

test "FilesFilter: shows exclude exceptions and the folders leading to them" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{
        \\  "files.exclude": {
        \\    "node_modules": true,
        \\    "*.js": true,
        \\    "!node_modules/@types": true,
        \\    "!gulpfile.js": true
        \\  },
        \\  "explorer.excludeGitIgnore": false
        \\}
    );

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try absoluteRoot(&tmp, io, &root_buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_path});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    const root = try ExplorerItem.create(allocator, root_path, "root", null, true);
    defer root.destroy();
    const node_modules = try createChild(allocator, root, "node_modules", true);
    const types = try createChild(allocator, node_modules, "@types", true);
    const index_types = try createChild(allocator, types, "index.d.ts", false);
    const react = try createChild(allocator, node_modules, "react", true);
    const gulpfile = try createChild(allocator, root, "gulpfile.js", false);
    const index_js = try createChild(allocator, root, "index.js", false);

    var filter = FilesFilter.init(allocator, io, configuration);
    defer filter.deinit();

    const items = [_]*ExplorerItem{ node_modules, types, index_types, react, gulpfile, index_js };
    const expected_visible = [_]bool{ true, true, true, false, true, false };
    var visibility = std.AutoHashMap(*ExplorerItem, TreeVisibility).init(allocator);
    defer visibility.deinit();

    for (items, expected_visible) |item, expected| {
        const parent_visibility = if (item.parent) |parent|
            visibility.get(parent) orelse TreeVisibility.visible
        else
            TreeVisibility.visible;
        const visible = filter.filter(item, parent_visibility);
        try visibility.put(item, if (visible) .visible else .hidden);
        try std.testing.expectEqual(expected, visible);
    }

    try std.testing.expect(!node_modules.is_excluded);
    try std.testing.expect(!types.is_excluded);
    try std.testing.expect(!index_types.is_excluded);
    try std.testing.expect(react.is_excluded);
    try std.testing.expect(!gulpfile.is_excluded);
    try std.testing.expect(index_js.is_excluded);
}

test "FilesFilter: gitignored folders that lead to an exception are not ignored" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.createDirPath(io, "out");
    try writeFile(&tmp, io, ".gitignore", "build/\nout/\n");
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{
        \\  "files.exclude": { "!build/keep.txt": true },
        \\  "explorer.excludeGitIgnore": true
        \\}
    );

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try absoluteRoot(&tmp, io, &root_buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_path});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    const root = try ExplorerItem.create(allocator, root_path, "root", null, true);
    defer root.destroy();
    _ = try createChild(allocator, root, ".gitignore", false);
    const build = try createChild(allocator, root, "build", true);
    const keep = try createChild(allocator, build, "keep.txt", false);
    const out = try createChild(allocator, root, "out", true);

    var filter = FilesFilter.init(allocator, io, configuration);
    defer filter.deinit();
    try filter.prepare(root);

    try std.testing.expect(filter.filter(build, .visible));
    try std.testing.expect(!build.is_excluded);
    try std.testing.expect(!filter.isIgnored(build));
    try std.testing.expect(!filter.isIgnored(keep));
    try std.testing.expect(filter.isIgnored(out));

    try std.testing.expect(!filter.filter(out, .visible));
    try std.testing.expect(out.is_excluded);
    try std.testing.expect(filter.filter(keep, .visible));
    try std.testing.expect(!keep.is_excluded);
}

test "FilesFilter: an open editor keeps excluded files and parents visible" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{
        \\  "files.exclude": { "dist": true },
        \\  "explorer.excludeGitIgnore": false
        \\}
    );

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try absoluteRoot(&tmp, io, &root_buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_path});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    const root = try ExplorerItem.create(allocator, root_path, "root", null, true);
    defer root.destroy();
    const dist = try createChild(allocator, root, "dist", true);
    const app = try createChild(allocator, dist, "app.js", false);

    var filter = FilesFilter.init(allocator, io, configuration);
    defer filter.deinit();

    const OpenState = struct {
        open_path: []const u8,
        fn isOpen(callback_context: *anyopaque, resource: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(callback_context));
            return std.mem.eql(u8, self.open_path, resource) or
                (std.mem.startsWith(u8, self.open_path, resource) and
                    self.open_path.len > resource.len and
                    (self.open_path[resource.len] == '/' or self.open_path[resource.len] == '\\'));
        }
    };
    var open_state = OpenState{ .open_path = app.resource };
    filter.setOpenEditorQuery(.{ .context = &open_state, .is_open = OpenState.isOpen });

    try std.testing.expect(filter.filter(dist, .visible));
    try std.testing.expect(dist.is_excluded);
    try std.testing.expect(filter.filter(app, .visible));
    try std.testing.expect(app.is_excluded);
}

test "FilesFilter: configuration changes invalidate cached root filters" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{
        \\  "files.exclude": { "dist": true },
        \\  "explorer.excludeGitIgnore": false
        \\}
    );

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try absoluteRoot(&tmp, io, &root_buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_path});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    const root = try ExplorerItem.create(allocator, root_path, "root", null, true);
    defer root.destroy();
    const dist = try createChild(allocator, root, "dist", true);

    var filter = FilesFilter.init(allocator, io, configuration);
    defer filter.deinit();
    try std.testing.expect(!filter.filter(dist, .visible));

    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{
        \\  "files.exclude": { "dist": false },
        \\  "explorer.excludeGitIgnore": false
        \\}
    );
    try configuration.reload();
    filter.updateConfiguration();
    try std.testing.expect(filter.filter(dist, .visible));
}

test "FilesFilter: files.exclude sibling clauses use the resolved siblings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{
        \\  "files.exclude": {
        \\    "*.js": { "when": "$(basename).ts" },
        \\    "!keep.js": true
        \\  },
        \\  "explorer.excludeGitIgnore": false
        \\}
    );

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try absoluteRoot(&tmp, io, &root_buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root_path});
    defer context.deinit();
    const configuration = try ConfigurationService.init(allocator, io, context, .{});
    defer configuration.deinit();

    const root = try ExplorerItem.create(allocator, root_path, "root", null, true);
    defer root.destroy();
    const keep_js = try createChild(allocator, root, "keep.js", false);
    _ = try createChild(allocator, root, "keep.ts", false);
    const drop_js = try createChild(allocator, root, "drop.js", false);
    _ = try createChild(allocator, root, "drop.ts", false);
    const other_js = try createChild(allocator, root, "other.js", false);

    var filter = FilesFilter.init(allocator, io, configuration);
    defer filter.deinit();

    try std.testing.expect(filter.filter(keep_js, .visible));
    try std.testing.expect(!keep_js.is_excluded);
    try std.testing.expect(!filter.filter(drop_js, .visible));
    try std.testing.expect(drop_js.is_excluded);
    try std.testing.expect(filter.filter(other_js, .visible));
    try std.testing.expect(!other_js.is_excluded);
}

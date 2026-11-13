// Port of the workspace model in
// `src/vs/platform/workspace/common/workspace.ts`.
//
// Terminal adaptation: workspace folders are canonical path strings instead of
// `URI`s. `Workspace` still owns its folders, exposes folder lookup by parent
// path, and keeps the workbench state (empty/folder/workspace) semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WorkbenchState = enum(u8) {
    EMPTY = 1,
    FOLDER = 2,
    WORKSPACE = 3,
};

pub const WorkspaceFolder = struct {
    resource: []u8,
    name: []u8,
    index: usize,

    pub fn create(allocator: Allocator, resource: []const u8, name: []const u8, index: usize) !WorkspaceFolder {
        const resource_copy = try allocator.dupe(u8, resource);
        errdefer allocator.free(resource_copy);
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        return .{ .resource = resource_copy, .name = name_copy, .index = index };
    }

    pub fn deinit(self: *WorkspaceFolder, allocator: Allocator) void {
        allocator.free(self.resource);
        allocator.free(self.name);
    }

    pub fn toResource(self: *const WorkspaceFolder, allocator: Allocator, relative_path: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.resource, relative_path });
    }
};

pub const Workspace = struct {
    allocator: Allocator,
    id: []u8,
    folders: std.array_list.Managed(WorkspaceFolder),
    /// The workspace configuration file, when this is a saved workspace.
    configuration: ?[]u8 = null,
    name: ?[]u8 = null,

    pub fn init(allocator: Allocator, id: []const u8) !Workspace {
        return .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .folders = std.array_list.Managed(WorkspaceFolder).init(allocator),
        };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.folders.items) |*folder| folder.deinit(self.allocator);
        self.folders.deinit();
        self.allocator.free(self.id);
        if (self.configuration) |value| self.allocator.free(value);
        if (self.name) |value| self.allocator.free(value);
    }

    pub fn addFolder(self: *Workspace, resource: []const u8, name: []const u8) !*WorkspaceFolder {
        const folder = try WorkspaceFolder.create(self.allocator, resource, name, self.folders.items.len);
        try self.folders.append(folder);
        return &self.folders.items[self.folders.items.len - 1];
    }

    pub fn setConfiguration(self: *Workspace, configuration: ?[]const u8) !void {
        if (self.configuration) |value| self.allocator.free(value);
        self.configuration = if (configuration) |value| try self.allocator.dupe(u8, value) else null;
    }

    pub fn setName(self: *Workspace, name: ?[]const u8) !void {
        if (self.name) |value| self.allocator.free(value);
        self.name = if (name) |value| try self.allocator.dupe(u8, value) else null;
    }

    fn pathIsEqualOrParent(resource: []const u8, folder: []const u8) bool {
        if (std.mem.eql(u8, resource, folder)) return true;
        if (!std.mem.startsWith(u8, resource, folder)) return false;
        if (folder.len == 0 or folder[folder.len - 1] == '/') return true;
        return resource[folder.len] == '/';
    }

    /// Returns the closest containing folder, mirroring `getFolder`'s
    /// `findSubstr` behavior.
    pub fn getFolder(self: *const Workspace, resource: []const u8) ?*const WorkspaceFolder {
        var best: ?*const WorkspaceFolder = null;
        for (self.folders.items) |*folder| {
            if (pathIsEqualOrParent(resource, folder.resource)) {
                if (best == null or folder.resource.len > best.?.resource.len) best = folder;
            }
        }
        return best;
    }
};

test "Workspace: folders and closest lookup" {
    const allocator = std.testing.allocator;
    var workspace = try Workspace.init(allocator, "test");
    defer workspace.deinit();

    _ = try workspace.addFolder("/root", "root");
    _ = try workspace.addFolder("/root/sub", "sub");

    try std.testing.expectEqualStrings("root", workspace.getFolder("/root/file.txt").?.name);
    try std.testing.expectEqualStrings("sub", workspace.getFolder("/root/sub/file.txt").?.name);
    try std.testing.expect(workspace.getFolder("/other/file.txt") == null);
}

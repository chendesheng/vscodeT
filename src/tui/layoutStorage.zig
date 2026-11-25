// Native workspace/profile storage for the LayoutStateKeys in layout.ts.
// The terminal profile keeps machine-local layout values in atomic JSON files.
const std = @import("std");
const storage = @import("../vs/platform/storage/common/storage.zig");
const Layout = @import("../vs/workbench/browser/layout.zig").Layout;
const WorkspaceFolder = @import("../vs/platform/workspace/common/workspace.zig").WorkspaceFolder;
const WillShutdownEvent = @import("../vs/workbench/services/lifecycle/common/lifecycle.zig").WillShutdownEvent;

pub const LayoutStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    layout: *Layout,
    restored_workspace: ?std.json.Parsed(Layout.WorkspaceState) = null,
    workspace_path: ?[]const u8,
    profile_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, layout: *Layout, folders: []const WorkspaceFolder, profile: []const u8, session: ?[]const u8) !LayoutStorage {
        const profile_path = try std.fs.path.join(allocator, &.{ profile, "User", "globalStorage", "layout.state.json" });
        errdefer allocator.free(profile_path);
        // An empty window has no folder identity. An explicit session path
        // identifies that window across launches.
        const workspace_path = if (folders.len > 0) blk: {
            const root = try std.fs.path.join(allocator, &.{ profile, "User", "workspaceStorage" });
            defer allocator.free(root);
            break :blk try @import("../vs/platform/storage/common/storage.zig").workspaceFolderStatePath(allocator, root, folders, "layout.state.json");
        } else if (session) |session_path| blk: {
            const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
            defer allocator.free(absolute);
            const resolved = try std.fs.path.resolve(allocator, &.{ absolute, session_path });
            defer allocator.free(resolved);
            var key: [16]u8 = undefined;
            const id = try std.fmt.bufPrint(&key, "{x:0>16}", .{std.hash.Wyhash.hash(0, resolved)});
            break :blk try std.fs.path.join(allocator, &.{ profile, "User", "workspaceStorage", id, "layout.state.json" });
        } else null;
        return .{ .allocator = allocator, .io = io, .layout = layout, .profile_path = profile_path, .workspace_path = workspace_path };
    }

    pub fn deinit(self: *LayoutStorage) void {
        if (self.restored_workspace) |parsed| parsed.deinit();
        self.allocator.free(self.profile_path);
        if (self.workspace_path) |path| self.allocator.free(path);
    }

    pub fn load(self: *LayoutStorage, reset_layout: bool) !?Layout.WorkspaceState {
        if (reset_layout) return null;
        if (try storage.readStateFile(Layout.ProfileState, self.allocator, self.io, self.profile_path)) |profile| {
            defer profile.deinit();
            try self.layout.restorePartSizes(profile.value);
        }
        const path = self.workspace_path orelse return null;
        const workspace = (try storage.readStateFile(Layout.WorkspaceState, self.allocator, self.io, path)) orelse return null;
        if (self.restored_workspace) |previous| previous.deinit();
        self.restored_workspace = workspace;
        return workspace.value;
    }

    pub fn save(_: WillShutdownEvent, self: *LayoutStorage) !void {
        try self.persist();
    }

    pub fn onWillSaveState(_: @import("../vs/platform/storage/common/storage.zig").IWillSaveStateEvent, self: *LayoutStorage) !void {
        try self.persist();
    }

    fn persist(self: *LayoutStorage) !void {
        if (self.workspace_path) |path| try storage.writeStateFile(self.allocator, self.io, path, self.layout.workspaceState());
        try storage.writeStateFile(self.allocator, self.io, self.profile_path, self.layout.profileState());
    }
};

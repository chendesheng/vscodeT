// Native workspace/profile storage for the LayoutStateKeys in layout.ts.
// The terminal profile keeps machine-local layout values in atomic JSON files.
const std = @import("std");
const Layout = @import("../vs/workbench/browser/layout.zig").Layout;
const Workbench = @import("workbench.zig").Workbench;
const WillShutdownEvent = @import("../vs/workbench/services/lifecycle/common/lifecycle.zig").WillShutdownEvent;

pub const LayoutStorage = struct {
    workbench: *Workbench,
    workspace_path: ?[]const u8,
    profile_path: []const u8,

    pub fn init(workbench: *Workbench, profile: []const u8, session: ?[]const u8) !LayoutStorage {
        const allocator = workbench.allocator;
        const profile_path = try std.fs.path.join(allocator, &.{ profile, "User", "globalStorage", "layout.state.json" });
        errdefer allocator.free(profile_path);
        const folders = workbench.workspace.getWorkspace().folders.items;
        // An empty window has no folder identity. An explicit session path
        // identifies that window across launches.
        const workspace_path = if (folders.len > 0) blk: {
            const root = try std.fs.path.join(allocator, &.{ profile, "User", "workspaceStorage" });
            defer allocator.free(root);
            break :blk try @import("../vs/platform/storage/common/storage.zig").workspaceFolderStatePath(allocator, root, folders, "layout.state.json");
        } else if (session) |session_path| blk: {
            const absolute = try std.Io.Dir.cwd().realPathFileAlloc(workbench.io, ".", allocator);
            defer allocator.free(absolute);
            const resolved = try std.fs.path.resolve(allocator, &.{ absolute, session_path });
            defer allocator.free(resolved);
            var key: [16]u8 = undefined;
            const id = try std.fmt.bufPrint(&key, "{x:0>16}", .{std.hash.Wyhash.hash(0, resolved)});
            break :blk try std.fs.path.join(allocator, &.{ profile, "User", "workspaceStorage", id, "layout.state.json" });
        } else null;
        return .{ .workbench = workbench, .profile_path = profile_path, .workspace_path = workspace_path };
    }

    pub fn deinit(self: *LayoutStorage) void {
        self.workbench.allocator.free(self.profile_path);
        if (self.workspace_path) |path| self.workbench.allocator.free(path);
    }

    pub fn load(self: *LayoutStorage, reset_layout: bool) !void {
        if (reset_layout) return;
        const wb = self.workbench;
        if (try self.read(Layout.ProfileState, self.profile_path)) |profile| {
            defer profile.deinit();
            try wb.layout.restorePartSizes(profile.value);
        }
        const path = self.workspace_path orelse return;
        const workspace = (try self.read(Layout.WorkspaceState, path)) orelse return;
        defer workspace.deinit();
        var state = workspace.value;
        if (state.@"workbench.panelpart.activepanelid") |id| {
            const focus = wb.focus;
            const opened = try wb.openPanelContainer(id);
            if (!opened) state.@"workbench.panel.hidden" = true;
            switch (focus) {
                .sidebar => wb.focusSidebar(),
                .statusbar => wb.focusStatusBar(),
                else => wb.focusEditor(),
            }
        }
        try wb.layout.restoreParts(state);
    }

    pub fn save(_: WillShutdownEvent, self: *LayoutStorage) !void {
        const wb = self.workbench;
        if (self.workspace_path) |path| try self.write(path, wb.layout.workspaceState(wb.panel_part.pane.active_id));
        try self.write(self.profile_path, Layout.ProfileState{
            .@"workbench.sideBar.size" = wb.sidebar_part.width,
            .@"workbench.panel.size" = wb.panel_part.getSize(),
        });
    }

    fn read(self: *LayoutStorage, comptime T: type, path: []const u8) !?std.json.Parsed(T) {
        const wb = self.workbench;
        const bytes = std.Io.Dir.cwd().readFileAlloc(wb.io, path, wb.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer wb.allocator.free(bytes);
        return try std.json.parseFromSlice(T, wb.allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    }

    fn write(self: *LayoutStorage, path: []const u8, value: anytype) !void {
        const wb = self.workbench;
        const bytes = try std.json.Stringify.valueAlloc(wb.allocator, value, .{});
        defer wb.allocator.free(bytes);
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(wb.io, std.fs.path.dirname(path).?);
        var atomic = try cwd.createFileAtomic(wb.io, path, .{ .replace = true });
        defer atomic.deinit(wb.io);
        try atomic.file.writeStreamingAll(wb.io, bytes);
        try atomic.replace(wb.io);
    }
};

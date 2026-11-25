// Native workspace/profile storage for the LayoutStateKeys in layout.ts.
// The terminal profile keeps machine-local layout values in atomic JSON files.
const std = @import("std");
const storage = @import("../vs/platform/storage/common/storage.zig");
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

    pub fn load(self: *LayoutStorage, reset_layout: bool) !?Layout.WorkspaceState {
        if (reset_layout) return null;
        const wb = self.workbench;
        if (try storage.readStateFile(Layout.ProfileState, wb.allocator, wb.io, self.profile_path)) |profile| {
            defer profile.deinit();
            try wb.layout.restorePartSizes(profile.value);
        }
        const path = self.workspace_path orelse return null;
        const workspace = (try storage.readStateFile(Layout.WorkspaceState, wb.allocator, wb.io, path)) orelse return null;
        defer workspace.deinit();
        var state = workspace.value;
        if (state.@"workbench.panelpart.activepanelid") |id| {
            const opened = try wb.pane_composite_api.openPaneComposite(id, .panel, false);
            if (!opened) state.@"workbench.panel.hidden" = true;
        }
        // The panel composite owns the selected ID after opening.
        state.@"workbench.panelpart.activepanelid" = null;
        return state;
    }

    pub fn save(_: WillShutdownEvent, self: *LayoutStorage) !void {
        const wb = self.workbench;
        if (self.workspace_path) |path| try storage.writeStateFile(wb.allocator, wb.io, path, wb.layout.workspaceState(wb.pane_composite_api.getLastActivePaneCompositeId(.panel)));
        try storage.writeStateFile(wb.allocator, wb.io, self.profile_path, Layout.ProfileState{
            .@"workbench.sideBar.size" = wb.sidebar_part.width,
            .@"workbench.panel.size" = wb.panel_part.getSize(),
        });
    }
};

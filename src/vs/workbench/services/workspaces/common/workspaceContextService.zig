// Port of the portable `IWorkspaceContextService` behavior used by the
// workbench. Upstream the full service lives in
// `src/vs/workbench/services/configuration/browser/configurationService.ts`
// and is backed by configuration/storage/remote services; this terminal
// implementation mirrors the `TestContextService` shape for the pieces the
// Explorer and workbench need: workspace folders, workbench state and folder
// lookup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const workspace_mod = @import("../../../../platform/workspace/common/workspace.zig");
const Workspace = workspace_mod.Workspace;
const WorkspaceFolder = workspace_mod.WorkspaceFolder;
const WorkbenchState = workspace_mod.WorkbenchState;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

/// IWorkspaceFoldersChangeEvent. Folder references are valid for the
/// synchronous event delivery, including removed folders from the old model.
pub const WorkspaceFoldersChangeEvent = struct {
    added: []const WorkspaceFolder = &.{},
    removed: []const WorkspaceFolder = &.{},
    changed: []const WorkspaceFolder = &.{},
};

pub const WorkspaceContextService = struct {
    allocator: Allocator,
    workspace: Workspace,
    owned: bool = true,
    on_did_add_folder: Emitter([]const u8),
    on_did_change_workspace_folders: Emitter(WorkspaceFoldersChangeEvent),

    pub fn initEmpty(allocator: Allocator, id: []const u8) !*WorkspaceContextService {
        const self = try allocator.create(WorkspaceContextService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .workspace = try Workspace.init(allocator, id),
            .on_did_add_folder = .init(allocator),
            .on_did_change_workspace_folders = .init(allocator),
        };
        return self;
    }

    pub fn initWithFolders(allocator: Allocator, id: []const u8, folders: []const []const u8) !*WorkspaceContextService {
        const self = try initEmpty(allocator, id);
        errdefer self.deinit();
        for (folders) |folder| {
            try self.addFolder(folder);
        }
        return self;
    }

    pub fn deinit(self: *WorkspaceContextService) void {
        self.on_did_add_folder.deinit();
        self.on_did_change_workspace_folders.deinit();
        self.workspace.deinit();
        self.allocator.destroy(self);
    }

    pub fn getWorkspace(self: *WorkspaceContextService) *Workspace {
        return &self.workspace;
    }

    pub fn addFolder(self: *WorkspaceContextService, resource: []const u8) !void {
        const name = std.fs.path.basename(resource);
        const folder = try self.workspace.addFolder(resource, name);
        const added = [_]WorkspaceFolder{folder.*};
        self.on_did_add_folder.fire(added[0].resource) catch {};
        self.on_did_change_workspace_folders.fire(.{ .added = &added }) catch {};
    }

    /// Update the portable workspace without replacing the service and its
    /// listeners. The configuration owner publishes the folder event once
    /// the new configuration has been loaded. The replacement then owns
    /// the prior workspace until delivery is complete.
    pub fn swapWorkspace(self: *WorkspaceContextService, replacement: *WorkspaceContextService) void {
        std.mem.swap(Workspace, &self.workspace, &replacement.workspace);
    }

    pub fn notifyWorkspaceFoldersChanged(self: *WorkspaceContextService, previous: *const Workspace) !void {
        var added: std.ArrayList(WorkspaceFolder) = .empty;
        defer added.deinit(self.allocator);
        var removed: std.ArrayList(WorkspaceFolder) = .empty;
        defer removed.deinit(self.allocator);
        var changed: std.ArrayList(WorkspaceFolder) = .empty;
        defer changed.deinit(self.allocator);
        for (self.workspace.folders.items) |folder| {
            if (findFolder(previous.folders.items, folder.resource)) |old| {
                if (old.index != folder.index or !std.mem.eql(u8, old.name, folder.name)) try changed.append(self.allocator, folder);
            } else try added.append(self.allocator, folder);
        }
        for (previous.folders.items) |folder| {
            if (findFolder(self.workspace.folders.items, folder.resource) == null) try removed.append(self.allocator, folder);
        }
        if (added.items.len == 0 and removed.items.len == 0 and changed.items.len == 0) return;
        try self.on_did_change_workspace_folders.fire(.{ .added = added.items, .removed = removed.items, .changed = changed.items });
    }

    fn findFolder(folders: []const WorkspaceFolder, path: []const u8) ?WorkspaceFolder {
        for (folders) |folder| if (std.mem.eql(u8, folder.resource, path)) return folder;
        return null;
    }

    pub fn setConfiguration(self: *WorkspaceContextService, configuration: ?[]const u8) !void {
        try self.workspace.setConfiguration(configuration);
    }

    pub fn getWorkbenchState(self: *const WorkspaceContextService) WorkbenchState {
        if (self.workspace.configuration != null) return .WORKSPACE;
        if (self.workspace.folders.items.len > 0) return .FOLDER;
        return .EMPTY;
    }

    pub fn hasWorkspaceData(self: *const WorkspaceContextService) bool {
        return self.getWorkbenchState() != .EMPTY;
    }

    pub fn getWorkspaceFolder(self: *const WorkspaceContextService, resource: []const u8) ?*const WorkspaceFolder {
        return self.workspace.getFolder(resource);
    }

    pub fn isInsideWorkspace(self: *const WorkspaceContextService, resource: []const u8) bool {
        return self.getWorkspaceFolder(resource) != null;
    }
};

test "WorkspaceContextService: workbench state and folder lookup" {
    const allocator = std.testing.allocator;
    const empty = try WorkspaceContextService.initEmpty(allocator, "empty");
    defer empty.deinit();
    try std.testing.expectEqual(WorkbenchState.EMPTY, empty.getWorkbenchState());
    try std.testing.expect(!empty.hasWorkspaceData());

    const folder = try WorkspaceContextService.initWithFolders(allocator, "folder", &.{"/repo"});
    defer folder.deinit();
    try std.testing.expectEqual(WorkbenchState.FOLDER, folder.getWorkbenchState());
    try std.testing.expect(folder.isInsideWorkspace("/repo/src/main.zig"));
    try std.testing.expect(!folder.isInsideWorkspace("/other/main.zig"));
    try std.testing.expectEqualStrings("repo", folder.getWorkspaceFolder("/repo/src/main.zig").?.name);
}

test "WorkspaceContextService: replacement reports added removed and reordered folders after update" {
    const allocator = std.testing.allocator;
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{ "/old", "/kept" });
    defer context.deinit();
    const replacement = try WorkspaceContextService.initWithFolders(allocator, "test", &.{ "/kept", "/new" });
    defer replacement.deinit();
    const Probe = struct {
        context: *WorkspaceContextService,
        calls: usize = 0,
        fn changed(event: WorkspaceFoldersChangeEvent, self: *@This()) !void {
            self.calls += 1;
            try std.testing.expectEqual(@as(usize, 1), event.added.len);
            try std.testing.expectEqualStrings("/new", event.added[0].resource);
            try std.testing.expectEqual(@as(usize, 1), event.removed.len);
            try std.testing.expectEqualStrings("/old", event.removed[0].resource);
            try std.testing.expectEqual(@as(usize, 1), event.changed.len);
            try std.testing.expectEqualStrings("/kept", event.changed[0].resource);
            try std.testing.expect(self.context.getWorkspaceFolder("/old") == null);
            try std.testing.expect(self.context.getWorkspaceFolder("/new") != null);
        }
    };
    var probe: Probe = .{ .context = context };
    const listener = try context.on_did_change_workspace_folders.listenDisposable(&probe, Probe.changed);
    defer listener.dispose();
    context.swapWorkspace(replacement);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try context.notifyWorkspaceFoldersChanged(replacement.getWorkspace());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

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

pub const WorkspaceContextService = struct {
    allocator: Allocator,
    workspace: Workspace,
    owned: bool = true,
    on_did_add_folder: @import("../../../../base/common/event.zig").Emitter([]const u8),

    pub fn initEmpty(allocator: Allocator, id: []const u8) !*WorkspaceContextService {
        const self = try allocator.create(WorkspaceContextService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .workspace = try Workspace.init(allocator, id),
            .on_did_add_folder = .init(allocator),
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
        self.workspace.deinit();
        self.allocator.destroy(self);
    }

    pub fn getWorkspace(self: *WorkspaceContextService) *Workspace {
        return &self.workspace;
    }

    pub fn addFolder(self: *WorkspaceContextService, resource: []const u8) !void {
        const name = std.fs.path.basename(resource);
        const folder = try self.workspace.addFolder(resource, name);
        self.on_did_add_folder.fire(folder.resource) catch {};
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

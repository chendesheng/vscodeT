// Native adapter for github.publish in vscode/extensions/github/src/commands.ts.
// The terminal currently delegates the interactive publish workflow to GitHub
// CLI; the extension's Octokit-based repository picker is not ported.
const std = @import("std");
const Repository = @import("../../git/src/repository.zig").Repository;
const WorkspaceContextService = @import("../../../vs/workbench/services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const TerminalActionServices = @import("../../../vs/workbench/contrib/terminal/browser/terminalActions.zig").TerminalActionServices;
const profiles = @import("../../../vs/platform/terminal/node/terminalProfiles.zig");
const Action2 = @import("../../../vs/platform/actions/common/actions.zig").Action2;
const Accessor = @import("../../../vs/platform/instantiation/common/instantiation.zig").ServicesAccessor;

pub const PublishCommand = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    repository: *const ?*Repository,
    workspace: *const *WorkspaceContextService,
    terminal: *TerminalActionServices,
    status_context: *anyopaque,
    report_status: *const fn (*anyopaque, []const u8) void,

    pub fn descriptor(self: *PublishCommand) Action2 {
        return .{
            .command = .{ .id = "github.publish", .title = "Publish to GitHub", .category = "GitHub" },
            .f1 = true,
            .context = self,
            .run_fn = run,
        };
    }

    fn run(context: *anyopaque, _: Accessor) !void {
        const self: *PublishCommand = @ptrCast(@alignCast(context));
        const folders = self.workspace.*.getWorkspace().folders.items;
        const folder = if (self.repository.*) |provider| provider.root else if (folders.len > 0) folders[0].resource else {
            self.report_status(self.status_context, "Open a folder to publish to GitHub");
            return;
        };
        const executable = try profiles.findTerminalExecutable(self.allocator, self.io, "gh") orelse {
            self.report_status(self.status_context, "Install GitHub CLI and add gh to PATH to publish a repository");
            return;
        };
        defer self.allocator.free(executable);
        _ = try self.terminal.launchProcess("Publish to GitHub", executable, &.{ "repo", "create" }, folder);
    }
};

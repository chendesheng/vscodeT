// Terminal adaptation of vscode/extensions/git/src/statusbar.ts. Git's
// checkout and sync commands are projected into one native entry while the
// full checkout/sync command UI is unported. The SCM contribution consumes
// the provider's statusBarCommands instead of reading Git state itself.
const std = @import("std");
const GitRepositoryState = @import("../../../vs/workbench/contrib/git/common/gitService.zig").GitRepositoryState;
const Command = @import("../../../vs/editor/common/languages.zig").Command;

pub const StatusBarCommands = struct {
    title_buffer: [96]u8 = undefined,
    commands: [1]Command = undefined,

    pub fn update(self: *StatusBarCommands, state: *const GitRepositoryState, resource_count: usize) []const Command {
        const branch = if (state.head) |head| head.ref.name orelse "" else "";
        const ahead = if (state.head) |head| head.ahead orelse 0 else 0;
        const behind = if (state.head) |head| head.behind orelse 0 else 0;
        const title = if (branch.len > 0)
            std.fmt.bufPrint(&self.title_buffer, "\u{2387} {s} \u{2191}{d} \u{2193}{d} ({d})", .{ branch, ahead, behind, resource_count }) catch "Git"
        else
            std.fmt.bufPrint(&self.title_buffer, "\u{2387} (detached) ({d})", .{resource_count}) catch "Git";
        self.commands[0] = .{ .id = "workbench.view.scm", .title = title };
        return &self.commands;
    }
};

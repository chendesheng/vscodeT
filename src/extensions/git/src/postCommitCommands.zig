// Port of the Git-provided secondary command groups in
// vscode/extensions/git/src/postCommitCommands.ts. The native extension uses
// its explicit CommitAction argument instead of JS sourceControl objects.
// Branch-protection prompts, third-party providers and persisted default
// command preferences remain unported.
const Descriptor = @import("../../../vs/workbench/contrib/scm/common/scm.zig").CommitActionDescriptor;

const commit_commands = [_]Descriptor{
    .{ .id = "git.commit", .title = "Commit", .action = .commit },
    .{ .id = "git.commitAmend", .title = "Commit (Amend)", .action = .amend },
};
const post_commit_commands = [_]Descriptor{
    .{ .id = "git.commit", .title = "Commit & Push", .action = .push },
    .{ .id = "git.commit", .title = "Commit & Sync", .action = .sync },
};
const secondary_commands = [_][]const Descriptor{ &commit_commands, &post_commit_commands };

pub fn getSecondaryCommands() []const []const Descriptor {
    return &secondary_commands;
}

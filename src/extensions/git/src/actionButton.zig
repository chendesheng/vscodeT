// Terminal projection of vscode/extensions/git/src/actionButton.ts.
// The native SCM view owns commit-button enabled state and its dropdown; this
// module owns the repository-dependent Publish Branch / Sync Changes choices.
// Operation-in-progress, branch protection and post-commit preference state
// remain to be ported from the upstream ActionButton and CommitCommandsCenter.
const GitRepositoryState = @import("../../../vs/workbench/contrib/git/common/gitService.zig").GitRepositoryState;
const BranchAction = @import("../../../vs/workbench/contrib/scm/common/scm.zig").BranchAction;

pub fn branchAction(state: *const GitRepositoryState) ?BranchAction {
    const head = state.head orelse return null;
    const ahead = head.ahead orelse 0;
    const behind = head.behind orelse 0;
    if (head.upstream != null and (ahead > 0 or behind > 0)) return .{ .sync = .{ .ahead = ahead, .behind = behind } };
    if (head.ref.name != null and head.upstream == null and state.remotes.len != 0) return .publish;
    return null;
}

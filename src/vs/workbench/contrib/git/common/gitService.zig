// Port of `src/vs/workbench/contrib/git/common/gitService.ts`.
//
// Terminal adaptations:
// - Resources are local filesystem paths (`[]const u8`) instead of `URI`.
//   The terminal workbench has one process and no cross-process git file-system
//   provider, so the URI indirection collapses to paths.
// - `Promise` becomes a synchronous `!T` return, and `IObservable` becomes a
//   state getter plus a change event. The observable system is not ported.
// - `readonly` interface fields are plain fields on the vtable structs.
const std = @import("std");
const Allocator = std.mem.Allocator;

const cancellation = @import("../../../../base/common/cancellation.zig");
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const CancellationToken = cancellation.CancellationToken;

pub const GitRefType = enum {
    head,
    remote_head,
    tag,
};

pub const GitRef = struct {
    ref_type: GitRefType,
    name: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    remote: ?[]const u8 = null,
};

pub fn freeGitRefs(allocator: Allocator, refs: []GitRef) void {
    for (refs) |ref| {
        if (ref.name) |value| allocator.free(value);
        if (ref.commit) |value| allocator.free(value);
        if (ref.remote) |value| allocator.free(value);
    }
    if (refs.len > 0) allocator.free(refs);
}

pub fn freeGitDiffChanges(allocator: Allocator, changes: []GitDiffChange) void {
    for (changes) |change| {
        allocator.free(change.change.path);
        if (change.change.original_path) |value| allocator.free(value);
        if (change.change.modified_path) |value| allocator.free(value);
    }
    if (changes.len > 0) allocator.free(changes);
}

pub const GitRefSort = enum {
    alphabetically,
    committerdate,
    creatordate,
};

pub const GitRefQuery = struct {
    contains: ?[]const u8 = null,
    count: ?usize = null,
    pattern: ?[]const u8 = null,
    /// Terminal extension: `for-each-ref` accepts several patterns. Upstream
    /// passes them via the `pattern` array form.
    patterns: []const []const u8 = &.{},
    sort: ?GitRefSort = null,
};

pub const GitChange = struct {
    path: []const u8,
    original_path: ?[]const u8 = null,
    modified_path: ?[]const u8 = null,
    /// Terminal adaptation: the v2 status letter (`M`, `A`, `D`, `R`, `U`,
    /// `?`, ...). Upstream's SCM extension derives this from its status map;
    /// the CLI parser records it so the terminal SCM view can paint it.
    status: u8 = 0,
    /// Porcelain v2 `XY` pair for an unmerged entry (`u` record). Upstream
    /// maps the seven conflict pairs to distinct statuses; the port keeps the
    /// pair so the Git provider can produce the same letters/tooltips.
    conflict: ?[2]u8 = null,
    /// A Gitlink reported by the porcelain v2 submodule field.
    submodule: bool = false,
};

pub const GitDiffChange = struct {
    change: GitChange,
    insertions: usize = 0,
    deletions: usize = 0,
};

pub const GitCommitShortStat = struct {
    files: usize = 0,
    insertions: usize = 0,
    deletions: usize = 0,
};

/// Terminal port of the extension `Commit` (upstream `api/git.d.ts`). Dates are
/// epoch seconds, like the `%at`/`%ct` placeholders; the history provider
/// converts them to the millisecond `timestamp` of the SCM contract.
pub const GitCommit = struct {
    hash: []const u8,
    message: []const u8,
    parents: []const []const u8,
    author_name: []const u8,
    author_email: []const u8,
    author_date: ?i64 = null,
    commit_date: ?i64 = null,
    ref_names: []const []const u8 = &.{},
    short_stat: ?GitCommitShortStat = null,

    pub fn clone(self: GitCommit, allocator: Allocator) !GitCommit {
        const hash = try allocator.dupe(u8, self.hash);
        errdefer allocator.free(hash);
        const message = try allocator.dupe(u8, self.message);
        errdefer allocator.free(message);
        const author_name = try allocator.dupe(u8, self.author_name);
        errdefer allocator.free(author_name);
        const author_email = try allocator.dupe(u8, self.author_email);
        errdefer allocator.free(author_email);
        const parents = try allocator.alloc([]const u8, self.parents.len);
        errdefer allocator.free(parents);
        var parents_owned: usize = 0;
        errdefer for (parents[0..parents_owned]) |parent| allocator.free(parent);
        for (self.parents, 0..) |parent, index| {
            parents[index] = try allocator.dupe(u8, parent);
            parents_owned = index + 1;
        }
        const ref_names = try allocator.alloc([]const u8, self.ref_names.len);
        errdefer allocator.free(ref_names);
        var refs_owned: usize = 0;
        errdefer for (ref_names[0..refs_owned]) |name| allocator.free(name);
        for (self.ref_names, 0..) |name, index| {
            ref_names[index] = try allocator.dupe(u8, name);
            refs_owned = index + 1;
        }
        return .{
            .hash = hash,
            .message = message,
            .parents = parents,
            .author_name = author_name,
            .author_email = author_email,
            .author_date = self.author_date,
            .commit_date = self.commit_date,
            .ref_names = ref_names,
            .short_stat = self.short_stat,
        };
    }

    pub fn deinit(self: *GitCommit, allocator: Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.message);
        allocator.free(self.author_name);
        allocator.free(self.author_email);
        for (self.parents) |parent| allocator.free(parent);
        if (self.parents.len > 0) allocator.free(self.parents);
        for (self.ref_names) |name| allocator.free(name);
        if (self.ref_names.len > 0) allocator.free(self.ref_names);
        self.* = undefined;
    }
};

pub fn freeGitCommits(allocator: Allocator, commits: []GitCommit) void {
    for (commits) |*commit| commit.deinit(allocator);
    if (commits.len > 0) allocator.free(commits);
}

/// Port of the extension `LogOptions`: `refNames` is nullable and may be empty,
/// `range` is the upstream `range` shorthand, `maxParents` filters roots.
pub const GitLogOptions = struct {
    ref_names: ?[]const []const u8 = null,
    range: ?[]const u8 = null,
    max_entries: ?usize = null,
    skip: ?usize = null,
    author: ?[]const u8 = null,
    grep: ?[]const u8 = null,
    max_parents: ?usize = null,
    short_stats: bool = false,
    /// Terminal extension: use `--all` instead of listing every revision.
    all_refs: bool = false,
};

pub const GitRemote = struct {
    name: []const u8,
    fetch_url: ?[]const u8 = null,
    push_url: ?[]const u8 = null,
    is_read_only: bool = false,
};

pub const GitBranch = struct {
    ref: GitRef,
    upstream: ?GitUpstreamRef = null,
    ahead: ?usize = null,
    behind: ?usize = null,

    pub fn deinit(self: *GitBranch, allocator: Allocator) void {
        if (self.ref.name) |name| allocator.free(name);
        if (self.ref.commit) |commit| allocator.free(commit);
        if (self.ref.remote) |remote| allocator.free(remote);
        if (self.upstream) |*upstream| {
            allocator.free(upstream.remote);
            allocator.free(upstream.name);
            if (upstream.commit) |commit| allocator.free(commit);
        }
        self.* = undefined;
    }
};

pub fn freeGitBranches(allocator: Allocator, branches: []GitBranch) void {
    for (branches) |*branch| branch.deinit(allocator);
    if (branches.len > 0) allocator.free(branches);
}

pub const GitBaseRef = struct {
    name: []const u8,
    is_protected: bool,
};

pub const GitUpstreamRef = struct {
    remote: []const u8,
    name: []const u8,
    commit: ?[]const u8 = null,
};

pub const GitCommitOptions = struct {
    amend: bool = false,
    /// Skips the pre-commit and commit-msg hooks.
    no_verify: ?bool = null,
    /// Overrides whether the commit is signed. Leaves the user's signing
    /// configuration in effect when null.
    sign_commit: ?bool = null,
};

/// Mirror of the Git extension's Submodule descriptor. The native Git
/// repository state carries this metadata with its status snapshot.
pub const GitSubmodule = struct {
    name: []const u8,
    path: []const u8,
    url: []const u8,

    pub fn deinit(self: GitSubmodule, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.url);
    }

    pub fn clone(self: GitSubmodule, allocator: Allocator) !GitSubmodule {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(path);
        return .{ .name = name, .path = path, .url = try allocator.dupe(u8, self.url) };
    }
};

/// Git extension Worktree descriptor, captured alongside the status snapshot.
pub const GitWorktree = struct {
    name: []const u8,
    path: []const u8,
    ref: []const u8,
    detached: bool,
    main: bool,

    pub fn deinit(self: GitWorktree, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.ref);
    }

    pub fn clone(self: GitWorktree, allocator: Allocator) !GitWorktree {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(path);
        return .{ .name = name, .path = path, .ref = try allocator.dupe(u8, self.ref), .detached = self.detached, .main = self.main };
    }
};

pub const GitRepositoryState = struct {
    head: ?GitBranch = null,
    remotes: []GitRemote = &.{},
    submodules: []GitSubmodule = &.{},
    worktrees: []GitWorktree = &.{},
    is_worktree: bool = false,
    merge_changes: []GitChange = &.{},
    index_changes: []GitChange = &.{},
    working_tree_changes: []GitChange = &.{},
    untracked_changes: []GitChange = &.{},

    /// Structural equality, matching upstream's `structuralEquals` observable
    /// comparer. Used to suppress no-op state change events.
    pub fn eql(a: GitRepositoryState, b: GitRepositoryState) bool {
        if (!optionalBranchEql(a.head, b.head)) return false;
        if (!remotesEql(a.remotes, b.remotes)) return false;
        if (!submodulesEql(a.submodules, b.submodules)) return false;
        if (a.is_worktree != b.is_worktree or !worktreesEql(a.worktrees, b.worktrees)) return false;
        if (!changesEql(a.merge_changes, b.merge_changes)) return false;
        if (!changesEql(a.index_changes, b.index_changes)) return false;
        if (!changesEql(a.working_tree_changes, b.working_tree_changes)) return false;
        if (!changesEql(a.untracked_changes, b.untracked_changes)) return false;
        return true;
    }

    /// Frees every owned slice in the state. States produced by the git CLI own
    /// their strings; callers that only borrow state data must not call this.
    pub fn deinit(self: *GitRepositoryState, allocator: Allocator) void {
        if (self.head) |*head| {
            freeRef(&head.ref, allocator);
            if (head.upstream) |*upstream| {
                allocator.free(upstream.remote);
                allocator.free(upstream.name);
                if (upstream.commit) |commit| allocator.free(commit);
            }
        }
        for (self.remotes) |remote| {
            allocator.free(remote.name);
            if (remote.fetch_url) |url| allocator.free(url);
            if (remote.push_url) |url| allocator.free(url);
        }
        if (self.remotes.len > 0) allocator.free(self.remotes);
        for (self.submodules) |submodule| submodule.deinit(allocator);
        if (self.submodules.len > 0) allocator.free(self.submodules);
        for (self.worktrees) |worktree| worktree.deinit(allocator);
        if (self.worktrees.len > 0) allocator.free(self.worktrees);
        freeChanges(self.merge_changes, allocator);
        freeChanges(self.index_changes, allocator);
        freeChanges(self.working_tree_changes, allocator);
        freeChanges(self.untracked_changes, allocator);
        self.* = .{};
    }

    /// Deep-copies `source` into `allocator`-owned memory.
    pub fn clone(self: GitRepositoryState, allocator: Allocator) !GitRepositoryState {
        return .{
            .head = if (self.head) |head| try cloneBranch(head, allocator) else null,
            .remotes = try cloneRemotes(self.remotes, allocator),
            .submodules = try cloneSubmodules(self.submodules, allocator),
            .worktrees = try cloneWorktrees(self.worktrees, allocator),
            .is_worktree = self.is_worktree,
            .merge_changes = try cloneChanges(self.merge_changes, allocator),
            .index_changes = try cloneChanges(self.index_changes, allocator),
            .working_tree_changes = try cloneChanges(self.working_tree_changes, allocator),
            .untracked_changes = try cloneChanges(self.untracked_changes, allocator),
        };
    }
};

fn worktreesEql(a: []const GitWorktree, b: []const GitWorktree) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.main != right.main or left.detached != right.detached or !std.mem.eql(u8, left.name, right.name) or !std.mem.eql(u8, left.path, right.path) or !std.mem.eql(u8, left.ref, right.ref)) return false;
    }
    return true;
}

fn cloneWorktrees(worktrees: []const GitWorktree, allocator: Allocator) ![]GitWorktree {
    if (worktrees.len == 0) return &.{};
    const result = try allocator.alloc(GitWorktree, worktrees.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |worktree| worktree.deinit(allocator);
        allocator.free(result);
    }
    for (worktrees, 0..) |worktree, i| {
        result[i] = try worktree.clone(allocator);
        initialized += 1;
    }
    return result;
}

fn freeRef(ref: *GitRef, allocator: Allocator) void {
    if (ref.name) |name| allocator.free(name);
    if (ref.commit) |commit| allocator.free(commit);
    if (ref.remote) |remote| allocator.free(remote);
}

fn freeChanges(changes: []const GitChange, allocator: Allocator) void {
    for (changes) |change| {
        allocator.free(change.path);
        if (change.original_path) |path| allocator.free(path);
        if (change.modified_path) |path| allocator.free(path);
    }
    if (changes.len > 0) allocator.free(changes);
}

fn optionalBranchEql(a: ?GitBranch, b: ?GitBranch) bool {
    if (a == null or b == null) return a == null and b == null;
    const left = a.?;
    const right = b.?;
    if (left.ref.ref_type != right.ref.ref_type) return false;
    if (!optionalStringEql(left.ref.name, right.ref.name)) return false;
    if (!optionalStringEql(left.ref.commit, right.ref.commit)) return false;
    if (!optionalStringEql(left.ref.remote, right.ref.remote)) return false;
    if (!optionalStringEql(if (left.upstream) |u| u.name else null, if (right.upstream) |u| u.name else null)) return false;
    if (!optionalUsizeEql(left.ahead, right.ahead)) return false;
    if (!optionalUsizeEql(left.behind, right.behind)) return false;
    return true;
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalUsizeEql(a: ?usize, b: ?usize) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn remotesEql(a: []const GitRemote, b: []const GitRemote) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (!optionalStringEql(left.fetch_url, right.fetch_url)) return false;
        if (!optionalStringEql(left.push_url, right.push_url)) return false;
        if (left.is_read_only != right.is_read_only) return false;
    }
    return true;
}

fn submodulesEql(a: []const GitSubmodule, b: []const GitSubmodule) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or !std.mem.eql(u8, left.path, right.path) or !std.mem.eql(u8, left.url, right.url)) return false;
    }
    return true;
}

fn cloneSubmodules(submodules: []const GitSubmodule, allocator: Allocator) ![]GitSubmodule {
    if (submodules.len == 0) return &.{};
    const result = try allocator.alloc(GitSubmodule, submodules.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |submodule| submodule.deinit(allocator);
        allocator.free(result);
    }
    for (submodules, 0..) |submodule, i| {
        result[i] = try submodule.clone(allocator);
        initialized += 1;
    }
    return result;
}

fn changesEql(a: []const GitChange, b: []const GitChange) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path)) return false;
        if (!optionalStringEql(left.original_path, right.original_path)) return false;
        if (!optionalStringEql(left.modified_path, right.modified_path)) return false;
        if (left.status != right.status) return false;
        if (!optionalConflictEql(left.conflict, right.conflict)) return false;
        if (left.submodule != right.submodule) return false;
    }
    return true;
}

fn optionalConflictEql(a: ?[2]u8, b: ?[2]u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?[0] == b.?[0] and a.?[1] == b.?[1];
}

fn cloneBranch(branch: GitBranch, allocator: Allocator) !GitBranch {
    var result = GitBranch{
        .ref = .{
            .ref_type = branch.ref.ref_type,
            .name = if (branch.ref.name) |name| try allocator.dupe(u8, name) else null,
            .commit = if (branch.ref.commit) |commit| try allocator.dupe(u8, commit) else null,
            .remote = if (branch.ref.remote) |remote| try allocator.dupe(u8, remote) else null,
        },
        .ahead = branch.ahead,
        .behind = branch.behind,
    };
    if (branch.upstream) |upstream| {
        result.upstream = .{
            .remote = try allocator.dupe(u8, upstream.remote),
            .name = try allocator.dupe(u8, upstream.name),
            .commit = if (upstream.commit) |commit| try allocator.dupe(u8, commit) else null,
        };
    }
    return result;
}

fn cloneChanges(changes: []const GitChange, allocator: Allocator) ![]GitChange {
    if (changes.len == 0) return &.{};
    const result = try allocator.alloc(GitChange, changes.len);
    errdefer allocator.free(result);
    for (changes, 0..) |change, index| {
        result[index] = .{
            .path = try allocator.dupe(u8, change.path),
            .original_path = if (change.original_path) |path| try allocator.dupe(u8, path) else null,
            .modified_path = if (change.modified_path) |path| try allocator.dupe(u8, path) else null,
            .status = change.status,
            .conflict = change.conflict,
            .submodule = change.submodule,
        };
    }
    return result;
}

fn cloneRemotes(remotes: []const GitRemote, allocator: Allocator) ![]GitRemote {
    if (remotes.len == 0) return &.{};
    const result = try allocator.alloc(GitRemote, remotes.len);
    errdefer allocator.free(result);
    for (remotes, 0..) |remote, index| {
        result[index] = .{
            .name = try allocator.dupe(u8, remote.name),
            .fetch_url = if (remote.fetch_url) |url| try allocator.dupe(u8, url) else null,
            .push_url = if (remote.push_url) |url| try allocator.dupe(u8, url) else null,
            .is_read_only = remote.is_read_only,
        };
    }
    return result;
}

pub const GitError = error{
    /// `GitService.setDelegate` can only be called once, matching upstream's
    /// `BugIndicatingError` for the single extension-host delegate.
    DelegateAlreadySet,
};

/// Terminal port of `IGitRepository`. `state()` returns the live state owned by
/// the repository; callers must not free it.
pub const IGitRepository = struct {
    context: *anyopaque,
    root_path: []const u8,
    state_fn: *const fn (context: *anyopaque) *const GitRepositoryState,
    update_state_fn: *const fn (context: *anyopaque, state: GitRepositoryState) void,
    change_event_fn: *const fn (context: *anyopaque) *Emitter(void),
    get_refs_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        query: GitRefQuery,
        token: CancellationToken,
    ) anyerror![]GitRef,
    diff_between_with_stats_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange,
    diff_between_with_stats2_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        ref: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange,
    commit_files_fn: *const fn (
        context: *anyopaque,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) anyerror!void,
    log_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        options: GitLogOptions,
        token: CancellationToken,
    ) anyerror![]GitCommit,
    diff_root_commit_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        commit: []const u8,
    ) anyerror![]GitDiffChange,
    merge_base_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        refs: []const []const u8,
    ) anyerror!?[]u8,
    get_branch_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        name: []const u8,
    ) anyerror!?GitBranch,
    get_branch_base_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        name: []const u8,
    ) anyerror!?GitBranch,
    read_ref_at_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        path: []const u8,
        revision: []const u8,
    ) anyerror!?[]u8,
    has_git_version_at_least_fn: *const fn (
        context: *anyopaque,
        major: usize,
        minor: usize,
    ) bool,

    pub fn state(self: IGitRepository) *const GitRepositoryState {
        return self.state_fn(self.context);
    }

    pub fn updateState(self: IGitRepository, new_state: GitRepositoryState) void {
        self.update_state_fn(self.context, new_state);
    }

    pub fn changeEvent(self: IGitRepository) *Emitter(void) {
        return self.change_event_fn(self.context);
    }

    pub fn getRefs(self: IGitRepository, allocator: Allocator, query: GitRefQuery, token: CancellationToken) ![]GitRef {
        return self.get_refs_fn(self.context, allocator, query, token);
    }

    pub fn diffBetweenWithStats(
        self: IGitRepository,
        allocator: Allocator,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        return self.diff_between_with_stats_fn(self.context, allocator, ref1, ref2, path);
    }

    pub fn diffBetweenWithStats2(
        self: IGitRepository,
        allocator: Allocator,
        ref: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        return self.diff_between_with_stats2_fn(self.context, allocator, ref, path);
    }

    pub fn commitFiles(
        self: IGitRepository,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) !void {
        return self.commit_files_fn(self.context, files, message, options);
    }

    pub fn log(self: IGitRepository, allocator: Allocator, options: GitLogOptions, token: CancellationToken) ![]GitCommit {
        return self.log_fn(self.context, allocator, options, token);
    }

    pub fn diffRootCommit(self: IGitRepository, allocator: Allocator, commit: []const u8) ![]GitDiffChange {
        return self.diff_root_commit_fn(self.context, allocator, commit);
    }

    pub fn mergeBase(self: IGitRepository, allocator: Allocator, refs: []const []const u8) !?[]u8 {
        return self.merge_base_fn(self.context, allocator, refs);
    }

    pub fn getBranch(self: IGitRepository, allocator: Allocator, name: []const u8) !?GitBranch {
        return self.get_branch_fn(self.context, allocator, name);
    }

    pub fn getBranchBase(self: IGitRepository, allocator: Allocator, name: []const u8) !?GitBranch {
        return self.get_branch_base_fn(self.context, allocator, name);
    }

    pub fn readRefAt(self: IGitRepository, allocator: Allocator, path: []const u8, revision: []const u8) !?[]u8 {
        return self.read_ref_at_fn(self.context, allocator, path, revision);
    }

    pub fn hasGitVersionAtLeast(self: IGitRepository, major: usize, minor: usize) bool {
        return self.has_git_version_at_least_fn(self.context, major, minor);
    }
};

/// Terminal port of `IGitExtensionDelegate`. `repositories` returns a borrowed
/// slice of the registered repositories.
pub const IGitExtensionDelegate = struct {
    context: *anyopaque,
    repositories_fn: *const fn (context: *anyopaque) []const IGitRepository,
    open_repository_fn: *const fn (context: *anyopaque, path: []const u8) anyerror!?IGitRepository,
    get_refs_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        query: GitRefQuery,
        token: CancellationToken,
    ) anyerror![]GitRef,
    diff_between_with_stats_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange,
    diff_between_with_stats2_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        ref: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange,
    commit_files_fn: *const fn (
        context: *anyopaque,
        root: []const u8,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) anyerror!void,
    log_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        options: GitLogOptions,
        token: CancellationToken,
    ) anyerror![]GitCommit,
    diff_root_commit_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        commit: []const u8,
    ) anyerror![]GitDiffChange,
    merge_base_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        refs: []const []const u8,
    ) anyerror!?[]u8,
    get_branch_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) anyerror!?GitBranch,
    get_branch_base_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) anyerror!?GitBranch,
    read_ref_at_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        root: []const u8,
        path: []const u8,
        revision: []const u8,
    ) anyerror!?[]u8,
    has_git_version_at_least_fn: *const fn (
        context: *anyopaque,
        major: usize,
        minor: usize,
    ) bool,

    pub fn repositories(self: IGitExtensionDelegate) []const IGitRepository {
        return self.repositories_fn(self.context);
    }

    pub fn openRepository(self: IGitExtensionDelegate, path: []const u8) !?IGitRepository {
        return self.open_repository_fn(self.context, path);
    }

    pub fn getRefs(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        query: GitRefQuery,
        token: CancellationToken,
    ) ![]GitRef {
        return self.get_refs_fn(self.context, allocator, root, query, token);
    }

    pub fn diffBetweenWithStats(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        return self.diff_between_with_stats_fn(self.context, allocator, root, ref1, ref2, path);
    }

    pub fn commitFiles(
        self: IGitExtensionDelegate,
        root: []const u8,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) !void {
        return self.commit_files_fn(self.context, root, files, message, options);
    }

    pub fn log(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        options: GitLogOptions,
        token: CancellationToken,
    ) ![]GitCommit {
        return self.log_fn(self.context, allocator, root, options, token);
    }

    pub fn diffRootCommit(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        commit: []const u8,
    ) ![]GitDiffChange {
        return self.diff_root_commit_fn(self.context, allocator, root, commit);
    }

    pub fn mergeBase(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        refs: []const []const u8,
    ) !?[]u8 {
        return self.merge_base_fn(self.context, allocator, root, refs);
    }

    pub fn getBranch(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) !?GitBranch {
        return self.get_branch_fn(self.context, allocator, root, name);
    }

    pub fn getBranchBase(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        name: []const u8,
    ) !?GitBranch {
        return self.get_branch_base_fn(self.context, allocator, root, name);
    }

    pub fn readRefAt(
        self: IGitExtensionDelegate,
        allocator: Allocator,
        root: []const u8,
        path: []const u8,
        revision: []const u8,
    ) !?[]u8 {
        return self.read_ref_at_fn(self.context, allocator, root, path, revision);
    }

    pub fn hasGitVersionAtLeast(
        self: IGitExtensionDelegate,
        major: usize,
        minor: usize,
    ) bool {
        return self.has_git_version_at_least_fn(self.context, major, minor);
    }
};

/// Terminal port of `IGitService`.
pub const IGitService = struct {
    context: *anyopaque,
    repositories_fn: *const fn (context: *anyopaque) []const IGitRepository,
    set_delegate_fn: *const fn (context: *anyopaque, delegate: *IGitExtensionDelegate) anyerror!IDisposable,
    open_repository_fn: *const fn (context: *anyopaque, path: []const u8) anyerror!?IGitRepository,

    pub fn repositories(self: IGitService) []const IGitRepository {
        return self.repositories_fn(self.context);
    }

    pub fn setDelegate(self: IGitService, delegate: *IGitExtensionDelegate) !IDisposable {
        return self.set_delegate_fn(self.context, delegate);
    }

    pub fn openRepository(self: IGitService, path: []const u8) !?IGitRepository {
        return self.open_repository_fn(self.context, path);
    }
};

test "GitRepositoryState: structural equality and ownership cleanup" {
    const allocator = std.testing.allocator;
    var state = GitRepositoryState{
        .head = .{ .ref = .{ .ref_type = .head, .name = try allocator.dupe(u8, "main") } },
        .untracked_changes = try allocator.alloc(GitChange, 1),
    };
    state.untracked_changes[0] = .{ .path = try allocator.dupe(u8, "a.zig") };

    var copy = try state.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expect(GitRepositoryState.eql(state, copy));
    if (copy.head) |*head| {
        allocator.free(head.ref.name.?);
        head.ref.name = try allocator.dupe(u8, "other");
    }
    try std.testing.expect(!GitRepositoryState.eql(state, copy));

    state.deinit(allocator);
}

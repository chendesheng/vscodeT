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

pub const GitRefSort = enum {
    alphabetically,
    committerdate,
    creatordate,
};

pub const GitRefQuery = struct {
    contains: ?[]const u8 = null,
    count: ?usize = null,
    pattern: ?[]const u8 = null,
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
};

pub const GitDiffChange = struct {
    change: GitChange,
    insertions: usize,
    deletions: usize,
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
};

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
    /// Skips the pre-commit and commit-msg hooks.
    no_verify: ?bool = null,
    /// Overrides whether the commit is signed. Leaves the user's signing
    /// configuration in effect when null.
    sign_commit: ?bool = null,
};

pub const GitRepositoryState = struct {
    head: ?GitBranch = null,
    remotes: []GitRemote = &.{},
    merge_changes: []GitChange = &.{},
    index_changes: []GitChange = &.{},
    working_tree_changes: []GitChange = &.{},
    untracked_changes: []GitChange = &.{},

    /// Structural equality, matching upstream's `structuralEquals` observable
    /// comparer. Used to suppress no-op state change events.
    pub fn eql(a: GitRepositoryState, b: GitRepositoryState) bool {
        if (!optionalBranchEql(a.head, b.head)) return false;
        if (!remotesEql(a.remotes, b.remotes)) return false;
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
            .merge_changes = try cloneChanges(self.merge_changes, allocator),
            .index_changes = try cloneChanges(self.index_changes, allocator),
            .working_tree_changes = try cloneChanges(self.working_tree_changes, allocator),
            .untracked_changes = try cloneChanges(self.untracked_changes, allocator),
        };
    }
};

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

fn changesEql(a: []const GitChange, b: []const GitChange) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path)) return false;
        if (!optionalStringEql(left.original_path, right.original_path)) return false;
        if (!optionalStringEql(left.modified_path, right.modified_path)) return false;
        if (left.status != right.status) return false;
    }
    return true;
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

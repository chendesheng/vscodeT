// Port of `src/vs/workbench/contrib/git/browser/gitService.ts`.
//
// Terminal adaptations:
// - `Promise` becomes a synchronous `!T` return.
// - The 10 second `AutoOpenBarrier` is not ported: the terminal sets its
//   command-line delegate during the native extension `Model.openRepository`, before anything can call
//   `openRepository`, so there is no cross-process wait.
// - `IObservable` becomes an owned state value plus a change event.
const std = @import("std");
const Allocator = std.mem.Allocator;

const git_common = @import("../common/gitService.zig");
const lifecycle = @import("../../../../base/common/lifecycle.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const IDisposable = lifecycle.IDisposable;
pub const CancellationToken = git_common.CancellationToken;
pub const GitRepositoryState = git_common.GitRepositoryState;
pub const GitRef = git_common.GitRef;
pub const GitRefQuery = git_common.GitRefQuery;
pub const GitDiffChange = git_common.GitDiffChange;
pub const GitCommit = git_common.GitCommit;
pub const GitLogOptions = git_common.GitLogOptions;
pub const GitCommitOptions = git_common.GitCommitOptions;
pub const GitBranch = git_common.GitBranch;
pub const IGitRepository = git_common.IGitRepository;
pub const IGitExtensionDelegate = git_common.IGitExtensionDelegate;
pub const IGitService = git_common.IGitService;
pub const GitError = git_common.GitError;

/// Port of `GitService`. One delegate per process, matching the upstream
/// single extension-host rule.
pub const GitService = struct {
    allocator: Allocator,
    delegate: ?*IGitExtensionDelegate = null,
    change: Emitter(void),

    pub fn init(allocator: Allocator) GitService {
        return .{ .allocator = allocator, .change = Emitter(void).init(allocator) };
    }

    pub fn deinit(self: *GitService) void {
        self.change.deinit();
        self.* = undefined;
    }

    pub fn repositories(self: *const GitService) []const IGitRepository {
        const delegate = self.delegate orelse return &.{};
        return delegate.repositories();
    }

    pub fn setDelegate(self: *GitService, delegate: *IGitExtensionDelegate) !IDisposable {
        if (self.delegate != null) return GitError.DelegateAlreadySet;
        self.delegate = delegate;
        self.change.fire({}) catch {};
        return IDisposable.from(GitService, self, clearDelegate);
    }

    fn clearDelegate(self: *GitService) void {
        self.delegate = null;
    }

    pub fn openRepository(self: *GitService, path: []const u8) !?IGitRepository {
        const delegate = self.delegate orelse return null;
        return delegate.openRepository(path);
    }

    pub fn interface(self: *GitService) IGitService {
        return .{
            .context = self,
            .repositories_fn = repositoriesThunk,
            .set_delegate_fn = setDelegateThunk,
            .open_repository_fn = openRepositoryThunk,
        };
    }

    fn repositoriesThunk(context: *anyopaque) []const IGitRepository {
        const self: *GitService = @ptrCast(@alignCast(context));
        return self.repositories();
    }

    fn setDelegateThunk(context: *anyopaque, delegate: *IGitExtensionDelegate) anyerror!IDisposable {
        const self: *GitService = @ptrCast(@alignCast(context));
        return self.setDelegate(delegate);
    }

    fn openRepositoryThunk(context: *anyopaque, path: []const u8) anyerror!?IGitRepository {
        const self: *GitService = @ptrCast(@alignCast(context));
        return self.openRepository(path);
    }
};

/// Port of `GitRepository`: a root, its state and the delegate forwarding.
/// The terminal git CLI owns one of these per discovered repository.
pub const GitRepository = struct {
    allocator: Allocator,
    root_path: []u8,
    state_arena: std.heap.ArenaAllocator,
    state: GitRepositoryState,
    delegate: *IGitExtensionDelegate,
    change: Emitter(void),
    disposed: bool = false,

    pub fn create(
        allocator: Allocator,
        root_path: []const u8,
        initial_state: GitRepositoryState,
        delegate: *IGitExtensionDelegate,
    ) !*GitRepository {
        const self = try allocator.create(GitRepository);
        errdefer allocator.destroy(self);
        const path = try allocator.dupe(u8, root_path);
        errdefer allocator.free(path);
        self.* = .{
            .allocator = allocator,
            .root_path = path,
            .state_arena = std.heap.ArenaAllocator.init(allocator),
            .state = .{},
            .delegate = delegate,
            .change = Emitter(void).init(allocator),
        };
        errdefer {
            self.change.deinit();
            self.state_arena.deinit();
            allocator.free(path);
        }
        try self.updateState(initial_state);
        return self;
    }

    pub fn destroy(self: *GitRepository) void {
        self.change.deinit();
        self.state_arena.deinit();
        self.allocator.free(self.root_path);
        self.allocator.destroy(self);
    }

    pub fn rootPath(self: *const GitRepository) []const u8 {
        return self.root_path;
    }

    pub fn stateRef(self: *const GitRepository) *const GitRepositoryState {
        return &self.state;
    }

    pub fn changeEvent(self: *GitRepository) *Emitter(void) {
        return &self.change;
    }

    /// Replaces the repository state. The incoming slices are deep-copied into
    /// the repository arena, so the caller keeps ownership of `new_state`.
    pub fn updateState(self: *GitRepository, new_state: GitRepositoryState) !void {
        if (GitRepositoryState.eql(self.state, new_state)) return;
        _ = self.state_arena.reset(.retain_capacity);
        self.state = try new_state.clone(self.state_arena.allocator());
        self.change.fire({}) catch {};
    }

    pub fn getRefs(self: *GitRepository, allocator: Allocator, query: GitRefQuery, token: CancellationToken) ![]GitRef {
        return self.delegate.get_refs_fn(
            self.delegate.context,
            allocator,
            self.root_path,
            query,
            token,
        );
    }

    pub fn diffBetweenWithStats(
        self: *GitRepository,
        allocator: Allocator,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        return self.delegate.diff_between_with_stats_fn(
            self.delegate.context,
            allocator,
            self.root_path,
            ref1,
            ref2,
            path,
        );
    }

    pub fn diffBetweenWithStats2(
        self: *GitRepository,
        allocator: Allocator,
        ref: []const u8,
        path: ?[]const u8,
    ) ![]GitDiffChange {
        return self.delegate.diff_between_with_stats2_fn(
            self.delegate.context,
            allocator,
            self.root_path,
            ref,
            path,
        );
    }

    pub fn commitFiles(
        self: *GitRepository,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) !void {
        return self.delegate.commit_files_fn(
            self.delegate.context,
            self.root_path,
            files,
            message,
            options,
        );
    }

    pub fn log(
        self: *GitRepository,
        allocator: Allocator,
        options: GitLogOptions,
        token: CancellationToken,
    ) ![]GitCommit {
        return self.delegate.log(allocator, self.root_path, options, token);
    }

    pub fn diffRootCommit(
        self: *GitRepository,
        allocator: Allocator,
        commit: []const u8,
    ) ![]GitDiffChange {
        return self.delegate.diffRootCommit(allocator, self.root_path, commit);
    }

    pub fn mergeBase(
        self: *GitRepository,
        allocator: Allocator,
        refs: []const []const u8,
    ) !?[]u8 {
        return self.delegate.mergeBase(allocator, self.root_path, refs);
    }

    pub fn getBranch(
        self: *GitRepository,
        allocator: Allocator,
        name: []const u8,
    ) !?GitBranch {
        return self.delegate.getBranch(allocator, self.root_path, name);
    }

    pub fn getBranchBase(
        self: *GitRepository,
        allocator: Allocator,
        name: []const u8,
    ) !?GitBranch {
        return self.delegate.getBranchBase(allocator, self.root_path, name);
    }

    pub fn readRefAt(
        self: *GitRepository,
        allocator: Allocator,
        path: []const u8,
        revision: []const u8,
    ) !?[]u8 {
        return self.delegate.readRefAt(allocator, self.root_path, path, revision);
    }

    pub fn hasGitVersionAtLeast(self: *GitRepository, major: usize, minor: usize) bool {
        return self.delegate.hasGitVersionAtLeast(major, minor);
    }

    pub fn interface(self: *GitRepository) IGitRepository {
        return .{
            .context = self,
            .root_path = self.root_path,
            .state_fn = stateThunk,
            .update_state_fn = updateStateThunk,
            .change_event_fn = changeEventThunk,
            .get_refs_fn = getRefsThunk,
            .diff_between_with_stats_fn = diffBetweenWithStatsThunk,
            .diff_between_with_stats2_fn = diffBetweenWithStats2Thunk,
            .commit_files_fn = commitFilesThunk,
            .log_fn = logThunk,
            .diff_root_commit_fn = diffRootCommitThunk,
            .merge_base_fn = mergeBaseThunk,
            .get_branch_fn = getBranchThunk,
            .get_branch_base_fn = getBranchBaseThunk,
            .read_ref_at_fn = readRefAtThunk,
            .has_git_version_at_least_fn = hasGitVersionAtLeastThunk,
        };
    }

    fn stateThunk(context: *anyopaque) *const GitRepositoryState {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.stateRef();
    }

    fn updateStateThunk(context: *anyopaque, new_state: GitRepositoryState) void {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        self.updateState(new_state) catch {};
    }

    fn changeEventThunk(context: *anyopaque) *Emitter(void) {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.changeEvent();
    }

    fn getRefsThunk(
        context: *anyopaque,
        allocator: Allocator,
        query: GitRefQuery,
        token: CancellationToken,
    ) anyerror![]GitRef {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.getRefs(allocator, query, token);
    }

    fn diffBetweenWithStatsThunk(
        context: *anyopaque,
        allocator: Allocator,
        ref1: []const u8,
        ref2: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.diffBetweenWithStats(allocator, ref1, ref2, path);
    }

    fn diffBetweenWithStats2Thunk(
        context: *anyopaque,
        allocator: Allocator,
        ref: []const u8,
        path: ?[]const u8,
    ) anyerror![]GitDiffChange {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.diffBetweenWithStats2(allocator, ref, path);
    }

    fn commitFilesThunk(
        context: *anyopaque,
        files: []const []const u8,
        message: []const u8,
        options: GitCommitOptions,
    ) anyerror!void {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.commitFiles(files, message, options);
    }

    fn logThunk(
        context: *anyopaque,
        allocator: Allocator,
        options: GitLogOptions,
        token: CancellationToken,
    ) anyerror![]GitCommit {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.log(allocator, options, token);
    }

    fn diffRootCommitThunk(
        context: *anyopaque,
        allocator: Allocator,
        commit: []const u8,
    ) anyerror![]GitDiffChange {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.diffRootCommit(allocator, commit);
    }

    fn mergeBaseThunk(
        context: *anyopaque,
        allocator: Allocator,
        refs: []const []const u8,
    ) anyerror!?[]u8 {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.mergeBase(allocator, refs);
    }

    fn getBranchThunk(
        context: *anyopaque,
        allocator: Allocator,
        name: []const u8,
    ) anyerror!?GitBranch {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.getBranch(allocator, name);
    }

    fn getBranchBaseThunk(
        context: *anyopaque,
        allocator: Allocator,
        name: []const u8,
    ) anyerror!?GitBranch {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.getBranchBase(allocator, name);
    }

    fn readRefAtThunk(
        context: *anyopaque,
        allocator: Allocator,
        path: []const u8,
        revision: []const u8,
    ) anyerror!?[]u8 {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.readRefAt(allocator, path, revision);
    }

    fn hasGitVersionAtLeastThunk(
        context: *anyopaque,
        major: usize,
        minor: usize,
    ) bool {
        const self: *GitRepository = @ptrCast(@alignCast(context));
        return self.hasGitVersionAtLeast(major, minor);
    }
};

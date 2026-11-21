// Tests for the terminal port of
// `src/vs/workbench/contrib/git/common/gitService.ts` and
// `src/vs/workbench/contrib/git/browser/gitService.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("../../common/gitService.zig");
const browser = @import("../../browser/gitService.zig");

const IGitRepository = common.IGitRepository;
const IGitExtensionDelegate = common.IGitExtensionDelegate;
const GitRepositoryState = common.GitRepositoryState;
const GitRef = common.GitRef;
const GitRefQuery = common.GitRefQuery;
const GitDiffChange = common.GitDiffChange;
const GitCommitOptions = common.GitCommitOptions;
const CancellationToken = common.CancellationToken;
const GitError = common.GitError;

const FakeDelegate = struct {
    base: IGitExtensionDelegate = undefined,
    open_calls: usize = 0,
    last_root: ?[]const u8 = null,
    repositories_data: [0]IGitRepository = .{},

    fn init(self: *FakeDelegate) void {
        self.base = .{
            .context = self,
            .repositories_fn = repositories,
            .open_repository_fn = openRepository,
            .get_refs_fn = getRefs,
            .diff_between_with_stats_fn = diffBetweenWithStats,
            .diff_between_with_stats2_fn = diffBetweenWithStats2,
            .commit_files_fn = commitFiles,
            .log_fn = log,
            .diff_root_commit_fn = diffRootCommit,
            .merge_base_fn = mergeBase,
            .get_branch_fn = getBranch,
            .get_branch_base_fn = getBranchBase,
            .read_ref_at_fn = readRefAt,
            .has_git_version_at_least_fn = hasGitVersionAtLeast,
        };
    }

    fn repositories(context: *anyopaque) []const IGitRepository {
        const self: *FakeDelegate = @ptrCast(@alignCast(context));
        return &self.repositories_data;
    }

    fn openRepository(context: *anyopaque, path: []const u8) anyerror!?IGitRepository {
        const self: *FakeDelegate = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        self.last_root = path;
        return null;
    }

    fn getRefs(_: *anyopaque, _: Allocator, _: []const u8, _: GitRefQuery, _: CancellationToken) anyerror![]GitRef {
        return &.{};
    }

    fn diffBetweenWithStats(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8, _: ?[]const u8) anyerror![]GitDiffChange {
        return &.{};
    }

    fn diffBetweenWithStats2(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: ?[]const u8) anyerror![]GitDiffChange {
        return &.{};
    }

    fn commitFiles(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8, _: GitCommitOptions) anyerror!void {}
    fn log(_: *anyopaque, _: Allocator, _: []const u8, _: common.GitLogOptions, _: CancellationToken) anyerror![]common.GitCommit {
        return &.{};
    }
    fn diffRootCommit(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror![]common.GitDiffChange {
        return &.{};
    }
    fn mergeBase(_: *anyopaque, _: Allocator, _: []const u8, _: []const []const u8) anyerror!?[]u8 {
        return null;
    }
    fn getBranch(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror!?common.GitBranch {
        return null;
    }
    fn getBranchBase(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror!?common.GitBranch {
        return null;
    }
    fn readRefAt(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!?[]u8 {
        return null;
    }
    fn hasGitVersionAtLeast(_: *anyopaque, _: usize, _: usize) bool {
        return true;
    }
};

test "gitService: delegate is set once and can be cleared" {
    const allocator = std.testing.allocator;
    var service = browser.GitService.init(allocator);
    defer service.deinit();

    var fake = FakeDelegate{};
    fake.init();
    try std.testing.expectEqual(@as(usize, 0), service.repositories().len);

    const disposable = try service.setDelegate(&fake.base);
    defer disposable.dispose();
    try std.testing.expectEqual(@as(usize, 0), service.repositories().len);

    try std.testing.expectError(GitError.DelegateAlreadySet, service.setDelegate(&fake.base));

    disposable.dispose();
    var second = FakeDelegate{};
    second.init();
    _ = try service.setDelegate(&second.base);
}

test "gitService: openRepository without a delegate returns null" {
    const allocator = std.testing.allocator;
    var service = browser.GitService.init(allocator);
    defer service.deinit();
    try std.testing.expect((try service.openRepository("/tmp")) == null);
}

test "gitService: openRepository forwards the path to the delegate" {
    const allocator = std.testing.allocator;
    var service = browser.GitService.init(allocator);
    defer service.deinit();
    var fake = FakeDelegate{};
    fake.init();
    const disposable = try service.setDelegate(&fake.base);
    defer disposable.dispose();

    try std.testing.expect((try service.openRepository("/repo")) == null);
    try std.testing.expectEqual(@as(usize, 1), fake.open_calls);
    try std.testing.expectEqualStrings("/repo", fake.last_root.?);
}

test "gitService: repository state change is deep-copied and emitted" {
    const allocator = std.testing.allocator;
    var fake = FakeDelegate{};
    fake.init();

    var initial = GitRepositoryState{
        .head = .{ .ref = .{ .ref_type = .head, .name = try allocator.dupe(u8, "main") } },
    };
    const repo = try browser.GitRepository.create(allocator, "/repo", initial, &fake.base);
    defer repo.destroy();
    initial.deinit(allocator);

    var events: usize = 0;
    const listener = try repo.change.listen(&events, struct {
        fn onEvent(_: void, counter: *usize) anyerror!void {
            counter.* += 1;
        }
    }.onEvent);
    defer repo.change.unlisten(listener);

    try std.testing.expectEqualStrings("main", repo.stateRef().head.?.ref.name.?);

    var same = try repo.stateRef().clone(allocator);
    defer same.deinit(allocator);
    try repo.updateState(same);
    try std.testing.expectEqual(@as(usize, 0), events);

    var changed = GitRepositoryState{
        .head = .{ .ref = .{ .ref_type = .head, .name = try allocator.dupe(u8, "next") } },
        .working_tree_changes = try allocator.alloc(common.GitChange, 1),
    };
    defer changed.deinit(allocator);
    changed.working_tree_changes[0] = .{ .path = try allocator.dupe(u8, "src/main.zig") };
    try repo.updateState(changed);
    try std.testing.expectEqual(@as(usize, 1), events);
    try std.testing.expectEqualStrings("next", repo.stateRef().head.?.ref.name.?);
    try std.testing.expectEqualStrings("src/main.zig", repo.stateRef().working_tree_changes[0].path);
}

test "gitService: repository forwards refs, diff and commit to the delegate" {
    const allocator = std.testing.allocator;
    var fake = FakeDelegate{};
    fake.init();
    const repo = try browser.GitRepository.create(allocator, "/repo", .{}, &fake.base);
    defer repo.destroy();

    const interface = repo.interface();
    try std.testing.expectEqualStrings("/repo", interface.root_path);
    try std.testing.expectEqual(@as(usize, 0), (try interface.getRefs(allocator, .{}, CancellationToken.None)).len);
    try std.testing.expectEqual(@as(usize, 0), (try interface.diffBetweenWithStats(allocator, "HEAD", "index", null)).len);
    try interface.commitFiles(&.{}, "message", .{});
}

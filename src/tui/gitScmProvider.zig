// TUI adapter that exposes the git service as a Source Control provider.
//
// There is no `vscode.git` extension-host SCM actor in this port, so the
// terminal implements `ISCMProvider` over the command-line git service. The
// upstream `git` extension's resource groups, status letters and quick-diff
// providers are reproduced here; the group/resource rows are painted by
// `src/tui/scmView.zig`.
//
// Groups: `Merge Changes`, `Staged Changes`, `Changes` (working-tree changes
// with untracked files mixed in, matching `git.untrackedChanges=mixed`).
const std = @import("std");
const Allocator = std.mem.Allocator;

const scm = @import("../vs/workbench/contrib/scm/common/scm.zig");
const quick_diff = @import("../vs/workbench/contrib/scm/common/quickDiff.zig");
const git_common = @import("../vs/workbench/contrib/git/common/gitService.zig");
const git_browser = @import("../vs/workbench/contrib/git/browser/gitService.zig");
const git_cli_mod = @import("./gitCli.zig");
const Emitter = @import("../vs/base/common/event.zig").Emitter;

pub const GitCli = git_cli_mod.GitCli;
pub const GitRepository = git_browser.GitRepository;
pub const GitRepositoryState = git_common.GitRepositoryState;
pub const GitChange = git_common.GitChange;
pub const QuickDiffProvider = quick_diff.QuickDiffProvider;
pub const Original = quick_diff.Original;

pub const Host = struct {
    context: *anyopaque,
    /// Opens the change represented by `resource` (usually a diff tab).
    open_change: *const fn (context: *anyopaque, provider: *GitScmProvider, resource: *GitScmResource) anyerror!void,
};

pub const ResourceKind = enum { merge, index, working, untracked };

pub const GitScmResource = struct {
    provider: *GitScmProvider,
    relative_path: []u8,
    absolute_path: []u8,
    kind: ResourceKind,
    status: u8,
    status_text: [1]u8,
    decorations: scm.ISCMResourceDecorations,
    iface: scm.ISCMResource,

    pub fn destroy(self: *GitScmResource) void {
        const allocator = self.provider.allocator;
        allocator.free(self.relative_path);
        allocator.free(self.absolute_path);
        if (self.decorations.tooltip) |tooltip| allocator.free(tooltip);
        allocator.destroy(self);
    }
};

pub const GitScmGroup = struct {
    provider: *GitScmProvider,
    index: usize,
    id: []const u8,
    label: []const u8,
    hide_when_empty: bool,
    resources: std.array_list.Managed(*GitScmResource),
    interfaces: std.array_list.Managed(scm.ISCMResource),
    iface: scm.ISCMResourceGroup,
    resources_changed: Emitter(void),
    changed: Emitter(void),

    pub fn destroy(self: *GitScmGroup) void {
        const allocator = self.provider.allocator;
        for (self.resources.items) |resource| resource.destroy();
        self.resources.deinit();
        self.interfaces.deinit();
        _ = allocator;
    }
};

pub const GitScmProvider = struct {
    allocator: Allocator,
    /// Null in focused tests that only validate group/resource projection.
    git: ?*GitCli,
    repository: *GitRepository,
    root: []u8,
    id: []u8,
    label: []u8,
    name: []u8,
    branch: ?[]u8 = null,
    host: Host,
    groups: [3]GitScmGroup,
    group_pointers: [3]*scm.ISCMResourceGroup,
    group_slice: [3]*scm.ISCMResourceGroup,
    base: scm.ISCMProvider,
    on_resources: Emitter(void),
    on_groups: Emitter(void),
    primary_quick_diff: QuickDiffProvider,
    secondary_quick_diff: QuickDiffProvider,

    pub fn create(
        allocator: Allocator,
        git: ?*GitCli,
        repository: *GitRepository,
        root: []const u8,
        host: Host,
    ) !*GitScmProvider {
        const self = try allocator.create(GitScmProvider);
        errdefer allocator.destroy(self);

        const root_copy = try allocator.dupe(u8, root);
        errdefer allocator.free(root_copy);
        const id = try std.fmt.allocPrint(allocator, "git:{s}", .{root});
        errdefer allocator.free(id);
        const label = try allocator.dupe(u8, "Git");
        errdefer allocator.free(label);
        const name = std.fs.path.basename(std.mem.trimEnd(u8, root, "/\\"));
        const name_copy = if (name.len > 0) try allocator.dupe(u8, name) else try allocator.dupe(u8, root);
        errdefer allocator.free(name_copy);
        const primary_id = try std.fmt.allocPrint(allocator, "git:{s}:working", .{root});
        errdefer allocator.free(primary_id);
        const secondary_id = try std.fmt.allocPrint(allocator, "git:{s}:staged", .{root});
        errdefer allocator.free(secondary_id);

        self.* = .{
            .allocator = allocator,
            .git = git,
            .repository = repository,
            .root = root_copy,
            .id = id,
            .label = label,
            .name = name_copy,
            .branch = null,
            .host = host,
            .groups = undefined,
            .group_pointers = undefined,
            .group_slice = undefined,
            .base = undefined,
            .on_resources = Emitter(void).init(allocator),
            .on_groups = Emitter(void).init(allocator),
            .primary_quick_diff = undefined,
            .secondary_quick_diff = undefined,
        };
        errdefer {
            self.on_resources.deinit();
            self.on_groups.deinit();
        }

        const group_ids = [_][]const u8{ "merge", "index", "working" };
        const group_labels = [_][]const u8{ "Merge Changes", "Staged Changes", "Changes" };
        const hide_when_empty = [_]bool{ true, true, false };
        for (0..3) |index| {
            self.groups[index] = .{
                .provider = self,
                .index = index,
                .id = group_ids[index],
                .label = group_labels[index],
                .hide_when_empty = hide_when_empty[index],
                .resources = std.array_list.Managed(*GitScmResource).init(allocator),
                .interfaces = std.array_list.Managed(scm.ISCMResource).init(allocator),
                .iface = undefined,
                .resources_changed = Emitter(void).init(allocator),
                .changed = Emitter(void).init(allocator),
            };
            self.groups[index].iface = .{
                .context = &self.groups[index],
                .id = group_ids[index],
                .provider = &self.base,
                .label = group_labels[index],
                .hide_when_empty = hide_when_empty[index],
                .resources_fn = groupResources,
                .on_did_change_resources = &self.groups[index].resources_changed,
                .on_did_change = &self.groups[index].changed,
            };
            self.group_pointers[index] = &self.groups[index].iface;
            self.group_slice[index] = &self.groups[index].iface;
        }

        self.base = .{
            .context = self,
            .id = id,
            .provider_id = "git",
            .label = label,
            .name = name_copy,
            .root_path = root_copy,
            .groups_fn = providerGroups,
            .on_did_change_resource_groups = &self.on_groups,
            .on_did_change_resources = &self.on_resources,
            .dispose_fn = null,
        };

        self.rebuild();

        self.primary_quick_diff = .{
            .context = self,
            .id = primary_id,
            .label = "Git: Working Tree",
            .root_path = root_copy,
            .kind = .primary,
            .get_original_fn = getIndexOriginal,
        };
        self.secondary_quick_diff = .{
            .context = self,
            .id = secondary_id,
            .label = "Git: Staged",
            .root_path = root_copy,
            .kind = .secondary,
            .get_original_fn = getHeadOriginal,
        };
        return self;
    }

    pub fn destroy(self: *GitScmProvider) void {
        const allocator = self.allocator;
        allocator.free(@constCast(self.primary_quick_diff.id));
        allocator.free(@constCast(self.secondary_quick_diff.id));
        for (&self.groups) |*group| {
            for (group.resources.items) |resource| resource.destroy();
            group.resources.deinit();
            group.interfaces.deinit();
            group.resources_changed.deinit();
            group.changed.deinit();
        }
        self.on_resources.deinit();
        self.on_groups.deinit();
        if (self.branch) |branch| allocator.free(branch);
        allocator.free(self.root);
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn interface(self: *GitScmProvider) *scm.ISCMProvider {
        return &self.base;
    }

    pub fn quickDiffProviders(self: *GitScmProvider) [2]*QuickDiffProvider {
        return .{ &self.primary_quick_diff, &self.secondary_quick_diff };
    }

    pub fn count(self: *const GitScmProvider) usize {
        var total: usize = 0;
        for (&self.groups) |*group| total += group.resources.items.len;
        return total;
    }

    /// Recomputes the status and rebuilds the group resource lists.
    pub fn refresh(self: *GitScmProvider) !void {
        if (self.git) |git| {
            git.refresh(self.repository) catch {};
        }
        self.rebuild();
        for (&self.groups) |*group| {
            group.resources_changed.fire({}) catch {};
            group.changed.fire({}) catch {};
        }
        self.on_resources.fire({}) catch {};
    }

    fn rebuild(self: *GitScmProvider) void {
        for (&self.groups) |*group| {
            for (group.resources.items) |resource| resource.destroy();
            group.resources.clearRetainingCapacity();
            group.interfaces.clearRetainingCapacity();
        }

        const state = self.repository.stateRef();
        for (state.merge_changes) |change| {
            self.appendResource(0, .merge, change) catch {};
        }
        for (state.index_changes) |change| {
            self.appendResource(1, .index, change) catch {};
        }
        for (state.working_tree_changes) |change| {
            self.appendResource(2, .working, change) catch {};
        }
        for (state.untracked_changes) |change| {
            self.appendResource(2, .untracked, change) catch {};
        }

        for (&self.groups) |*group| {
            for (group.resources.items) |resource| {
                group.interfaces.append(resource.iface) catch {};
            }
        }
        self.base.count = self.count();
        if (self.branch) |branch| self.allocator.free(branch);
        self.branch = null;
        if (state.head) |head| {
            if (head.ref.name) |branch_name| {
                self.branch = self.allocator.dupe(u8, branch_name) catch null;
            }
        }
        self.base.detail = self.branch;
    }

    fn appendResource(self: *GitScmProvider, group_index: usize, kind: ResourceKind, change: GitChange) !void {
        const resource = try self.allocator.create(GitScmResource);
        errdefer self.allocator.destroy(resource);
        const relative = try self.allocator.dupe(u8, change.path);
        errdefer self.allocator.free(relative);
        const absolute = if (change.path.len > 0 and std.fs.path.isAbsolute(change.path))
            try self.allocator.dupe(u8, change.path)
        else
            try std.fs.path.join(self.allocator, &.{ self.root, change.path });
        errdefer self.allocator.free(absolute);
        const tooltip = try self.allocator.dupe(u8, change.path);
        errdefer self.allocator.free(tooltip);

        const status: u8 = if (change.status != 0) change.status else switch (kind) {
            .merge => 'U',
            .untracked => '?',
            else => 'M',
        };
        const group = &self.groups[group_index];
        resource.* = .{
            .provider = self,
            .relative_path = relative,
            .absolute_path = absolute,
            .kind = kind,
            .status = status,
            .status_text = .{status},
            .decorations = .{
                .tooltip = tooltip,
                .strike_through = status == 'D',
                .faded = kind == .untracked,
            },
            .iface = .{
                .context = resource,
                .resource_group = &group.iface,
                .source_path = absolute,
                .decorations = .{
                    .tooltip = tooltip,
                    .strike_through = status == 'D',
                    .faded = kind == .untracked,
                },
                .context_value = &resource.status_text,
                .command = null,
                .open_fn = openResource,
            },
        };
        try group.resources.append(resource);
    }

    fn relativePath(self: *const GitScmProvider, path: []const u8) ?[]const u8 {
        const root = std.mem.trimEnd(u8, self.root, "/\\");
        if (path.len <= root.len + 1) return null;
        if (!std.mem.startsWith(u8, path, root)) return null;
        if (path[root.len] != '/' and path[root.len] != '\\') return null;
        return path[root.len + 1 ..];
    }
};

fn providerGroups(context: *anyopaque) []const *scm.ISCMResourceGroup {
    const self: *GitScmProvider = @ptrCast(@alignCast(context));
    return &self.group_slice;
}

fn groupResources(context: *anyopaque) []const scm.ISCMResource {
    const group: *GitScmGroup = @ptrCast(@alignCast(context));
    return group.interfaces.items;
}

fn openResource(context: *anyopaque, preserve_focus: bool) anyerror!void {
    _ = preserve_focus;
    const resource: *GitScmResource = @ptrCast(@alignCast(context));
    return resource.provider.host.open_change(
        resource.provider.host.context,
        resource.provider,
        resource,
    );
}

fn getIndexOriginal(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?Original {
    return getOriginal(context, allocator, path, .index, "Index");
}

fn getHeadOriginal(context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?Original {
    return getOriginal(context, allocator, path, .head, "HEAD");
}

fn getOriginal(
    context: *anyopaque,
    allocator: Allocator,
    path: []const u8,
    kind: git_cli_mod.RefKind,
    label: []const u8,
) !?Original {
    const self: *GitScmProvider = @ptrCast(@alignCast(context));
    const git = self.git orelse return null;
    const relative = self.relativePath(path) orelse return null;
    const content = try git.readRef(self.root, relative, kind) orelse return null;
    errdefer allocator.free(content);
    return .{
        .content = content,
        .ref_label = try allocator.dupe(u8, label),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const FakeDelegate = struct {
    base: git_common.IGitExtensionDelegate = undefined,

    fn init(self: *FakeDelegate) void {
        self.base = .{
            .context = self,
            .repositories_fn = repositories,
            .open_repository_fn = openRepository,
            .get_refs_fn = getRefs,
            .diff_between_with_stats_fn = diffBetween,
            .diff_between_with_stats2_fn = diffBetween2,
            .commit_files_fn = commitFiles,
        };
    }

    fn repositories(_: *anyopaque) []const git_common.IGitRepository {
        return &.{};
    }
    fn openRepository(_: *anyopaque, _: []const u8) anyerror!?git_common.IGitRepository {
        return null;
    }
    fn getRefs(_: *anyopaque, _: Allocator, _: []const u8, _: git_common.GitRefQuery, _: git_common.CancellationToken) anyerror![]git_common.GitRef {
        return &.{};
    }
    fn diffBetween(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8, _: ?[]const u8) anyerror![]git_common.GitDiffChange {
        return &.{};
    }
    fn diffBetween2(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: ?[]const u8) anyerror![]git_common.GitDiffChange {
        return &.{};
    }
    fn commitFiles(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8, _: git_common.GitCommitOptions) anyerror!void {}
};

const TestHost = struct {
    opened: usize = 0,

    fn openChange(context: *anyopaque, _: *GitScmProvider, _: *GitScmResource) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.opened += 1;
    }
};

fn makeState(allocator: Allocator) !GitRepositoryState {
    var state = GitRepositoryState{};
    state.merge_changes = try allocator.alloc(GitChange, 1);
    state.merge_changes[0] = .{ .path = try allocator.dupe(u8, "conflict.zig"), .status = 'U' };
    state.index_changes = try allocator.alloc(GitChange, 1);
    state.index_changes[0] = .{ .path = try allocator.dupe(u8, "staged.zig"), .status = 'M' };
    state.working_tree_changes = try allocator.alloc(GitChange, 1);
    state.working_tree_changes[0] = .{ .path = try allocator.dupe(u8, "working.zig"), .status = 'M' };
    state.untracked_changes = try allocator.alloc(GitChange, 1);
    state.untracked_changes[0] = .{ .path = try allocator.dupe(u8, "new.zig"), .status = '?' };
    return state;
}

test "gitScmProvider: groups, status letters and resource opening" {
    const allocator = testing.allocator;
    var fake = FakeDelegate{};
    fake.init();
    var state = try makeState(allocator);
    const repository = try GitRepository.create(allocator, "/repo", state, &fake.base);
    defer repository.destroy();
    state.deinit(allocator);

    var host = TestHost{};
    const provider = try GitScmProvider.create(allocator, null, repository, "/repo", .{
        .context = &host,
        .open_change = TestHost.openChange,
    });
    defer provider.destroy();

    const interface = provider.interface();
    try testing.expectEqualStrings("Git", interface.label);
    try testing.expectEqualStrings("repo", interface.name);
    const groups = interface.groups();
    try testing.expectEqual(@as(usize, 3), groups.len);
    try testing.expectEqualStrings("Merge Changes", groups[0].label);
    try testing.expectEqualStrings("Staged Changes", groups[1].label);
    try testing.expectEqualStrings("Changes", groups[2].label);

    try testing.expectEqual(@as(usize, 1), groups[0].resources().len);
    try testing.expectEqual(@as(u8, 'U'), provider.groups[0].resources.items[0].status);
    try testing.expectEqual(@as(usize, 2), groups[2].resources().len);
    try testing.expectEqualStrings("/repo/new.zig", groups[2].resources()[1].source_path);
    try testing.expectEqual(@as(usize, 4), provider.count());

    try groups[1].resources()[0].open(false);
    try testing.expectEqual(@as(usize, 1), host.opened);

    try testing.expectEqual(@as(usize, 2), provider.quickDiffProviders().len);
}

test "gitScmProvider: refresh rebuilds from the repository state" {
    const allocator = testing.allocator;
    var fake = FakeDelegate{};
    fake.init();
    var state = try makeState(allocator);
    const repository = try GitRepository.create(allocator, "/repo", state, &fake.base);
    defer repository.destroy();
    state.deinit(allocator);

    var host = TestHost{};
    const provider = try GitScmProvider.create(allocator, null, repository, "/repo", .{
        .context = &host,
        .open_change = TestHost.openChange,
    });
    defer provider.destroy();

    try testing.expectEqual(@as(usize, 4), provider.count());
    var next = GitRepositoryState{};
    next.index_changes = try allocator.alloc(GitChange, 1);
    next.index_changes[0] = .{ .path = try allocator.dupe(u8, "only-staged.zig"), .status = 'A' };
    defer next.deinit(allocator);
    try repository.updateState(next);

    try provider.refresh();
    try testing.expectEqual(@as(usize, 1), provider.count());
    const groups = provider.interface().groups();
    try testing.expectEqualStrings("/repo/only-staged.zig", groups[1].resources()[0].source_path);
}

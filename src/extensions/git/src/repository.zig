// Port of `vscode/extensions/git/src/repository.ts` (terminal SCM subset).
//
// There is no `vscode.git` extension-host SCM actor in this port, so this
// terminal `Repository` implements `ISCMProvider` directly over the
// command-line git service instead of calling `scm.createSourceControl`. The
// upstream `git` extension's resource groups, status letters and quick-diff
// providers are reproduced here; the group/resource rows are painted by
// `src/vs/workbench/contrib/scm/browser/scmViewPane.zig`.
//
// Groups: `Merge Changes`, `Staged Changes`, `Changes` (working-tree changes
// with untracked files mixed in, matching `git.untrackedChanges=mixed`).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const scm = @import("../../../vs/workbench/contrib/scm/common/scm.zig");
const quick_diff = @import("../../../vs/workbench/contrib/scm/common/quickDiff.zig");
const git_common = @import("../../../vs/workbench/contrib/git/common/gitService.zig");
const git_browser = @import("../../../vs/workbench/contrib/git/browser/gitService.zig");
const git_mod = @import("./git.zig");
const history_provider_mod = @import("./historyProvider.zig");
const configuration = @import("../../../vs/platform/configuration/common/configuration.zig");
const ConfigurationService = @import("../../../vs/workbench/services/configuration/browser/configurationService.zig").ConfigurationService;
const Emitter = @import("../../../vs/base/common/event.zig").Emitter;

pub const Git = git_mod.Git;
pub const GitRepository = git_browser.GitRepository;
pub const GitRepositoryState = git_common.GitRepositoryState;
pub const GitChange = git_common.GitChange;
pub const QuickDiffProvider = quick_diff.QuickDiffProvider;
pub const GitHistoryProvider = history_provider_mod.GitHistoryProvider;
pub const Original = quick_diff.Original;

const dispatch = @import("../../../vs/base/common/windowDispatch.zig");
const watchers = @import("../../../vs/platform/files/node/watcher/fileWatcherService.zig");
const files = @import("../../../vs/platform/files/common/files.zig");
const time = @import("../../../vs/base/common/timeCompat.zig");

pub const Host = struct {
    auto_refresh: ?*const fn (*anyopaque) bool = null,
    refresh: ?*const fn (*anyopaque) void = null,
    context: *anyopaque,
    /// Opens the change represented by `resource` (usually a diff tab).
    open_change: *const fn (context: *anyopaque, provider: *Repository, resource: *GitScmResource) anyerror!void,
};

pub const ResourceKind = enum { merge, index, working, untracked };

pub const GitScmResource = struct {
    provider: *Repository,
    relative_path: []u8,
    original_path: ?[]u8 = null,
    absolute_path: []u8,
    kind: ResourceKind,
    /// Porcelain v2 status letter (`M`, `A`, `D`, `R`, `?`, ...).
    status: u8,
    /// Upstream `Resource.letter` projection (`U` for untracked, `!` for a
    /// conflict, ...); the resource row paints it as a file decoration badge.
    letter: [1]u8,
    decorations: scm.ISCMResourceDecorations,
    iface: scm.ISCMResource,

    pub fn destroy(self: *GitScmResource) void {
        const allocator = self.provider.allocator;
        allocator.free(self.relative_path);
        if (self.original_path) |path| allocator.free(path);
        allocator.free(self.absolute_path);
        if (self.decorations.tooltip) |tooltip| allocator.free(tooltip);
        allocator.destroy(self);
    }
};

pub const GitScmGroup = struct {
    provider: *Repository,
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

pub const Repository = struct {
    allocator: Allocator,
    /// Null in focused tests that only validate group/resource projection.
    git: ?*Git,
    repository: *GitRepository,
    root: []u8,
    id: []u8,
    label: []u8,
    name: []u8,
    branch: ?[]u8 = null,
    status_bar: @import("statusbar.zig").StatusBarCommands = .{},
    host: Host,
    groups: [3]GitScmGroup,
    group_pointers: [3]*scm.ISCMResourceGroup,
    group_slice: [3]*scm.ISCMResourceGroup,
    base: scm.ISCMProvider,
    on_resources: Emitter(void),
    on_change: Emitter(void),
    input_placeholder_buffer: [160]u8 = undefined,
    configuration_service: ?*ConfigurationService = null,
    configuration_listener: ?usize = null,
    on_groups: Emitter(void),
    primary_quick_diff: QuickDiffProvider,
    secondary_quick_diff: QuickDiffProvider,
    history: ?*GitHistoryProvider = null,
    file_service: ?*watchers.FileWatcherService = null,
    file_listener: ?usize = null,
    root_watcher: ?*watchers.WatchHandle = null,
    dot_git_watcher: ?*watchers.WatchHandle = null,
    upstream_watcher: ?*watchers.WatchHandle = null,
    dot_git: ?Git.DotGit = null,
    status_timer: dispatch.Task = .{},
    next_status_at: i64 = 0,
    focused: bool = true,
    host_focus_listener: ?@import("../../../vs/base/common/event.zig").SignalSubscription = null,
    refresh_when_focused: bool = false,

    pub fn create(
        allocator: Allocator,
        git: ?*Git,
        repository: *GitRepository,
        root: []const u8,
        host: Host,
    ) !*Repository {
        const self = try allocator.create(Repository);
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
            .on_change = Emitter(void).init(allocator),
            .on_groups = Emitter(void).init(allocator),
            .primary_quick_diff = undefined,
            .secondary_quick_diff = undefined,
        };
        errdefer {
            self.on_resources.deinit();
            self.on_change.deinit();
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
            .on_did_change = &self.on_change,
            .dispose_fn = null,
        };

        self.rebuild();

        if (history_provider_mod.GitHistoryProvider.create(allocator, repository)) |history| {
            self.history = history;
            self.base.history_provider = history.interface();
        } else |_| {}

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

    pub fn watch(self: *Repository, service: *watchers.FileWatcherService) !void {
        if (self.file_service != null) return;
        const git = self.git orelse return;
        const root_watcher = try service.watch(self.root, .{ .recursive = true });
        errdefer root_watcher.dispose();
        try self.listenForFileChanges(service);
        self.root_watcher = root_watcher;
        // A worktree's metadata can live outside its workspace.
        self.dot_git = git.getRepositoryDotGit(self.root) catch return;
        self.dot_git_watcher = service.watch(self.dot_git.?.path, .{ .recursive = false }) catch null;
        self.updateUpstreamWatcher();
    }

    // The extension owns its workspace watcher subscription, just as
    // Repository listens to onRepositoryWorkingTreeFileChange and DotGitWatcher.
    fn listenForFileChanges(self: *Repository, service: *watchers.FileWatcherService) !void {
        self.file_listener = try service.on_did_change.listen(self, onFileChanges);
        self.file_service = service;
    }

    fn onFileChanges(changes: []const files.FileChange, self: *Repository) !void {
        for (changes) |change| self.onFileChange(change.resource);
    }

    fn updateUpstreamWatcher(self: *Repository) void {
        const service = self.file_service orelse return;
        const dot = self.dot_git orelse return;
        const head = self.repository.stateRef().head;
        const upstream = if (head) |branch| branch.upstream else null;
        const target = if (upstream) |u| std.fs.path.join(self.allocator, &.{ dot.common_path, "refs", "remotes", u.remote, u.name }) catch return else null;
        defer if (target) |path| self.allocator.free(path);
        if (self.upstream_watcher) |watcher| {
            if (target != null and std.mem.eql(u8, watcher.path, target.?)) return;
            watcher.dispose();
            self.upstream_watcher = null;
        }
        if (target) |path| self.upstream_watcher = service.watch(path, .{ .recursive = false }) catch null;
    }

    pub fn attachWindow(self: *Repository, window: *dispatch.Queue) void {
        self.status_timer = .{ .queue = window, .context = self, .run = updateWhenIdle };
    }

    pub fn onFileChange(self: *Repository, path: []const u8) void {
        if (self.configuration_service) |config| if (!config.getBool("git.autorefresh", true)) return;
        if (self.host.auto_refresh) |enabled| if (!enabled(self.host.context)) return;
        const ignore_case = @import("builtin").os.tag == .windows;
        const name = std.fs.path.basename(path);
        if (std.mem.startsWith(u8, name, ".watchman-cookie-")) return;
        const upstream = if (self.upstream_watcher) |w| std.mem.eql(u8, w.path, path) else false;
        if (!upstream) {
            if (self.dot_git) |dot| {
                if (std.mem.eql(u8, path, dot.path)) return;
                if (files.isParent(path, dot.path, ignore_case)) {
                    if (!std.mem.eql(u8, std.fs.path.dirname(path) orelse return, dot.path) or std.mem.eql(u8, name, "index.lock")) return;
                    self.scheduleStatus();
                    return;
                }
            }
            if (!files.isParent(path, self.root, ignore_case)) return;
            var segments = std.mem.tokenizeAny(u8, path[self.root.len..], "/\\");
            while (segments.next()) |part| if (std.mem.eql(u8, part, ".git")) return;
        }
        self.scheduleStatus();
    }

    fn scheduleStatus(self: *Repository) void {
        self.status_timer.schedule(@max(time.milliTimestamp() + 1000, self.next_status_at));
    }

    pub fn attachHostService(self: *Repository, host: @import("../../../vs/workbench/services/host/browser/host.zig").IHostService) !void {
        if (self.host_focus_listener) |listener| listener.dispose();
        self.host_focus_listener = null;
        self.host_focus_listener = try host.on_did_change_focus.listenDisposable(self, onDidChangeWindowState);
        self.onWindowFocus(host.hasFocus());
    }

    fn onDidChangeWindowState(focused: bool, self: *Repository) !void {
        self.onWindowFocus(focused);
    }

    pub fn onWindowFocus(self: *Repository, focused: bool) void {
        self.focused = focused;
        if (focused and self.refresh_when_focused) {
            self.refresh_when_focused = false;
            self.status_timer.schedule(@max(time.milliTimestamp(), self.next_status_at));
        }
    }

    fn updateWhenIdle(ctx: *anyopaque, now: i64, _: bool) bool {
        const self: *Repository = @ptrCast(@alignCast(ctx));
        if (!self.focused) {
            self.refresh_when_focused = true;
            return false;
        }
        if (self.host.refresh) |refresh_status| refresh_status(self.host.context);
        self.next_status_at = now + 5000;
        return true;
    }

    pub fn destroy(self: *Repository) void {
        const allocator = self.allocator;
        if (self.host_focus_listener) |listener| listener.dispose();
        self.detachConfiguration();
        self.status_timer.schedule(null);
        if (self.file_listener) |listener| self.file_service.?.on_did_change.unlisten(listener);
        if (self.upstream_watcher) |w| w.dispose();
        if (self.dot_git_watcher) |w| w.dispose();
        if (self.root_watcher) |w| w.dispose();
        if (self.dot_git) |dot| dot.deinit(allocator);
        if (self.history) |history| history.destroy();
        self.history = null;
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
        self.on_change.deinit();
        self.on_groups.deinit();
        if (self.branch) |branch| allocator.free(branch);
        allocator.free(self.root);
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.name);
        allocator.destroy(self);
    }

    pub fn interface(self: *Repository) *scm.ISCMProvider {
        return &self.base;
    }

    pub fn historyProvider(self: *Repository) ?*GitHistoryProvider {
        return self.history;
    }

    pub fn detachConfiguration(self: *Repository) void {
        if (self.configuration_listener) |listener| self.configuration_service.?.unlistenConfigurationChange(listener);
        self.configuration_listener = null;
        self.configuration_service = null;
    }

    pub fn setConfiguration(self: *Repository, config: ?*ConfigurationService) !void {
        self.detachConfiguration();
        self.configuration_service = config;
        if (config) |service| self.configuration_listener = try service.listenConfigurationChange(self, onDidChangeConfiguration);
        self.applyConfiguration();
    }

    fn onDidChangeConfiguration(change: configuration.Change, self: *Repository) !void {
        if (configuration.affectsConfiguration(change, "git.showCommitInput") or
            configuration.affectsConfiguration(change, "git.commitShortHashLength"))
            self.applyConfiguration();
    }

    fn applyConfiguration(self: *Repository) void {
        const config = self.configuration_service;
        self.base.input_box_visible = if (config) |service| service.getBool("git.showCommitInput", true) else true;
        var short_hash_length: usize = 7;
        if (config) |service| {
            if (service.getValue("git.commitShortHashLength", .{})) |value| {
                if (value.* == .integer) short_hash_length = @intCast(@max(value.integer, 1));
            }
        }
        self.setCommitShortHashLength(short_hash_length);
        self.on_change.fire({}) catch {};
    }

    pub fn setCommitShortHashLength(self: *Repository, length: usize) void {
        if (self.history) |history| history.setCommitShortHashLength(length);
    }

    /// Re-reads history refs; returns whether anything changed. Errors are kept
    /// on the provider (`lastError`) so the view can show an empty state.
    pub fn refreshHistoryRefs(self: *Repository, silent: bool) bool {
        const history = self.history orelse return false;
        return history.refreshRefs(silent) catch |err| {
            history.last_error = err;
            return false;
        };
    }

    pub fn quickDiffProviders(self: *Repository) [2]*QuickDiffProvider {
        return .{ &self.primary_quick_diff, &self.secondary_quick_diff };
    }

    /// The Git resource's status determines its original and modified
    /// resources. Conflict resources open the file instead of a snapshot diff.
    pub fn diffRefsForResource(self: *Repository, resource: *const GitScmResource) ?struct { left: git_mod.DiffRef, right: git_mod.DiffRef } {
        _ = self;
        return switch (resource.kind) {
            .merge => null,
            .untracked => .{ .left = .empty, .right = .working },
            .index => .{ .left = .head, .right = .index },
            // The working-tree modified resource has the stable Git URI
            // with ref "~" (the index when staged, otherwise HEAD). The
            // index contains HEAD's blob when the file is not staged, so it
            // is also the correct initial content for that same resource.
            .working => .{ .left = if (resource.status == 'M') .index else .head, .right = .working },
        };
    }

    pub fn stage(self: *Repository, path: []const u8, contents: []const u8, encoding: @import("../../../vs/workbench/services/textfile/common/encoding.zig").Encoding) !void {
        const codec = @import("../../../vs/workbench/services/textfile/common/encoding.zig");
        const relative = self.relativePath(path) orelse return error.OutsideRepository;
        const bytes = try codec.encode(self.allocator, contents, encoding);
        defer self.allocator.free(bytes);
        try (self.git orelse return error.NoGit).stage(self.root, relative, bytes);
    }

    pub fn count(self: *const Repository) usize {
        var total: usize = 0;
        for (&self.groups) |*group| total += group.resources.items.len;
        return total;
    }

    /// Recomputes the status and rebuilds the group resource lists.
    pub fn refresh(self: *Repository) !void {
        if (self.git) |git| {
            git.refresh(self.repository) catch {};
        }
        self.rebuild();
        self.updateUpstreamWatcher();
        for (&self.groups) |*group| {
            group.resources_changed.fire({}) catch {};
            group.changed.fire({}) catch {};
        }
        self.on_resources.fire({}) catch {};
        self.on_change.fire({}) catch {};
    }

    fn rebuild(self: *Repository) void {
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
        self.base.status_bar_commands = self.status_bar.update(state, self.count());
        if (self.branch) |branch| self.allocator.free(branch);
        self.branch = null;
        if (state.head) |head| {
            if (head.ref.name) |branch_name| {
                self.branch = self.allocator.dupe(u8, branch_name) catch null;
            }
        }
        self.base.detail = self.branch;
        self.base.branch_action = @import("actionButton.zig").branchAction(state);
        self.base.action_button_secondary_commands = @import("actionButton.zig").getCommitActionButtonSecondaryCommands(state);
        self.base.fresh_repository = if (state.head) |head| head.ref.commit == null else true;
        // Upstream inserts the accept-command keybinding into the template.
        // This terminal input currently accepts Enter.
        self.base.input_box_placeholder = if (self.branch) |branch|
            std.fmt.bufPrint(&self.input_placeholder_buffer, "Message (Enter to commit on \"{s}\")", .{branch}) catch "Message (Enter to commit)"
        else
            "Message (Enter to commit)";
    }

    fn appendResource(self: *Repository, group_index: usize, kind: ResourceKind, change: GitChange) !void {
        const resource = try self.allocator.create(GitScmResource);
        errdefer self.allocator.destroy(resource);
        const relative = try self.allocator.dupe(u8, change.path);
        errdefer self.allocator.free(relative);
        const original = if (change.original_path) |path| try self.allocator.dupe(u8, path) else null;
        errdefer if (original) |path| self.allocator.free(path);
        const absolute = if (change.path.len > 0 and std.fs.path.isAbsolute(change.path))
            try self.allocator.dupe(u8, change.path)
        else
            try std.fs.path.join(self.allocator, &.{ self.root, change.path });
        errdefer self.allocator.free(absolute);
        const status: u8 = if (change.status != 0) change.status else switch (kind) {
            .merge => 'U',
            .untracked => '?',
            else => 'M',
        };
        const info = statusDecoration(kind, status, change.conflict);
        const tooltip = try self.allocator.dupe(u8, info.tooltip);
        errdefer self.allocator.free(tooltip);

        const group = &self.groups[group_index];
        resource.* = .{
            .provider = self,
            .relative_path = relative,
            .original_path = original,
            .absolute_path = absolute,
            .kind = kind,
            .status = status,
            .letter = .{info.letter},
            .decorations = .{
                .tooltip = tooltip,
                .strike_through = info.strike_through,
                .faded = false,
                .letter = &resource.letter,
                .color = info.color,
            },
            .iface = .{
                .context = resource,
                .resource_group = &group.iface,
                .source_path = absolute,
                .decorations = .{
                    .tooltip = tooltip,
                    .strike_through = info.strike_through,
                    .faded = false,
                    .letter = &resource.letter,
                    .color = info.color,
                },
                .context_value = null,
                .command = null,
                .open_fn = openResource,
            },
        };
        try group.resources.append(resource);
    }

    fn relativePath(self: *const Repository, path: []const u8) ?[]const u8 {
        const root = std.mem.trimEnd(u8, self.root, "/\\");
        if (path.len <= root.len + 1) return null;
        if (!std.mem.startsWith(u8, path, root)) return null;
        if (path[root.len] != '/' and path[root.len] != '\\') return null;
        return path[root.len + 1 ..];
    }
};

const StatusDecoration = struct {
    letter: u8,
    tooltip: []const u8,
    color: []const u8,
    strike_through: bool = false,
};

/// Port of the upstream `git` extension's `Resource.getStatusLetter`/
/// `getStatusText`/`getStatusColor` mapping. The terminal provider carries the
/// resulting file decoration on the SCM resource because the workbench has no
/// general file decoration service.
fn statusDecoration(kind: ResourceKind, status: u8, conflict: ?[2]u8) StatusDecoration {
    return switch (kind) {
        .merge => conflictDecoration(conflict),
        .index => switch (status) {
            'M' => .{ .letter = 'M', .tooltip = "Index Modified", .color = "gitDecoration.stageModifiedResourceForeground" },
            'A' => .{ .letter = 'A', .tooltip = "Index Added", .color = "gitDecoration.addedResourceForeground" },
            'D' => .{ .letter = 'D', .tooltip = "Index Deleted", .color = "gitDecoration.stageDeletedResourceForeground", .strike_through = true },
            'R' => .{ .letter = 'R', .tooltip = "Index Renamed", .color = "gitDecoration.renamedResourceForeground" },
            'C' => .{ .letter = 'C', .tooltip = "Index Copied", .color = "gitDecoration.renamedResourceForeground" },
            else => .{ .letter = status, .tooltip = "Index Modified", .color = "gitDecoration.stageModifiedResourceForeground" },
        },
        .working => switch (status) {
            'M' => .{ .letter = 'M', .tooltip = "Modified", .color = "gitDecoration.modifiedResourceForeground" },
            'D' => .{ .letter = 'D', .tooltip = "Deleted", .color = "gitDecoration.deletedResourceForeground", .strike_through = true },
            'A' => .{ .letter = 'A', .tooltip = "Intent to Add", .color = "gitDecoration.addedResourceForeground" },
            'R' => .{ .letter = 'R', .tooltip = "Intent to Rename", .color = "gitDecoration.renamedResourceForeground" },
            'T' => .{ .letter = 'T', .tooltip = "Type Changed", .color = "gitDecoration.modifiedResourceForeground" },
            '?' => .{ .letter = 'U', .tooltip = "Untracked", .color = "gitDecoration.untrackedResourceForeground" },
            else => .{ .letter = status, .tooltip = "Modified", .color = "gitDecoration.modifiedResourceForeground" },
        },
        .untracked => .{ .letter = 'U', .tooltip = "Untracked", .color = "gitDecoration.untrackedResourceForeground" },
    };
}

fn conflictDecoration(conflict: ?[2]u8) StatusDecoration {
    const pair = conflict orelse return .{
        .letter = '!',
        .tooltip = "Conflict",
        .color = "gitDecoration.conflictingResourceForeground",
    };
    const xy = pair;
    if (xy[0] == 'D' and xy[1] == 'D') {
        return .{ .letter = '!', .tooltip = "Conflict: Both Deleted", .color = "gitDecoration.conflictingResourceForeground", .strike_through = true };
    }
    if (xy[0] == 'A' and xy[1] == 'U') {
        return .{ .letter = '!', .tooltip = "Conflict: Added By Us", .color = "gitDecoration.conflictingResourceForeground" };
    }
    if (xy[0] == 'U' and xy[1] == 'D') {
        return .{ .letter = '!', .tooltip = "Conflict: Deleted By Them", .color = "gitDecoration.conflictingResourceForeground", .strike_through = true };
    }
    if (xy[0] == 'U' and xy[1] == 'A') {
        return .{ .letter = '!', .tooltip = "Conflict: Added By Them", .color = "gitDecoration.conflictingResourceForeground" };
    }
    if (xy[0] == 'D' and xy[1] == 'U') {
        return .{ .letter = '!', .tooltip = "Conflict: Deleted By Us", .color = "gitDecoration.conflictingResourceForeground", .strike_through = true };
    }
    if (xy[0] == 'A' and xy[1] == 'A') {
        return .{ .letter = '!', .tooltip = "Conflict: Both Added", .color = "gitDecoration.conflictingResourceForeground" };
    }
    if (xy[0] == 'U' and xy[1] == 'U') {
        return .{ .letter = '!', .tooltip = "Conflict: Both Modified", .color = "gitDecoration.conflictingResourceForeground" };
    }
    return .{ .letter = '!', .tooltip = "Conflict", .color = "gitDecoration.conflictingResourceForeground" };
}

fn providerGroups(context: *anyopaque) []const *scm.ISCMResourceGroup {
    const self: *Repository = @ptrCast(@alignCast(context));
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
    kind: git_mod.RefKind,
    label: []const u8,
) !?Original {
    const self: *Repository = @ptrCast(@alignCast(context));
    const git = self.git orelse return null;
    const relative = self.relativePath(path) orelse return null;
    const content = try git.readRef(self.root, relative, kind) orelse return null;
    errdefer allocator.free(content);
    const ref_label = try allocator.dupe(u8, label);
    errdefer allocator.free(ref_label);
    const absolute = try std.fs.path.join(allocator, &.{ self.root, relative });
    defer allocator.free(absolute);
    const uri = try @import("uri.zig").toGitUriWithOptions(allocator, absolute, if (kind == .index) "" else "HEAD", .{ .replace_file_extension = true });
    defer allocator.free(uri.path.raw);
    defer allocator.free(uri.query.?.raw);
    return .{ .content = content, .ref_label = ref_label, .resource_uri = try @import("../../../vs/base/common/stdUri.zig").resourceKey(allocator, uri) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The fake repository root is spelled the way the host spells an absolute
/// path, so the provider's `std.fs.path.join` expectations match production.
const test_root = if (builtin.os.tag == .windows) "C:\\repo" else "/repo";

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
            .log_fn = log,
            .diff_root_commit_fn = diffRootCommit,
            .merge_base_fn = mergeBase,
            .get_branch_fn = getBranch,
            .get_branch_base_fn = getBranchBase,
            .read_ref_at_fn = readRefAt,
            .has_git_version_at_least_fn = hasGitVersionAtLeast,
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
    fn log(_: *anyopaque, _: Allocator, _: []const u8, _: git_common.GitLogOptions, _: git_common.CancellationToken) anyerror![]git_common.GitCommit {
        return &.{};
    }
    fn diffRootCommit(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror![]git_common.GitDiffChange {
        return &.{};
    }
    fn mergeBase(_: *anyopaque, _: Allocator, _: []const u8, _: []const []const u8) anyerror!?[]u8 {
        return null;
    }
    fn getBranch(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror!?git_common.GitBranch {
        return null;
    }
    fn getBranchBase(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror!?git_common.GitBranch {
        return null;
    }
    fn readRefAt(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!?[]u8 {
        return null;
    }
    fn hasGitVersionAtLeast(_: *anyopaque, _: usize, _: usize) bool {
        return true;
    }
};

const TestHost = struct {
    opened: usize = 0,

    fn openChange(context: *anyopaque, _: *Repository, _: *GitScmResource) anyerror!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.opened += 1;
    }
};

fn makeState(allocator: Allocator) !GitRepositoryState {
    var state = GitRepositoryState{};
    state.merge_changes = try allocator.alloc(GitChange, 1);
    state.merge_changes[0] = .{
        .path = try allocator.dupe(u8, "conflict.zig"),
        .status = 'U',
        .conflict = .{ 'U', 'U' },
    };
    state.index_changes = try allocator.alloc(GitChange, 1);
    state.index_changes[0] = .{ .path = try allocator.dupe(u8, "staged.zig"), .status = 'M' };
    state.working_tree_changes = try allocator.alloc(GitChange, 1);
    state.working_tree_changes[0] = .{ .path = try allocator.dupe(u8, "working.zig"), .status = 'M' };
    state.untracked_changes = try allocator.alloc(GitChange, 1);
    state.untracked_changes[0] = .{ .path = try allocator.dupe(u8, "new.zig"), .status = '?' };
    return state;
}

test "repository: groups, status letters and resource opening" {
    const allocator = testing.allocator;
    var fake = FakeDelegate{};
    fake.init();
    var state = try makeState(allocator);
    const repository = try GitRepository.create(allocator, test_root, state, &fake.base);
    defer repository.destroy();
    state.deinit(allocator);

    var host = TestHost{};
    const provider = try Repository.create(allocator, null, repository, test_root, .{
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
    const merge_decorations = groups[0].resources()[0].decorations;
    try testing.expectEqualStrings("!", merge_decorations.letter.?);
    try testing.expectEqualStrings("Conflict: Both Modified", merge_decorations.tooltip.?);
    try testing.expectEqualStrings("gitDecoration.conflictingResourceForeground", merge_decorations.color.?);

    const staged_decorations = groups[1].resources()[0].decorations;
    try testing.expectEqualStrings("M", staged_decorations.letter.?);
    try testing.expectEqualStrings("Index Modified", staged_decorations.tooltip.?);
    try testing.expectEqualStrings("gitDecoration.stageModifiedResourceForeground", staged_decorations.color.?);

    try testing.expectEqual(@as(usize, 2), groups[2].resources().len);
    const working_decorations = groups[2].resources()[0].decorations;
    try testing.expectEqualStrings("M", working_decorations.letter.?);
    try testing.expectEqualStrings("Modified", working_decorations.tooltip.?);
    try testing.expectEqualStrings("gitDecoration.modifiedResourceForeground", working_decorations.color.?);
    const untracked_decorations = groups[2].resources()[1].decorations;
    try testing.expectEqualStrings("U", untracked_decorations.letter.?);
    try testing.expectEqualStrings("Untracked", untracked_decorations.tooltip.?);
    try testing.expectEqualStrings("gitDecoration.untrackedResourceForeground", untracked_decorations.color.?);
    try testing.expect(!untracked_decorations.faded);
    const expected_untracked = try std.fs.path.join(allocator, &.{ test_root, "new.zig" });
    defer allocator.free(expected_untracked);
    try testing.expectEqualStrings(expected_untracked, groups[2].resources()[1].source_path);
    try testing.expectEqual(@as(usize, 4), provider.count());

    try groups[1].resources()[0].open(false);
    try testing.expectEqual(@as(usize, 1), host.opened);

    try testing.expectEqual(@as(usize, 2), provider.quickDiffProviders().len);
}

test "repository: refresh rebuilds from the repository state" {
    const allocator = testing.allocator;
    var fake = FakeDelegate{};
    fake.init();
    var state = try makeState(allocator);
    const repository = try GitRepository.create(allocator, test_root, state, &fake.base);
    defer repository.destroy();
    state.deinit(allocator);

    var host = TestHost{};
    const provider = try Repository.create(allocator, null, repository, test_root, .{
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
    const expected_staged = try std.fs.path.join(allocator, &.{ test_root, "only-staged.zig" });
    defer allocator.free(expected_staged);
    try testing.expectEqualStrings(expected_staged, groups[1].resources()[0].source_path);
}

test "repository: file changes debounce status, wait for focus and respect autorefresh" {
    const allocator = testing.allocator;
    var fake = FakeDelegate{};
    fake.init();
    const repository = try GitRepository.create(allocator, test_root, .{}, &fake.base);
    defer repository.destroy();

    const HostState = struct {
        enabled: bool = true,
        refreshes: usize = 0,
        fn enabledForWindow(ctx: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.enabled;
        }
        fn refreshStatus(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.refreshes += 1;
        }
    };
    var host = HostState{};
    var window = dispatch.Queue{ .io = testing.io };
    const file_service = try watchers.FileWatcherService.init(allocator, testing.io);
    defer file_service.deinit();
    const provider = try Repository.create(allocator, null, repository, test_root, .{
        .context = &host,
        .open_change = TestHost.openChange,
        .auto_refresh = HostState.enabledForWindow,
        .refresh = HostState.refreshStatus,
    });
    defer provider.destroy();
    provider.attachWindow(&window);
    try provider.listenForFileChanges(file_service);
    const index = try std.fs.path.join(allocator, &.{ test_root, ".git", "index" });
    defer allocator.free(index);
    const index_lock = try std.mem.concat(allocator, u8, &.{ index, ".lock" });
    defer allocator.free(index_lock);
    provider.dot_git = .{
        .path = try allocator.dupe(u8, std.fs.path.dirname(index).?),
        .common_path = try allocator.dupe(u8, std.fs.path.dirname(index).?),
    };
    try file_service.on_did_change.fire(&.{.{ .type = .ADDED, .resource = index_lock }});
    try testing.expect(provider.status_timer.at == null);
    host.enabled = false;
    try file_service.on_did_change.fire(&.{.{ .type = .UPDATED, .resource = index }});
    try testing.expect(provider.status_timer.at == null);
    host.enabled = true;
    try file_service.on_did_change.fire(&.{.{ .type = .UPDATED, .resource = index }});
    try file_service.on_did_change.fire(&.{.{ .type = .UPDATED, .resource = index }});
    const due = provider.status_timer.at.?;
    try testing.expect(!window.dispatch(due - 1));
    provider.onWindowFocus(false);
    try testing.expect(!window.dispatch(due));
    try testing.expectEqual(@as(usize, 0), host.refreshes);
    provider.onWindowFocus(true);
    try testing.expect(window.dispatch(due));
    try testing.expectEqual(@as(usize, 1), host.refreshes);
    const deleted_file = try std.fs.path.join(allocator, &.{ test_root, "removed.txt" });
    defer allocator.free(deleted_file);
    try file_service.on_did_change.fire(&.{.{ .type = .DELETED, .resource = deleted_file }});
    try testing.expect(!window.dispatch(due + 4999));
    try testing.expect(window.dispatch(due + 5000));
    try testing.expectEqual(@as(usize, 2), host.refreshes);
}

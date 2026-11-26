// Port of the native commit and resource-command subset of vscode/extensions/git/src/commands.ts.
// The terminal currently accepts the smart-commit prompt automatically when
// the index is empty; signing/branch-protection and empty-commit dialogs are
// not ported here. The command owns the selected paths and reports the result
// to the status and repository-refresh boundary; no Workbench dependency.
const std = @import("std");
const Allocator = std.mem.Allocator;
const repository_mod = @import("repository.zig");
const git_mod = @import("git.zig");
const SnapshotSource = @import("../../../vs/editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;
const IConfigurationService = @import("../../../vs/platform/configuration/common/configuration.zig").IConfigurationService;
const IEditorService = @import("../../../vs/workbench/services/editor/common/editorService.zig").IEditorService;

const scm = @import("../../../vs/workbench/contrib/scm/common/scm.zig");
const CommitAction = scm.CommitAction;
const dialogs = @import("../../../vs/platform/dialogs/common/dialogs.zig");
const FileChange = @import("../../../vs/platform/files/common/files.zig").FileChange;
const history = @import("../../../vs/workbench/contrib/scm/common/history.zig");

pub const Commands = struct {
    allocator: Allocator,
    repository: *repository_mod.Repository,
    configuration: ?IConfigurationService,
    host: Host,

    pub const Host = struct {
        context: *anyopaque,
        report_status: *const fn (*anyopaque, []const u8) void,
        did_run_remote_action: *const fn (*anyopaque) void,
        resources: ?ResourceHost = null,
    };

    pub const ResourceHost = struct {
        io: std.Io,
        dialogs: dialogs.IDialogService,
        resolve_repository: *const fn (*anyopaque) ?*repository_mod.Repository,
        open_path: *const fn (*anyopaque, []const u8) anyerror!void,
        open_diff: *const fn (*anyopaque, []const u8, git_mod.DiffRef, git_mod.DiffRef) anyerror!void,
        open_ref_diff: *const fn (*anyopaque, []const u8, ?[]const u8, ?[]const u8, []const u8, []const u8, []const u8) anyerror!void,
        focus_editor: *const fn (*anyopaque) void,
        refresh: *const fn (*anyopaque) void,
        files_changed: *const fn (*anyopaque, []const FileChange) void,
        request_frame: *const fn (*anyopaque) void,
    };

    pub fn openChange(self: Commands, resource: *repository_mod.GitScmResource) !void {
        const host = self.host.resources orelse return error.ResourceActionsUnavailable;
        if (resource.provider.diffRefsForResource(resource)) |refs| {
            try host.open_diff(self.host.context, resource.absolute_path, refs.left, refs.right);
        } else try host.open_path(self.host.context, resource.absolute_path);
    }

    pub fn openHistoryChange(self: Commands, item: *const history.ISCMHistoryItem, change: *const history.ISCMHistoryItemChange, revision: []const u8) !void {
        const host = self.host.resources orelse return error.ResourceActionsUnavailable;
        const display = if (std.mem.eql(u8, revision, item.id)) item.display_id orelse item.id else revision[0..@min(revision.len, 7)];
        if (item.parent_ids.len > 0) {
            const parent = item.parent_ids[0];
            const parent_label = if (item.display_id) |id| parent[0..@min(parent.len, id.len)] else parent;
            return host.open_ref_diff(self.host.context, change.path, change.original_path, parent, revision, parent_label, display);
        }
        return host.open_ref_diff(self.host.context, change.path, change.original_path, null, revision, "Empty", display);
    }

    /// Native Git commands own the resource-group and rename-path decisions.
    /// This is the single-resource subset of stage, unstage, open and clean.
    pub fn runResourceAction(self: Commands, action: scm.ResourceAction, resource: *scm.ISCMResource) !void {
        const host = self.host.resources orelse return error.ResourceActionsUnavailable;
        const git_resource: *repository_mod.GitScmResource = @ptrCast(@alignCast(resource.context));
        const provider = git_resource.provider;
        switch (action) {
            .open_file => {
                if (git_resource.status == 'D') {
                    try self.openChange(git_resource);
                } else {
                    try host.open_path(self.host.context, git_resource.absolute_path);
                    host.focus_editor(self.host.context);
                }
            },
            .open_change => try self.openChange(git_resource),
            .stage, .unstage => {
                const git = provider.git orelse return error.NoGit;
                const head = provider.repository.stateRef().head;
                const has_head = if (head) |branch| branch.ref.commit != null else false;
                const operation: git_mod.Git.ResourceAction = if (action == .stage) .stage else if (has_head) .unstage else .unstage_unborn;
                var paths = [_][]const u8{ git_resource.relative_path, "" };
                var count: usize = 1;
                if (git_resource.status == 'R') {
                    if (git_resource.original_path) |path| {
                        paths[1] = path;
                        count += 1;
                    }
                }
                try git.runResourceAction(provider.root, operation, paths[0..count]);
                host.refresh(self.host.context);
            },
            .discard => try self.confirmDiscard(git_resource),
        }
    }

    /// The current local clean command confirms one working-tree or untracked
    /// file. Trash/undo, bulk selection and checkout conflict dialogs remain
    /// unported. Keep the resource identity copied until confirmation, then
    /// resolve and validate the current repository rather than a stale row.
    fn confirmDiscard(self: Commands, resource: *const repository_mod.GitScmResource) !void {
        const host = self.host.resources orelse return error.ResourceActionsUnavailable;
        if (host.dialogs.hasDialog()) return error.DialogAlreadyOpen;
        if (resource.kind != .working and resource.kind != .untracked) return error.InvalidScmResource;
        const untracked = resource.kind == .untracked;
        const message = try std.fmt.allocPrint(self.allocator, "{s} {s}?", .{ if (untracked) "Permanently delete the untracked file" else "Discard working tree changes to", resource.relative_path });
        defer self.allocator.free(message);
        const root = try self.allocator.dupe(u8, resource.provider.root);
        errdefer self.allocator.free(root);
        const path = try self.allocator.dupe(u8, resource.relative_path);
        errdefer self.allocator.free(path);
        const pending = try self.allocator.create(DiscardConfirmation);
        errdefer self.allocator.destroy(pending);
        pending.* = .{ .allocator = self.allocator, .host = self.host, .root = root, .path = path, .untracked = untracked };
        _ = try host.dialogs.confirm(.{
            .message = message,
            .detail = if (untracked) "This deletes the file from disk." else "This restores the file from the Git index.",
            .primary_button = if (untracked) "Delete" else "Discard",
            .initial_focus = 1,
        }, .{ .context = pending, .complete = DiscardConfirmation.complete, .dispose = DiscardConfirmation.dispose });
    }

    const DiscardConfirmation = struct {
        allocator: Allocator,
        host: Host,
        root: []u8,
        path: []u8,
        untracked: bool,

        fn complete(context: *anyopaque, result: dialogs.IConfirmationResult) void {
            const self: *DiscardConfirmation = @ptrCast(@alignCast(context));
            if (!result.confirmed) return;
            self.resolve() catch |err| {
                var buffer: [256]u8 = undefined;
                self.host.report_status(self.host.context, std.fmt.bufPrint(&buffer, "Discard failed: {s}", .{@errorName(err)}) catch "Discard failed");
            };
        }

        fn dispose(context: *anyopaque) void {
            const self: *DiscardConfirmation = @ptrCast(@alignCast(context));
            self.allocator.free(self.root);
            self.allocator.free(self.path);
            self.allocator.destroy(self);
        }

        fn resolve(self: *DiscardConfirmation) !void {
            const host = self.host.resources orelse return error.ResourceActionsUnavailable;
            const context = self.host.context;
            const provider = host.resolve_repository(context) orelse return error.NoRepository;
            if (!std.mem.eql(u8, provider.root, self.root)) return error.RepositoryChanged;
            const git = provider.git orelse return error.NoGit;
            const absolute = try std.fs.path.join(self.allocator, &.{ self.root, self.path });
            defer self.allocator.free(absolute);
            defer host.refresh(context);
            var state = try git.status(self.root);
            defer state.deinit(git.allocator);
            const candidates = if (self.untracked) state.untracked_changes else state.working_tree_changes;
            const change = for (candidates) |candidate| {
                if (std.mem.eql(u8, candidate.path, self.path)) break candidate;
            } else return error.ChangeNoLongerAvailable;
            if (self.untracked) {
                // Refuse a directory that replaced the confirmed file.
                try std.Io.Dir.cwd().deleteFile(host.io, absolute);
                host.request_frame(context);
                return;
            }
            if (change.status == 'R' and change.original_path != null) {
                try git.runResourceAction(self.root, .restore, &.{ self.path, change.original_path.? });
                const original = try std.fs.path.join(self.allocator, &.{ self.root, change.original_path.? });
                defer self.allocator.free(original);
                host.files_changed(context, &.{.{ .type = .UPDATED, .resource = original }});
            } else {
                try git.runResourceAction(self.root, .restore, &.{self.path});
            }
            host.files_changed(context, &.{.{ .type = .UPDATED, .resource = absolute }});
        }
    };

    fn status(self: Commands, comptime format: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        self.host.report_status(self.host.context, std.fmt.bufPrint(&buffer, format, args) catch "Git command failed");
    }

    pub fn remote(self: Commands, action: git_mod.Git.RemoteAction, remote_name: ?[]const u8) !void {
        const git = self.repository.git orelse return error.NoGit;
        try git.runRemoteAction(self.repository.root, action, remote_name);
        self.host.did_run_remote_action(self.host.context);
    }

    fn finishCommit(self: Commands, action: CommitAction) void {
        if (action == .sync) {
            self.remote(.pull, null) catch |err| {
                self.status("Committed, but pull failed: {s}", .{@errorName(err)});
                return;
            };
        }
        if (action == .push or action == .sync) {
            self.remote(.push, null) catch |err| {
                self.status("Committed, but push failed: {s}", .{@errorName(err)});
                return;
            };
        }
        self.status("Committed", .{});
    }

    pub fn commit(self: Commands, message: []const u8, action: CommitAction) !void {
        const provider = self.repository;
        const state = provider.repository.stateRef();
        if (message.len == 0 and action != .amend) {
            self.status("Commit message is required", .{});
            return error.EmptyCommitMessage;
        }
        if (state.merge_changes.len > 0) {
            self.status("Resolve the merge conflicts before committing", .{});
            return error.UnresolvedConflicts;
        }
        const total = state.index_changes.len +
            state.working_tree_changes.len +
            state.untracked_changes.len;
        if (total == 0 and action != .amend) {
            self.status("No changes to commit", .{});
            return error.NoChanges;
        }

        const git = provider.git orelse {
            self.status("Commit failed: Git is not available", .{});
            return error.NoGit;
        };

        const options = git_mod.GitCommitOptions{ .amend = action == .amend };
        if (state.index_changes.len > 0 or total == 0) {
            git.commitFiles(provider.root, &.{}, message, options) catch |err| {
                self.status("Commit failed: {s}", .{@errorName(err)});
                return err;
            };
            self.finishCommit(action);
            return;
        }

        var tracked_only = false;
        if (self.configuration) |configuration| {
            if (configuration.getValue("git.smartCommitChanges")) |value| {
                switch (value.*) {
                    .string => |text| tracked_only = std.mem.eql(u8, text, "tracked"),
                    else => {},
                }
            }
        }
        var files = std.array_list.Managed([]const u8).init(self.allocator);
        defer files.deinit();
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        const working_paths = try uniqueChangePaths(&seen, state.working_tree_changes, files.allocator);
        defer files.allocator.free(working_paths);
        try files.appendSlice(working_paths);
        if (!tracked_only) {
            const untracked_paths = try uniqueChangePaths(&seen, state.untracked_changes, files.allocator);
            defer files.allocator.free(untracked_paths);
            try files.appendSlice(untracked_paths);
        }
        if (files.items.len == 0) {
            self.status("No tracked changes to commit", .{});
            return error.NothingStaged;
        }
        git.commitFiles(provider.root, files.items, message, options) catch |err| {
            self.status("Commit failed: {s}", .{@errorName(err)});
            return err;
        };
        self.finishCommit(action);
    }

    fn uniqueChangePaths(
        seen: *std.StringHashMap(void),
        changes: []const repository_mod.GitChange,
        allocator: Allocator,
    ) ![]const []const u8 {
        var paths = std.array_list.Managed([]const u8).init(allocator);
        errdefer paths.deinit();
        for (changes) |change| {
            if (change.path.len == 0) continue;
            if (seen.contains(change.path)) continue;
            try seen.put(change.path, {});
            try paths.append(change.path);
        }
        return paths.toOwnedSlice();
    }
};

// Native counterpart of the command registration and publish picker in
// extensions/git/src/commands.ts. The UI host implements the generic selected
// SCM resource, input commit and editor-opening contracts.
const platform_actions = @import("../../../vs/platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../vs/platform/instantiation/common/instantiation.zig").ServicesAccessor;
const QuickInputService = @import("../../../vs/platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../vs/platform/quickinput/browser/quickInput.zig").QuickPick;
const QuickPickItem = @import("../../../vs/platform/quickinput/common/quickInput.zig").QuickPickItem;
const Model = @import("model.zig").Model;

pub const CommandContribution = struct {
    allocator: Allocator,
    model: *Model,
    io: std.Io,
    snapshot_io: std.Io,
    quick_input: *QuickInputService,
    configuration: *const IConfigurationService,
    editors: *const IEditorService,
    dialogs: *const dialogs.IDialogService,
    publish_arena: std.heap.ArenaAllocator,
    publish_root: ?[]const u8 = null,
    host: struct {
        context: *anyopaque,
        focus_editor: *const fn (*anyopaque) void,
        refresh_resources: *const fn (*anyopaque) void,
        did_run_remote_action: *const fn (*anyopaque) void,
        files_changed: *const fn (*anyopaque, []const FileChange) void,
        request_frame: *const fn (*anyopaque) void,
        report_status: *const fn (*anyopaque, []const u8) void,
        working_text: *const fn (*anyopaque, Allocator, []const u8) anyerror!?[]u8,
        has_diff: *const fn (*anyopaque, []const u8, []const u8, []const u8) bool,
        // Consumes the virtual source even when opening fails.
        open_snapshot: *const fn (*anyopaque, []const u8, SnapshotSource, []const u8, []const u8) anyerror!void,
        refresh: *const fn (*anyopaque) void,
        commit_input: *const fn (*anyopaque) void,
        selected_resource: *const fn (*anyopaque) ?*scm.ISCMResource,
        open_active_diff: *const fn (*anyopaque) anyerror!void,
    },

    pub fn commands(self: *CommandContribution) !Commands {
        return self.commandsFor(self.model.repository orelse return error.NoRepository);
    }

    /// One command instance targets a captured repository. All native
    /// resource and confirmation callbacks are resolved by the extension
    /// contribution; the window supplies only the service/focus boundary.
    pub fn commandsFor(self: *CommandContribution, repository: *repository_mod.Repository) Commands {
        return .{
            .allocator = self.allocator,
            .repository = repository,
            .configuration = self.configuration.*,
            .host = .{
                .context = self,
                .report_status = struct {
                    fn run(context: *anyopaque, message: []const u8) void {
                        const owner: *CommandContribution = @ptrCast(@alignCast(context));
                        owner.host.report_status(owner.host.context, message);
                    }
                }.run,
                .did_run_remote_action = struct {
                    fn run(context: *anyopaque) void {
                        const owner: *CommandContribution = @ptrCast(@alignCast(context));
                        owner.host.did_run_remote_action(owner.host.context);
                    }
                }.run,
                .resources = .{
                    .io = self.io,
                    .dialogs = self.dialogs.*,
                    .resolve_repository = struct {
                        fn run(context: *anyopaque) ?*repository_mod.Repository {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            return owner.model.repository;
                        }
                    }.run,
                    .open_path = struct {
                        fn run(context: *anyopaque, path: []const u8) !void {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            try owner.editors.openEditor(path, .{});
                        }
                    }.run,
                    .open_diff = struct {
                        fn run(context: *anyopaque, path: []const u8, left: git_mod.DiffRef, right: git_mod.DiffRef) !void {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            try owner.openDiff(path, left, right);
                        }
                    }.run,
                    .open_ref_diff = struct {
                        fn run(context: *anyopaque, path: []const u8, original_path: ?[]const u8, left: ?[]const u8, right: []const u8, left_label: []const u8, right_label: []const u8) !void {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            try owner.openRefDiff(path, original_path, left, right, left_label, right_label);
                        }
                    }.run,
                    .focus_editor = struct {
                        fn run(context: *anyopaque) void {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            owner.host.focus_editor(owner.host.context);
                        }
                    }.run,
                    .refresh = struct {
                        fn run(context: *anyopaque) void {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            owner.host.refresh_resources(owner.host.context);
                        }
                    }.run,
                    .files_changed = struct {
                        fn run(context: *anyopaque, changes: []const FileChange) void {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            owner.host.files_changed(owner.host.context, changes);
                        }
                    }.run,
                    .request_frame = struct {
                        fn run(context: *anyopaque) void {
                            const owner: *CommandContribution = @ptrCast(@alignCast(context));
                            owner.host.request_frame(owner.host.context);
                        }
                    }.run,
                },
            },
        };
    }

    pub fn runResourceAction(self: *CommandContribution, action: scm.ResourceAction, resource: *scm.ISCMResource) void {
        const target = self.commands() catch |err| {
            self.status("Source Control action failed: {s}", .{@errorName(err)});
            return;
        };
        target.runResourceAction(action, resource) catch |err| self.status("Source Control action failed: {s}", .{@errorName(err)});
    }

    pub fn runBranchAction(self: *CommandContribution, action: scm.BranchAction) void {
        switch (action) {
            .publish => self.publish() catch |err| self.status("Publish failed: {s}", .{@errorName(err)}),
            .sync => {
                self.runRemoteAction(.pull, null) catch |err| {
                    self.status("Pull failed: {s}", .{@errorName(err)});
                    return;
                };
                self.runRemoteCommand(.push);
            },
        }
    }

    pub fn deinit(self: *CommandContribution) void {
        if (self.quick_input.handler_context == @as(*anyopaque, self)) self.quick_input.hide();
        self.publish_arena.deinit();
    }

    fn status(self: *CommandContribution, comptime fmt: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, fmt, args) catch return;
        self.host.report_status(self.host.context, message);
    }

    /// Terminal snapshot refresh resolves the same Git refs again. Commit
    /// labels are display IDs rather than refs and cannot be re-resolved.
    pub fn refreshSnapshot(context: *anyopaque, path: []const u8, left_label: []const u8, right_label: []const u8) !void {
        const self: *CommandContribution = @ptrCast(@alignCast(context));
        const left = refFromLabel(left_label) orelse return;
        const right = refFromLabel(right_label) orelse return;
        try self.openDiff(path, left, right);
    }

    fn refFromLabel(label: []const u8) ?git_mod.DiffRef {
        for ([_]git_mod.DiffRef{ .head, .index, .working, .empty }) |ref| {
            if (std.mem.eql(u8, label, ref.label())) return ref;
        }
        return null;
    }

    /// Resolve Git's original/modified resource contents, including the
    /// unsaved working editor when present, then ask the editor service to
    /// reveal or mount the diff input.
    pub fn openDiff(self: *CommandContribution, path: []const u8, left: git_mod.DiffRef, right: git_mod.DiffRef) !void {
        if (self.model.repository == null) return error.NoRepository;
        const left_label = left.label();
        const right_label = right.label();
        const working = if (left == .working or right == .working) try self.host.working_text(self.host.context, self.allocator, path) else null;
        defer if (working) |text| self.allocator.free(text);
        const source = try self.model.snapshotSource(self.snapshot_io, path, working, left, right, self.host.has_diff(self.host.context, path, left_label, right_label));
        try self.host.open_snapshot(self.host.context, path, source, left_label, right_label);
    }

    pub fn openRefDiff(self: *CommandContribution, path: []const u8, original_path: ?[]const u8, left: ?[]const u8, right: []const u8, left_label: []const u8, right_label: []const u8) !void {
        const source = try self.model.revisionSnapshotSource(self.snapshot_io, path, original_path, left, right);
        try self.host.open_snapshot(self.host.context, path, source, left_label, right_label);
    }

    pub fn runRemoteAction(self: *CommandContribution, action: git_mod.Git.RemoteAction, remote: ?[]const u8) !void {
        const repository = self.model.repository orelse return error.NoRepository;
        try self.commandsFor(repository).remote(action, remote);
    }

    pub fn runRemoteCommand(self: *CommandContribution, comptime action: git_mod.Git.RemoteAction) void {
        self.runRemoteAction(action, null) catch |err| switch (action) {
            .fetch => self.status("Fetch failed: {s}", .{@errorName(err)}),
            .pull => self.status("Pull failed: {s}", .{@errorName(err)}),
            .push => self.status("Push failed: {s}", .{@errorName(err)}),
            .publish => self.status("Publish failed: {s}", .{@errorName(err)}),
        };
    }

    pub fn publish(self: *CommandContribution) !void {
        const provider = self.model.repository orelse return;
        if (self.quick_input.isVisible()) self.quick_input.hide();
        _ = self.publish_arena.reset(.retain_capacity);
        const arena = self.publish_arena.allocator();
        const remotes = provider.repository.stateRef().remotes;
        var items: std.ArrayList(QuickPickItem) = .empty;
        for (remotes) |remote| {
            if (remote.is_read_only) continue;
            const name = try arena.dupe(u8, remote.name);
            try items.append(arena, .{ .item = .{ .id = name, .label = name } });
        }
        if (items.items.len == 0) {
            self.status("No remote to publish to", .{});
            return;
        }
        self.publish_root = try arena.dupe(u8, provider.root);
        errdefer self.publish_root = null;
        try self.quick_input.showPick(items.items, .{
            .placeholder = "Select a Remote to Publish the Branch",
            .cleanup = cleanupPublish,
            .cleanup_context = self,
        }, onPublishPick, self);
    }

    fn cleanupPublish(context: *anyopaque) void {
        const self: *CommandContribution = @ptrCast(@alignCast(context));
        self.publish_root = null;
    }

    fn onPublishPick(context: *anyopaque, picker: *QuickPick) !void {
        const self: *CommandContribution = @ptrCast(@alignCast(context));
        const repository = self.model.repository orelse return;
        const root = self.publish_root orelse return;
        if (!std.mem.eql(u8, root, repository.root)) return;
        const item = picker.selectedItem() orelse picker.activeItem() orelse return;
        self.runRemoteAction(.publish, item.id) catch |err| self.status("Publish failed: {s}", .{@errorName(err)});
    }

    fn refresh(self: *CommandContribution) !void {
        self.host.refresh(self.host.context);
    }

    fn commit(self: *CommandContribution) !void {
        self.host.commit_input(self.host.context);
    }

    fn remoteCommand(self: *CommandContribution, comptime action: git_mod.Git.RemoteAction) !void {
        self.runRemoteCommand(action);
    }

    fn openChange(self: *CommandContribution) !void {
        const resource = self.host.selected_resource(self.host.context) orelse return;
        try resource.open(false);
    }

    fn openFile(self: *CommandContribution) !void {
        try self.host.open_active_diff(self.host.context);
    }

    fn actionDescriptor(self: *CommandContribution, id: []const u8, title: []const u8, comptime run: anytype, comptime args: anytype) platform_actions.Action2 {
        return .{
            .command = .{ .id = id, .title = title, .category = "Source Control" },
            .f1 = true,
            .context = self,
            .run_fn = struct {
                fn invoke(context: *anyopaque, _: ServicesAccessor) !void {
                    const contribution: *CommandContribution = @ptrCast(@alignCast(context));
                    try @call(.auto, run, .{contribution} ++ args);
                }
            }.invoke,
        };
    }

    pub fn refreshActions(self: *CommandContribution) [2]platform_actions.Action2 {
        return .{
            self.actionDescriptor("git.refresh", "Refresh", refresh, .{}),
            self.actionDescriptor("git.commit", "Commit", commit, .{}),
        };
    }

    pub fn remoteActions(self: *CommandContribution) [4]platform_actions.Action2 {
        return .{
            self.actionDescriptor("git.fetchAll", "Fetch From All Remotes", remoteCommand, .{git_mod.Git.RemoteAction.fetch}),
            self.actionDescriptor("git.pullRef", "Pull", remoteCommand, .{git_mod.Git.RemoteAction.pull}),
            self.actionDescriptor("git.pushRef", "Push", remoteCommand, .{git_mod.Git.RemoteAction.push}),
            self.actionDescriptor("git.publish", "Publish Branch", publish, .{}),
        };
    }

    pub fn openActions(self: *CommandContribution) [2]platform_actions.Action2 {
        return .{
            self.actionDescriptor("git.openChange", "Open Change", openChange, .{}),
            self.actionDescriptor("git.openFile", "Open File", openFile, .{}),
        };
    }
};

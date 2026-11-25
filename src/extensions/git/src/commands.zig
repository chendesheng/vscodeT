// Port of the native commit and resource-command subset of vscode/extensions/git/src/commands.ts.
// The terminal currently accepts the smart-commit prompt automatically when
// the index is empty; signing/branch-protection and empty-commit dialogs are
// not ported here. The command owns the selected paths and reports the result
// to the status and repository-refresh boundary; no Workbench dependency.
const std = @import("std");
const Allocator = std.mem.Allocator;
const repository_mod = @import("repository.zig");
const git_mod = @import("git.zig");
const IConfigurationService = @import("../../../vs/platform/configuration/common/configuration.zig").IConfigurationService;

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

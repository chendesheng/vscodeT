// Port of the native commit-command subset of vscode/extensions/git/src/commands.ts.
// The terminal currently accepts the smart-commit prompt automatically when
// the index is empty; signing/branch-protection and empty-commit dialogs are
// not ported here. The command owns the selected paths and reports the result
// to the status and repository-refresh boundary; no Workbench dependency.
const std = @import("std");
const Allocator = std.mem.Allocator;
const repository_mod = @import("repository.zig");
const git_mod = @import("git.zig");
const IConfigurationService = @import("../../../vs/platform/configuration/common/configuration.zig").IConfigurationService;

const CommitAction = @import("../../../vs/workbench/contrib/scm/common/scm.zig").CommitAction;

pub const Commands = struct {
    allocator: Allocator,
    repository: *repository_mod.Repository,
    configuration: ?IConfigurationService,
    host: Host,

    pub const Host = struct {
        context: *anyopaque,
        report_status: *const fn (*anyopaque, []const u8) void,
        did_run_remote_action: *const fn (*anyopaque) void,
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

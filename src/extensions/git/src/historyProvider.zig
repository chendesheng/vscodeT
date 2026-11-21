// Port of `vscode/extensions/git/src/historyProvider.ts` (read-only subset).
//
// Terminal adaptations:
// - The provider is backed by the mirrored `Repository`/`git.zig` instead of
//   the extension host RPC and `Repository.log`/`getMergeBase`/... are
//   synchronous.
// - File decorations, avatars, emoji expansion, markdown tooltips and the
//   chat-context methods are not ported; the Graph pane builds its own plain
//   hover content from the returned history items.
// - History item refs carry `RefIcon` tags instead of `ThemeIcon`/`URI`.
// - `resolveHistoryItem` is not needed by the terminal Graph; the reveal path
//   loads more pages instead.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../vs/base/common/event.zig").Emitter;
const git_browser = @import("../../../vs/workbench/contrib/git/browser/gitService.zig");
const git_common = @import("../../../vs/workbench/contrib/git/common/gitService.zig");
const scm_history = @import("../../../vs/workbench/contrib/scm/common/history.zig");
const util = @import("./util.zig");

const CancellationToken = git_common.CancellationToken;

pub const GitHistoryProvider = struct {
    allocator: Allocator,
    repository: *git_browser.GitRepository,
    interface_value: scm_history.ISCMHistoryProvider,

    current_ref: ?scm_history.ISCMHistoryItemRef = null,
    remote_ref: ?scm_history.ISCMHistoryItemRef = null,
    base_ref: ?scm_history.ISCMHistoryItemRef = null,

    history_item_refs: std.array_list.Managed(scm_history.ISCMHistoryItemRef),
    refs_changed: Emitter(scm_history.ISCMHistoryItemRefsChangeEvent),

    commit_short_hash_length: usize = 7,
    last_head_name: ?[]u8 = null,
    last_error: ?anyerror = null,

    pub fn create(
        allocator: Allocator,
        repository: *git_browser.GitRepository,
    ) !*GitHistoryProvider {
        const self = try allocator.create(GitHistoryProvider);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .repository = repository,
            .interface_value = undefined,
            .history_item_refs = std.array_list.Managed(scm_history.ISCMHistoryItemRef).init(allocator),
            .refs_changed = Emitter(scm_history.ISCMHistoryItemRefsChangeEvent).init(allocator),
        };
        self.interface_value = .{
            .context = self,
            .on_did_change_history_item_refs = &self.refs_changed,
            .provide_history_item_refs_fn = provideHistoryItemRefsThunk,
            .provide_history_items_fn = provideHistoryItemsThunk,
            .provide_history_item_changes_fn = provideHistoryItemChangesThunk,
            .resolve_history_item_refs_common_ancestor_fn = resolveCommonAncestorThunk,
        };
        _ = self.refreshRefs(true) catch |err| {
            self.last_error = err;
        };
        return self;
    }

    pub fn destroy(self: *GitHistoryProvider) void {
        self.clearState();
        self.history_item_refs.deinit();
        self.refs_changed.deinit();
        if (self.last_head_name) |value| self.allocator.free(value);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *GitHistoryProvider) *scm_history.ISCMHistoryProvider {
        return &self.interface_value;
    }

    pub fn setCommitShortHashLength(self: *GitHistoryProvider, length: usize) void {
        self.commit_short_hash_length = @max(length, 1);
    }

    pub fn lastError(self: *const GitHistoryProvider) ?anyerror {
        return self.last_error;
    }

    fn clearState(self: *GitHistoryProvider) void {
        if (self.current_ref) |*ref| ref.deinit(self.allocator);
        if (self.remote_ref) |*ref| ref.deinit(self.allocator);
        if (self.base_ref) |*ref| ref.deinit(self.allocator);
        self.current_ref = null;
        self.remote_ref = null;
        self.base_ref = null;
        self.interface_value.history_item_ref = null;
        self.interface_value.history_item_remote_ref = null;
        self.interface_value.history_item_base_ref = null;
        for (self.history_item_refs.items) |*ref| ref.deinit(self.allocator);
        self.history_item_refs.clearRetainingCapacity();
    }

    fn setCurrentRefs(
        self: *GitHistoryProvider,
        current: ?scm_history.ISCMHistoryItemRef,
        remote: ?scm_history.ISCMHistoryItemRef,
        base: ?scm_history.ISCMHistoryItemRef,
    ) void {
        if (self.current_ref) |*ref| ref.deinit(self.allocator);
        if (self.remote_ref) |*ref| ref.deinit(self.allocator);
        if (self.base_ref) |*ref| ref.deinit(self.allocator);
        self.current_ref = current;
        self.remote_ref = remote;
        self.base_ref = base;
        self.interface_value.history_item_ref = current;
        self.interface_value.history_item_remote_ref = remote;
        self.interface_value.history_item_base_ref = base;
    }

    /// Re-reads refs and the current/remote/base history refs. Emits the
    /// upstream `historyItemRefChanges` delta; returns whether anything changed.
    pub fn refreshRefs(self: *GitHistoryProvider, silent: bool) !bool {
        const state = self.repository.stateRef();
        const head = state.head orelse {
            const had_refs = self.history_item_refs.items.len > 0 or self.current_ref != null;
            self.clearState();
            if (self.last_head_name) |value| {
                self.allocator.free(value);
                self.last_head_name = null;
            }
            return had_refs;
        };

        const fetched = try self.repository.getRefs(
            self.allocator,
            .{},
            CancellationToken.None,
        );
        defer git_common.freeGitRefs(self.allocator, fetched);

        var new_refs = std.array_list.Managed(scm_history.ISCMHistoryItemRef).init(self.allocator);
        errdefer {
            for (new_refs.items) |*ref| ref.deinit(self.allocator);
            new_refs.deinit();
        }
        for (fetched) |reference| {
            const item_ref = try toHistoryItemRef(self.allocator, reference);
            try new_refs.append(item_ref);
        }
        util.sortHistoryItemRefs(new_refs.items);

        var delta = try util.deltaHistoryItemRefs(self.allocator, self.history_item_refs.items, new_refs.items);
        defer delta.deinit();

        const local = try self.buildCurrentRef(head);
        var local_owned = true;
        errdefer if (local_owned) {
            if (local) |value| {
                var ref = value;
                ref.deinit(self.allocator);
            }
        };
        const remote = try self.buildRemoteRef(head, new_refs.items);
        var remote_owned = true;
        errdefer if (remote_owned) {
            if (remote) |value| {
                var ref = value;
                ref.deinit(self.allocator);
            }
        };
        const base = try self.buildBaseRef(head, &delta);
        var base_owned = true;
        errdefer if (base_owned) {
            if (base) |value| {
                var ref = value;
                ref.deinit(self.allocator);
            }
        };

        const changed_current = !refsEqual(self.current_ref, local) or
            !refsEqual(self.remote_ref, remote) or
            !refsEqual(self.base_ref, base);
        const changed_delta = delta.added.items.len > 0 or delta.removed.items.len > 0 or delta.modified.items.len > 0;

        // Replace the provider state before emitting so listeners read the new
        // current refs. The delta event borrows both old and new ref lists.
        const old_refs = self.history_item_refs;
        self.history_item_refs = new_refs;
        new_refs = std.array_list.Managed(scm_history.ISCMHistoryItemRef).init(self.allocator);

        if (changed_delta) {
            self.refs_changed.fire(.{
                .added = delta.added.items,
                .removed = delta.removed.items,
                .modified = delta.modified.items,
                .silent = silent,
            }) catch {};
        }

        self.setCurrentRefs(local, remote, base);
        local_owned = false;
        remote_owned = false;
        base_owned = false;

        for (old_refs.items) |*ref| ref.deinit(self.allocator);
        old_refs.deinit();
        new_refs.deinit();

        return changed_delta or changed_current;
    }

    fn buildCurrentRef(
        self: *GitHistoryProvider,
        head: git_common.GitBranch,
    ) !?scm_history.ISCMHistoryItemRef {
        const revision = head.ref.commit;
        if (head.ref.name) |name| {
            const id = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
            errdefer self.allocator.free(id);
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_revision = if (revision) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (owned_revision) |value| self.allocator.free(value);
            return .{
                .id = id,
                .name = owned_name,
                .revision = owned_revision,
                .icon = .head,
            };
        }
        // Detached commit.
        const commit = revision orelse return null;
        const id = try self.allocator.dupe(u8, commit);
        errdefer self.allocator.free(id);
        const name = try self.allocator.dupe(u8, commit);
        errdefer self.allocator.free(name);
        const owned_revision = try self.allocator.dupe(u8, commit);
        errdefer self.allocator.free(owned_revision);
        return .{ .id = id, .name = name, .revision = owned_revision, .icon = .head };
    }

    fn buildRemoteRef(
        self: *GitHistoryProvider,
        head: git_common.GitBranch,
        refs: []const scm_history.ISCMHistoryItemRef,
    ) !?scm_history.ISCMHistoryItemRef {
        const upstream = head.upstream orelse return null;
        const is_local = std.mem.eql(u8, upstream.remote, ".");
        const id = if (is_local)
            try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{upstream.name})
        else
            try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}/{s}", .{ upstream.remote, upstream.name });
        errdefer self.allocator.free(id);
        const name = if (is_local)
            try self.allocator.dupe(u8, upstream.name)
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ upstream.remote, upstream.name });
        errdefer self.allocator.free(name);
        var revision = if (upstream.commit) |value| try self.allocator.dupe(u8, value) else null;
        if (revision == null) {
            for (refs) |reference| {
                if (!std.mem.eql(u8, reference.id, id)) continue;
                if (reference.revision) |value| revision = try self.allocator.dupe(u8, value);
                break;
            }
        }
        return .{
            .id = id,
            .name = name,
            .revision = revision,
            .icon = if (is_local) .branch else .remote,
        };
    }

    fn buildBaseRef(
        self: *GitHistoryProvider,
        head: git_common.GitBranch,
        delta: *const util.HistoryItemRefDelta,
    ) !?scm_history.ISCMHistoryItemRef {
        const branch_name = head.ref.name orelse return null;
        const branch_changed = if (self.last_head_name) |last|
            !std.mem.eql(u8, last, branch_name)
        else
            true;

        if (branch_changed) {
            if (self.last_head_name) |last| self.allocator.free(last);
            self.last_head_name = try self.allocator.dupe(u8, branch_name);

            var base_branch = (try self.repository.getBranchBase(self.allocator, branch_name)) orelse return null;
            defer base_branch.deinit(self.allocator);
            const remote = base_branch.ref.remote orelse return null;
            const name = base_branch.ref.name orelse return null;
            const id = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}/{s}", .{ remote, name });
            errdefer self.allocator.free(id);
            const owned_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ remote, name });
            errdefer self.allocator.free(owned_name);
            const revision = if (base_branch.ref.commit) |value| try self.allocator.dupe(u8, value) else null;
            return .{
                .id = id,
                .name = owned_name,
                .revision = revision,
                .icon = .remote,
            };
        }

        // Same branch: update the base revision from a modified ref, like
        // upstream `onDidRunWriteOperation`.
        const base = self.base_ref orelse return null;
        for (delta.modified.items) |modified| {
            if (std.mem.eql(u8, modified.id, base.id)) {
                var copy = try base.clone(self.allocator);
                if (copy.revision) |old| self.allocator.free(old);
                copy.revision = if (modified.revision) |value| try self.allocator.dupe(u8, value) else null;
                return copy;
            }
        }
        var copy = try base.clone(self.allocator);
        errdefer copy.deinit(self.allocator);
        return copy;
    }

    fn provideHistoryItemRefs(
        self: *GitHistoryProvider,
        allocator: Allocator,
        history_item_refs: ?[]const []const u8,
    ) ![]scm_history.ISCMHistoryItemRef {
        const query: git_common.GitRefQuery = if (history_item_refs) |refs|
            .{ .patterns = refs }
        else
            .{};
        const refs = try self.repository.getRefs(allocator, query, CancellationToken.None);
        defer git_common.freeGitRefs(allocator, refs);

        var result = std.array_list.Managed(scm_history.ISCMHistoryItemRef).init(allocator);
        errdefer freeRefList(allocator, &result);

        for ([_]git_common.GitRefType{ .head, .remote_head, .tag }) |kind| {
            for (refs) |reference| {
                if (reference.ref_type != kind) continue;
                const prefix: []const u8 = switch (kind) {
                    .remote_head => "Remote branch at ",
                    .tag => "Tag at ",
                    .head => "",
                };
                try result.append(try toHistoryItemRefWithDescription(allocator, reference, prefix));
            }
        }
        return result.toOwnedSlice();
    }

    fn provideHistoryItems(
        self: *GitHistoryProvider,
        allocator: Allocator,
        options: scm_history.ISCMHistoryOptions,
    ) ![]scm_history.ISCMHistoryItem {
        if (self.current_ref == null) return allocator.alloc(scm_history.ISCMHistoryItem, 0);
        if (options.history_item_refs.len == 0 and !options.all_refs) {
            return allocator.alloc(scm_history.ISCMHistoryItem, 0);
        }

        var ref_names = std.array_list.Managed([]const u8).init(allocator);
        defer ref_names.deinit();
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (options.history_item_refs) |name| {
            if (seen.contains(name)) continue;
            try seen.put(name, {});
            try ref_names.append(name);
        }

        var range: ?[]u8 = null;
        defer if (range) |value| allocator.free(value);
        var max_entries: ?usize = null;
        switch (options.limit) {
            .none => {},
            .count => |count| max_entries = count,
            .id => |id| {
                const commits = self.repository.log(allocator, .{
                    .ref_names = &.{id},
                    .max_entries = 1,
                }, CancellationToken.None) catch return allocator.alloc(scm_history.ISCMHistoryItem, 0);
                defer git_common.freeGitCommits(allocator, commits);
                if (commits.len > 0 and commits[0].parents.len > 0) {
                    range = try std.fmt.allocPrint(allocator, "{s}..", .{commits[0].parents[0]});
                } else {
                    range = try allocator.dupe(u8, id);
                }
            },
        }

        const page_size: usize = @max(max_entries orelse 50, 1);
        const log_options = git_common.GitLogOptions{
            .ref_names = ref_names.items,
            .range = range,
            .max_entries = if (range == null) page_size else null,
            .skip = options.skip,
            .short_stats = true,
            .all_refs = options.all_refs and range == null,
        };

        var commits: []git_common.GitCommit = undefined;
        var commits_owned = false;
        if (options.filter_text) |filter_text| {
            const trimmed = std.mem.trim(u8, filter_text, " \t");
            if (trimmed.len > 0) {
                var author_options = log_options;
                author_options.ref_names = null;
                author_options.author = trimmed;
                const author_commits = self.repository.log(allocator, author_options, CancellationToken.None) catch
                    try allocator.alloc(git_common.GitCommit, 0);
                defer git_common.freeGitCommits(allocator, author_commits);
                var grep_options = log_options;
                grep_options.ref_names = null;
                grep_options.grep = trimmed;
                const grep_commits = self.repository.log(allocator, grep_options, CancellationToken.None) catch
                    try allocator.alloc(git_common.GitCommit, 0);
                defer git_common.freeGitCommits(allocator, grep_commits);

                var merged = std.array_list.Managed(git_common.GitCommit).init(allocator);
                errdefer {
                    for (merged.items) |*commit| commit.deinit(allocator);
                    merged.deinit();
                }
                var hashes = std.StringHashMap(void).init(allocator);
                defer hashes.deinit();
                for ([_][]git_common.GitCommit{ author_commits, grep_commits }) |source| {
                    for (source) |commit| {
                        if (hashes.contains(commit.hash)) continue;
                        try hashes.put(commit.hash, {});
                        try merged.append(try commit.clone(allocator));
                    }
                }
                commits = try merged.toOwnedSlice();
                commits_owned = true;
                if (commits.len > page_size) {
                    // Keep the first page and free the tail's owned strings; the
                    // array itself is shrunk by moving the kept structs.
                    for (commits[page_size..]) |*commit| commit.deinit(allocator);
                    const kept = try allocator.alloc(git_common.GitCommit, page_size);
                    @memcpy(kept, commits[0..page_size]);
                    allocator.free(commits);
                    commits = kept;
                }
            } else {
                commits = self.repository.log(allocator, log_options, CancellationToken.None) catch
                    try allocator.alloc(git_common.GitCommit, 0);
                commits_owned = true;
            }
        } else {
            commits = self.repository.log(allocator, log_options, CancellationToken.None) catch
                try allocator.alloc(git_common.GitCommit, 0);
            commits_owned = true;
        }
        defer if (commits_owned) git_common.freeGitCommits(allocator, commits);

        var items = std.array_list.Managed(scm_history.ISCMHistoryItem).init(allocator);
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit();
        }
        for (commits) |commit| {
            try items.append(try self.commitToHistoryItem(allocator, commit));
        }
        return items.toOwnedSlice();
    }

    fn commitToHistoryItem(
        self: *GitHistoryProvider,
        allocator: Allocator,
        commit: git_common.GitCommit,
    ) !scm_history.ISCMHistoryItem {
        const id = try allocator.dupe(u8, commit.hash);
        errdefer allocator.free(id);
        const message = try allocator.dupe(u8, commit.message);
        errdefer allocator.free(message);
        const subject = try allocator.dupe(u8, util.subject(commit.message));
        errdefer allocator.free(subject);
        const author_name = try allocator.dupe(u8, commit.author_name);
        errdefer allocator.free(author_name);
        const author_email = try allocator.dupe(u8, commit.author_email);
        errdefer allocator.free(author_email);
        const display_id = try util.truncate(allocator, commit.hash, self.commit_short_hash_length);
        errdefer allocator.free(display_id);

        const parents = try allocator.alloc([]const u8, commit.parents.len);
        errdefer allocator.free(parents);
        var parents_owned: usize = 0;
        errdefer for (parents[0..parents_owned]) |parent| allocator.free(parent);
        for (commit.parents, 0..) |parent, index| {
            parents[index] = try allocator.dupe(u8, parent);
            parents_owned = index + 1;
        }

        const references = try resolveHistoryItemRefs(allocator, commit);
        errdefer {
            for (references) |*reference| reference.deinit(allocator);
            if (references.len > 0) allocator.free(references);
        }

        return .{
            .id = id,
            .parent_ids = parents,
            .subject = subject,
            .message = message,
            .display_id = display_id,
            .author = author_name,
            .author_email = author_email,
            .timestamp = if (commit.author_date) |date| date * 1000 else null,
            .statistics = if (commit.short_stat) |stat| .{
                .files = stat.files,
                .insertions = stat.insertions,
                .deletions = stat.deletions,
            } else .{},
            .references = references,
        };
    }

    fn provideHistoryItemChanges(
        self: *GitHistoryProvider,
        allocator: Allocator,
        history_item_id: []const u8,
        history_item_parent_id: ?[]const u8,
    ) ![]scm_history.ISCMHistoryItemChange {
        const diffs = if (history_item_parent_id) |parent|
            try self.repository.diffBetweenWithStats(allocator, parent, history_item_id, null)
        else
            try self.repository.diffRootCommit(allocator, history_item_id);
        defer git_common.freeGitDiffChanges(allocator, diffs);

        var changes = std.array_list.Managed(scm_history.ISCMHistoryItemChange).init(allocator);
        errdefer {
            for (changes.items) |*change| change.deinit(allocator);
            changes.deinit();
        }
        for (diffs) |diff| {
            const path = try allocator.dupe(u8, diff.change.path);
            errdefer allocator.free(path);
            const original = if (diff.change.original_path) |value| try allocator.dupe(u8, value) else null;
            errdefer if (original) |value| allocator.free(value);
            try changes.append(.{
                .path = path,
                .original_path = original,
                .status = diff.change.status,
                .insertions = diff.insertions,
                .deletions = diff.deletions,
            });
        }
        return changes.toOwnedSlice();
    }

    fn resolveHistoryItemRefsCommonAncestor(
        self: *GitHistoryProvider,
        allocator: Allocator,
        history_item_refs: []const []const u8,
    ) !?[]u8 {
        if (history_item_refs.len == 0) return null;
        const current = self.current_ref;
        if (history_item_refs.len == 1 and current != null and
            std.mem.eql(u8, history_item_refs[0], current.?.id))
        {
            if (self.remote_ref) |remote| {
                if (try self.repository.mergeBase(allocator, &.{ history_item_refs[0], remote.id })) |ancestor| {
                    return ancestor;
                }
            }
            if (self.base_ref) |base| {
                if (try self.repository.mergeBase(allocator, &.{ history_item_refs[0], base.id })) |ancestor| {
                    return ancestor;
                }
            }
            const commits = self.repository.log(allocator, .{
                .ref_names = &.{"HEAD"},
                .max_parents = 0,
                .max_entries = 1,
            }, CancellationToken.None) catch return null;
            defer git_common.freeGitCommits(allocator, commits);
            if (commits.len > 0) return try allocator.dupe(u8, commits[0].hash);
            return null;
        }
        if (history_item_refs.len > 1) {
            return try self.repository.mergeBase(allocator, history_item_refs);
        }
        return null;
    }
};

fn refsEqual(a: ?scm_history.ISCMHistoryItemRef, b: ?scm_history.ISCMHistoryItemRef) bool {
    if (a == null or b == null) return a == null and b == null;
    const left = a.?;
    const right = b.?;
    if (!std.mem.eql(u8, left.id, right.id)) return false;
    if (!std.mem.eql(u8, left.name, right.name)) return false;
    if (!optionalStringEql(left.revision, right.revision)) return false;
    return true;
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn freeRefList(allocator: Allocator, list: *std.array_list.Managed(scm_history.ISCMHistoryItemRef)) void {
    for (list.items) |*reference| reference.deinit(allocator);
    list.deinit();
}

fn toHistoryItemRef(
    allocator: Allocator,
    reference: git_common.GitRef,
) !scm_history.ISCMHistoryItemRef {
    return toHistoryItemRefWithDescription(allocator, reference, "");
}

fn toHistoryItemRefWithDescription(
    allocator: Allocator,
    reference: git_common.GitRef,
    description_prefix: []const u8,
) !scm_history.ISCMHistoryItemRef {
    const name = reference.name orelse return error.InvalidRef;
    const revision = reference.commit;
    const id = switch (reference.ref_type) {
        .head => try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{name}),
        .remote_head => try std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{name}),
        .tag => try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{name}),
    };
    errdefer allocator.free(id);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_revision = if (revision) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_revision) |value| allocator.free(value);

    var description: ?[]const u8 = null;
    if (revision) |value| {
        const short = try util.truncate(allocator, value, 7);
        defer allocator.free(short);
        if (description_prefix.len > 0) {
            description = try std.fmt.allocPrint(allocator, "{s}{s}", .{ description_prefix, short });
        } else {
            description = try allocator.dupe(u8, short);
        }
    }
    errdefer if (description) |value| allocator.free(value);

    const category: ?[]const u8 = try allocator.dupe(u8, switch (reference.ref_type) {
        .head => "branches",
        .remote_head => "remote branches",
        .tag => "tags",
    });
    errdefer if (category) |value| allocator.free(value);
    const icon: scm_history.RefIcon = switch (reference.ref_type) {
        .head => .branch,
        .remote_head => .remote,
        .tag => .tag,
    };
    return .{
        .id = id,
        .name = owned_name,
        .revision = owned_revision,
        .description = description,
        .category = category,
        .icon = icon,
    };
}

fn resolveHistoryItemRefs(
    allocator: Allocator,
    commit: git_common.GitCommit,
) ![]scm_history.ISCMHistoryItemRef {
    var refs = std.array_list.Managed(scm_history.ISCMHistoryItemRef).init(allocator);
    errdefer freeRefList(allocator, &refs);

    for (commit.ref_names) |raw| {
        if (std.mem.eql(u8, raw, "refs/remotes/origin/HEAD")) continue;
        if (std.mem.startsWith(u8, raw, "HEAD -> refs/heads/")) {
            const name = raw["HEAD -> refs/heads/".len..];
            try appendResolvedRef(allocator, &refs, try allocator.dupe(u8, raw["HEAD -> ".len..]), name, "branches", .head, commit.hash);
        } else if (std.mem.startsWith(u8, raw, "refs/heads/")) {
            const name = raw["refs/heads/".len..];
            try appendResolvedRef(allocator, &refs, try allocator.dupe(u8, raw), name, "branches", .branch, commit.hash);
        } else if (std.mem.startsWith(u8, raw, "refs/remotes/")) {
            const name = raw["refs/remotes/".len..];
            try appendResolvedRef(allocator, &refs, try allocator.dupe(u8, raw), name, "remote branches", .remote, commit.hash);
        } else if (std.mem.startsWith(u8, raw, "tag: refs/tags/")) {
            const name = raw["tag: refs/tags/".len..];
            try appendResolvedRef(allocator, &refs, try allocator.dupe(u8, raw["tag: ".len..]), name, "tags", .tag, commit.hash);
        }
    }
    std.sort.insertion(scm_history.ISCMHistoryItemRef, refs.items, {}, refLessThan);
    return refs.toOwnedSlice();
}

fn appendResolvedRef(
    allocator: Allocator,
    refs: *std.array_list.Managed(scm_history.ISCMHistoryItemRef),
    id: []u8,
    name: []const u8,
    category: []const u8,
    icon: scm_history.RefIcon,
    revision: []const u8,
) !void {
    errdefer allocator.free(id);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_revision = try allocator.dupe(u8, revision);
    errdefer allocator.free(owned_revision);
    const owned_category = try allocator.dupe(u8, category);
    errdefer allocator.free(owned_category);
    try refs.append(.{
        .id = id,
        .name = owned_name,
        .revision = owned_revision,
        .category = owned_category,
        .icon = icon,
    });
}

fn refLessThan(_: void, a: scm_history.ISCMHistoryItemRef, b: scm_history.ISCMHistoryItemRef) bool {
    const a_order = refOrder(a);
    const b_order = refOrder(b);
    if (a_order != b_order) return a_order < b_order;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn refOrder(reference: scm_history.ISCMHistoryItemRef) usize {
    if (std.mem.startsWith(u8, reference.id, "refs/heads/")) return 1;
    if (std.mem.startsWith(u8, reference.id, "refs/remotes/")) return 2;
    if (std.mem.startsWith(u8, reference.id, "refs/tags/")) return 3;
    return 99;
}

fn provideHistoryItemRefsThunk(
    context: *anyopaque,
    allocator: Allocator,
    history_item_refs: ?[]const []const u8,
) anyerror![]scm_history.ISCMHistoryItemRef {
    const self: *GitHistoryProvider = @ptrCast(@alignCast(context));
    return self.provideHistoryItemRefs(allocator, history_item_refs);
}

fn provideHistoryItemsThunk(
    context: *anyopaque,
    allocator: Allocator,
    options: scm_history.ISCMHistoryOptions,
) anyerror![]scm_history.ISCMHistoryItem {
    const self: *GitHistoryProvider = @ptrCast(@alignCast(context));
    return self.provideHistoryItems(allocator, options);
}

fn provideHistoryItemChangesThunk(
    context: *anyopaque,
    allocator: Allocator,
    history_item_id: []const u8,
    history_item_parent_id: ?[]const u8,
) anyerror![]scm_history.ISCMHistoryItemChange {
    const self: *GitHistoryProvider = @ptrCast(@alignCast(context));
    return self.provideHistoryItemChanges(allocator, history_item_id, history_item_parent_id);
}

fn resolveCommonAncestorThunk(
    context: *anyopaque,
    allocator: Allocator,
    history_item_refs: []const []const u8,
) anyerror!?[]u8 {
    const self: *GitHistoryProvider = @ptrCast(@alignCast(context));
    return self.resolveHistoryItemRefsCommonAncestor(allocator, history_item_refs);
}

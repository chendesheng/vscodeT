// Port of `src/vs/workbench/contrib/scm/common/history.ts`.
//
// Terminal adaptations:
// - Strings are paths and identifiers instead of `URI` values; change entries
//   carry the repository-relative path plus the rename source.
// - `IObservable` fields become plain state on the provider plus a
//   `historyItemRefChanges` emitter, like the other ported SCM services.
// - Promises become synchronous `!T` methods; results are owned by the caller
//   and freed with the helpers below. Event payloads stay borrowed from the
//   provider until the next refresh.
// - Chat context methods, markdown tooltips and avatar URIs are not part of the
//   read-only terminal scope; the history item keeps the fields needed by the
//   graph, the hover overlay and the diff opener.
// - `theme icons` become a single-cell `RefIcon` tag.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const SCMIncomingHistoryItemId = "scm-graph-incoming-changes";
pub const SCMOutgoingHistoryItemId = "scm-graph-outgoing-changes";

/// Terminal projection of the upstream reference/avatar theme icons.
pub const RefIcon = enum { head, branch, remote, tag };

pub const ISCMHistoryItemRef = struct {
    id: []const u8,
    name: []const u8,
    revision: ?[]const u8 = null,
    category: ?[]const u8 = null,
    description: ?[]const u8 = null,
    color: ?[]const u8 = null,
    icon: ?RefIcon = null,

    pub fn clone(self: ISCMHistoryItemRef, allocator: Allocator) !ISCMHistoryItemRef {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const revision = if (self.revision) |value| try allocator.dupe(u8, value) else null;
        errdefer if (revision) |value| allocator.free(value);
        const category = if (self.category) |value| try allocator.dupe(u8, value) else null;
        errdefer if (category) |value| allocator.free(value);
        const description = if (self.description) |value| try allocator.dupe(u8, value) else null;
        errdefer if (description) |value| allocator.free(value);
        const color = if (self.color) |value| try allocator.dupe(u8, value) else null;
        errdefer if (color) |value| allocator.free(value);

        return .{
            .id = id,
            .name = name,
            .revision = revision,
            .category = category,
            .description = description,
            .color = color,
            .icon = self.icon,
        };
    }

    /// Clones the reference and overrides its graph color (upstream spreads
    /// `{ ...ref, color }`, so a missing map entry clears the color too).
    pub fn cloneWithColor(
        self: ISCMHistoryItemRef,
        allocator: Allocator,
        color: ?[]const u8,
    ) !ISCMHistoryItemRef {
        var copy = try self.clone(allocator);
        errdefer copy.deinit(allocator);
        if (copy.color) |old| allocator.free(old);
        copy.color = if (color) |value| try allocator.dupe(u8, value) else null;
        return copy;
    }

    pub fn deinit(self: *ISCMHistoryItemRef, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.revision) |value| allocator.free(value);
        if (self.category) |value| allocator.free(value);
        if (self.description) |value| allocator.free(value);
        if (self.color) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ISCMHistoryItemRefsChangeEvent = struct {
    added: []const ISCMHistoryItemRef = &.{},
    removed: []const ISCMHistoryItemRef = &.{},
    modified: []const ISCMHistoryItemRef = &.{},
    silent: bool = false,
};

pub const ISCMHistoryItemStatistics = struct {
    files: usize = 0,
    insertions: usize = 0,
    deletions: usize = 0,
};

pub const ISCMHistoryItem = struct {
    id: []const u8,
    parent_ids: []const []const u8,
    subject: []const u8,
    message: []const u8,
    display_id: ?[]const u8 = null,
    author: ?[]const u8 = null,
    author_email: ?[]const u8 = null,
    /// Author timestamp in milliseconds, like the upstream `timestamp` field.
    timestamp: ?i64 = null,
    statistics: ISCMHistoryItemStatistics = .{},
    references: []ISCMHistoryItemRef = &.{},

    pub fn clone(self: ISCMHistoryItem, allocator: Allocator) !ISCMHistoryItem {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const subject = try allocator.dupe(u8, self.subject);
        errdefer allocator.free(subject);
        const message = try allocator.dupe(u8, self.message);
        errdefer allocator.free(message);
        const display_id = if (self.display_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (display_id) |value| allocator.free(value);
        const author = if (self.author) |value| try allocator.dupe(u8, value) else null;
        errdefer if (author) |value| allocator.free(value);
        const author_email = if (self.author_email) |value| try allocator.dupe(u8, value) else null;
        errdefer if (author_email) |value| allocator.free(value);

        const parent_ids = try allocator.alloc([]const u8, self.parent_ids.len);
        errdefer allocator.free(parent_ids);
        var parents_owned: usize = 0;
        errdefer for (parent_ids[0..parents_owned]) |parent| allocator.free(parent);
        for (self.parent_ids, 0..) |parent, index| {
            parent_ids[index] = try allocator.dupe(u8, parent);
            parents_owned = index + 1;
        }

        const references = try allocator.alloc(ISCMHistoryItemRef, self.references.len);
        errdefer allocator.free(references);
        var refs_owned: usize = 0;
        errdefer for (references[0..refs_owned]) |*reference| reference.deinit(allocator);
        for (self.references, 0..) |reference, index| {
            references[index] = try reference.clone(allocator);
            refs_owned = index + 1;
        }

        return .{
            .id = id,
            .parent_ids = parent_ids,
            .subject = subject,
            .message = message,
            .display_id = display_id,
            .author = author,
            .author_email = author_email,
            .timestamp = self.timestamp,
            .statistics = self.statistics,
            .references = references,
        };
    }

    pub fn deinit(self: *ISCMHistoryItem, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.subject);
        allocator.free(self.message);
        if (self.display_id) |value| allocator.free(value);
        if (self.author) |value| allocator.free(value);
        if (self.author_email) |value| allocator.free(value);
        for (self.parent_ids) |parent| allocator.free(parent);
        allocator.free(self.parent_ids);
        for (self.references) |*reference| reference.deinit(allocator);
        allocator.free(self.references);
        self.* = undefined;
    }

    /// The upstream `subject` derivation: the text before the first newline.
    pub fn subjectOf(message: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, message, '\n')) |index| return message[0..index];
        return message;
    }
};

pub const ISCMHistoryItemRefsChangeEventList = struct {
    added: std.array_list.Managed(ISCMHistoryItemRef),
    removed: std.array_list.Managed(ISCMHistoryItemRef),
    modified: std.array_list.Managed(ISCMHistoryItemRef),
    silent: bool = false,
};

pub const HistoryLimit = union(enum) {
    none,
    count: usize,
    id: []const u8,
};

pub const ISCMHistoryOptions = struct {
    skip: ?usize = null,
    limit: HistoryLimit = .none,
    history_item_refs: []const []const u8 = &.{},
    filter_text: ?[]const u8 = null,
    /// Terminal extension: ask the git host for `--all` instead of passing a
    /// possibly huge revision list on the command line.
    all_refs: bool = false,
};

pub const ISCMHistoryItemGraphNode = struct {
    id: []const u8,
    color: []const u8,
};

pub const HistoryItemKind = enum { head, node, incoming_changes, outgoing_changes };

pub const ISCMHistoryItemViewModel = struct {
    history_item: ISCMHistoryItem,
    input_swimlanes: []ISCMHistoryItemGraphNode,
    output_swimlanes: []ISCMHistoryItemGraphNode,
    kind: HistoryItemKind,

    pub fn deinit(self: *ISCMHistoryItemViewModel, allocator: Allocator) void {
        self.history_item.deinit(allocator);
        freeGraphNodes(allocator, self.input_swimlanes);
        freeGraphNodes(allocator, self.output_swimlanes);
        self.* = undefined;
    }
};

pub const ISCMHistoryItemChange = struct {
    path: []const u8,
    original_path: ?[]const u8 = null,
    status: u8 = 0,
    insertions: usize = 0,
    deletions: usize = 0,

    pub fn clone(self: ISCMHistoryItemChange, allocator: Allocator) !ISCMHistoryItemChange {
        const path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(path);
        const original_path = if (self.original_path) |value| try allocator.dupe(u8, value) else null;
        return .{
            .path = path,
            .original_path = original_path,
            .status = self.status,
            .insertions = self.insertions,
            .deletions = self.deletions,
        };
    }

    pub fn deinit(self: *ISCMHistoryItemChange, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.original_path) |value| allocator.free(value);
        self.* = undefined;
    }
};

/// Terminal port of `ISCMHistoryProvider`. The three current refs are owned by
/// the provider and replaced on refresh; methods return caller-owned results.
pub const ISCMHistoryProvider = struct {
    context: *anyopaque,
    /// Current history item reference (HEAD/branch/tag/detached commit).
    history_item_ref: ?ISCMHistoryItemRef = null,
    history_item_remote_ref: ?ISCMHistoryItemRef = null,
    history_item_base_ref: ?ISCMHistoryItemRef = null,
    on_did_change_history_item_refs: *Emitter(ISCMHistoryItemRefsChangeEvent),
    provide_history_item_refs_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        history_item_refs: ?[]const []const u8,
    ) anyerror![]ISCMHistoryItemRef,
    provide_history_items_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        options: ISCMHistoryOptions,
    ) anyerror![]ISCMHistoryItem,
    provide_history_item_changes_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        history_item_id: []const u8,
        history_item_parent_id: ?[]const u8,
    ) anyerror![]ISCMHistoryItemChange,
    resolve_history_item_refs_common_ancestor_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        history_item_refs: []const []const u8,
    ) anyerror!?[]u8,

    pub fn provideHistoryItemRefs(
        self: ISCMHistoryProvider,
        allocator: Allocator,
        history_item_refs: ?[]const []const u8,
    ) ![]ISCMHistoryItemRef {
        return self.provide_history_item_refs_fn(self.context, allocator, history_item_refs);
    }

    pub fn provideHistoryItems(
        self: ISCMHistoryProvider,
        allocator: Allocator,
        options: ISCMHistoryOptions,
    ) ![]ISCMHistoryItem {
        return self.provide_history_items_fn(self.context, allocator, options);
    }

    pub fn provideHistoryItemChanges(
        self: ISCMHistoryProvider,
        allocator: Allocator,
        history_item_id: []const u8,
        history_item_parent_id: ?[]const u8,
    ) ![]ISCMHistoryItemChange {
        return self.provide_history_item_changes_fn(self.context, allocator, history_item_id, history_item_parent_id);
    }

    pub fn resolveHistoryItemRefsCommonAncestor(
        self: ISCMHistoryProvider,
        allocator: Allocator,
        history_item_refs: []const []const u8,
    ) !?[]u8 {
        return self.resolve_history_item_refs_common_ancestor_fn(self.context, allocator, history_item_refs);
    }
};

pub fn freeHistoryItemRefs(allocator: Allocator, refs: []ISCMHistoryItemRef) void {
    for (refs) |*reference| reference.deinit(allocator);
    if (refs.len > 0) allocator.free(refs);
}

pub fn freeHistoryItems(allocator: Allocator, items: []ISCMHistoryItem) void {
    for (items) |*item| item.deinit(allocator);
    if (items.len > 0) allocator.free(items);
}

pub fn freeHistoryItemChanges(allocator: Allocator, changes: []ISCMHistoryItemChange) void {
    for (changes) |*change| change.deinit(allocator);
    if (changes.len > 0) allocator.free(changes);
}

pub fn freeGraphNodes(allocator: Allocator, nodes: []ISCMHistoryItemGraphNode) void {
    for (nodes) |node| {
        allocator.free(node.id);
        allocator.free(node.color);
    }
    if (nodes.len > 0) allocator.free(nodes);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "history: item and ref clones own their strings" {
    const allocator = testing.allocator;
    var ref = ISCMHistoryItemRef{
        .id = "refs/heads/main",
        .name = "main",
        .revision = "abc",
        .category = "branches",
        .description = "abc",
        .color = "scmGraph.foreground1",
        .icon = .branch,
    };
    var ref_clone = try ref.clone(allocator);
    defer ref_clone.deinit(allocator);
    try testing.expectEqualStrings(ref.id, ref_clone.id);
    try testing.expectEqualStrings(ref.color.?, ref_clone.color.?);
    try testing.expect(ref_clone.id.ptr != ref.id.ptr);

    var item = ISCMHistoryItem{
        .id = "abc",
        .parent_ids = &.{"parent"},
        .subject = "subject",
        .message = "subject\nbody",
        .display_id = "abc1234",
        .author = "Author",
        .author_email = "a@example.com",
        .timestamp = 1000,
        .statistics = .{ .files = 2, .insertions = 3, .deletions = 1 },
        .references = @constCast(&[_]ISCMHistoryItemRef{ref}),
    };
    var clone = try item.clone(allocator);
    defer clone.deinit(allocator);
    try testing.expectEqualStrings("abc", clone.id);
    try testing.expectEqualStrings("parent", clone.parent_ids[0]);
    try testing.expectEqualStrings("main", clone.references[0].name);
    try testing.expectEqual(@as(usize, 2), clone.statistics.files);
    try testing.expectEqualStrings("subject", ISCMHistoryItem.subjectOf(clone.message));
}

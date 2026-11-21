// Port of the history-related helpers in `vscode/extensions/git/src/util.ts`.
//
// Only the functions used by the terminal history provider are ported:
// `deltaHistoryItemRefs`, `subject` and `truncate`. Clone/remote/operation
// helpers are outside the ported extension subset.
const std = @import("std");
const Allocator = std.mem.Allocator;
const history = @import("../../../vs/workbench/contrib/scm/common/history.zig");

pub const HistoryItemRefDelta = struct {
    added: std.array_list.Managed(history.ISCMHistoryItemRef),
    removed: std.array_list.Managed(history.ISCMHistoryItemRef),
    modified: std.array_list.Managed(history.ISCMHistoryItemRef),

    pub fn init(allocator: Allocator) HistoryItemRefDelta {
        return .{
            .added = std.array_list.Managed(history.ISCMHistoryItemRef).init(allocator),
            .removed = std.array_list.Managed(history.ISCMHistoryItemRef).init(allocator),
            .modified = std.array_list.Managed(history.ISCMHistoryItemRef).init(allocator),
        };
    }

    pub fn deinit(self: *HistoryItemRefDelta) void {
        self.added.deinit();
        self.removed.deinit();
        self.modified.deinit();
        self.* = undefined;
    }
};

fn compareRefs(_: void, a: history.ISCMHistoryItemRef, b: history.ISCMHistoryItemRef) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Port of the extension's `deltaHistoryItemRefs`. Both inputs are sorted by
/// id (as the provider sorts them); the event arrays borrow the elements.
pub fn deltaHistoryItemRefs(
    allocator: Allocator,
    before: []const history.ISCMHistoryItemRef,
    after: []const history.ISCMHistoryItemRef,
) !HistoryItemRefDelta {
    var delta = HistoryItemRefDelta.init(allocator);
    errdefer delta.deinit();

    if (before.len == 0) {
        try delta.added.appendSlice(after);
        return delta;
    }

    var before_index: usize = 0;
    var after_index: usize = 0;
    while (true) {
        if (before_index == before.len) {
            try delta.added.appendSlice(after[after_index..]);
            break;
        }
        if (after_index == after.len) {
            try delta.removed.appendSlice(before[before_index..]);
            break;
        }

        const before_element = before[before_index];
        const after_element = after[after_index];
        switch (std.mem.order(u8, before_element.id, after_element.id)) {
            .eq => {
                const before_revision = before_element.revision orelse "";
                const after_revision = after_element.revision orelse "";
                if (!std.mem.eql(u8, before_revision, after_revision)) {
                    try delta.modified.append(after_element);
                }
                before_index += 1;
                after_index += 1;
            },
            .lt => {
                try delta.removed.append(before_element);
                before_index += 1;
            },
            .gt => {
                try delta.added.append(after_element);
                after_index += 1;
            },
        }
    }

    return delta;
}

/// Sorts refs by id, matching the provider's reference list order.
pub fn sortHistoryItemRefs(refs: []history.ISCMHistoryItemRef) void {
    std.sort.insertion(history.ISCMHistoryItemRef, refs, {}, compareRefs);
}

/// Upstream `subject`: the text before the first newline.
pub fn subject(message: []const u8) []const u8 {
    return history.ISCMHistoryItem.subjectOf(message);
}

/// Upstream `truncate(value, length, ellipsis)`, used for short hashes.
pub fn truncate(allocator: Allocator, value: []const u8, length: usize) ![]u8 {
    if (length == 0 or value.len <= length) return allocator.dupe(u8, value);
    return allocator.dupe(u8, value[0..length]);
}

// Tests live in `src/extensions/git/src/test/util.test.zig`.

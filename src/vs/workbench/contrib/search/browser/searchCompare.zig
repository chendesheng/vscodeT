// Port of `src/vs/workbench/contrib/search/browser/searchCompare.ts`.
//
// Notebook and AI match variants are not ported, so the comparers only see
// the text heading/folder/file/match nodes of `searchTreeCommon.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const comparers = @import("../../../../base/common/comparers.zig");
const range_mod = @import("../../../../editor/common/core/range.zig");
const Range = range_mod.Range;
const search = @import("../../../services/search/common/search.zig");
const SearchSortOrder = search.SearchSortOrder;

/// Compares instances of the same match type. Different match types should not
/// be siblings and their sort order is undefined.
pub fn searchMatchComparer(a: Node, b: Node, sort_order: SearchSortOrder) i32 {
    if (a == .file and b == .folder) return 1;
    if (b == .file and a == .folder) return -1;
    if (a == .folder and b == .folder) {
        const a_folder = a.folder;
        const b_folder = b.folder;
        if (a_folder.index != b_folder.index) return @intCast(@as(isize, @intCast(a_folder.index)) - @as(isize, @intCast(b_folder.index)));
        return switch (sort_order) {
            .count_descending => countCompare(b_folder.recursiveMatchCount(), a_folder.recursiveMatchCount()),
            .count_ascending => countCompare(a_folder.recursiveMatchCount(), b_folder.recursiveMatchCount()),
            .type => comparers.compareFileExtensions(a_folder.name, b_folder.name),
            .file_names => comparers.compareFileNames(a_folder.name, b_folder.name),
            else => if (a_folder.path.len == 0 or b_folder.path.len == 0)
                0
            else
                firstNonZero(
                    comparers.comparePaths(a_folder.path, b_folder.path),
                    comparers.compareFileNames(a_folder.name, b_folder.name),
                ),
        };
    }

    if (a == .file and b == .file) {
        const a_file = a.file;
        const b_file = b.file;
        return switch (sort_order) {
            .count_descending => countCompare(b_file.count(), a_file.count()),
            .count_ascending => countCompare(a_file.count(), b_file.count()),
            .type => comparers.compareFileExtensions(a_file.name, b_file.name),
            .file_names => comparers.compareFileNames(a_file.name, b_file.name),
            // File stats are not collected by the terminal search service, so
            // `modified` falls through to the path order like upstream does
            // when a stat is missing.
            else => firstNonZero(
                comparers.comparePaths(a_file.path, b_file.path),
                comparers.compareFileNames(a_file.name, b_file.name),
            ),
        };
    }

    if (a == .match and b == .match) {
        const a_range = a.match.range();
        const b_range = b.match.range();
        return @intCast(range_mod.compareRangesUsingStarts(&a_range, &b_range));
    }

    return 0;
}

/// Compares two elements by walking up their parents until the hierarchies
/// differ, then delegates to `searchMatchComparer`.
pub fn searchComparer(a: Node, b: Node, sort_order: SearchSortOrder) i32 {
    var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator.deinit();
    const a_parents = createParentList(allocator.allocator(), a) catch return 0;
    const b_parents = createParentList(allocator.allocator(), b) catch return 0;

    var i: isize = @as(isize, @intCast(a_parents.len)) - 1;
    var j: isize = @as(isize, @intCast(b_parents.len)) - 1;
    while (i >= 0 and j >= 0) {
        const a_node = a_parents[@intCast(i)];
        const b_node = b_parents[@intCast(j)];
        if (!std.mem.eql(u8, nodeId(a_node), nodeId(b_node))) {
            return searchMatchComparer(a_node, b_node, sort_order);
        }
        i -= 1;
        j -= 1;
    }

    const a_at_end = i == 0;
    const b_at_end = j == 0;
    if (a_at_end and !b_at_end) return 1;
    if (!a_at_end and b_at_end) return -1;
    return 0;
}

/// Port of `createParentList`: the element itself followed by its parents,
/// stopping before the text heading.
pub fn createParentList(allocator: Allocator, element: Node) ![]Node {
    var parents = std.array_list.Managed(Node).init(allocator);
    errdefer parents.deinit();
    var current: ?Node = element;
    while (current) |node| {
        switch (node) {
            .heading => break,
            .folder => |folder| {
                try parents.append(node);
                current = if (folder.parent_folder) |parent| Node{ .folder = parent } else Node{ .heading = folder.heading };
            },
            .file => |file| {
                try parents.append(node);
                current = Node{ .folder = file.parent_folder };
            },
            .match => |match| {
                try parents.append(node);
                current = Node{ .file = match.parent_file };
            },
        }
    }
    return try parents.toOwnedSlice();
}

/// Port of `compareLevels` from `searchActionsRemoveReplace.ts`.
pub fn compareLevels(a: Node, b: Node) i32 {
    switch (a) {
        .match => return if (b == .match) 0 else -1,
        .file => return switch (b) {
            .match => 1,
            .file => 0,
            else => -1,
        },
        .folder => return switch (b) {
            .heading => -1,
            .folder => 0,
            else => 1,
        },
        .heading => return if (b == .heading) 0 else 1,
    }
}

fn countCompare(a: usize, b: usize) i32 {
    return @intCast(@as(isize, @intCast(a)) - @as(isize, @intCast(b)));
}

fn firstNonZero(first: i32, second: i32) i32 {
    return if (first != 0) first else second;
}

fn nodeId(node: Node) []const u8 {
    return node.id();
}

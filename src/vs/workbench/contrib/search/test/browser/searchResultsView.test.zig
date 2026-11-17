// Tests for the ported `searchResultsView.zig` data source and row labels.

const std = @import("std");
const search = @import("../../../../services/search/common/search.zig");
const tree = @import("../../browser/searchTreeModel/searchTreeCommon.zig");
const results_view = @import("../../browser/searchResultsView.zig");

fn addFile(
    allocator: std.mem.Allocator,
    result: *tree.SearchResult,
    path: []const u8,
    line: usize,
) !*tree.FileMatch {
    const ranges = [_]search.SearchRange{search.SearchRange.init(line, 0, line, 3)};
    var raw_match = try search.TextSearchMatch.init(allocator, "abc", &ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
    var raw_file = search.SearchFileResult{
        .allocator = allocator,
        .resource = try allocator.dupe(u8, path),
        .results = try allocator.alloc(search.TextSearchMatch, 1),
    };
    raw_file.results[0] = raw_match;
    defer {
        for (raw_file.results) |*item| item.deinit();
        allocator.free(raw_file.results);
        allocator.free(raw_file.resource);
    }
    _ = &raw_match;
    try result.add(&.{raw_file}, false);
    const files = try result.matches(allocator);
    defer allocator.free(files);
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return error.FileNotFound;
}

test "searchResultsView: single root is transparent and ordered" {
    const allocator = std.testing.allocator;
    var query = try search.TextQuery.init(allocator, "abc", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);
    _ = try addFile(allocator, result, "/root/b.txt", 0);
    _ = try addFile(allocator, result, "/root/a.txt", 0);

    const data = results_view.SearchViewDataSource.init(result, .{ .mode = .list });
    const roots = try data.getRootChildren(allocator);
    defer allocator.free(roots);
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expect(roots[0] == .file);
    try std.testing.expectEqualStrings("a.txt", roots[0].file.name);
    try std.testing.expectEqualStrings("b.txt", roots[1].file.name);
}

test "searchResultsView: row labels, counts and line numbers" {
    const allocator = std.testing.allocator;
    var query = try search.TextQuery.init(allocator, "abc", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);
    const file = try addFile(allocator, result, "/root/a.txt", 4);

    const file_row = results_view.rowData(.{ .file = file }, .{ .mode = .list });
    try std.testing.expectEqual(results_view.Template.file_match, file_row.template);
    try std.testing.expectEqualStrings("a.txt", file_row.label);
    try std.testing.expectEqualStrings("a.txt", file_row.description);
    try std.testing.expectEqual(@as(usize, 1), file_row.count);

    const match_row = results_view.rowData(.{ .match = file.matches()[0] }, .{ .show_line_numbers = true });
    try std.testing.expectEqual(@as(usize, 5), match_row.line_number);
    try std.testing.expectEqualStrings("abc", match_row.inside);

    const title = try results_view.badgeTitle(allocator, .{ .file = file });
    defer allocator.free(title);
    try std.testing.expectEqualStrings("1 match found", title);
}

test "searchResultsView: aria labels follow upstream text" {
    const allocator = std.testing.allocator;
    var query = try search.TextQuery.init(allocator, "abc", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);
    const file = try addFile(allocator, result, "/root/a.txt", 0);
    const model = try @import("../../browser/searchTreeModel/searchModel.zig").SearchModel.init(allocator, undefined);
    defer model.deinit();

    const file_label = try results_view.ariaLabel(allocator, .{ .file = file }, model);
    defer allocator.free(file_label);
    try std.testing.expect(std.mem.indexOf(u8, file_label, "1 matches in file a.txt") != null);

    const match_label = try results_view.ariaLabel(allocator, .{ .match = file.matches()[0] }, model);
    defer allocator.free(match_label);
    try std.testing.expect(std.mem.indexOf(u8, match_label, "found abc") != null);
}

test "searchResultsView: visible rows carry tree depth and honor collapse" {
    const allocator = std.testing.allocator;
    var query = try search.TextQuery.init(allocator, "abc", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);
    const file = try addFile(allocator, result, "/root/a.txt", 0);

    const State = struct {
        collapse_file: bool,
        visits: usize = 0,
        target: *tree.FileMatch,

        fn isCollapsed(context: *anyopaque, node: tree.Node) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.collapse_file and node == .file and node.file == self.target;
        }

        fn visit(context: *anyopaque, _: tree.Node) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.visits += 1;
        }
    };
    var state = State{ .collapse_file = false, .target = file };
    const data = results_view.SearchViewDataSource.init(result, .{ .mode = .list });

    const expanded = try data.visibleRows(allocator, .{
        .context = &state,
        .is_collapsed = State.isCollapsed,
        .on_visit = State.visit,
    });
    defer allocator.free(expanded);
    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expect(expanded[0].node == .file);
    try std.testing.expectEqual(@as(usize, 0), expanded[0].depth);
    try std.testing.expect(expanded[1].node == .match);
    try std.testing.expectEqual(@as(usize, 1), expanded[1].depth);
    try std.testing.expectEqual(@as(usize, 0), results_view.indentCells(expanded[0].depth));
    try std.testing.expectEqual(@as(usize, 3), results_view.matchIndentCells(expanded[1].depth));

    state.collapse_file = true;
    state.visits = 0;
    const collapsed = try data.visibleRows(allocator, .{
        .context = &state,
        .is_collapsed = State.isCollapsed,
        .on_visit = State.visit,
    });
    defer allocator.free(collapsed);
    try std.testing.expectEqual(@as(usize, 1), collapsed.len);
    try std.testing.expectEqual(@as(usize, 1), state.visits);
}

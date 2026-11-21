// Adapted hierarchy and lifecycle cases from
// `src/vs/workbench/contrib/search/test/browser/searchResult.test.ts`.
// Notebook and AI variants are not ported.

const std = @import("std");
const search = @import("../../../../services/search/common/search.zig");
const tree = @import("../../browser/searchTreeModel/searchTreeCommon.zig");

test "SearchResult: adds and removes file matches" {
    const allocator = std.testing.allocator;
    var query = try search.TextQuery.init(allocator, "foo", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);

    const ranges = [_]search.SearchRange{search.SearchRange.init(0, 0, 0, 3)};
    const raw = try search.TextSearchMatch.init(allocator, "foo", &ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
    var file = search.SearchFileResult{
        .allocator = allocator,
        .resource = try allocator.dupe(u8, "/root/a.txt"),
        .results = try allocator.alloc(search.TextSearchMatch, 1),
    };
    file.results[0] = raw;
    try result.add(&.{file}, false);
    try std.testing.expectEqual(@as(usize, 1), result.count());

    const files = try result.matches(allocator);
    defer allocator.free(files);
    result.removeFile(files[0]);
    try std.testing.expect(result.isEmpty());
    for (file.results) |*item| item.deinit();
    allocator.free(file.results);
    allocator.free(file.resource);
}

test "SearchResult: surrounding contexts are attached to the file match" {
    const allocator = std.testing.allocator;
    var query = try search.TextQuery.init(allocator, "foo", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator);
    defer result.deinit();
    result.setQuery(&query);

    const ranges = [_]search.SearchRange{search.SearchRange.init(1, 0, 1, 3)};
    const raw = try search.TextSearchMatch.init(allocator, "foo", &ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
    const contexts = try allocator.alloc(search.TextSearchContext, 1);
    contexts[0] = .{
        .text = try allocator.dupe(u8, "context line"),
        .line_number = 1,
    };
    var file = search.SearchFileResult{
        .allocator = allocator,
        .resource = try allocator.dupe(u8, "/root/a.txt"),
        .results = try allocator.alloc(search.TextSearchMatch, 1),
        .contexts = contexts,
    };
    file.results[0] = raw;
    try result.add(&.{file}, false);

    const files = try result.matches(allocator);
    defer allocator.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("context line", files[0].contextForLine(1).?);

    for (file.results) |*item| item.deinit();
    allocator.free(file.results);
    allocator.free(file.contexts[0].text);
    allocator.free(file.contexts);
    allocator.free(file.resource);
}

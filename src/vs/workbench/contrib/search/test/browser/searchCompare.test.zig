// Adapted comparer cases from
// `src/vs/workbench/contrib/search/test/browser/searchViewlet.test.ts`.

const std = @import("std");
const search = @import("../../../../services/search/common/search.zig");
const tree = @import("../../browser/searchTreeModel/searchTreeCommon.zig");
const compare = @import("../../browser/searchCompare.zig");

fn addFile(allocator: std.mem.Allocator, result: *tree.SearchResult, path: []const u8) !*tree.FileMatch {
    const ranges = [_]search.SearchRange{search.SearchRange.init(0, 0, 0, 3)};
    const raw_match = try search.TextSearchMatch.init(allocator, "abc", &ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
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
    try result.add(&.{raw_file}, false);
    const files = try result.matches(allocator);
    defer allocator.free(files);
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file;
    }
    return error.FileNotFound;
}

test "searchCompare: path, file name, type and cross-type order" {
    const allocator = std.testing.allocator;
    var query = try search.TextQuery.init(allocator, "abc", &.{ "/root/voo", "/root/with" }, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator, std.testing.io);
    defer result.deinit();
    result.setQuery(&query);

    const file1 = try addFile(allocator, result, "/root/voo/foo10");
    const file2 = try addFile(allocator, result, "/root/with/foo1");
    const file3 = try addFile(allocator, result, "/root/with/bar.a");
    const file4 = try addFile(allocator, result, "/root/with/bar.b");

    try std.testing.expect(compare.searchMatchComparer(.{ .file = file1 }, .{ .file = file2 }, .default) < 0);
    try std.testing.expect(compare.searchMatchComparer(.{ .file = file1 }, .{ .file = file2 }, .file_names) > 0);
    try std.testing.expect(compare.searchMatchComparer(.{ .file = file3 }, .{ .file = file4 }, .type) < 0);

    try std.testing.expect(compare.searchComparer(.{ .file = file1 }, .{ .file = file3 }, .default) < 0);
    try std.testing.expect(compare.searchComparer(.{ .file = file2 }, .{ .file = file3 }, .default) > 0);
    try std.testing.expect(compare.searchComparer(.{ .match = file1.matches()[0] }, .{ .match = file3.matches()[0] }, .default) < 0);
}

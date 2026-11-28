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
    const result = try tree.SearchResult.create(allocator, std.testing.io);
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
    const result = try tree.SearchResult.create(allocator, std.testing.io);
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

test "SearchResult: initial file match uses the live model rather than stale disk results" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../../../editor/test/common/port/testSupport.zig").TestModel;
    const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
    const dispatch = @import("../../../../../base/common/windowDispatch.zig");
    var model = try TestModel.init(allocator, "unmatched", "plaintext");
    defer model.deinit();
    var queue = dispatch.Queue{ .io = std.testing.io };
    var query = try search.TextQuery.init(allocator, "foo", &.{"/root"}, "", "", &.{});
    defer query.deinit();
    const result = try tree.SearchResult.create(allocator, std.testing.io);
    defer result.deinit();
    result.model_host = .{
        .context = model.model,
        .queue = &queue,
        .get = struct {
            fn get(context: *anyopaque, path: []const u8) ?*TextModel {
                if (!std.mem.eql(u8, path, "/root/a.txt")) return null;
                return @ptrCast(@alignCast(context));
            }
        }.get,
    };
    result.setQuery(&query);
    const ranges = [_]search.SearchRange{search.SearchRange.init(0, 0, 0, 3)};
    var raw = try search.TextSearchMatch.init(allocator, "foo", &ranges, .{ .match_lines = 1, .chars_per_line = 1000 });
    defer raw.deinit();
    var files = [_]search.SearchFileResult{.{
        .allocator = allocator,
        .resource = try allocator.dupe(u8, "/root/a.txt"),
        .results = try allocator.alloc(search.TextSearchMatch, 1),
    }};
    defer allocator.free(files[0].resource);
    defer allocator.free(files[0].results);
    files[0].results[0] = raw;
    try result.add(&files, false);
    try std.testing.expectEqual(@as(usize, 0), result.count());
    const folder = result.heading.getFolderMatch("/root/a.txt").?;
    const file = folder.getDownstreamFileMatch("/root/a.txt").?;
    try std.testing.expect(file.model == model.model);
    try model.applyEdit(.init(1, 1, 1, 10), "foo foo");
    try std.testing.expect(queue.dispatch(file.scheduler.at.?));
    try std.testing.expectEqual(@as(usize, 2), result.count());
    // Dismiss both matches; subsequent model changes can return new matches.
    file.remove(file.matches()[0]);
    file.remove(file.matches()[0]);
    try std.testing.expectEqual(@as(usize, 0), result.count());
    try std.testing.expect(folder.getDownstreamFileMatch("/root/a.txt") == file);
    try model.applyEdit(.init(1, 1, 1, 1), "x ");
    try std.testing.expect(queue.dispatch(file.scheduler.at.?));
    try std.testing.expectEqual(@as(usize, 2), result.count());
}

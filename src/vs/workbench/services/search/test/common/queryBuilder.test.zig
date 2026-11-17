// Adapted from
// `src/vs/workbench/services/search/test/common/queryBuilder.test.ts`.
//
// The three upstream helper cases (path escaping) belong to the browser path
// utilities that are not ported. The text-query decisions that the terminal
// view depends on are covered here instead: smart case, preview, max results,
// configuration excludes and `useIgnoreFiles`.

const std = @import("std");
const search = @import("../../common/search.zig");
const query_builder = @import("../../common/queryBuilder.zig");
const configuration = @import("../../../configuration/browser/configurationService.zig");
const workspace_context = @import("../../../workspaces/common/workspaceContextService.zig");
const search_configuration = @import("../../../../contrib/search/common/searchConfiguration.zig");

fn fixture(allocator: std.mem.Allocator) !struct {
    workspace: *workspace_context.WorkspaceContextService,
    configuration: *configuration.ConfigurationService,
} {
    const io = std.Io.Threaded.global_single_threaded.io();
    const workspace = try workspace_context.WorkspaceContextService.initWithFolders(allocator, "test", &.{"/root"});
    errdefer workspace.deinit();
    const config = try configuration.ConfigurationService.init(allocator, io, workspace, .{
        .defaults_json = &.{search_configuration.defaults_json},
    });
    return .{ .workspace = workspace, .configuration = config };
}

test "QueryBuilder: smart case and preview options" {
    const allocator = std.testing.allocator;
    var f = try fixture(allocator);
    defer f.configuration.deinit();
    defer f.workspace.deinit();

    const builder = query_builder.QueryBuilder.init(allocator, f.configuration, f.workspace);
    var query = try builder.text(.{ .pattern = "Foo" }, .{ .is_smart_case = true });
    defer query.deinit();
    try std.testing.expect(query.is_case_sensitive);
    try std.testing.expectEqual(@as(usize, 1000), query.preview.chars_per_line);
    try std.testing.expectEqual(search.DEFAULT_MAX_SEARCH_RESULTS, query.max_results);
}

test "QueryBuilder: regex preview and newline normalization" {
    const allocator = std.testing.allocator;
    var f = try fixture(allocator);
    defer f.configuration.deinit();
    defer f.workspace.deinit();

    const builder = query_builder.QueryBuilder.init(allocator, f.configuration, f.workspace);
    var query = try builder.text(.{ .pattern = "foo\nbar", .is_regex = true }, .{});
    defer query.deinit();
    try std.testing.expectEqualStrings("foo\\nbar", query.pattern);
    try std.testing.expectEqual(@as(usize, 10000), query.preview.chars_per_line);
}

test "QueryBuilder: configuration excludes and useIgnoreFiles" {
    const allocator = std.testing.allocator;
    var f = try fixture(allocator);
    defer f.configuration.deinit();
    defer f.workspace.deinit();

    const builder = query_builder.QueryBuilder.init(allocator, f.configuration, f.workspace);
    var query = try builder.text(.{ .pattern = "foo" }, .{});
    defer query.deinit();
    try std.testing.expect(query.exclude_entries.len >= 2);
    try std.testing.expect(query.use_ignore_files);

    var excluded = false;
    for (query.exclude_entries) |entry| {
        if (std.mem.eql(u8, entry.pattern, "**/node_modules")) excluded = true;
    }
    try std.testing.expect(excluded);

    var disabled = try builder.text(.{ .pattern = "foo" }, .{ .use_excludes_and_ignore_files = false });
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 0), disabled.exclude_entries.len);
    try std.testing.expect(!disabled.use_ignore_files);
}

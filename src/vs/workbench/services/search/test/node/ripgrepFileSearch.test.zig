// Port of `src/vs/workbench/services/search/test/node/ripgrepFileSearch.test.ts`
// plus the argument-construction cases the TUI needs to keep upstream-shaped.

const std = @import("std");
const builtin = @import("builtin");
const search = @import("../../common/search.zig");
const ripgrep = @import("../../node/ripgrepFileSearch.zig");
const glob = @import("../../../../../base/common/glob.zig");

const folder_info = search.FolderInfo{ .resource = "/repo", .name = "repo" };

fn makeQuery(allocator: std.mem.Allocator, options: search.FileQueryOptions) !search.FileQuery {
    return search.FileQuery.init(allocator, &.{folder_info}, options);
}

fn build(
    allocator: std.mem.Allocator,
    query: *const search.FileQuery,
    options: ripgrep.BuildOptions,
) !ripgrep.Args {
    const folder = search.FolderQuery{ .folder = folder_info.resource };
    return ripgrep.buildArgs(allocator, query, folder, options);
}

fn hasArg(args: []const []const u8, wanted: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, wanted)) return true;
    }
    return false;
}

fn globIndex(args: []const []const u8, wanted: []const u8) ?usize {
    var index: usize = 0;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "-g") and std.mem.eql(u8, args[index + 1], wanted)) return index;
    }
    return null;
}

test "getAbsoluteGlob: POSIX" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const cases = [_]struct { folder: []const u8, pattern: []const u8, expected: []const u8 }{
        .{ .folder = "/foo/bar", .pattern = "glob/**", .expected = "/foo/bar/glob/**" },
        .{ .folder = "/", .pattern = "glob/**", .expected = "/glob/**" },
        .{ .folder = "/", .pattern = "/project/folder", .expected = "/project/folder" },
    };
    for (cases) |case| {
        const absolute = try ripgrep.getAbsoluteGlob(allocator, case.folder, case.pattern);
        defer allocator.free(absolute);
        const fixed = try ripgrep.fixDriveC(allocator, absolute);
        defer allocator.free(fixed);
        try std.testing.expectEqualStrings(case.expected, fixed);
    }
}

test "getAbsoluteGlob: Windows drive-letter rewriting" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const cases = [_]struct { folder: []const u8, pattern: []const u8, expected: []const u8 }{
        .{ .folder = "C:/foo/bar", .pattern = "glob/**", .expected = "/foo\\bar\\glob\\**" },
        .{ .folder = "c:/", .pattern = "glob/**", .expected = "/glob\\**" },
        .{ .folder = "C:\\foo\\bar", .pattern = "glob\\**", .expected = "/foo\\bar\\glob\\**" },
        .{ .folder = "c:\\", .pattern = "glob\\**", .expected = "/glob\\**" },
        .{ .folder = "\\\\localhost\\c$\\foo\\bar", .pattern = "glob/**", .expected = "\\\\localhost\\c$\\foo\\bar\\glob\\**" },
        .{ .folder = "c:/foo/bar", .pattern = "/path/something", .expected = "/path/something" },
        .{ .folder = "c:/foo/bar", .pattern = "c:\\project\\folder", .expected = "/project\\folder" },
    };
    for (cases) |case| {
        const absolute = try ripgrep.getAbsoluteGlob(allocator, case.folder, case.pattern);
        defer allocator.free(absolute);
        const fixed = try ripgrep.fixDriveC(allocator, absolute);
        defer allocator.free(fixed);
        try std.testing.expectEqualStrings(case.expected, fixed);
    }
}

test "buildArgs: default quick-open flags" {
    const allocator = std.testing.allocator;
    var query = try makeQuery(allocator, .{});
    defer query.deinit();
    var args = try build(allocator, &query, .{});
    defer args.deinit();

    try std.testing.expect(hasArg(args.args, "--files"));
    try std.testing.expect(hasArg(args.args, "--hidden"));
    try std.testing.expect(hasArg(args.args, "--case-sensitive"));
    try std.testing.expect(hasArg(args.args, "--no-require-git"));
    try std.testing.expect(hasArg(args.args, "--follow"));
    try std.testing.expect(hasArg(args.args, "--no-config"));
    try std.testing.expect(!hasArg(args.args, "--no-ignore"));
    try std.testing.expect(!hasArg(args.args, "--no-ignore-parent"));
    try std.testing.expect(!args.sibling_clauses);
}

test "buildArgs: casing, includes, excludes and sibling clauses" {
    const allocator = std.testing.allocator;
    var query = try makeQuery(allocator, .{
        .ignore_glob_case = true,
        .include_pattern = "src/**/*.js",
    });
    defer query.deinit();
    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "**/node_modules" },
        .{ .pattern = "**/*.tmp", .enabled = false },
        .{ .pattern = "*.css", .when = "$(basename).less" },
    };
    var args = try build(allocator, &query, .{ .exclude = &excludes });
    defer args.deinit();

    try std.testing.expect(hasArg(args.args, "--glob-case-insensitive"));
    try std.testing.expect(hasArg(args.args, "--ignore-file-case-insensitive"));
    try std.testing.expect(globIndex(args.args, "/src/**/*.js") != null);
    try std.testing.expect(globIndex(args.args, "!**/node_modules") != null);
    try std.testing.expect(globIndex(args.args, "!/repo/**/*.tmp") == null);
    try std.testing.expect(args.sibling_clauses);
}

test "buildArgs: ignore-file and symlink settings" {
    const allocator = std.testing.allocator;

    var no_ignore_query = try makeQuery(allocator, .{
        .settings = .{ .use_ignore_files = false },
    });
    defer no_ignore_query.deinit();
    var no_ignore = try build(allocator, &no_ignore_query, .{});
    defer no_ignore.deinit();
    try std.testing.expect(hasArg(no_ignore.args, "--no-ignore"));

    var no_parent_query = try makeQuery(allocator, .{
        .settings = .{ .use_parent_ignore_files = false },
    });
    defer no_parent_query.deinit();
    var no_parent = try build(allocator, &no_parent_query, .{});
    defer no_parent.deinit();
    try std.testing.expect(hasArg(no_parent.args, "--no-ignore-parent"));
    try std.testing.expect(!hasArg(no_parent.args, "--no-ignore"));

    var no_global_query = try makeQuery(allocator, .{
        .settings = .{ .use_global_ignore_files = false },
    });
    defer no_global_query.deinit();
    var no_global = try build(allocator, &no_global_query, .{});
    defer no_global.deinit();
    try std.testing.expect(hasArg(no_global.args, "--no-ignore-global"));

    var no_symlink_query = try makeQuery(allocator, .{ .ignore_symlinks = true });
    defer no_symlink_query.deinit();
    var no_symlink = try build(allocator, &no_symlink_query, .{});
    defer no_symlink.deinit();
    try std.testing.expect(!hasArg(no_symlink.args, "--follow"));

    var no_follow_query = try makeQuery(allocator, .{
        .settings = .{ .follow_symlinks = false },
    });
    defer no_follow_query.deinit();
    var no_follow = try build(allocator, &no_follow_query, .{});
    defer no_follow.deinit();
    try std.testing.expect(!hasArg(no_follow.args, "--follow"));
}

test "buildArgs: threads and exists" {
    const allocator = std.testing.allocator;
    var query = try makeQuery(allocator, .{});
    defer query.deinit();
    var args = try build(allocator, &query, .{ .threads = 4, .exists = true });
    defer args.deinit();

    var index: usize = 0;
    var found = false;
    while (index + 1 < args.args.len) : (index += 1) {
        if (std.mem.eql(u8, args.args[index], "--threads")) {
            try std.testing.expectEqualStrings("4", args.args[index + 1]);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(hasArg(args.args, "--quiet"));
}

test "buildArgs: exception runs ignore includes and excludes" {
    const allocator = std.testing.allocator;
    var query = try makeQuery(allocator, .{ .include_pattern = "src/**" });
    defer query.deinit();
    const excludes = [_]glob.ExcludeEntry{.{ .pattern = "examples" }};
    var args = try build(allocator, &query, .{
        .exclude = &excludes,
        .exclude_exceptions = &.{"node_modules/@types"},
    });
    defer args.deinit();

    try std.testing.expect(hasArg(args.args, "--no-ignore"));
    try std.testing.expect(globIndex(args.args, "/src/**") == null);
    try std.testing.expect(globIndex(args.args, "!/repo/examples") == null);
    try std.testing.expect(globIndex(args.args, "!*") != null);
    try std.testing.expect(globIndex(args.args, "/node_modules/") != null);
    try std.testing.expect(globIndex(args.args, "/node_modules/@types") != null);
}

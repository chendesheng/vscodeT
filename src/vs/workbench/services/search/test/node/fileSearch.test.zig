// Port of `src/vs/workbench/services/search/test/node/fileSearch.integrationTest.ts`
// and the walker cancellation cases from `fileSearch.test.ts`.
//
// The tests use the pinned VS Code checkout's search fixtures. They skip when
// the `vscode/` submodule is absent or `rg` is not installed; CI installs
// ripgrep on every platform.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const search = @import("../../common/search.zig");
const glob = @import("../../../../../base/common/glob.zig");
const file_search = @import("../../node/fileSearch.zig");
const FileWalker = file_search.FileWalker;
const WalkOutcome = file_search.WalkOutcome;
const time_compat = @import("../../../../../base/common/timeCompat.zig");

const fixtures_path = "vscode/src/vs/workbench/services/search/test/node/fixtures";
const fixtures2_path = "vscode/src/vs/workbench/services/search/test/node/fixtures2";

fn rgAvailable(allocator: Allocator) bool {
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "rg", "--version" },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn requireFixtures(allocator: Allocator) !struct { fixtures: []u8, fixtures2: []u8 } {
    if (!rgAvailable(allocator)) return error.SkipZigTest;
    const fixtures = realPathAlloc(allocator, std.testing.io, fixtures_path) catch return error.SkipZigTest;
    errdefer allocator.free(fixtures);
    const fixtures2 = realPathAlloc(allocator, std.testing.io, fixtures2_path) catch return error.SkipZigTest;
    return .{ .fixtures = fixtures, .fixtures2 = fixtures2 };
}

fn realPathAlloc(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    const resolved = try Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}

fn runWalk(
    allocator: Allocator,
    folders: []const search.FolderInfo,
    options: search.FileQueryOptions,
) !WalkOutcome {
    var query = try search.FileQuery.init(allocator, folders, options);
    defer query.deinit();
    var walker = try FileWalker.init(allocator, std.testing.io, &query, "rg");
    defer walker.deinit();
    return walker.walk();
}

fn normalizedPath(allocator: Allocator, path: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, path);
    for (copy) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return copy;
}

fn lastSeparator(path: []const u8) usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\') orelse 0;
    return @max(slash, backslash);
}

fn expectPath(actual: []const u8, expected: []const u8) !void {
    if (actual.len != expected.len) return error.TestExpectedEqual;
    for (actual, expected) |left, right| {
        const normalized = if (left == '\\') '/' else left;
        if (normalized != right) return error.TestExpectedEqual;
    }
}

fn relativePaths(allocator: Allocator, outcome: *const WalkOutcome) ![][]u8 {
    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }
    for (outcome.matches) |match| {
        try paths.append(try normalizedPath(allocator, match.relative_path));
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return paths.toOwnedSlice();
}

fn freePaths(allocator: Allocator, paths: [][]u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

fn writeFile(tmp: *std.testing.TmpDir, io: Io, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try tmp.dir.createDirPath(io, directory);
    var file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn writeScript(tmp: *std.testing.TmpDir, io: Io, allocator: Allocator, path: []const u8, contents: []const u8) ![]u8 {
    var file = try tmp.dir.createFile(io, path, .{});
    try file.writeStreamingAll(io, contents);
    try file.setPermissions(io, .executable_file);
    file.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..length], path });
}

/// Waits until `path` exists. Cancellation tests use this to cancel a child
/// that has actually started, instead of racing process startup.
fn waitForPath(io: Io, path: []const u8, timeout_ms: i64) !void {
    const deadline = time_compat.milliTimestamp() + timeout_ms;
    while (true) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (time_compat.milliTimestamp() >= deadline) return error.Timeout;
                time_compat.sleepMillis(5);
                continue;
            },
            else => return err,
        };
        return;
    }
}

test "FileSearch: simple" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);

    var outcome = try runWalk(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{});
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 14), outcome.matches.len);
}

test "FileSearch: file pattern" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);

    var outcome = try runWalk(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{
        .file_pattern = "anotherfile",
    });
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), outcome.matches.len);
    try expectPath(outcome.matches[0].relative_path, "examples/subfolder/anotherfolder/anotherfile.txt");
}

test "FileSearch: exclude" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);

    const excludes = [_]glob.ExcludeEntry{.{ .pattern = "**/anotherfolder/**" }};
    var outcome = try runWalk(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{
        .file_pattern = "file",
        .exclude_entries = &excludes,
    });
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 2), outcome.matches.len);
}

test "FileSearch: multiroot and folder name scoring" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);
    const examples = try std.fs.path.join(allocator, &.{ fixtures.fixtures, "examples" });
    defer allocator.free(examples);
    const more = try std.fs.path.join(allocator, &.{ fixtures.fixtures, "more" });
    defer allocator.free(more);

    const folders = [_]search.FolderInfo{
        .{ .resource = examples, .name = "examples_folder" },
        .{ .resource = more, .name = "more" },
    };
    const excludes = [_]glob.ExcludeEntry{.{ .pattern = "**/anotherfolder/**" }};
    var multiroot = try runWalk(allocator, &folders, .{
        .file_pattern = "file",
        .exclude_entries = &excludes,
    });
    defer multiroot.deinit();
    try std.testing.expectEqual(@as(usize, 2), multiroot.matches.len);

    var named = try runWalk(allocator, &folders, .{
        .file_pattern = "examples_folder anotherfile",
    });
    defer named.deinit();
    try std.testing.expectEqual(@as(usize, 1), named.matches.len);
    try expectPath(named.matches[0].relative_path, "subfolder/anotherfolder/anotherfile.txt");
}

test "FileSearch: sibling exclude clause" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);

    const folders = [_]search.FolderInfo{
        .{ .resource = fixtures.fixtures, .name = "folder1" },
        .{ .resource = fixtures.fixtures2, .name = "fixtures2" },
    };
    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "*.css", .when = "$(basename).less" },
    };
    var outcome = try runWalk(allocator, &folders, .{
        .file_pattern = "folder1 site",
        .exclude_entries = &excludes,
    });
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), outcome.matches.len);
    try expectPath(outcome.matches[0].relative_path, "site.less");
}

test "FileSearch: exclude exception re-includes a folder below an excluded folder" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);

    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "examples" },
        .{ .pattern = "!examples/subfolder/anotherfolder" },
    };
    var outcome = try runWalk(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{
        .exclude_entries = &excludes,
    });
    defer outcome.deinit();

    const paths = try relativePaths(allocator, &outcome);
    defer freePaths(allocator, paths);
    try std.testing.expectEqual(@as(usize, 9), paths.len);
    var found = false;
    for (paths) |path| {
        if (std.mem.startsWith(u8, path, "examples/")) {
            try expectPath(path, "examples/subfolder/anotherfolder/anotherfile.txt");
            found = true;
        }
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 1), outcome.stats.exclude_exception_runs);
}

test "FileSearch: exclude exception re-includes a gitignored file" {
    const allocator = std.testing.allocator;
    if (!rgAvailable(allocator)) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(&tmp, io, ".gitignore", "build/\n");
    try writeFile(&tmp, io, "build/keep.txt", "");
    try writeFile(&tmp, io, "build/drop.txt", "");
    try writeFile(&tmp, io, "node_modules/@types/node/index.d.ts", "");
    try writeFile(&tmp, io, "node_modules/react/index.js", "");
    try writeFile(&tmp, io, "index.js", "");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "node_modules" },
        .{ .pattern = "!node_modules/@types" },
        .{ .pattern = "!build/keep.txt" },
    };
    var outcome = try runWalk(allocator, &.{.{ .resource = root, .name = "root" }}, .{
        .exclude_entries = &excludes,
    });
    defer outcome.deinit();
    const paths = try relativePaths(allocator, &outcome);
    defer freePaths(allocator, paths);
    try std.testing.expectEqual(@as(usize, 4), paths.len);
    try std.testing.expectEqualStrings(".gitignore", paths[0]);
    try std.testing.expectEqualStrings("build/keep.txt", paths[1]);
    try std.testing.expectEqualStrings("index.js", paths[2]);
    try std.testing.expectEqualStrings("node_modules/@types/node/index.d.ts", paths[3]);

    const unanchored = [_]glob.ExcludeEntry{
        .{ .pattern = "node_modules" },
        .{ .pattern = "!**/keep.txt" },
        .{ .pattern = "!**/@types" },
    };
    var unanchored_outcome = try runWalk(allocator, &.{.{ .resource = root, .name = "root" }}, .{
        .exclude_entries = &unanchored,
    });
    defer unanchored_outcome.deinit();
    const unanchored_paths = try relativePaths(allocator, &unanchored_outcome);
    defer freePaths(allocator, unanchored_paths);
    try std.testing.expectEqual(@as(usize, 4), unanchored_paths.len);
}

test "FileSearch: exclude exception respects folder includes and nested roots" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);
    const examples = try std.fs.path.join(allocator, &.{ fixtures.fixtures, "examples" });
    defer allocator.free(examples);

    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "examples" },
        .{ .pattern = "!examples/subfolder/anotherfolder" },
    };
    var query = try search.FileQuery.init(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{
        .exclude_entries = &excludes,
    });
    defer query.deinit();
    query.folder_queries[0].include_pattern = "more/**";
    var walker = try FileWalker.init(allocator, std.testing.io, &query, "rg");
    defer walker.deinit();
    var include_outcome = try walker.walk();
    defer include_outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), include_outcome.matches.len);
    try expectPath(include_outcome.matches[0].relative_path, "more/file.txt");

    const nested_excludes = [_]glob.ExcludeEntry{.{ .pattern = "!**/small.js" }};
    const folders = [_]search.FolderInfo{
        .{ .resource = fixtures.fixtures, .name = "fixtures" },
        .{ .resource = examples, .name = "examples" },
    };
    var nested = try runWalk(allocator, &folders, .{
        .file_pattern = "small",
        .exclude_entries = &nested_excludes,
    });
    defer nested.deinit();
    try std.testing.expectEqual(@as(usize, 1), nested.matches.len);
    try std.testing.expectEqualStrings("examples", nested.matches[0].base[lastSeparator(nested.matches[0].base) + 1 ..]);
    try expectPath(nested.matches[0].relative_path, "small.js");
}

test "FileSearch: exists only counts exceptions that pass includes" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);

    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "examples" },
        .{ .pattern = "!examples/small.js" },
    };

    var missing_query = try search.FileQuery.init(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{
        .exclude_entries = &excludes,
        .exists = true,
    });
    defer missing_query.deinit();
    missing_query.folder_queries[0].include_pattern = "nonexistent/**";
    var missing_walker = try FileWalker.init(allocator, std.testing.io, &missing_query, "rg");
    defer missing_walker.deinit();
    var missing = try missing_walker.walk();
    defer missing.deinit();
    try std.testing.expect(!missing.limit_hit);

    var examples_query = try search.FileQuery.init(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{
        .exclude_entries = &excludes,
        .exists = true,
    });
    defer examples_query.deinit();
    examples_query.folder_queries[0].include_pattern = "examples/**";
    var examples_walker = try FileWalker.init(allocator, std.testing.io, &examples_query, "rg");
    defer examples_walker.deinit();
    var examples_outcome = try examples_walker.walk();
    defer examples_outcome.deinit();
    try std.testing.expect(examples_outcome.limit_hit);
}

test "FileSearch: exclude exceptions keep the on-disk casing" {
    const allocator = std.testing.allocator;
    const fixtures = try requireFixtures(allocator);
    defer allocator.free(fixtures.fixtures);
    defer allocator.free(fixtures.fixtures2);

    const excludes = [_]glob.ExcludeEntry{.{ .pattern = "!EXAMPLES/small.js" }};
    var outcome = try runWalk(allocator, &.{.{ .resource = fixtures.fixtures, .name = "fixtures" }}, .{
        .file_pattern = "small",
        .ignore_glob_case = true,
        .exclude_entries = &excludes,
    });
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 1), outcome.matches.len);
    try expectPath(outcome.matches[0].relative_path, "examples/small.js");
}

test "FileSearch: exception with a parent segment does not search outside the folder" {
    const allocator = std.testing.allocator;
    if (!rgAvailable(allocator)) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(&tmp, io, "folder/a.txt", "");
    try writeFile(&tmp, io, "secret.txt", "");
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const folder_path = try std.fs.path.join(allocator, &.{ root_buffer[0..root_len], "folder" });
    defer allocator.free(folder_path);

    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "*.txt" },
        .{ .pattern = "!../secret.txt" },
    };
    var outcome = try runWalk(allocator, &.{.{ .resource = folder_path, .name = "folder" }}, .{
        .exclude_entries = &excludes,
    });
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 0), outcome.matches.len);
}

test "FileSearch: ignored symlinks are not followed by exception runs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    if (!rgAvailable(allocator)) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(&tmp, io, "target/file.txt", "");
    try tmp.dir.symLink(io, "target", "link", .{ .is_directory = true });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    const excludes = [_]glob.ExcludeEntry{
        .{ .pattern = "target" },
        .{ .pattern = "!link" },
    };
    var outcome = try runWalk(allocator, &.{.{ .resource = root, .name = "root" }}, .{
        .ignore_symlinks = true,
        .exclude_entries = &excludes,
    });
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 0), outcome.matches.len);
}

test "FileSearch: parser handles chunk boundaries and a trailing newline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try writeScript(&tmp, io, allocator, "fake-rg.sh",
        \\#!/bin/sh
        \\printf 'alpha.tx'
        \\sleep 0.05
        \\printf 't\nbeta.txt\n'
        \\printf ''
    );
    defer allocator.free(script);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var query = try search.FileQuery.init(allocator, &.{.{ .resource = root, .name = "root" }}, .{});
    defer query.deinit();
    var walker = try FileWalker.init(allocator, io, &query, script);
    defer walker.deinit();
    var outcome = try walker.walk();
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 2), outcome.matches.len);
    try expectPath(outcome.matches[0].relative_path, "alpha.txt");
    try expectPath(outcome.matches[1].relative_path, "beta.txt");
}

test "FileSearch: empty output completes with an empty result" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try writeScript(&tmp, io, allocator, "empty-rg.sh",
        \\#!/bin/sh
        \\exit 1
    );
    defer allocator.free(script);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var query = try search.FileQuery.init(allocator, &.{.{ .resource = root, .name = "root" }}, .{});
    defer query.deinit();
    var walker = try FileWalker.init(allocator, io, &query, script);
    defer walker.deinit();
    var outcome = try walker.walk();
    defer outcome.deinit();
    try std.testing.expectEqual(@as(usize, 0), outcome.matches.len);
    try std.testing.expectEqual(@as(usize, 0), outcome.errors.len);
}

test "FileSearch: cancellation kills a sleeping rg and returns quickly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const ready = try std.fs.path.join(allocator, &.{ root, "ready.txt" });
    defer allocator.free(ready);
    const contents = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\sleep 5 &
        \\echo "$!" > "{s}"
        \\wait "$!"
        \\printf 'late.txt\n'
    , .{ready});
    defer allocator.free(contents);
    const script = try writeScript(&tmp, io, allocator, "sleep-rg.sh", contents);
    defer allocator.free(script);

    var query = try search.FileQuery.init(allocator, &.{.{ .resource = root, .name = "root" }}, .{});
    defer query.deinit();
    var walker = try FileWalker.init(allocator, io, &query, script);
    defer walker.deinit();

    const ThreadContext = struct {
        walker: *FileWalker,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            if (self.walker.walk()) |outcome| {
                var owned = outcome;
                owned.deinit();
            } else |err| {
                self.result = err;
            }
        }
    };
    var context = ThreadContext{ .walker = &walker };
    const thread = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    // Wait for the wrapper's sleep child: it holds the stdout pipe open, so
    // cancellation must kill the whole process group to return promptly.
    try waitForPath(io, ready, 3000);
    const started = time_compat.milliTimestamp();
    walker.cancel();
    thread.join();
    const elapsed = time_compat.milliTimestamp() - started;

    try std.testing.expect(elapsed < 1000);
    try std.testing.expect(context.result != null);
    try std.testing.expectEqual(error.Canceled, context.result.?);
}

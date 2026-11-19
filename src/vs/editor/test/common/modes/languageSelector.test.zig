// Port of `src/vs/editor/test/common/modes/languageSelector.test.ts`.

const std = @import("std");
const selector = @import("../../../common/languageSelector.zig");
const Selector = selector.Selector;
const Candidate = selector.Candidate;
const score = selector.score;
const compileSelector = selector.compileSelector;
const selectLanguageIds = selector.selectLanguageIds;

test "languageSelector: invalid selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidate = Candidate{ .scheme = "file", .fs_path = "/testbed/file.fb", .language = "farboo", .synchronized = true };
    const empty_filter = Selector{ .filter = .{} };
    try std.testing.expectEqual(@as(i32, 0), try score(arena.allocator(), empty_filter, candidate));
    const empty_language = Selector{ .language = "" };
    try std.testing.expectEqual(@as(i32, 0), try score(arena.allocator(), empty_language, candidate));
}

test "languageSelector: any language and default schemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file_candidate = Candidate{ .scheme = "file", .fs_path = "/testbed/file.fb", .language = "farboo", .synchronized = true };

    try std.testing.expectEqual(@as(i32, 5), try score(a, .{ .filter = .{ .language = "*" } }, file_candidate));
    try std.testing.expectEqual(@as(i32, 5), try score(a, .{ .language = "*" }, file_candidate));
    var git_candidate = file_candidate;
    git_candidate.scheme = "git";
    git_candidate.fs_path = "/foo/file.txt";
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .language = "farboo" }, git_candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .language = "farboo", .scheme = "" } }, git_candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .language = "farboo", .scheme = "git" } }, git_candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .language = "farboo", .scheme = "*" } }, git_candidate));
    try std.testing.expectEqual(@as(i32, 5), try score(a, .{ .filter = .{ .language = "*" } }, git_candidate));
    try std.testing.expectEqual(@as(i32, 5), try score(a, .{ .filter = .{ .scheme = "*" } }, git_candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .scheme = "git" } }, git_candidate));
}

test "languageSelector: filters and patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const candidate = Candidate{ .scheme = "file", .fs_path = "/testbed/file.fb", .language = "farboo", .synchronized = true };

    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .language = "farboo" } }, candidate));
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .filter = .{ .language = "farboo", .scheme = "http" } }, candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .pattern = .{ .string = "**/*.fb" } } }, candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .pattern = .{ .string = "**/*.fb" }, .scheme = "file" } }, candidate));

    var foo_candidate = candidate;
    foo_candidate.scheme = "foo";
    foo_candidate.fs_path = "bar";
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .filter = .{ .pattern = .{ .string = "**/*.fb" } } }, foo_candidate));
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .filter = .{ .pattern = .{ .string = "**/*.fb" }, .scheme = "foo" } }, foo_candidate));

    var js_candidate = candidate;
    js_candidate.scheme = "git";
    js_candidate.fs_path = "/my/file.js";
    js_candidate.language = "javascript";
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .language = "javascript", .scheme = "git" } }, js_candidate));
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .language = "fooLang" }, js_candidate));
    try std.testing.expectEqual(@as(i32, 5), try score(a, .{ .list = &.{
        .{ .language = "fooLang" },
        .{ .language = "*" },
    } }, js_candidate));
}

test "languageSelector: max filters and hasAccessToAllModels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const candidate = Candidate{ .scheme = "file", .fs_path = "/testbed/file.fb", .language = "farboo", .synchronized = true };
    const match = Selector{ .filter = .{ .language = "farboo", .scheme = "file" } };
    const fail = Selector{ .filter = .{ .language = "farboo", .scheme = "http" } };
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .list = &.{ match, fail } }, candidate));
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .list = &.{ fail, fail } }, candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .list = &.{ .{ .language = "farboo" }, .{ .language = "*" } } }, candidate));

    var unsync = candidate;
    unsync.synchronized = false;
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .language = "farboo" }, unsync));
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .filter = .{ .language = "farboo", .scheme = "file" } }, unsync));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{
        .language = "farboo",
        .scheme = "file",
        .has_access_to_all_models = true,
    } }, unsync));
}

test "languageSelector: notebookType" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const candidate = Candidate{
        .scheme = "vscode-notebook-cell",
        .fs_path = "/my/file.js",
        .language = "javascript",
        .synchronized = true,
        .notebook_scheme = "file",
        .notebook_fs_path = "/my/file.js",
        .notebook_type = "fooBook",
    };
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .notebook_type = "fooBook" } }, candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{
        .notebook_type = "fooBook",
        .language = "javascript",
        .scheme = "file",
    } }, candidate));
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{ .notebook_type = "fooBook", .language = "*" } }, candidate));
    try std.testing.expectEqual(@as(i32, 5), try score(a, .{ .filter = .{ .notebook_type = "*", .language = "*" } }, candidate));

    var no_notebook = candidate;
    no_notebook.notebook_type = null;
    no_notebook.notebook_fs_path = null;
    no_notebook.notebook_scheme = null;
    try std.testing.expectEqual(@as(i32, 0), try score(a, .{ .filter = .{ .notebook_type = "fooBook" } }, no_notebook));
}

test "languageSelector: platform paths and relative patterns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const candidate = Candidate{ .scheme = "file", .fs_path = "/C:/Users/zlhe/Desktop/test.interface.json", .language = "json", .synchronized = true };
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{
        .language = "json",
        .scheme = "file",
        .pattern = .{ .string = "**/*.interface.json" },
    } }, candidate));

    const unix_candidate = Candidate{ .scheme = "file", .fs_path = "/home/user/Desktop/test.json", .language = "json", .synchronized = true };
    try std.testing.expectEqual(@as(i32, 10), try score(a, .{ .filter = .{
        .pattern = .{ .relative = .{ .base = "/home/user/Desktop", .pattern = "*.json" } },
    } }, unix_candidate));
}

test "languageSelector: selectLanguageIds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var result = std.StringHashMap(void).init(a);
    try selectLanguageIds(try compileSelector(a, .{ .language = "typescript" }), &result);
    try selectLanguageIds(try compileSelector(a, .{ .filter = .{ .language = "python", .scheme = "file" } }), &result);
    try selectLanguageIds(try compileSelector(a, .{ .filter = .{ .scheme = "file" } }), &result);
    try selectLanguageIds(try compileSelector(a, .{ .list = &.{
        .{ .language = "javascript" },
        .{ .filter = .{ .language = "css" } },
        .{ .filter = .{ .scheme = "untitled" } },
    } }), &result);
    try std.testing.expect(result.contains("typescript"));
    try std.testing.expect(result.contains("python"));
    try std.testing.expect(result.contains("javascript"));
    try std.testing.expect(result.contains("css"));
    try std.testing.expect(!result.contains("file"));
}

// Port of the shorten suites in src/vs/base/test/common/labels.test.ts.
const std = @import("std");
const labels = @import("../../common/labels.zig");

fn check(sep: u8, paths: []const ?[]const u8, expected: []const ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try labels.shorten(arena.allocator(), paths, sep);
    try std.testing.expectEqual(expected.len, result.len);
    for (expected, result) |want, got| {
        if (want) |label| try std.testing.expectEqualStrings(label, got orelse return error.MissingLabel) else try std.testing.expect(got == null);
    }
}

test "shorten - windows" {
    try check('\\', &.{"a"}, &.{"a"});
    try check('\\', &.{ "a", "b" }, &.{ "a", "b" });
    try check('\\', &.{ "a", "b", "c" }, &.{ "a", "b", "c" });
    try check('\\', &.{ "\\\\x\\a", "\\\\x\\a" }, &.{ "\\\\x\\a", "\\\\x\\a" });
    try check('\\', &.{ "C:\\a", "C:\\b" }, &.{ "C:\\a", "C:\\b" });
    try check('\\', &.{ "a\\b", "c\\d", "e\\f" }, &.{ "…\\b", "…\\d", "…\\f" });
    try check('\\', &.{ "a", "a\\b" }, &.{ "a", "…\\b" });
    try check('\\', &.{ "a\\b", "a\\b\\c" }, &.{ "…\\b", "…\\c" });
    try check('\\', &.{ "a", "a\\b", "a\\b\\c" }, &.{ "a", "…\\b", "…\\c" });
    try check('\\', &.{ "x:\\a\\b", "x:\\a\\c" }, &.{ "x:\\…\\b", "x:\\…\\c" });
    try check('\\', &.{ "\\\\a\\b", "\\\\a\\c" }, &.{ "\\\\a\\b", "\\\\a\\c" });
    try check('\\', &.{ "a", "b\\a" }, &.{ "a", "b\\…" });
    try check('\\', &.{ "a\\b\\c", "d\\b\\c" }, &.{ "a\\…", "d\\…" });
    try check('\\', &.{ "a\\b\\c\\d", "f\\b\\c\\d" }, &.{ "a\\…", "f\\…" });
    try check('\\', &.{ "d\\e\\a\\b\\c", "d\\b\\c" }, &.{ "…\\a\\…", "d\\b\\…" });
    try check('\\', &.{ "a\\b\\c\\d", "a\\f\\b\\c\\d" }, &.{ "a\\b\\…", "…\\f\\…" });
    try check('\\', &.{ "a\\b\\a", "b\\b\\a" }, &.{ "a\\b\\…", "b\\b\\…" });
    try check('\\', &.{ "d\\f\\a\\b\\c", "h\\d\\b\\c" }, &.{ "…\\a\\…", "h\\…" });
    try check('\\', &.{ "a\\b\\c", "x:\\0\\a\\b\\c" }, &.{ "a\\b\\c", "x:\\0\\…" });
    try check('\\', &.{ "x:\\a\\b\\c", "x:\\0\\a\\b\\c" }, &.{ "x:\\a\\…", "x:\\0\\…" });
    try check('\\', &.{ "x:\\a\\b", "y:\\a\\b" }, &.{ "x:\\…", "y:\\…" });
    try check('\\', &.{ "x:\\a", "x:\\c" }, &.{ "x:\\a", "x:\\c" });
    try check('\\', &.{ "x:\\a\\b", "y:\\x\\a\\b" }, &.{ "x:\\…", "y:\\…" });
    try check('\\', &.{ "\\\\x\\b", "\\\\y\\b" }, &.{ "\\\\x\\…", "\\\\y\\…" });
    try check('\\', &.{ "\\\\x\\a", "\\\\x\\b" }, &.{ "\\\\x\\a", "\\\\x\\b" });
    try check('\\', &.{ "a\\b", "a\\c", "a\\e-b" }, &.{ "…\\b", "…\\c", "…\\e-b" });
    try check('\\', &.{ "a\\b\\c", "d\\b\\e" }, &.{ "…\\c", "…\\e" });
    try check('\\', &.{ "a\\b\\c", "d\\b\\C" }, &.{ "…\\c", "…\\C" });
    try check('\\', &.{ "", null }, &.{ ".\\", null });
    try check('\\', &.{ "a", "a\\b", "a\\b\\c", "d\\b\\c", "d\\b" }, &.{ "a", "a\\b", "a\\b\\c", "d\\b\\c", "d\\b" });
    try check('\\', &.{ "a", "a\\b", "b" }, &.{ "a", "a\\b", "b" });
    try check('\\', &.{ "", "a", "b", "b\\c", "a\\c" }, &.{ ".\\", "a", "b", "b\\c", "a\\c" });
    try check('\\', &.{ "src\\vs\\workbench\\parts\\execution\\electron-browser", "src\\vs\\workbench\\parts\\execution\\electron-browser\\something", "src\\vs\\workbench\\parts\\terminal\\electron-browser" }, &.{ "…\\execution\\electron-browser", "…\\something", "…\\terminal\\…" });
    try check('\\', &.{ "https://a.com/b", "C:\\foo\\d" }, &.{ "https://a.com/b", "C:\\…\\d" });
    try check('\\', &.{ "https://a.com/x", "C:\\foo\\x" }, &.{ "https://a.com/…", "C:\\foo\\…" });
    try check('\\', &.{ "https://a.com/y/z", "C:\\foo\\bar\\z" }, &.{ "https://a.com/y/…", "C:\\…\\bar\\…" });
    try check('\\', &.{ "file://C:/foo/bar/z", "C:\\foo\\bar\\z" }, &.{ "file://C:/…/bar/z", "C:\\…\\bar\\z" });
}

test "shorten - not windows" {
    try check('/', &.{"a"}, &.{"a"});
    try check('/', &.{ "a", "b" }, &.{ "a", "b" });
    try check('/', &.{ "/a", "/b" }, &.{ "/a", "/b" });
    try check('/', &.{ "~/a/b/c", "~/a/b/c" }, &.{ "~/a/b/c", "~/a/b/c" });
    try check('/', &.{ "a", "b", "c" }, &.{ "a", "b", "c" });
    try check('/', &.{ "a/b", "c/d", "e/f" }, &.{ "…/b", "…/d", "…/f" });
    try check('/', &.{ "a", "a/b" }, &.{ "a", "…/b" });
    try check('/', &.{ "a/b", "a/b/c" }, &.{ "…/b", "…/c" });
    try check('/', &.{ "a", "a/b", "a/b/c" }, &.{ "a", "…/b", "…/c" });
    try check('/', &.{ "/a/b", "/a/c" }, &.{ "/a/b", "/a/c" });
    try check('/', &.{ "a", "b/a" }, &.{ "a", "b/…" });
    try check('/', &.{ "a/b/c", "d/b/c" }, &.{ "a/…", "d/…" });
    try check('/', &.{ "a/b/c/d", "f/b/c/d" }, &.{ "a/…", "f/…" });
    try check('/', &.{ "d/e/a/b/c", "d/b/c" }, &.{ "…/a/…", "d/b/…" });
    try check('/', &.{ "a/b/c/d", "a/f/b/c/d" }, &.{ "a/b/…", "…/f/…" });
    try check('/', &.{ "a/b/a", "b/b/a" }, &.{ "a/b/…", "b/b/…" });
    try check('/', &.{ "d/f/a/b/c", "h/d/b/c" }, &.{ "…/a/…", "h/…" });
    try check('/', &.{ "/x/b", "/y/b" }, &.{ "/x/…", "/y/…" });
    try check('/', &.{ "a/b", "a/c", "a/e-b" }, &.{ "…/b", "…/c", "…/e-b" });
    try check('/', &.{ "a/b/c", "d/b/e" }, &.{ "…/c", "…/e" });
    try check('/', &.{ "a/b/c", "d/b/C" }, &.{ "…/c", "…/C" });
    try check('/', &.{ "", null }, &.{ "./", null });
    try check('/', &.{ "a", "a/b", "a/b/c", "d/b/c", "d/b" }, &.{ "a", "a/b", "a/b/c", "d/b/c", "d/b" });
    try check('/', &.{ "a", "a/b", "b" }, &.{ "a", "a/b", "b" });
    try check('/', &.{ "", "a", "b", "b/c", "a/c" }, &.{ "./", "a", "b", "b/c", "a/c" });
    try check('/', &.{"https://a.com/b"}, &.{"https://a.com/b"});
    try check('/', &.{ "https://a.com/", "https://b.com/" }, &.{ "https://a.com/", "https://b.com/" });
    try check('/', &.{ "https://a.com/b", "https://a.com/c" }, &.{ "https://a.com/b", "https://a.com/c" });
    try check('/', &.{ "https://a.com/x/y", "https://b.com/x/y" }, &.{ "https://a.com/…", "https://b.com/…" });
    try check('/', &.{ "https://a.com/b", "https://a.com/b/c" }, &.{ "https://a.com/b", "https://a.com/…/c" });
    try check('/', &.{ "https://a.com/b", "http://a.com/b" }, &.{ "https://a.com/b", "http://a.com/b" });
    try check('/', &.{ "https://a.com/x/y/z", "https://a.com/x/w/z" }, &.{ "https://a.com/…/y/…", "https://a.com/…/w/…" });
    try check('/', &.{ "https://a.com/b", "/c/d" }, &.{ "https://a.com/b", "/c/d" });
    try check('/', &.{ "https://a.com/x", "/c/x" }, &.{ "https://a.com/…", "/c/x" });
    try check('/', &.{ "https://a.com/x/y", "/c/x/y" }, &.{ "https://a.com/…", "/c/x/…" });
    try check('/', &.{ "file:///foo/bar/z", "/foo/bar/z" }, &.{ "file:///foo/bar/z", "/foo/bar/z" });
}

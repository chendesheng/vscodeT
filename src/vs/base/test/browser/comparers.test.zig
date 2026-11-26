// Terminal-adapted subset of `src/vs/base/test/browser/comparers.test.ts`.
//
// The browser suite relies on `Intl.Collator` locale rules (punctuation and
// case-group ordering); the terminal `compareFileNames` is a case-insensitive
// natural/unicode approximation documented in `comparers.zig`. This file keeps
// the language-independent assertions: equality, null (empty) ordering and
// numeric-run ordering/disambiguation.
const std = @import("std");
const comparers = @import("../../common/comparers.zig");

test "compareFileNames numeric and equality rules" {
    try std.testing.expectEqual(@as(i32, 0), comparers.compareFileNames("", ""));
    try std.testing.expect(comparers.compareFileNames("", "abc") < 0);
    try std.testing.expectEqual(@as(i32, 0), comparers.compareFileNames("abc", "abc"));
    try std.testing.expect(comparers.compareFileNames("abc1.txt", "abc2.txt") < 0);
    try std.testing.expect(comparers.compareFileNames("abc2.txt", "abc10.txt") < 0);
    try std.testing.expect(comparers.compareFileNames("abc02.txt", "abc010.txt") < 0);
    try std.testing.expect(comparers.compareFileNames("abc1.10.txt", "abc1.2.txt") > 0);
    try std.testing.expect(comparers.compareFileNames("abc02.txt", "abc002.txt") > 0);
    try std.testing.expect(comparers.compareFileNames("abc.txt1", "abc.txt01") > 0);

    var names = [_][]const u8{ "a10.txt", "A2.txt", "A100.txt", "a20.txt" };
    std.mem.sort([]const u8, &names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return comparers.compareFileNames(a, b) < 0;
        }
    }.lessThan);
    try std.testing.expectEqualSlices([]const u8, &.{ "A2.txt", "a10.txt", "a20.txt", "A100.txt" }, &names);
}

test "compareFileExtensions orders by extension then name" {
    try std.testing.expectEqual(@as(i32, 0), comparers.compareFileExtensions("file.txt", "file.txt"));
    try std.testing.expect(comparers.compareFileExtensions("a.ext1", "b.Ext1") < 0);
    try std.testing.expect(comparers.compareFileExtensions("a.txt", "a.zig") < 0);
    try std.testing.expect(comparers.compareFileExtensions("a2.txt", "a10.txt") < 0);
    try std.testing.expect(comparers.compareFileExtensions("file1.txt", "file01.txt") > 0);
}

test "comparePaths orders folders lexically and final filenames naturally" {
    try std.testing.expectEqual(@as(i32, 0), comparers.comparePaths("a/b", "a/b"));
    try std.testing.expect(comparers.comparePaths("a/b", "a/c") < 0);
    // comparePathComponents is lexical; only the last component uses
    // compareFileNames and its numeric collation (upstream comparePaths).
    try std.testing.expect(comparers.comparePaths("a2/b", "a10/b") > 0);
    try std.testing.expect(comparers.comparePaths("a/b2", "a/b10") < 0);
    try std.testing.expect(comparers.comparePaths("a/z", "a/a/child") < 0);
    try std.testing.expect(comparers.comparePaths("a/b/c", "a/b") > 0);
    try std.testing.expect(comparers.comparePaths("a", "b/c") < 0);
}

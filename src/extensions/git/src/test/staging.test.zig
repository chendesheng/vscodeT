// Tests for `vscode/extensions/git/src/staging.ts`, including its EOF newline
// correction for issue #59670.
const std = @import("std");
const staging = @import("../staging.zig");
const TestModel = @import("../../../../vs/editor/test/common/port/testSupport.zig").TestModel;

fn check(original: []const u8, modified: []const u8, changes: []const staging.LineChange, expected: []const u8) !void {
    const a = std.testing.allocator;
    var left = try TestModel.init(a, original, "plaintext");
    defer left.deinit();
    var right = try TestModel.init(a, modified, "plaintext");
    defer right.deinit();
    const actual = try staging.applyLineChanges(a, left.model, right.model, changes);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "Git staging: selected line changes leave the remaining source unchanged" {
    const first: staging.LineChange = .{ .originalStartLineNumber = 2, .originalEndLineNumber = 2, .modifiedStartLineNumber = 2, .modifiedEndLineNumber = 2 };
    const last: staging.LineChange = .{ .originalStartLineNumber = 4, .originalEndLineNumber = 4, .modifiedStartLineNumber = 4, .modifiedEndLineNumber = 4 };
    try check("one\ntwo\nthree\nfour\n", "one\nTWO\nthree\nFOUR\n", &.{first}, "one\nTWO\nthree\nfour\n");
    try check("one\ntwo\nthree\nfour\n", "one\nTWO\nthree\nFOUR\n", &.{last}, "one\ntwo\nthree\nFOUR\n");
    try check("one\r\ntwo\r\nthree\r\nfour\r\n", "one\r\nTWO\r\nthree\r\nFOUR\r\n", &.{ first, last }, "one\r\nTWO\r\nthree\r\nFOUR\r\n");
}

test "Git staging: insertion and deletion at the beginning and end preserve boundaries" {
    const append: staging.LineChange = .{ .originalStartLineNumber = 2, .originalEndLineNumber = 0, .modifiedStartLineNumber = 3, .modifiedEndLineNumber = 3 };
    try check("one\ntwo", "one\ntwo\nthree", &.{append}, "one\ntwo\nthree");
    try check("one\ntwo\nthree", "one\ntwo", &.{staging.invertLineChange(append)}, "one\ntwo");
    const prepend: staging.LineChange = .{ .originalStartLineNumber = 0, .originalEndLineNumber = 0, .modifiedStartLineNumber = 1, .modifiedEndLineNumber = 1 };
    try check("two\nthree", "one\ntwo\nthree", &.{prepend}, "one\ntwo\nthree");
    try check("one\ntwo\nthree", "two\nthree", &.{staging.invertLineChange(prepend)}, "two\nthree");
}

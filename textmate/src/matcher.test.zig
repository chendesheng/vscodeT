// Port of `../vscode-textmate/src/tests/matcher.test.ts` (v9.3.2).
const std = @import("std");
const matcher = @import("matcher.zig");

fn nameMatcher(identifiers: []const []const u8, stack: []const []const u8) bool {
    var last_index: usize = 0;
    for (identifiers) |identifier| {
        var found = false;
        var index = last_index;
        while (index < stack.len) : (index += 1) {
            if (std.mem.eql(u8, stack[index], identifier)) {
                last_index = index + 1;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "matcher: upstream cases" {
    const Case = struct {
        expression: []const u8,
        input: []const []const u8,
        result: bool,
    };
    const cases = [_]Case{
        .{ .expression = "foo", .input = &.{"foo"}, .result = true },
        .{ .expression = "foo", .input = &.{"bar"}, .result = false },
        .{ .expression = "- foo", .input = &.{"foo"}, .result = false },
        .{ .expression = "- foo", .input = &.{"bar"}, .result = true },
        .{ .expression = "- - foo", .input = &.{"bar"}, .result = false },
        .{ .expression = "bar foo", .input = &.{"foo"}, .result = false },
        .{ .expression = "bar foo", .input = &.{"bar"}, .result = false },
        .{ .expression = "bar foo", .input = &.{ "bar", "foo" }, .result = true },
        .{ .expression = "bar - foo", .input = &.{"bar"}, .result = true },
        .{ .expression = "bar - foo", .input = &.{ "foo", "bar" }, .result = false },
        .{ .expression = "bar - foo", .input = &.{"foo"}, .result = false },
        .{ .expression = "bar, foo", .input = &.{"foo"}, .result = true },
        .{ .expression = "bar, foo", .input = &.{"bar"}, .result = true },
        .{ .expression = "bar, foo", .input = &.{ "bar", "foo" }, .result = true },
        .{ .expression = "bar, -foo", .input = &.{ "bar", "foo" }, .result = true },
        .{ .expression = "bar, -foo", .input = &.{"yo"}, .result = true },
        .{ .expression = "bar, -foo", .input = &.{"foo"}, .result = false },
        .{ .expression = "(foo)", .input = &.{"foo"}, .result = true },
        .{ .expression = "(foo - bar)", .input = &.{"foo"}, .result = true },
        .{ .expression = "(foo - bar)", .input = &.{ "foo", "bar" }, .result = false },
        .{ .expression = "foo bar - (yo man)", .input = &.{ "foo", "bar" }, .result = true },
        .{ .expression = "foo bar - (yo man)", .input = &.{ "foo", "bar", "yo" }, .result = true },
        .{ .expression = "foo bar - (yo man)", .input = &.{ "foo", "bar", "yo", "man" }, .result = false },
        .{ .expression = "foo bar - (yo | man)", .input = &.{ "foo", "bar", "yo", "man" }, .result = false },
        .{ .expression = "foo bar - (yo | man)", .input = &.{ "foo", "bar", "yo" }, .result = false },
        .{ .expression = "R:text.html - (comment.block, text.html source)", .input = &.{ "text.html", "bar", "source" }, .result = false },
        .{ .expression = "text.html.php - (meta.embedded | meta.tag), L:text.html.php meta.tag, L:source.js.embedded.html", .input = &.{ "text.html.php", "bar", "source.js" }, .result = true },
    };

    for (cases) |case| {
        var matchers = try matcher.createMatchers([]const []const u8, std.testing.allocator, case.expression, nameMatcher);
        defer matchers.deinit();
        try std.testing.expectEqual(case.result, matchers.any(nameMatcher, case.input));
    }
}

test "matcher: priorities are preserved" {
    var matchers = try matcher.createMatchers([]const []const u8, std.testing.allocator, "R:foo, L:bar, baz", nameMatcher);
    defer matchers.deinit();

    try std.testing.expectEqual(@as(usize, 3), matchers.matchers.len);
    try std.testing.expectEqual(@as(i8, 1), matchers.matchers[0].priority);
    try std.testing.expectEqual(@as(i8, -1), matchers.matchers[1].priority);
    try std.testing.expectEqual(@as(i8, 0), matchers.matchers[2].priority);
}

test "matcher: empty selector has no matchers" {
    var matchers = try matcher.createMatchers([]const []const u8, std.testing.allocator, "", nameMatcher);
    defer matchers.deinit();
    try std.testing.expectEqual(@as(usize, 0), matchers.matchers.len);
}

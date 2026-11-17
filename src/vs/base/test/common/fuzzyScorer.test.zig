// Port of the `prepareQuery` case of `src/vs/base/test/common/fuzzyScorer.test.ts`.
const std = @import("std");
const fuzzy = @import("../../common/fuzzyScorer.zig");

test "prepareQuery" {
    const allocator = std.testing.allocator;

    const checks = [_]struct { query: []const u8, normalized: []const u8 }{
        .{ .query = " f*a ", .normalized = "fa" },
        .{ .query = " f…a ", .normalized = "fa" },
        .{ .query = "main#", .normalized = "main" },
        .{ .query = "foo*", .normalized = "foo" },
        .{ .query = "model Tester.ts", .normalized = "modelTester.ts" },
        .{ .query = "\"hello\"", .normalized = "hello" },
    };
    for (checks) |check| {
        const query = try fuzzy.prepareQuery(allocator, check.query);
        defer query.deinit(allocator);
        try std.testing.expectEqualStrings(check.normalized, query.normalized);
    }

    const main = try fuzzy.prepareQuery(allocator, "main#");
    defer main.deinit(allocator);
    try std.testing.expectEqualStrings("main#", main.original);

    const model = try fuzzy.prepareQuery(allocator, "model Tester.ts");
    defer model.deinit(allocator);
    try std.testing.expectEqualStrings("model Tester.ts", model.original);
    try std.testing.expectEqualStrings("model tester.ts", model.originalLowercase);
    try std.testing.expect(!model.expectContiguousMatch);
    try std.testing.expect(model.values != null);
    try std.testing.expectEqual(@as(usize, 2), model.values.?.len);

    const uppercase = try fuzzy.prepareQuery(allocator, "Model Tester.ts");
    defer uppercase.deinit(allocator);
    try std.testing.expectEqualStrings("modeltester.ts", uppercase.normalizedLowercase);

    const no_sep = try fuzzy.prepareQuery(allocator, "ModelTester.ts");
    defer no_sep.deinit(allocator);
    try std.testing.expect(!no_sep.containsPathSeparator);

    const sep_query = try fuzzy.prepareQuery(allocator, "Model/Tester.ts");
    defer sep_query.deinit(allocator);
    try std.testing.expect(sep_query.containsPathSeparator);

    const exact = try fuzzy.prepareQuery(allocator, "\"hello\"");
    defer exact.deinit(allocator);
    try std.testing.expect(exact.expectContiguousMatch);

    const spaced = try fuzzy.prepareQuery(allocator, "He*llo World");
    defer spaced.deinit(allocator);
    try std.testing.expectEqualStrings("He*llo World", spaced.original);
    try std.testing.expectEqualStrings("HelloWorld", spaced.normalized);
    try std.testing.expectEqualStrings("helloworld", spaced.normalizedLowercase);
    try std.testing.expectEqual(@as(usize, 2), spaced.values.?.len);
    try std.testing.expectEqualStrings("He*llo", spaced.values.?[0].original);
    try std.testing.expectEqualStrings("Hello", spaced.values.?[0].normalized);
    try std.testing.expectEqualStrings("hello", spaced.values.?[0].normalizedLowercase);
    try std.testing.expectEqualStrings("World", spaced.values.?[1].original);
    try std.testing.expectEqualStrings("World", spaced.values.?[1].normalized);

    const restored = try fuzzy.pieceToQuery(allocator, spaced.values.?);
    defer restored.deinit(allocator);
    try std.testing.expectEqualStrings(spaced.original, restored.original);
    try std.testing.expectEqual(spaced.values.?.len, restored.values.?.len);
    try std.testing.expectEqual(spaced.containsPathSeparator, restored.containsPathSeparator);

    const padded = try fuzzy.prepareQuery(allocator, " Hello   World  \t");
    defer padded.deinit(allocator);
    try std.testing.expectEqualStrings(" Hello   World  \t", padded.original);
    try std.testing.expectEqualStrings(" hello   world  \t", padded.originalLowercase);
    try std.testing.expectEqualStrings("HelloWorld", padded.normalized);
    try std.testing.expectEqualStrings("helloworld", padded.normalizedLowercase);
    try std.testing.expectEqual(@as(usize, 2), padded.values.?.len);
    try std.testing.expectEqualStrings("Hello", padded.values.?[0].original);
    try std.testing.expectEqualStrings("hello", padded.values.?[0].originalLowercase);
    try std.testing.expectEqualStrings("World", padded.values.?[1].original);

    const posix = try fuzzy.prepareQuery(allocator, "/some/path");
    defer posix.deinit(allocator);
    try std.testing.expectEqualStrings("/some/path", posix.pathNormalized);
    try std.testing.expectEqualStrings("/some/path", posix.normalized);
    try std.testing.expect(posix.containsPathSeparator);

    const backslash = try fuzzy.prepareQuery(allocator, "\\some\\path");
    defer backslash.deinit(allocator);
    try std.testing.expectEqualStrings("/some/path", backslash.pathNormalized);
    try std.testing.expectEqualStrings("/some/path", backslash.normalized);
    try std.testing.expect(backslash.containsPathSeparator);
}

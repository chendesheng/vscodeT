// Ported text-search type cases from
// `src/vs/workbench/services/search/test/common/search.test.ts`.

const std = @import("std");
const search = @import("../../common/search.zig");
const glob = @import("../../../../../base/common/glob.zig");

test "TextSearchMatch: empty and short ranges" {
    const allocator = std.testing.allocator;
    var empty = try search.TextSearchMatch.init(allocator, "", &[_]search.SearchRange{}, null);
    defer empty.deinit();
    try std.testing.expectEqualStrings("", empty.preview_text);

    var short = try search.TextSearchMatch.init(
        allocator,
        "foo bar",
        &[_]search.SearchRange{search.SearchRange.init(5, 4, 5, 7)},
        .{ .match_lines = 1, .chars_per_line = 100 },
    );
    defer short.deinit();
    const range = short.range_locations[0].preview;
    try std.testing.expectEqualStrings("bar", short.preview_text[range.start_column..range.end_column]);
}

fn assertOneLinePreviewText(text: []const u8, result: *const search.TextSearchMatch) !void {
    try std.testing.expectEqual(@as(usize, 1), result.range_locations.len);
    const range = result.range_locations[0].preview;
    const end = @min(range.end_column, result.preview_text.len);
    const start = @min(range.start_column, end);
    try std.testing.expectEqualStrings(text, result.preview_text[start..end]);
}

test "TextSearchMatch: leading, trailing and middle previews" {
    const allocator = std.testing.allocator;
    const options = search.PreviewOptions{ .match_lines = 1, .chars_per_line = 100 };

    var leading = try search.TextSearchMatch.init(allocator, "long text very long text foo", &[_]search.SearchRange{search.SearchRange.init(5, 25, 5, 28)}, options);
    defer leading.deinit();
    try assertOneLinePreviewText("foo", &leading);

    var trailing = try search.TextSearchMatch.init(
        allocator,
        "foo long text very long text long text very long text long text very long text long text very long text long text very long text",
        &[_]search.SearchRange{search.SearchRange.init(5, 0, 5, 3)},
        options,
    );
    defer trailing.deinit();
    try assertOneLinePreviewText("foo", &trailing);

    var middle = try search.TextSearchMatch.init(
        allocator,
        "long text very long text long foo text very long text long text very long text long text very long text long text very long text",
        &[_]search.SearchRange{search.SearchRange.init(5, 30, 5, 33)},
        options,
    );
    defer middle.deinit();
    try assertOneLinePreviewText("foo", &middle);
}

test "TextSearchMatch: truncating match" {
    const allocator = std.testing.allocator;
    var result = try search.TextSearchMatch.init(
        allocator,
        "foo bar",
        &[_]search.SearchRange{search.SearchRange.init(0, 4, 0, 7)},
        .{ .match_lines = 1, .chars_per_line = 1 },
    );
    defer result.deinit();
    try assertOneLinePreviewText("b", &result);
}

test "TextSearchMatch: one line of multiline match" {
    const allocator = std.testing.allocator;
    const range = search.SearchRange.init(5, 4, 6, 3);
    var result = try search.TextSearchMatch.init(allocator, "foo bar\nfoo bar", &[_]search.SearchRange{range}, .{ .match_lines = 1, .chars_per_line = 10000 });
    defer result.deinit();
    try std.testing.expectEqualStrings("foo bar\nfoo bar", result.preview_text);
    try std.testing.expectEqual(@as(usize, 1), result.range_locations.len);
    try std.testing.expectEqual(@as(usize, 0), result.range_locations[0].preview.start_line_number);
    try std.testing.expectEqual(@as(usize, 4), result.range_locations[0].preview.start_column);
    try std.testing.expectEqual(@as(usize, 1), result.range_locations[0].preview.end_line_number);
    try std.testing.expectEqual(@as(usize, 3), result.range_locations[0].preview.end_column);
}

test "TextSearchMatch: compacts multiple ranges on long lines" {
    const allocator = std.testing.allocator;
    const ranges = [_]search.SearchRange{
        search.SearchRange.init(5, 4, 5, 7),
        search.SearchRange.init(5, 133, 5, 136),
        search.SearchRange.init(5, 141, 5, 144),
    };
    var result = try search.TextSearchMatch.init(
        allocator,
        "foo bar 123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890 foo bar baz bar",
        &ranges,
        .{ .match_lines = 1, .chars_per_line = 10 },
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.range_locations.len);
    try std.testing.expectEqual(search.SearchRange.init(0, 4, 0, 7), result.range_locations[0].preview);
    // Terminal columns are UTF-8 bytes, so the elision markers shift the range
    // columns by their 4 extra UTF-8 bytes relative to upstream's UTF-16 columns.
    try std.testing.expectEqual(search.SearchRange.init(0, 46, 0, 49), result.range_locations[1].preview);
    try std.testing.expectEqual(search.SearchRange.init(0, 54, 0, 57), result.range_locations[2].preview);
    try std.testing.expectEqualStrings("foo bar 123456⟪ 117 characters skipped ⟫o bar baz bar", result.preview_text);
}

test "TextSearchMatch: trims line endings" {
    const allocator = std.testing.allocator;
    var lf = try search.TextSearchMatch.init(allocator, "foo bar\n", &[_]search.SearchRange{search.SearchRange.init(5, 3, 5, 5)}, .{ .match_lines = 1, .chars_per_line = 10000 });
    defer lf.deinit();
    try std.testing.expectEqualStrings("foo bar", lf.preview_text);

    var crlf = try search.TextSearchMatch.init(allocator, "foo bar\r\n", &[_]search.SearchRange{search.SearchRange.init(5, 3, 5, 5)}, .{ .match_lines = 1, .chars_per_line = 10000 });
    defer crlf.deinit();
    try std.testing.expectEqualStrings("foo bar", crlf.preview_text);
}

test "isFilePatternMatch: glob match is case-sensitive by default" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try search.isFilePatternMatch(allocator, "src/Foo.ts", null, "**/*.ts", false, false));
    try std.testing.expect(!try search.isFilePatternMatch(allocator, "src/Foo.ts", null, "**/*.TS", false, false));
}

test "isFilePatternMatch: glob match is case-insensitive when ignoreCase is true" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try search.isFilePatternMatch(allocator, "src/Foo.ts", null, "**/*.TS", false, true));
    try std.testing.expect(try search.isFilePatternMatch(allocator, "src/Foo.ts", null, "**/*.Ts", false, true));
}

test "isFilePatternMatch: glob match with mixed case pattern" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try search.isFilePatternMatch(allocator, "src/MyComponent.TSX", null, "**/*.tsx", false, false));
    try std.testing.expect(try search.isFilePatternMatch(allocator, "src/MyComponent.TSX", null, "**/*.tsx", false, true));
}

const exclude_pattern = [_]glob.ExcludeEntry{
    .{ .pattern = "node_modules" },
    .{ .pattern = "**/*.js", .when = "$(basename).ts" },
    .{ .pattern = "!node_modules/@types" },
    .{ .pattern = "!off", .enabled = false },
};

test "exclude exceptions: QueryGlobTester applies exceptions and sibling clauses" {
    const allocator = std.testing.allocator;
    const empty = [_]glob.ExcludeEntry{};
    var tester = try search.QueryGlobTester.init(allocator, &empty, &exclude_pattern);
    defer tester.deinit();

    const Sibling = struct {
        fn callback(_: *anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "a.ts");
        }
    };
    var sibling_state: u8 = 0;
    const has_sibling = glob.HasSibling{ .context = &sibling_state, .callback = Sibling.callback };

    try std.testing.expect(tester.matchesExcludesSync("node_modules", "node_modules", null));
    try std.testing.expect(!tester.includedInQuery("node_modules", "node_modules", null));
    try std.testing.expect(!tester.includedInQuery("a.js", "a.js", has_sibling));
    try std.testing.expect(tester.isExcepted("node_modules/@types/node/index.d.ts", null));
    try std.testing.expect(tester.couldExceptionMatchBeneath("node_modules"));
    try std.testing.expect(!tester.couldExceptionMatchBeneath("src"));
}

test "exclude exceptions: providers receive patterns without exceptions" {
    const allocator = std.testing.allocator;
    const global = [_]glob.ExcludeEntry{.{ .pattern = "!gulpfile.js" }};
    const excludes = try search.resolveExcludePatternsForProvider(allocator, &global, &exclude_pattern);
    defer allocator.free(excludes);
    try std.testing.expectEqual(@as(usize, 1), excludes.len);
    try std.testing.expectEqualStrings("node_modules", excludes[0]);

    const exceptions = try search.resolveExcludeExceptionsForProvider(allocator, &global, &exclude_pattern);
    defer {
        for (exceptions) |exception| allocator.free(exception);
        allocator.free(exceptions);
    }
    try std.testing.expectEqual(@as(usize, 2), exceptions.len);
    try std.testing.expectEqualStrings("gulpfile.js", exceptions[0]);
    try std.testing.expectEqualStrings("node_modules/@types", exceptions[1]);
}

test "exclude exceptions: counts distinct exceptions of a query" {
    const allocator = std.testing.allocator;
    const global = [_]glob.ExcludeEntry{.{ .pattern = "!**/Scripts" }};
    const folder_expressions = [_][]const glob.ExcludeEntry{ &exclude_pattern, &exclude_pattern };
    const counts = try search.getExcludeExceptionCounts(allocator, &global, &folder_expressions);
    try std.testing.expectEqual(@as(usize, 2), counts.exclude_exception_count);
    try std.testing.expectEqual(@as(usize, 1), counts.unanchored_exclude_exception_count);
}

// Ported text-search type cases from
// `src/vs/workbench/services/search/test/common/search.test.ts`.

const std = @import("std");
const search = @import("../../common/search.zig");

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

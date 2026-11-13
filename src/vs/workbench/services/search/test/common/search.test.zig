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

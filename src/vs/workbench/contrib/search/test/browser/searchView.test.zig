// Adapted from the non-AI behavior of
// `src/vs/workbench/contrib/search/test/browser/searchView.test.ts`.
//
// Upstream's two cases exercise keyword suggestions from the AI search model,
// which this port omits. The message/confirmation grammar that the terminal
// view renders is covered instead.

const std = @import("std");
const view = @import("../../browser/searchView.zig");

test "Search View: result count grammar" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        results: usize,
        files: usize,
        expected: []const u8,
    }{
        .{ .results = 1, .files = 1, .expected = "1 result in 1 file" },
        .{ .results = 1, .files = 2, .expected = "1 result in 2 files" },
        .{ .results = 2, .files = 1, .expected = "2 results in 1 file" },
        .{ .results = 2, .files = 2, .expected = "2 results in 2 files" },
    };
    for (cases) |case| {
        const message = try view.buildResultCountMessage(allocator, case.results, case.files);
        defer allocator.free(message);
        try std.testing.expectEqualStrings(case.expected, message);
    }
}

test "Search View: replace-all confirmation and after messages" {
    const allocator = std.testing.allocator;
    const confirmation1 = try view.buildReplaceAllConfirmationMessage(allocator, 1, 1, "omega");
    defer allocator.free(confirmation1);
    try std.testing.expectEqualStrings("Replace 1 occurrence across 1 file with 'omega'?", confirmation1);

    const confirmation2 = try view.buildReplaceAllConfirmationMessage(allocator, 2, 1, "");
    defer allocator.free(confirmation2);
    try std.testing.expectEqualStrings("Replace 2 occurrences across 1 file?", confirmation2);

    const after1 = try view.buildAfterReplaceAllMessage(allocator, 1, 2, "omega");
    defer allocator.free(after1);
    try std.testing.expectEqualStrings("Replaced 1 occurrence across 2 files with 'omega'.", after1);

    const after2 = try view.buildAfterReplaceAllMessage(allocator, 0, 0, "");
    defer allocator.free(after2);
    try std.testing.expectEqualStrings("Replaced 0 occurrences across 0 files.", after2);
}

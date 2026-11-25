// Port of src/vs/workbench/services/search/test/common/searchHelpers.test.ts.
const std = @import("std");
const helpers = @import("../../common/searchHelpers.zig");
const search = @import("../../common/search.zig");
const FindMatch = @import("../../../../../editor/common/model.zig").FindMatch;
const allocator = std.testing.allocator;

const Model = struct {
    pub fn getLineContent(_: Model, number: usize) !std.array_list.Managed(u8) {
        if (number < 1 or number > 100) return error.InvalidLine;
        return .fromOwnedSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{number}));
    }

    pub fn getLineCount(_: Model) usize {
        return 100;
    }
};

fn checkGroup(result: search.TextSearchMatch, text: []const u8, source: []const search.SearchRange, preview: []const search.SearchRange) !void {
    try std.testing.expectEqualStrings(text, result.preview_text);
    try std.testing.expectEqual(source.len, result.range_locations.len);
    for (result.range_locations, source, preview) |loc, s, p| {
        try std.testing.expectEqual(s, loc.source);
        try std.testing.expectEqual(p, loc.preview);
    }
}

fn freeMatches(results: []search.TextSearchMatch) void {
    for (results) |*result| result.deinit();
    allocator.free(results);
}

test "editorMatchesToTextSearchResults simple" {
    const results = try helpers.editorMatchesToTextSearchResults(allocator, &.{.init(.init(6, 1, 6, 2), null)}, Model{}, null);
    defer freeMatches(results);
    try std.testing.expectEqual(1, results.len);
    try checkGroup(results[0], "6\n", &.{.init(5, 0, 5, 1)}, &.{.init(0, 0, 0, 1)});
}

test "editorMatchesToTextSearchResults multiple" {
    const results = try helpers.editorMatchesToTextSearchResults(allocator, &.{ .init(.init(6, 1, 6, 2), null), .init(.init(6, 4, 8, 2), null), .init(.init(9, 1, 10, 3), null) }, Model{}, null);
    defer freeMatches(results);
    try std.testing.expectEqual(2, results.len);
    try checkGroup(results[0], "6\n7\n8\n", &.{ .init(5, 0, 5, 1), .init(5, 3, 7, 1) }, &.{ .init(0, 0, 0, 1), .init(0, 3, 2, 1) });
    try checkGroup(results[1], "9\n10\n", &.{.init(8, 0, 9, 2)}, &.{.init(0, 0, 1, 2)});
}

fn checkContext(lines: []const usize, surrounding: usize, expected: []const usize) !void {
    var matches: std.ArrayList(search.TextSearchMatch) = .empty;
    defer {
        for (matches.items) |*m| m.deinit();
        matches.deinit(allocator);
    }
    for (lines) |line| try matches.append(allocator, try .init(allocator, "foo", &.{.init(line, 0, line, 10)}, null));
    const rows = try helpers.getTextSearchMatchWithModelContext(allocator, matches.items, Model{}, surrounding);
    defer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |line, row| {
        try std.testing.expectEqual(line, row.line_number);
        var text: [8]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&text, "{d}", .{line}), row.text);
    }
}

test "addContextToEditorMatches no context" {
    try checkContext(&.{0}, 0, &.{});
}
test "addContextToEditorMatches simple" {
    try checkContext(&.{1}, 1, &.{ 1, 3 });
}
test "addContextToEditorMatches multiple matches next to each other" {
    try checkContext(&.{ 1, 2 }, 1, &.{ 1, 4 });
}
test "addContextToEditorMatches boundaries" {
    try checkContext(&.{ 0, 99 }, 1, &.{ 2, 99 });
}

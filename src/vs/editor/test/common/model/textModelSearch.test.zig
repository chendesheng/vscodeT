// Port of selected cases from
// `src/vs/editor/test/common/model/textModelSearch.test.ts`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TestModel = @import("../port/testSupport.zig").TestModel;
const TextModelSearch = @import("../../../common/model/textModelSearch.zig").TextModelSearch;
const SearchParams = @import("../../../common/model/textModelSearch.zig").SearchParams;
const FindMatch = @import("../../../common/model.zig").FindMatch;
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;
const USUAL_WORD_SEPARATORS = @import("../../../common/core/wordHelper.zig").USUAL_WORD_SEPARATORS;

fn freeMatches(allocator: Allocator, matches: []FindMatch) void {
    for (matches) |*match| match.free(allocator);
}

fn expectMatch(actual: ?FindMatch, expected_range: Range, expected_captures: ?[]const []const u8) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualDeep(expected_range, actual.?.range);
    if (expected_captures) |captures| {
        try std.testing.expect(actual.?.matches != null);
        try std.testing.expectEqual(captures.len, actual.?.matches.?.len);
        for (captures, actual.?.matches.?) |want, got| {
            try std.testing.expectEqualStrings(want, got);
        }
    } else {
        try std.testing.expect(actual.?.matches == null);
    }
}

fn check(model: *@import("../../../common/model/textModel.zig").TextModel, params: SearchParams, expected: []const Range) !void {
    const allocator = model.getAllocator();
    var actual = try TextModelSearch.findMatches(model, params, model.getFullModelRange(), false, 1000);
    defer {
        freeMatches(allocator, actual.items);
        actual.deinit();
    }
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |want, got| try std.testing.expectEqualDeep(want, got.range);

    if (expected.len == 0) return;
    var start = Position.init(1, 1);
    var first = try TextModelSearch.findNextMatch(model, params, start, false);
    defer if (first) |*match| match.free(allocator);
    try expectMatch(first, expected[0], null);
    for (expected) |want| {
        start = want.getStartPosition();
        var match = try TextModelSearch.findNextMatch(model, params, start, false);
        defer if (match) |*m| m.free(allocator);
        try expectMatch(match, want, null);
    }

    start = Position.init(model.getLineCount(), model.getLineMaxColumn(model.getLineCount()));
    var last = try TextModelSearch.findPreviousMatch(model, params, start, false);
    defer if (last) |*match| match.free(allocator);
    try expectMatch(last, expected[expected.len - 1], null);
    for (expected) |want| {
        start = want.getEndPosition();
        var match = try TextModelSearch.findPreviousMatch(model, params, start, false);
        defer if (match) |*m| m.free(allocator);
        try expectMatch(match, want, null);
    }
}

fn assertFindMatches(allocator: Allocator, text: []const u8, search_string: []const u8, is_regex: bool, match_case: bool, word_separators: ?[]const u8, expected: []const Range) !void {
    for (0..2) |variant| {
        var model = try TestModel.init(allocator, text, "plaintext");
        defer model.deinit();
        if (variant == 1) try model.model.pushEOL(.CRLF);
        try check(model.model, SearchParams.init(search_string, is_regex, match_case, word_separators), expected);
    }
}

test "textModelSearch: simple, case-sensitive and whole-word find" {
    const text = "This is some foo - bar text which contains foo and bar - as in Barcelona.\n" ++
        "Now it begins a word fooBar and now it is caps Foo-isn't this great?\n" ++
        "And here's a dull line with nothing interesting in it\n" ++
        "It is also interesting if it's part of a word like amazingFooBar\n" ++
        "Again nothing interesting here";

    try assertFindMatches(std.testing.allocator, text, "foo", false, false, null, &.{
        Range.init(1, 14, 1, 17),
        Range.init(1, 44, 1, 47),
        Range.init(2, 22, 2, 25),
        Range.init(2, 48, 2, 51),
        Range.init(4, 59, 4, 62),
    });
    try assertFindMatches(std.testing.allocator, text, "foo", false, true, null, &.{
        Range.init(1, 14, 1, 17),
        Range.init(1, 44, 1, 47),
        Range.init(2, 22, 2, 25),
    });
    try assertFindMatches(std.testing.allocator, text, "foo", false, false, USUAL_WORD_SEPARATORS, &.{
        Range.init(1, 14, 1, 17),
        Range.init(1, 44, 1, 47),
        Range.init(2, 48, 2, 51),
    });
}

test "textModelSearch: line boundary and dot-star regexes" {
    const text = "This is some foo - bar text which contains foo and bar - as in Barcelona.\n" ++
        "Now it begins a word fooBar and now it is caps Foo-isn't this great?\n" ++
        "And here's a dull line with nothing interesting in it\n" ++
        "It is also interesting if it's part of a word like amazingFooBar\n" ++
        "Again nothing interesting here";
    try assertFindMatches(std.testing.allocator, text, "^", true, false, null, &.{
        Range.init(1, 1, 1, 1),
        Range.init(2, 1, 2, 1),
        Range.init(3, 1, 3, 1),
        Range.init(4, 1, 4, 1),
        Range.init(5, 1, 5, 1),
    });
    try assertFindMatches(std.testing.allocator, text, "$", true, false, null, &.{
        Range.init(1, 74, 1, 74),
        Range.init(2, 69, 2, 69),
        Range.init(3, 54, 3, 54),
        Range.init(4, 65, 4, 65),
        Range.init(5, 31, 5, 31),
    });
    try assertFindMatches(std.testing.allocator, text, ".*", true, false, null, &.{
        Range.init(1, 1, 1, 74),
        Range.init(2, 1, 2, 69),
        Range.init(3, 1, 3, 54),
        Range.init(4, 1, 4, 65),
        Range.init(5, 1, 5, 31),
    });
    try assertFindMatches(std.testing.allocator, "This is some foo - bar text which contains foo and bar - as in Barcelona.\n\nAnd here's a dull line with nothing interesting in it\n\nAgain nothing interesting here", "^$", true, false, null, &.{
        Range.init(2, 1, 2, 1),
        Range.init(4, 1, 4, 1),
    });
}

test "textModelSearch: multiline finds" {
    const text = "Just some text text\nJust some text text\nsome text again\nagain some text";
    try assertFindMatches(std.testing.allocator, text, "text\\n", true, false, null, &.{
        Range.init(1, 16, 2, 1),
        Range.init(2, 16, 3, 1),
    });
    try assertFindMatches(std.testing.allocator, text, "text\\nJust", true, false, null, &.{
        Range.init(1, 16, 2, 5),
    });
    try assertFindMatches(std.testing.allocator, text, "\\nagain", true, false, null, &.{
        Range.init(3, 16, 4, 6),
    });
    try assertFindMatches(std.testing.allocator, text, ".*\\nJust.*\\n", true, false, null, &.{
        Range.init(1, 1, 3, 1),
    });
}

test "textModelSearch: findNextMatch without regex" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "line line one\nline two\nthree", "plaintext");
    defer model.deinit();
    const params = SearchParams.init("line", false, false, null);

    var actual = try TextModelSearch.findNextMatch(model.model, params, Position.init(1, 1), false);
    try expectMatch(actual, Range.init(1, 1, 1, 5), null);
    actual = try TextModelSearch.findNextMatch(model.model, params, Position.init(1, 5), false);
    try expectMatch(actual, Range.init(1, 6, 1, 10), null);
    actual = try TextModelSearch.findNextMatch(model.model, params, Position.init(1, 3), false);
    try expectMatch(actual, Range.init(1, 6, 1, 10), null);
    actual = try TextModelSearch.findNextMatch(model.model, params, Position.init(1, 10), false);
    try expectMatch(actual, Range.init(2, 1, 2, 5), null);
    actual = try TextModelSearch.findNextMatch(model.model, params, Position.init(2, 5), false);
    try expectMatch(actual, Range.init(1, 1, 1, 5), null);
}

test "textModelSearch: capturing matches" {
    const allocator = std.testing.allocator;
    var model = try TestModel.init(allocator, "one line line\ntwo line\nthree", "plaintext");
    defer model.deinit();
    const params = SearchParams.init("(l(in)e)", true, false, null);

    var actual = try TextModelSearch.findMatches(model.model, params, model.model.getFullModelRange(), true, 100);
    defer {
        freeMatches(allocator, actual.items);
        actual.deinit();
    }
    try std.testing.expectEqual(@as(usize, 3), actual.items.len);
    const expected_ranges = [_]Range{ Range.init(1, 5, 1, 9), Range.init(1, 10, 1, 14), Range.init(2, 5, 2, 9) };
    const expected_captures = [_][]const u8{ "line", "line", "in" };
    for (expected_ranges, actual.items) |want, got| {
        try std.testing.expectEqualDeep(want, got.range);
        try std.testing.expect(got.matches != null);
        for (expected_captures, got.matches.?) |want_capture, got_capture| {
            try std.testing.expectEqualStrings(want_capture, got_capture);
        }
    }

    var next = try TextModelSearch.findNextMatch(model.model, params, Position.init(1, 1), true);
    defer if (next) |*match| match.free(allocator);
    try expectMatch(next, Range.init(1, 5, 1, 9), &expected_captures);

    var prev = try TextModelSearch.findPreviousMatch(model.model, params, Position.init(1, 1), true);
    defer if (prev) |*match| match.free(allocator);
    try expectMatch(prev, Range.init(2, 5, 2, 9), &expected_captures);
}

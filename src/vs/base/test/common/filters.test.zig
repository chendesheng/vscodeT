// Port of the `fuzzyScore` cases of `src/vs/base/test/common/filters.test.ts`.
const std = @import("std");
const filters = @import("../../common/filters.zig");

fn lower(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, text.len);
    for (text, 0..) |character, index| result[index] = std.ascii.toLower(character);
    return result;
}

fn assertMatches(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    word: []const u8,
    decorated_word: ?[]const u8,
    options: filters.FuzzyScoreOptions,
) !void {
    var scorer = try filters.FuzzyScorer.init(allocator);
    defer scorer.deinit();
    const pattern_low = try lower(allocator, pattern);
    defer allocator.free(pattern_low);
    const word_low = try lower(allocator, word);
    defer allocator.free(word_low);
    const value = try scorer.score(pattern, pattern_low, 0, word, word_low, 0, options);
    if (decorated_word == null) {
        try std.testing.expect(value == null);
        return;
    }
    const score_value = value.?;
    defer score_value.deinit(allocator);
    const matches = try filters.createScorerMatches(allocator, score_value);
    defer allocator.free(matches);

    var actual = std.array_list.Managed(u8).init(allocator);
    defer actual.deinit();
    var position: usize = 0;
    for (matches) |match| {
        try actual.appendSlice(word[position..match.start]);
        var index = match.start;
        while (index < match.end) : (index += 1) {
            try actual.append('^');
            try actual.append(word[index]);
        }
        position = match.end;
    }
    try actual.appendSlice(word[position..]);
    try std.testing.expectEqualStrings(decorated_word.?, actual.items);
}

test "fuzzyScore, #23215" {
    const allocator = std.testing.allocator;
    const options = filters.FuzzyScoreOptions{};
    try assertMatches(allocator, "tit", "win.tit", "win.^t^i^t", options);
    try assertMatches(allocator, "title", "win.title", "win.^t^i^t^l^e", options);
    try assertMatches(allocator, "WordCla", "WordCharacterClassifier", "^W^o^r^dCharacter^C^l^assifier", options);
    try assertMatches(allocator, "WordCCla", "WordCharacterClassifier", "^W^o^r^d^Character^C^l^assifier", options);
}

test "fuzzyScore, #23332" {
    const allocator = std.testing.allocator;
    try assertMatches(allocator, "dete", "\"editor.quickSuggestionsDelay\"", null, .{});
}

test "fuzzyScore, #23190" {
    const allocator = std.testing.allocator;
    try assertMatches(allocator, "c:\\do", "& 'C:\\Documents and Settings'", "& '^C^:^\\^D^ocuments and Settings'", .{});
    try assertMatches(allocator, "c:\\do", "& 'c:\\Documents and Settings'", "& '^c^:^\\^D^ocuments and Settings'", .{});
}

test "fuzzyScore, #23581" {
    const allocator = std.testing.allocator;
    try assertMatches(allocator, "close", "css.lint.importStatement", "^css.^lint.imp^ort^Stat^ement", .{});
    try assertMatches(allocator, "close", "css.colorDecorators.enable", "^css.co^l^orDecorator^s.^enable", .{});
    try assertMatches(allocator, "close", "workbench.quickOpen.closeOnFocusOut", "workbench.quickOpen.^c^l^o^s^eOnFocusOut", .{});
}

test "fuzzyScore, #23458" {
    const allocator = std.testing.allocator;
    try assertMatches(allocator, "highlight", "editorHoverHighlight", "editorHover^H^i^g^h^l^i^g^h^t", .{});
    try assertMatches(allocator, "hhighlight", "editorHoverHighlight", "editor^Hover^H^i^g^h^l^i^g^h^t", .{});
    try assertMatches(allocator, "dhhighlight", "editorHoverHighlight", null, .{});
}

test "fuzzyScore, #23746" {
    const allocator = std.testing.allocator;
    try assertMatches(allocator, "-moz", "-moz-foo", "^-^m^o^z-foo", .{});
    try assertMatches(allocator, "moz", "-moz-foo", "-^m^o^z-foo", .{});
    try assertMatches(allocator, "moz", "-moz-animation", "-^m^o^z-animation", .{});
    try assertMatches(allocator, "moza", "-moz-animation", "-^m^o^z-^animation", .{});
}

test "fuzzyScore" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, word: []const u8, decorated: ?[]const u8 }{
        .{ .pattern = "ab", .word = "abA", .decorated = "^a^bA" },
        .{ .pattern = "ccm", .word = "cacmelCase", .decorated = "^ca^c^melCase" },
        .{ .pattern = "bti", .word = "the_black_knight", .decorated = null },
        .{ .pattern = "ccm", .word = "camelCase", .decorated = null },
        .{ .pattern = "BK", .word = "the_black_knight", .decorated = "the_^black_^knight" },
        .{ .pattern = "KeyboardLayout=", .word = "KeyboardLayout", .decorated = null },
        .{ .pattern = "TEdit", .word = "TextEdit", .decorated = "^Text^E^d^i^t" },
        .{ .pattern = "TEdit", .word = "TextEditor", .decorated = "^Text^E^d^i^tor" },
        .{ .pattern = "TEdit", .word = "text_edit", .decorated = "^text_^e^d^i^t" },
        .{ .pattern = "ba", .word = "?AB?", .decorated = null },
        .{ .pattern = "foobar", .word = "foobar", .decorated = "^f^o^o^b^a^r" },
        .{ .pattern = "no", .word = "", .decorated = null },
        .{ .pattern = "no", .word = "match", .decorated = null },
        .{ .pattern = "ob", .word = "foobar", .decorated = null },
        .{ .pattern = "Three", .word = "HTMLHRElement", .decorated = null },
        .{ .pattern = "Three", .word = "Three", .decorated = "^T^h^r^e^e" },
        .{ .pattern = "fo", .word = "barfoo", .decorated = null },
        .{ .pattern = "fo", .word = "bar_foo", .decorated = "bar_^f^oo" },
    };
    for (cases) |case| {
        try assertMatches(allocator, case.pattern, case.word, case.decorated, .{});
    }
}

test "fuzzyScore - extended matches" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, word: []const u8, decorated: ?[]const u8 }{
        .{ .pattern = "cmcm", .word = "camelCase", .decorated = null },
        .{ .pattern = "LLL", .word = "SVisualLoggerLogsList", .decorated = "SVisual^Logger^Logs^List" },
        .{ .pattern = "LLLL", .word = "SVilLoLosLi", .decorated = null },
        .{ .pattern = "TEdit", .word = "Textedit", .decorated = "^Text^e^d^i^t" },
        .{ .pattern = "TEditDit", .word = "TextEditorDecorationType", .decorated = "^Text^E^d^i^tor^Decorat^ion^Type" },
        .{ .pattern = "TEdit", .word = "TextEditorDecorationType", .decorated = "^Text^E^d^i^torDecorationType" },
        .{ .pattern = "Tedit", .word = "TextEdit", .decorated = "^Text^E^d^i^t" },
        .{ .pattern = "bkn", .word = "the_black_knight", .decorated = "the_^black_^k^night" },
        .{ .pattern = "bt", .word = "the_black_knight", .decorated = "the_^black_knigh^t" },
        .{ .pattern = "ccm", .word = "camelCasecm", .decorated = "^camel^Casec^m" },
        .{ .pattern = "fdm", .word = "findModel", .decorated = "^fin^d^Model" },
        .{ .pattern = "fob", .word = "foobar", .decorated = "^f^oo^bar" },
        .{ .pattern = "fobz", .word = "foobar", .decorated = null },
        .{ .pattern = "form", .word = "editor.formatOnSave", .decorated = "editor.^f^o^r^matOnSave" },
        .{ .pattern = "g p", .word = "Git: Pull", .decorated = "^Git:^ ^Pull" },
        .{ .pattern = "gip", .word = "Git: Pull", .decorated = "^G^it: ^Pull" },
        .{ .pattern = "gp", .word = "Git_Git_Pull", .decorated = "^Git_Git_^Pull" },
        .{ .pattern = "is", .word = "ImportStatement", .decorated = "^Import^Statement" },
        .{ .pattern = "is", .word = "isValid", .decorated = "^i^sValid" },
        .{ .pattern = "lowrd", .word = "lowWord", .decorated = "^l^o^wWo^r^d" },
        .{ .pattern = "myvable", .word = "myvariable", .decorated = "^m^y^v^aria^b^l^e" },
        .{ .pattern = "sl", .word = "SVisualLoggerLogsList", .decorated = "^SVisual^LoggerLogsList" },
        .{ .pattern = "sllll", .word = "SVisualLoggerLogsList", .decorated = "^SVisua^l^Logger^Logs^List" },
        .{ .pattern = "fo", .word = "bar_Foo", .decorated = "bar_^F^oo" },
        .{ .pattern = "fo", .word = "bar foo", .decorated = "bar ^f^oo" },
        .{ .pattern = "fo", .word = "bar/foo", .decorated = "bar/^f^oo" },
        .{ .pattern = "fo", .word = "bar\\foo", .decorated = "bar\\^f^oo" },
    };
    for (cases) |case| {
        try assertMatches(allocator, case.pattern, case.word, case.decorated, .{});
    }
}

fn topScoreIndex(allocator: std.mem.Allocator, pattern: []const u8, words: []const []const u8) !usize {
    var scorer = try filters.FuzzyScorer.init(allocator);
    defer scorer.deinit();
    const pattern_low = try lower(allocator, pattern);
    defer allocator.free(pattern_low);
    var top_score: i32 = -1000;
    var top_index: usize = 0;
    for (words, 0..) |word, index| {
        const word_low = try lower(allocator, word);
        defer allocator.free(word_low);
        const result = try scorer.score(pattern, pattern_low, 0, word, word_low, 0, .{});
        if (result) |value| {
            var mutable = value;
            defer mutable.deinit(allocator);
            if (value.score > top_score) {
                top_score = value.score;
                top_index = index;
            }
        }
    }
    return top_index;
}

test "topScore - fuzzyScore" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 2), try topScoreIndex(allocator, "cons", &.{ "ArrayBufferConstructor", "Console", "console" }));
    try std.testing.expectEqual(@as(usize, 1), try topScoreIndex(allocator, "Foo", &.{ "foo", "Foo" }));
    try std.testing.expectEqual(@as(usize, 1), try topScoreIndex(allocator, "onMess", &.{ "onmessage", "onMessage", "onThisMegaEscape" }));
    try std.testing.expectEqual(@as(usize, 1), try topScoreIndex(allocator, "CC", &.{ "camelCase", "CamelCase" }));
    try std.testing.expectEqual(@as(usize, 0), try topScoreIndex(allocator, "cC", &.{ "camelCase", "CamelCase" }));
}

fn expectWordMatch(allocator: std.mem.Allocator, word: []const u8, target: []const u8) !void {
    const matches = (try filters.matchesWords(allocator, word, target)) orelse return error.TestUnexpectedResult;
    defer allocator.free(matches);
}

test "matchesWords basic word filters" {
    const allocator = std.testing.allocator;
    try expectWordMatch(allocator, "alpha", "alpha");
    try expectWordMatch(allocator, "alpha", "alphasomething");
    try std.testing.expect((try filters.matchesWords(allocator, "alpha", "alp")) == null);
    try expectWordMatch(allocator, "a", "alpha");
    try std.testing.expect((try filters.matchesWords(allocator, "x", "alpha")) == null);
    try expectWordMatch(allocator, "A", "alpha");
    try expectWordMatch(allocator, "AlPh", "alPHA");
    try expectWordMatch(allocator, "Debug Console", "Open: Debug Console");
    try expectWordMatch(allocator, "gp", "Git: Pull");
    try expectWordMatch(allocator, "g p", "Git: Pull");
    try expectWordMatch(allocator, "gipu", "Git: Pull");
    try expectWordMatch(allocator, "gp", "Category: Git: Pull");
    try expectWordMatch(allocator, "gipu", "Category: Git: Pull");
    try std.testing.expect((try filters.matchesWords(allocator, "it", "Git: Pull")) == null);
    try std.testing.expect((try filters.matchesWords(allocator, "ll", "Git: Pull")) == null);
    try expectWordMatch(allocator, "bar", "foo-bar");
    try expectWordMatch(allocator, "bar test", "foo-bar test");
    try expectWordMatch(allocator, "fbt", "foo-bar test");
    try expectWordMatch(allocator, "bar test", "foo-bar (test)");
    try expectWordMatch(allocator, "foo bar", "foo (bar)");
    try std.testing.expect((try filters.matchesWords(allocator, "bar est", "foo-bar test")) == null);
    try std.testing.expect((try filters.matchesWords(allocator, "fo ar", "foo-bar test")) == null);
    try std.testing.expect((try filters.matchesWords(allocator, "for", "foo-bar test")) == null);
    try expectWordMatch(allocator, "foo bar", "123 foo-bar 456");
    try expectWordMatch(allocator, "foo:bar", "foo:bar");
    try expectWordMatch(allocator, "C++", "C/C++: command");
    try expectWordMatch(allocator, "foo bar", "foo-bar");
    try expectWordMatch(allocator, "foo-bar", "foo bar");
    {
        const separator_only = (try filters.matchesWords(allocator, ".", ":")) orelse return error.TestUnexpectedResult;
        defer allocator.free(separator_only);
        try std.testing.expectEqual(@as(usize, 0), separator_only.len);
    }
    try expectWordMatch(allocator, ".", ".");
}

test "matchesContiguousSubString finds case-insensitive substrings" {
    const match = filters.matchesContiguousSubString("cela", "cancelAnimationFrame()").?;
    try std.testing.expectEqual(@as(usize, 3), match.start);
    try std.testing.expectEqual(@as(usize, 7), match.end);
    try std.testing.expect(filters.matchesContiguousSubString("missing", "target") == null);
}

test "matchesSubString coalesces consecutive positions" {
    const allocator = std.testing.allocator;
    {
        const matches = (try filters.matchesSubString(allocator, "cmm", "cancelAnimationFrame()")) orelse return error.TestUnexpectedResult;
        defer allocator.free(matches);
        try std.testing.expectEqual(@as(usize, 3), matches.len);
        try std.testing.expectEqual(@as(usize, 0), matches[0].start);
        try std.testing.expectEqual(@as(usize, 9), matches[1].start);
        try std.testing.expectEqual(@as(usize, 18), matches[2].start);
    }
    {
        const matches = (try filters.matchesSubString(allocator, "abc", "abcabc")) orelse return error.TestUnexpectedResult;
        defer allocator.free(matches);
        try std.testing.expectEqual(@as(usize, 1), matches.len);
        try std.testing.expectEqual(@as(usize, 0), matches[0].start);
        try std.testing.expectEqual(@as(usize, 3), matches[0].end);
    }
    {
        const matches = (try filters.matchesSubString(allocator, "abc", "aaabbbccc")) orelse return error.TestUnexpectedResult;
        defer allocator.free(matches);
        try std.testing.expectEqual(@as(usize, 3), matches.len);
        try std.testing.expectEqual(@as(usize, 0), matches[0].start);
        try std.testing.expectEqual(@as(usize, 3), matches[1].start);
        try std.testing.expectEqual(@as(usize, 6), matches[2].start);
    }
    try std.testing.expect((try filters.matchesSubString(allocator, "aaaaaaaaaaaaaaaaaaaax", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")) == null);
}

test "prefix filters handle case sensitivity" {
    try std.testing.expect(filters.matchesStrictPrefix("", "") == null);
    try std.testing.expect(filters.matchesStrictPrefix("", "anything") != null);
    const matched = filters.matchesStrictPrefix("alpha", "alphasomething").?;
    try std.testing.expectEqual(@as(usize, 0), matched.start);
    try std.testing.expectEqual(@as(usize, 5), matched.end);
    try std.testing.expect(filters.matchesStrictPrefix("alpha", "alp") == null);
    try std.testing.expect(filters.matchesStrictPrefix("A", "alpha") == null);
    try std.testing.expect(filters.matchesStrictPrefix("AlPh", "alPHA") == null);

    try std.testing.expect(filters.matchesPrefix("alpha", "alpha") != null);
    try std.testing.expect(filters.matchesPrefix("A", "alpha") != null);
    try std.testing.expect(filters.matchesPrefix("AlPh", "alPHA") != null);
    try std.testing.expect(filters.matchesPrefix("x", "alpha") == null);
    try std.testing.expect(filters.matchesPrefix("T", "4") == null);
}

fn expectCamel(allocator: std.mem.Allocator, word: []const u8, target: []const u8, expected: []const [2]usize) !void {
    const matches = (try filters.matchesCamelCase(allocator, word, target)) orelse return error.TestUnexpectedResult;
    defer allocator.free(matches);
    try std.testing.expectEqual(expected.len, matches.len);
    for (expected, matches) |range, match| {
        try std.testing.expectEqual(range[0], match.start);
        try std.testing.expectEqual(range[1], match.end);
    }
}

test "matchesCamelCase" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try filters.matchesCamelCase(allocator, "", "")) == null);
    const empty = (try filters.matchesCamelCase(allocator, "", "anything")) orelse return error.TestUnexpectedResult;
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    try expectCamel(allocator, "alpha", "alpha", &.{.{ 0, 5 }});
    try expectCamel(allocator, "AlPhA", "alpha", &.{.{ 0, 5 }});
    try expectCamel(allocator, "alpha", "alphasomething", &.{.{ 0, 5 }});
    try std.testing.expect((try filters.matchesCamelCase(allocator, "alpha", "alp")) == null);

    try expectCamel(allocator, "c", "CamelCaseRocks", &.{.{ 0, 1 }});
    try expectCamel(allocator, "cc", "CamelCaseRocks", &.{ .{ 0, 1 }, .{ 5, 6 } });
    try expectCamel(allocator, "ccr", "CamelCaseRocks", &.{ .{ 0, 1 }, .{ 5, 6 }, .{ 9, 10 } });
    try expectCamel(allocator, "cacr", "CamelCaseRocks", &.{ .{ 0, 2 }, .{ 5, 6 }, .{ 9, 10 } });
    try expectCamel(allocator, "cacar", "CamelCaseRocks", &.{ .{ 0, 2 }, .{ 5, 7 }, .{ 9, 10 } });
    try expectCamel(allocator, "ccarocks", "CamelCaseRocks", &.{ .{ 0, 1 }, .{ 5, 7 }, .{ 9, 14 } });
    try expectCamel(allocator, "cr", "CamelCaseRocks", &.{ .{ 0, 1 }, .{ 9, 10 } });

    try expectCamel(allocator, "fba", "FooBarAbe", &.{ .{ 0, 1 }, .{ 3, 5 } });
    try expectCamel(allocator, "fbar", "FooBarAbe", &.{ .{ 0, 1 }, .{ 3, 6 } });
    try expectCamel(allocator, "fbara", "FooBarAbe", &.{ .{ 0, 1 }, .{ 3, 7 } });
    try expectCamel(allocator, "fbaa", "FooBarAbe", &.{ .{ 0, 1 }, .{ 3, 5 }, .{ 6, 7 } });
    try expectCamel(allocator, "fbaab", "FooBarAbe", &.{ .{ 0, 1 }, .{ 3, 5 }, .{ 6, 8 } });

    try expectCamel(allocator, "c2d", "canvasCreation2D", &.{ .{ 0, 1 }, .{ 14, 16 } });
    try expectCamel(allocator, "cce", "_canvasCreationEvent", &.{ .{ 1, 2 }, .{ 7, 8 }, .{ 15, 16 } });
}

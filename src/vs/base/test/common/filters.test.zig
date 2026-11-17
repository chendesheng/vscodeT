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

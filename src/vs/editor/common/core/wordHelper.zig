const std = @import("std");
const ArrayList = std.array_list.Managed;
const RegExp = @import("../../../../support/regexp.zig").RegExp;

pub const USUAL_WORD_SEPARATORS = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?";

pub const IWordAtPosition = struct {
    word: []const u8,
    startColumn: usize,
    endColumn: usize,
};

fn createWordRegExp(allowInWords: []const u8) RegExp {
    var source = ArrayList(u8).init(std.heap.page_allocator);
    defer source.deinit();
    source.appendSlice("(-?\\d*\\.\\d\\w*)|([^") catch unreachable;
    for (USUAL_WORD_SEPARATORS) |sep| {
        if (std.mem.indexOfScalar(u8, allowInWords, sep) != null) continue;
        source.append('\\') catch unreachable;
        source.append(sep) catch unreachable;
    }
    source.appendSlice("\\s]+)") catch unreachable;
    return RegExp.init(source.items, .{}) catch unreachable;
}

var default_word_regexp: ?RegExp = null;

pub fn defaultWordRegExp() RegExp {
    if (default_word_regexp == null) {
        default_word_regexp = createWordRegExp("");
    }
    return default_word_regexp.?;
}

pub fn ensureValidWordDefinition(wordDefinition: ?RegExp) RegExp {
    return wordDefinition orelse defaultWordRegExp();
}

pub const GetWordAtTextConfig = struct {
    maxLen: usize = 1000,
    windowSize: usize = 15,
    timeBudget: i64 = 150,
};

/// Returns a word borrowed from `text`. The caller must keep `text` alive for
/// as long as the result is used, or copy `word`.
pub fn getWordAtText(column: usize, wordDefinition: ?RegExp, text: []const u8, textOffset: usize) ?IWordAtPosition {
    const config = GetWordAtTextConfig{};
    return getWordAtTextWithConfig(column, wordDefinition, text, textOffset, config);
}

pub fn getWordAtTextWithConfig(column: usize, wordDefinition: ?RegExp, text: []const u8, textOffset: usize, config: GetWordAtTextConfig) ?IWordAtPosition {
    var regex = ensureValidWordDefinition(wordDefinition);

    if (text.len > config.maxLen) {
        const half = config.maxLen / 2;
        var start: usize = 0;
        if (column > half) start = column - half;
        if (start >= text.len) return null;
        return getWordAtTextWithConfig(column, regex, text[start..], textOffset + start, config);
    }

    if (column <= textOffset) return null;
    const pos = column - 1 - textOffset;
    if (pos >= text.len) return null;

    var iter = regex.searchIterator(text, 0);
    while (iter.next()) |result| {
        defer result.deinit();
        const index = result.index();
        const len = result.length();
        if (index > pos) break;
        if (index <= pos and pos <= index + len) {
            return .{
                .word = text[index .. index + len],
                .startColumn = textOffset + 1 + index,
                .endColumn = textOffset + 1 + index + len,
            };
        }
    }

    return null;
}

test "wordHelper: english word at position" {
    const text = "This text has some  words. ";
    try std.testing.expectEqualStrings("This", getWordAtText(1, null, text, 0).?.word);
    try std.testing.expectEqualStrings("This", getWordAtText(4, null, text, 0).?.word);
    try std.testing.expectEqualStrings("text", getWordAtText(6, null, text, 0).?.word);
    try std.testing.expectEqualStrings("some", getWordAtText(19, null, text, 0).?.word);
    try std.testing.expect(getWordAtText(20, null, text, 0) == null);
    try std.testing.expectEqualStrings("words", getWordAtText(21, null, text, 0).?.word);
}

test "wordHelper: numbers and punctuation" {
    const text = "foo.bar 12.5 -x";
    try std.testing.expectEqualStrings("foo", getWordAtText(1, null, text, 0).?.word);
    try std.testing.expectEqualStrings("12.5", getWordAtText(9, null, text, 0).?.word);
    try std.testing.expectEqualStrings("x", getWordAtText(15, null, text, 0).?.word);
}

// Port of `src/vs/editor/common/core/wordHelper.ts`.
const std = @import("std");
const ArrayList = std.array_list.Managed;
const RegExp = @import("../../../../support/regexp.zig").RegExp;
const timeCompat = @import("../../../base/common/timeCompat.zig");

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

var default_config: GetWordAtTextConfig = .{};

pub fn setDefaultGetWordAtTextConfig(value: GetWordAtTextConfig) void {
    default_config = value;
}

/// Returns a word borrowed from `text`. The caller must keep `text` alive for
/// as long as the result is used, or copy `word`.
pub fn getWordAtText(column: usize, wordDefinition: ?RegExp, text: []const u8, textOffset: usize) ?IWordAtPosition {
    return getWordAtTextWithConfig(column, wordDefinition, text, textOffset, default_config);
}

pub fn getWordAtTextWithConfig(column: usize, wordDefinition: ?RegExp, text: []const u8, textOffset: usize, config: GetWordAtTextConfig) ?IWordAtPosition {
    const regex = ensureValidWordDefinition(wordDefinition);

    if (text.len > config.maxLen) {
        // Do not hand very long strings to the regex. Take a window around the
        // column; upstream keeps the column in the same absolute position.
        const half = config.maxLen / 2;
        var start: usize = 0;
        var offset = textOffset;
        if (column > half) {
            start = column - half;
            offset += start;
        } else {
            offset = textOffset;
        }
        if (start >= text.len) return null;
        const end = @min(text.len, column +| half);
        if (start > end) return null;
        return getWordAtTextWithConfig(column, regex, text[start..end], offset, config);
    }

    if (column <= textOffset) return null;
    const pos = column - 1 - textOffset;
    if (pos > text.len) return null;

    const t1 = timeCompat.milliTimestamp();
    var prev_regex_index: isize = -1;
    var match: ?Match = null;
    var i: usize = 1;
    while (true) : (i += 1) {
        if (timeCompat.milliTimestamp() - t1 >= config.timeBudget) break;

        const window_offset = @min(config.windowSize *| i, @as(usize, @intCast(std.math.maxInt(isize))));
        const regex_index = @as(isize, @intCast(pos)) - @as(isize, @intCast(window_offset));
        const start: usize = @intCast(@max(0, regex_index));
        const this_match = findRegexMatchEnclosingPosition(regex, text, @intCast(pos), prev_regex_index, start);

        if (this_match == null and match != null) {
            // Stop: we already have a match from a previous window.
            break;
        }
        match = this_match;

        if (regex_index <= 0) break;
        prev_regex_index = regex_index;
    }

    if (match) |found| {
        return .{
            .word = text[found.index .. found.index + found.len],
            .startColumn = textOffset + 1 + found.index,
            .endColumn = textOffset + 1 + found.index + found.len,
        };
    }
    return null;
}

const Match = struct {
    index: usize,
    len: usize,
};

fn findRegexMatchEnclosingPosition(regex: RegExp, text: []const u8, pos: isize, stop_pos: isize, start: usize) ?Match {
    var iterator = regex.searchIterator(text, start);
    while (iterator.next()) |result| {
        defer result.deinit();
        const index = result.index();
        const len = result.length();
        const end = index + len;
        if (@as(isize, @intCast(index)) <= pos and @as(isize, @intCast(end)) >= pos) {
            return .{ .index = index, .len = len };
        } else if (stop_pos > 0 and @as(isize, @intCast(index)) > stop_pos) {
            return null;
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

test "wordHelper: end-of-line position finds the last word" {
    const text = "abc";
    try std.testing.expectEqualStrings("abc", getWordAtText(4, null, text, 0).?.word);
    try std.testing.expect(getWordAtText(5, null, text, 0) == null);
}

test "wordHelper: windowed search finds words in long lines" {
    const allocator = std.testing.allocator;
    var text = ArrayList(u8).init(allocator);
    defer text.deinit();
    try text.appendNTimes(' ', 2000);
    try text.appendSlice("word");
    const line = text.items;

    const at_end = getWordAtText(2004, null, line, 0).?;
    try std.testing.expectEqualStrings("word", at_end.word);
    try std.testing.expectEqual(@as(usize, 2001), at_end.startColumn);
    try std.testing.expectEqual(@as(usize, 2005), at_end.endColumn);

    try std.testing.expect(getWordAtText(2000, null, line, 0) == null);
}

test "wordHelper: numbers and punctuation" {
    const text = "foo.bar 12.5 -x";
    try std.testing.expectEqualStrings("foo", getWordAtText(1, null, text, 0).?.word);
    try std.testing.expectEqualStrings("12.5", getWordAtText(9, null, text, 0).?.word);
    try std.testing.expectEqualStrings("x", getWordAtText(15, null, text, 0).?.word);
}

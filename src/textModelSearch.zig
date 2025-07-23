const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = std.unicode;
const WordCharacterClassifier = @import("wordCharacterClassifier.zig").WordCharacterClassifier;
const WordCharacterClass = @import("wordCharacterClassifier.zig").WordCharacterClass;
const RegExp = @import("RegExp.zig").RegExp;
const RegExpExecResult = @import("RegExp.zig").RegExpExecResult;
const strings = @import("strings.zig");
const safeUtf8Substring = @import("tui/utf8Helper.zig").safeUtf8Substring;
const DefaultWordSeparators = @import("wordCharacterClassifier.zig").DefaultWordSeparators;
const lastCodepoint = @import("tui/utf8Helper.zig").lastCodepoint;

const LIMIT_FIND_COUNT = 999;

fn leftIsWordBounday(wordSeparators: *const WordCharacterClassifier, text: []const u8, matchStartIndex: usize, matchLength: usize) bool {
    if (matchStartIndex == 0) {
        // Match starts at start of string
        return true;
    }

    const charBefore = lastCodepoint(text, matchStartIndex) catch {
        return true;
    };

    if (wordSeparators.get(charBefore) != WordCharacterClass.Regular) {
        // The character before the match is a word separator
        return true;
    }

    if (charBefore == '\r' or charBefore == '\n') {
        // The character before the match is line break or carriage return.
        return true;
    }

    if (matchLength > 0) {
        const firstCharInMatch = text[matchStartIndex];
        if (wordSeparators.get(firstCharInMatch) != WordCharacterClass.Regular) {
            // The first character inside the match is a word separator
            return true;
        }
    }

    return false;
}

fn rightIsWordBounday(wordSeparators: *const WordCharacterClassifier, text: []const u8, textLength: usize, matchStartIndex: usize, matchLength: usize) bool {
    if (matchStartIndex + matchLength == textLength) {
        // Match ends at end of string
        return true;
    }

    var iter = unicode.Utf8Iterator{
        .bytes = text,
        .i = matchStartIndex + matchLength,
    };

    const charAfter = iter.nextCodepoint() orelse {
        return true;
    };
    if (wordSeparators.get(charAfter) != WordCharacterClass.Regular) {
        // The character after the match is a word separator
        return true;
    }

    if (charAfter == '\r' or charAfter == '\n') {
        // The character after the match is line break or carriage return.
        return true;
    }

    if (matchLength > 0) {
        const lastCharInMatch = lastCodepoint(text, matchStartIndex + matchLength) catch {
            return true;
        };
        if (wordSeparators.get(lastCharInMatch) != WordCharacterClass.Regular) {
            // The last character in the match is a word separator
            return true;
        }
    }

    return false;
}

pub fn isValidMatch(wordSeparators: *const WordCharacterClassifier, text: []const u8, textLength: usize, matchStartIndex: usize, matchLength: usize) bool {
    return leftIsWordBounday(wordSeparators, text, matchStartIndex, matchLength) and rightIsWordBounday(wordSeparators, text, textLength, matchStartIndex, matchLength);
}

test "isValidMatch" {
    var wordSeparators = try WordCharacterClassifier.init(std.testing.allocator, DefaultWordSeparators);
    defer wordSeparators.deinit();
    try std.testing.expect(isValidMatch(&wordSeparators, "hello? world", 11, 0, 5));
    try std.testing.expect(!isValidMatch(&wordSeparators, "hello! world", 11, 1, 5));
}

pub const Searcher = struct {
    _wordSeparators: ?*WordCharacterClassifier,
    _searchRegex: *const RegExp,
    _prevMatchStartIndex: ?usize,
    _prevMatchLength: usize,

    pub fn init(wordSeparators: ?*WordCharacterClassifier, searchRegex: *const RegExp) Searcher {
        return Searcher{
            ._wordSeparators = wordSeparators,
            ._searchRegex = searchRegex,
            ._prevMatchStartIndex = null,
            ._prevMatchLength = 0,
        };
    }

    pub fn reset(self: *Searcher, lastIndex: usize) void {
        _ = lastIndex;
        self._prevMatchStartIndex = null;
        self._prevMatchLength = 0;
    }

    pub fn next(self: *Searcher, text: []const u8) ?RegExpExecResult {
        const textLength = text.len;

        var m: ?RegExpExecResult = null;
        while (true) {
            if (self._prevMatchStartIndex + self._prevMatchLength == textLength) {
                // Reached the end of the line
                return null;
            }

            m = self._searchRegex.exec(text);
            if (m == null) {
                return null;
            }

            const matchStartIndex = m.index;
            const matchLength = m.matches[0].len;
            if (matchStartIndex == self._prevMatchStartIndex and matchLength == self._prevMatchLength) {
                if (matchLength == 0) {
                    // the search result is an empty string and won't advance `regex.lastIndex`, so `regex.exec` will stuck here
                    // we attempt to recover from that by advancing by two if surrogate pair found and by one otherwise
                    const size = try strings.getNextCodePointSize(text, textLength, self._searchRegex.lastIndex);
                    self._searchRegex.lastIndex += size;
                    continue;
                }
                // Exit early if the regex matches the same range twice
                return null;
            }
            self._prevMatchStartIndex = matchStartIndex;
            self._prevMatchLength = matchLength;

            if (self._wordSeparators) |wordSeparators| {
                if (isValidMatch(wordSeparators, text, textLength, matchStartIndex, matchLength)) {
                    return m;
                }
            }

            if (m == null) {
                break;
            }
        }

        return null;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const unicode = std.unicode;
const WordCharacterClassifier = @import("wordCharacterClassifier.zig").WordCharacterClassifier;
const WordCharacterClass = @import("wordCharacterClassifier.zig").WordCharacterClass;
const RegExp = @import("RegExp.zig").RegExp;
const SearchResultIterator = @import("RegExp.zig").SearchResultIterator;
const RegExpExecResult = @import("RegExp.zig").RegExpExecResult;
const strings = @import("strings.zig");
const safeUtf8Substring = @import("tui/utf8Helper.zig").safeUtf8Substring;
const DefaultWordSeparators = @import("wordCharacterClassifier.zig").DefaultWordSeparators;
const lastCodepoint = @import("tui/utf8Helper.zig").lastCodepoint;
const SearchResult = @import("RegExp.zig").SearchResult;
const FindMatch = @import("model.zig").FindMatch;
const Range = @import("range.zig").Range;

const LIMIT_FIND_COUNT = 999;

pub fn createFindMatch(allocator: Allocator, range: Range, rawMatches: SearchResult, captureMatches: bool) !FindMatch {
    if (!captureMatches) {
        return FindMatch.init(range, null);
    }
    var matches = ArrayList([]const u8).init(allocator);
    for (0..rawMatches.numberOfGroups()) |i| {
        // FIXME: do we need to copy the string?
        try matches.append(rawMatches.groupN(i));
    }
    return FindMatch.init(range, try matches.toOwnedSlice());
}

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
    wordSeparators: ?*const WordCharacterClassifier,
    _iterator: SearchResultIterator,

    pub fn init(classifier: ?*const WordCharacterClassifier, searchRegex: *const RegExp, text: []const u8, start: usize) Searcher {
        return Searcher{
            .wordSeparators = classifier,
            ._iterator = searchRegex.searchIterator(text, start),
        };
    }

    pub fn reset(self: *Searcher, input: []const u8, offset: usize) void {
        self._iterator.reset(input, offset);
    }

    pub fn next(self: *Searcher) ?SearchResult {
        if (self.wordSeparators) |wordSeparators| {
            while (self._iterator.next()) |current| {
                if (isValidMatch(wordSeparators, self._iterator._input, self._iterator._input.len, current.index(), current.length())) {
                    return current;
                }
            }
            return null;
        } else {
            return self._iterator.next();
        }
    }
};

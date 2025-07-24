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
const DefaultWordSeparators = @import("wordCharacterClassifier.zig").DefaultWordSeparators;
const lastCodepoint = @import("tui/utf8Helper.zig").lastCodepoint;
const SearchResult = @import("RegExp.zig").SearchResult;
const FindMatch = @import("model.zig").FindMatch;
const Range = @import("range.zig").Range;
const SearchData = @import("model.zig").SearchData;
const getMapForWordSeparators = @import("wordCharacterClassifier.zig").getMapForWordSeparators;

const LIMIT_FIND_COUNT = 999;

pub const SearchParams = struct {
    searchString: []const u8,
    isRegex: bool,
    matchCase: bool,
    wordSeparators: ?[]const u8,

    pub fn init(searchString: []const u8, isRegex: bool, matchCase: bool, wordSeparators: ?[]const u8) SearchParams {
        return SearchParams{
            .searchString = searchString,
            .isRegex = isRegex,
            .matchCase = matchCase,
            .wordSeparators = wordSeparators,
        };
    }

    pub fn parseSearchRequest(self: *SearchParams, allocator: Allocator) !?SearchData {
        if (self.searchString.len == 0) {
            return null;
        }

        // Try to create a RegExp out of the params
        var multiline: bool = false;
        if (self.isRegex) {
            multiline = isMultilineRegexSource(self.searchString);
        } else {
            multiline = (std.mem.indexOf(u8, self.searchString, "\n") != null);
        }

        const regex: ?RegExp = strings.createRegExp(allocator, self.searchString, false, .{
            .ignore_case = self.matchCase,
            .multiline = multiline,
        }) catch null;

        if (regex == null) {
            return null;
        }

        var canUseSimpleSearch = (!self.isRegex and !multiline);
        if (canUseSimpleSearch and std.ascii.toLower(self.searchString) != std.ascii.toUpper(self.searchString)) {
            // casing might make a difference
            canUseSimpleSearch = self.matchCase;
        }

        const classifier = if (self.wordSeparators) |wordSeparators| try getMapForWordSeparators(allocator, wordSeparators) else null;
        const simpleSearch = if (canUseSimpleSearch) self.searchString else null;
        return SearchData.init(regex, classifier, simpleSearch);
    }
};

pub fn isMultilineRegexSource(searchString: []const u8) bool {
    if (searchString.len == 0) {
        return false;
    }

    const len = searchString.len;
    for (0..len) |i| {
        const chCode = searchString[i];

        if (chCode == '\n') {
            return true;
        }

        if (chCode == '\\') {

            // move to next char
            i += 1;

            if (i >= len) {
                // string ends with a \
                break;
            }

            const nextChCode = searchString[i];
            if (nextChCode == 'n' or nextChCode == 'r' or nextChCode == 'W') {
                return true;
            }
        }
    }

    return false;
}

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

pub const LineFeedCounter = struct {
    _lineFeedsOffsets: ArrayList(usize),

    pub fn init(allocator: Allocator, text: []const u8) LineFeedCounter {
        var lineFeedsOffsets = ArrayList(usize).init(allocator);
        for (0..text.len) |i| {
            if (text[i] == '\n') {
                try lineFeedsOffsets.append(i);
            }
        }
        return LineFeedCounter{
            ._lineFeedsOffsets = lineFeedsOffsets,
        };
    }

    pub fn deinit(self: *LineFeedCounter) void {
        self._lineFeedsOffsets.deinit();
    }

    pub fn findLineFeedCountBeforeOffset(self: *LineFeedCounter, offset: usize) usize {
        const lineFeedsOffsets = self._lineFeedsOffsets.items;
        if (lineFeedsOffsets.len == 0) {
            // no line feeds
            return 0;
        }

        var min: usize = 0;
        var max: usize = lineFeedsOffsets.len - 1;

        if (offset <= lineFeedsOffsets[0]) {
            // before first line feed
            return 0;
        }

        while (min < max) {
            const mid = min + ((max - min) / 2);

            if (lineFeedsOffsets[mid] >= offset) {
                max = mid - 1;
            } else {
                if (lineFeedsOffsets[mid + 1] >= offset) {
                    // bingo!
                    min = mid;
                    max = mid;
                } else {
                    min = mid + 1;
                }
            }
        }
        return min + 1;
    }
};

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

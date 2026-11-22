// Port of `src/vs/editor/common/model/textModelSearch.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const unicode = std.unicode;
const WordCharacterClassifier = @import("../core/wordCharacterClassifier.zig").WordCharacterClassifier;
const WordCharacterClass = @import("../core/wordCharacterClassifier.zig").WordCharacterClass;
const RegExp = @import("../../../../support/regexp.zig").RegExp;
const SearchResultIterator = @import("../../../../support/regexp.zig").SearchResultIterator;
const RegExpExecResult = @import("../../../../support/regexp.zig").RegExpExecResult;
const strings = @import("../../../base/common/strings.zig");
const DefaultWordSeparators = @import("../core/wordCharacterClassifier.zig").DefaultWordSeparators;
const lastCodepoint = @import("../../../base/common/strings.zig").lastCodepoint;
const SearchResult = @import("../../../../support/regexp.zig").SearchResult;
const FindMatch = @import("../model.zig").FindMatch;
const Range = @import("../core/range.zig").Range;
const SearchData = @import("../model.zig").SearchData;
const getMapForWordSeparators = @import("../core/wordCharacterClassifier.zig").getMapForWordSeparators;
const TextModel = @import("./textModel.zig").TextModel;
const Position = @import("../core/position.zig").Position;
const usizeAdd = @import("../../../base/common/utils.zig").usizeAdd;

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
            multiline = strings.containsLF(self.searchString);
        }

        const regex: ?RegExp = strings.createRegExp(allocator, self.searchString, self.isRegex, false, .{
            .ignore_case = !self.matchCase,
            .multiline = multiline,
        }) catch null;

        if (regex == null) {
            return null;
        }
        errdefer regex.?.deinit();

        var canUseSimpleSearch = (!self.isRegex and !multiline);
        if (canUseSimpleSearch and
            (strings.containsEnglishLetter(self.searchString) or !strings.isBasicASCII(self.searchString)))
        {
            // Casing might make a difference. Upstream disables simple search
            // for every cased character; non-ASCII text conservatively takes
            // the regex path so Unicode case folding matches.
            canUseSimpleSearch = self.matchCase;
        }

        const classifier = if (self.wordSeparators) |wordSeparators| try getMapForWordSeparators(allocator, wordSeparators) else null;
        const simpleSearch = if (canUseSimpleSearch) self.searchString else null;
        return SearchData.init(regex.?, classifier, simpleSearch);
    }
};

test "SearchParams" {
    const allocator = std.testing.allocator;
    var params = SearchParams.init("Hello", false, false, null);
    if (try params.parseSearchRequest(allocator)) |searchData| {
        try std.testing.expect(searchData.regex.isMatch("Hello"));
        try std.testing.expect(searchData.wordSeparators == null);
        try std.testing.expect(searchData.simpleSearch == null);
    } else {
        unreachable;
    }
}

test "SearchParams failed" {
    const allocator = std.testing.allocator;
    var params = SearchParams.init("(", true, false, null);
    try std.testing.expectEqual(null, try params.parseSearchRequest(allocator));
}

pub fn isMultilineRegexSource(searchString: []const u8) bool {
    if (searchString.len == 0) {
        return false;
    }

    const len = searchString.len;
    var i: usize = 0;
    while (i < len) : (i += 1) {
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

test "isMultilineRegexSource" {
    try std.testing.expect(!isMultilineRegexSource(""));
    try std.testing.expect(isMultilineRegexSource("1\n2\n"));
    try std.testing.expect(!isMultilineRegexSource("12"));
}

pub fn createFindMatch(allocator: Allocator, range: Range, rawMatches: SearchResult, captureMatches: bool) !FindMatch {
    if (!captureMatches) {
        return FindMatch.init(range, null);
    }
    var matches = ArrayList([]const u8).init(allocator);
    errdefer {
        for (matches.items) |match| allocator.free(match);
        matches.deinit();
    }
    for (0..rawMatches.numberOfGroups()) |i| {
        // The regex groups point into a transient line buffer. Copy them so the
        // find model can build replacement strings after the search returns.
        // A group that did not participate matches JS `undefined`, which the
        // replacement builder treats like the empty string.
        const group = rawMatches.groupNOrNull(i) orelse "";
        try matches.append(try allocator.dupe(u8, group));
    }
    return FindMatch.init(range, try matches.toOwnedSlice());
}

pub const LineFeedCounter = struct {
    _lineFeedsOffsets: ArrayList(usize),

    pub fn init(allocator: Allocator, text: []const u8) !LineFeedCounter {
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

    // offset is exclusive
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

test "LineFeedCounter" {
    var lineFeedCounter = try LineFeedCounter.init(std.testing.allocator, "1\n2\n");
    defer lineFeedCounter.deinit();
    try std.testing.expectEqual(0, lineFeedCounter.findLineFeedCountBeforeOffset(0));
    try std.testing.expectEqual(0, lineFeedCounter.findLineFeedCountBeforeOffset(1));
    try std.testing.expectEqual(1, lineFeedCounter.findLineFeedCountBeforeOffset(2));
    try std.testing.expectEqual(1, lineFeedCounter.findLineFeedCountBeforeOffset(3));
    try std.testing.expectEqual(2, lineFeedCounter.findLineFeedCountBeforeOffset(4));
    try std.testing.expectEqual(2, lineFeedCounter.findLineFeedCountBeforeOffset(100));
}

pub const TextModelSearch = struct {
    pub fn findMatches(model: *TextModel, searchParams: SearchParams, searchRange: Range, captureMatches: bool, limitResultCount: usize) !ArrayList(FindMatch) {
        const allocator = model.getAllocator();
        var params = searchParams;
        if (try params.parseSearchRequest(allocator)) |searchData| {
            defer searchData.regex.deinit();
            if (searchData.regex.options().multiline) {
                return _doFindMatchesMultiline(model, searchRange, Searcher.init(searchData.wordSeparators, &searchData.regex, "", 0), captureMatches, limitResultCount);
            }
            return _doFindMatchesLineByLine(model, searchRange, searchData, captureMatches, limitResultCount);
        }

        return ArrayList(FindMatch).init(allocator);
    }

    // Multiline search always executes on the lines concatenated with \n.
    // We must therefore compensate for the count of \n in case the model is CRLF
    fn _getMultilineMatchRange(model: *TextModel, deltaOffset: usize, text: []const u8, lfCounter: ?*LineFeedCounter, matchIndex: usize, match0: []const u8) !Range {
        _ = text;
        var startOffset: usize = undefined;
        var lineFeedCountBeforeMatch: usize = 0;
        if (lfCounter) |lf| {
            lineFeedCountBeforeMatch = lf.findLineFeedCountBeforeOffset(matchIndex);
            startOffset = deltaOffset + matchIndex + lineFeedCountBeforeMatch; // add as many \r as there were \n
        } else {
            startOffset = deltaOffset + matchIndex;
        }

        var endOffset: usize = undefined;
        if (lfCounter) |lf| {
            const lineFeedCountBeforeEndOfMatch = lf.findLineFeedCountBeforeOffset(matchIndex + match0.len);
            const lineFeedCountInMatch = lineFeedCountBeforeEndOfMatch - lineFeedCountBeforeMatch;
            endOffset = startOffset + match0.len + lineFeedCountInMatch; // add as many \r as there were \n
        } else {
            endOffset = startOffset + match0.len;
        }

        const startPosition = model.getPositionAt(startOffset);
        const endPosition = model.getPositionAt(endOffset);
        return Range.init(startPosition.lineNumber, startPosition.column, endPosition.lineNumber, endPosition.column);
    }

    /// JS `substring` clamps and swaps; callers can pass reversed or oversized
    /// ranges.
    fn sliceClamped(text: []const u8, start_: usize, end_: usize) []const u8 {
        var start = @min(start_, text.len);
        var end = @min(end_, text.len);
        if (start > end) std.mem.swap(usize, &start, &end);
        return text[start..end];
    }

    fn _doFindMatchesMultiline(model: *TextModel, searchRange: Range, searcher: Searcher, captureMatches: bool, limitResultCount: usize) !ArrayList(FindMatch) {
        const allocator = model.getAllocator();
        const deltaOffset = model.getOffsetAt(searchRange.getStartPosition());
        // We always execute multiline search over the lines joined with \n
        // This makes it that \n will match the EOL for both CRLF and LF models
        // We compensate for offset errors in `_getMultilineMatchRange`
        const value = try model.getValueInRange(searchRange, .LF);
        defer value.deinit();
        const text = value.items;
        var lf_counter: ?LineFeedCounter = if (model.getEOL() == .CRLF) try LineFeedCounter.init(allocator, text) else null;
        defer if (lf_counter) |*counter| counter.deinit();
        const lf_counter_ptr: ?*LineFeedCounter = if (lf_counter) |*counter| counter else null;

        var result = ArrayList(FindMatch).init(allocator);

        var local_searcher = searcher;
        local_searcher.reset(text, 0);
        while (local_searcher.next()) |m| {
            const matchRange = try _getMultilineMatchRange(model, deltaOffset, text, lf_counter_ptr, m.index(), m.groupN(0));
            try result.append(try createFindMatch(allocator, matchRange, m, captureMatches));
            if (result.items.len >= limitResultCount) {
                return result;
            }
        }

        return result;
    }

    fn _doFindMatchesLineByLine(model: *TextModel, searchRange: Range, searchData: SearchData, captureMatches: bool, limitResultCount: usize) !ArrayList(FindMatch) {
        const allocator = model.getAllocator();
        var result = ArrayList(FindMatch).init(allocator);

        // Early case for a search range that starts & stops on the same line number
        if (searchRange.startLineNumber == searchRange.endLineNumber) {
            const lineContent = try model.getLineContent(searchRange.startLineNumber);
            defer lineContent.deinit();
            const text = sliceClamped(lineContent.items, searchRange.startColumn - 1, searchRange.endColumn - 1);
            try _findMatchesInLine(searchData, text, searchRange.startLineNumber, searchRange.startColumn - 1, &result, captureMatches, limitResultCount);
            return result;
        }

        // Collect results from first line
        const lineContent = try model.getLineContent(searchRange.startLineNumber);
        defer lineContent.deinit();
        const text = sliceClamped(lineContent.items, searchRange.startColumn - 1, lineContent.items.len);
        try _findMatchesInLine(searchData, text, searchRange.startLineNumber, searchRange.startColumn - 1, &result, captureMatches, limitResultCount);

        // Collect results from middle lines
        for (searchRange.startLineNumber + 1..searchRange.endLineNumber) |lineNumber| {
            if (result.items.len >= limitResultCount) break;
            const text2 = try model.getLineContent(lineNumber);
            defer text2.deinit();
            try _findMatchesInLine(searchData, text2.items, lineNumber, 0, &result, captureMatches, limitResultCount);
        }

        // Collect results from last line
        if (result.items.len < limitResultCount) {
            const lineContent2 = try model.getLineContent(searchRange.endLineNumber);
            defer lineContent2.deinit();
            const text2 = lineContent2.items[0 .. searchRange.endColumn - 1];
            try _findMatchesInLine(searchData, text2, searchRange.endLineNumber, 0, &result, captureMatches, limitResultCount);
        }

        return result;
    }

    fn _findMatchesInLine(searchData: SearchData, text: []const u8, lineNumber: usize, deltaOffset: usize, result: *ArrayList(FindMatch), captureMatches: bool, limitResultCount: usize) !void {
        const wordSeparators = searchData.wordSeparators;
        if (!captureMatches and searchData.simpleSearch != null) {
            const searchString = searchData.simpleSearch.?;
            const searchStringLen = searchString.len;
            const textLength = text.len;

            var lastMatchIndex: usize = 0;
            while (true) {
                const match_index = std.mem.find(u8, text[lastMatchIndex..], searchString) orelse break;
                const absolute_match_index = lastMatchIndex + match_index;
                lastMatchIndex = absolute_match_index + searchStringLen;

                if (wordSeparators == null or isValidMatch(wordSeparators.?, text, textLength, absolute_match_index, searchStringLen)) {
                    try result.append(FindMatch.init(Range.init(lineNumber, absolute_match_index + 1 + deltaOffset, lineNumber, absolute_match_index + searchStringLen + 1 + deltaOffset), null));
                    if (result.items.len >= limitResultCount) {
                        return;
                    }
                }
            }
            return;
        }

        const allocator = result.allocator;
        var searcher = Searcher.init(searchData.wordSeparators, &searchData.regex, text, 0);
        // Reset regex to search from the beginning
        while (searcher.next()) |m| {
            const index = m.index();
            const mLength = m.length();
            try result.append(try createFindMatch(allocator, Range.init(lineNumber, index + 1 + deltaOffset, lineNumber, index + 1 + mLength + deltaOffset), m, captureMatches));
            if (result.items.len >= limitResultCount) {
                break;
            }
        }
        return;
    }

    pub fn findNextMatch(model: *TextModel, searchParams: SearchParams, searchStart: Position, captureMatches: bool) !?FindMatch {
        var params = searchParams;
        if (try params.parseSearchRequest(model.getAllocator())) |searchData| {
            defer searchData.regex.deinit();
            const searcher = Searcher.init(searchData.wordSeparators, &searchData.regex, "", 0);

            if (searchData.regex.options().multiline) {
                return _doFindNextMatchMultiline(model, searchStart, searcher, captureMatches);
            }
            return _doFindNextMatchLineByLine(model, searchStart, searcher, captureMatches);
        } else {
            return null;
        }
    }

    fn _doFindNextMatchMultiline(model: *TextModel, searchStart: Position, searcher: Searcher, captureMatches: bool) !?FindMatch {
        const allocator = model.getAllocator();
        const searchTextStart = Position.init(searchStart.lineNumber, 1);
        const deltaOffset = model.getOffsetAt(searchTextStart);
        const lineCount = model.getLineCount();
        // We always execute multiline search over the lines joined with \n
        // This makes it that \n will match the EOL for both CRLF and LF models
        // We compensate for offset errors in `_getMultilineMatchRange`
        const value = try model.getValueInRange(Range.init(searchTextStart.lineNumber, searchTextStart.column, lineCount, model.getLineMaxColumn(lineCount)), .LF);
        defer value.deinit();
        const text = value.items;
        var lf_counter: ?LineFeedCounter = if (model.getEOL() == .CRLF) try LineFeedCounter.init(allocator, text) else null;
        defer if (lf_counter) |*counter| counter.deinit();
        const lf_counter_ptr: ?*LineFeedCounter = if (lf_counter) |*counter| counter else null;
        var local_searcher = searcher;
        // Upstream starts scanning at the cursor column inside the joined text.
        local_searcher.reset(text, searchStart.column - 1);
        if (local_searcher.next()) |m| {
            return try createFindMatch(allocator, try _getMultilineMatchRange(model, deltaOffset, text, lf_counter_ptr, m.index(), m.groupN(0)), m, captureMatches);
        }

        if (searchStart.lineNumber != 1 or searchStart.column != 1) {
            // Try again from the top
            return _doFindNextMatchMultiline(model, Position.init(1, 1), searcher, captureMatches);
        }

        return null;
    }

    fn _doFindNextMatchLineByLine(model: *TextModel, searchStart: Position, searcher: Searcher, captureMatches: bool) !?FindMatch {
        const allocator = model.getAllocator();
        const lineCount = model.getLineCount();
        const startLineNumber = searchStart.lineNumber;

        // Look in first line
        const text = try model.getLineContent(startLineNumber);
        defer text.deinit();
        const r = try _findFirstMatchInLine(allocator, searcher, text.items, startLineNumber, searchStart.column, captureMatches);
        if (r != null) {
            return r;
        }

        for (1..lineCount + 1) |i| {
            const lineIndex = (startLineNumber + i - 1) % lineCount;
            const text2 = try model.getLineContent(lineIndex + 1);
            defer text2.deinit();
            const r2 = try _findFirstMatchInLine(allocator, searcher, text2.items, lineIndex + 1, 1, captureMatches);
            if (r2 != null) {
                return r2;
            }
        }

        return null;
    }

    fn _findFirstMatchInLine(allocator: Allocator, searcher: Searcher, text: []const u8, lineNumber: usize, fromColumn: usize, captureMatches: bool) !?FindMatch {
        // Set regex to search from column
        var local_searcher = searcher;
        local_searcher.reset(text, fromColumn - 1);
        if (local_searcher.next()) |m| {
            const index = m.index();
            const mLength = m.length();
            return try createFindMatch(allocator, Range.init(lineNumber, index + 1, lineNumber, index + 1 + mLength), m, captureMatches);
        }
        return null;
    }

    pub fn findPreviousMatch(model: *TextModel, searchParams: SearchParams, searchStart: Position, captureMatches: bool) !?FindMatch {
        var params = searchParams;
        if (try params.parseSearchRequest(model.getAllocator())) |searchData| {
            defer searchData.regex.deinit();
            const searcher = Searcher.init(searchData.wordSeparators, &searchData.regex, "", 0);

            if (searchData.regex.options().multiline) {
                return _doFindPreviousMatchMultiline(model, searchStart, searcher, captureMatches);
            }
            return _doFindPreviousMatchLineByLine(model, searchStart, searcher, captureMatches);
        } else {
            return null;
        }
    }

    fn _doFindPreviousMatchMultiline(model: *TextModel, searchStart: Position, searcher: Searcher, captureMatches: bool) !?FindMatch {
        const allocator = model.getAllocator();
        var matches = try _doFindMatchesMultiline(model, Range.init(1, 1, searchStart.lineNumber, searchStart.column), searcher, captureMatches, 10 * LIMIT_FIND_COUNT);
        if (matches.items.len > 0) {
            const result = matches.items[matches.items.len - 1];
            for (matches.items[0 .. matches.items.len - 1]) |match| match.free(allocator);
            matches.deinit();
            return result;
        }
        matches.deinit();

        const lineCount = model.getLineCount();
        if (searchStart.lineNumber != lineCount or searchStart.column != model.getLineMaxColumn(lineCount)) {
            // Try again with all content
            return _doFindPreviousMatchMultiline(model, Position.init(lineCount, model.getLineMaxColumn(lineCount)), searcher, captureMatches);
        }

        return null;
    }

    fn _doFindPreviousMatchLineByLine(model: *TextModel, searchStart: Position, searcher: Searcher, captureMatches: bool) !?FindMatch {
        const allocator = model.getAllocator();
        const lineCount = model.getLineCount();
        const startLineNumber = searchStart.lineNumber;

        // Look in first line
        const text_content = try model.getLineContent(startLineNumber);
        defer text_content.deinit();
        const text = text_content.items[0..@min(searchStart.column - 1, text_content.items.len)];
        const r = try _findLastMatchInLine(allocator, searcher, text, startLineNumber, captureMatches);
        if (r != null) {
            return r;
        }

        for (1..lineCount + 1) |i| {
            const lineIndex = (lineCount + startLineNumber - i - 1) % lineCount;
            const text2 = try model.getLineContent(lineIndex + 1);
            defer text2.deinit();
            const r2 = try _findLastMatchInLine(allocator, searcher, text2.items, lineIndex + 1, captureMatches);
            if (r2 != null) {
                return r2;
            }
        }

        return null;
    }

    fn _findLastMatchInLine(allocator: Allocator, searcher: Searcher, text: []const u8, lineNumber: usize, captureMatches: bool) !?FindMatch {
        var local_searcher = searcher;
        local_searcher.reset(text, 0);

        var lastMatch: ?SearchResult = null;
        while (local_searcher.next()) |m| {
            lastMatch = m;
        }

        if (lastMatch) |m| {
            const index = m.index();
            const mLength = m.length();
            return try createFindMatch(allocator, Range.init(lineNumber, index + 1, lineNumber, index + 1 + mLength), m, captureMatches);
        }

        return null;
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

    pub fn init(classifier: ?*const WordCharacterClassifier, searchRegex: *const RegExp, input: []const u8, start: usize) Searcher {
        return Searcher{
            .wordSeparators = classifier,
            ._iterator = searchRegex.searchIterator(input, start),
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

test "findMatches: regex matches do not overlap" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var test_model = try TestModel.init(allocator, "aaaa", "plaintext");
    defer test_model.deinit();

    var matches = try test_model.model.findMatches("aa", null, true, true, null, false, 100);
    defer {
        for (matches.items) |*match| match.free(allocator);
        matches.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 3), matches.items[0].range);
    try std.testing.expectEqualDeep(Range.init(1, 3, 1, 5), matches.items[1].range);
}

test "findMatches: optional capture groups are empty, not a panic" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var test_model = try TestModel.init(allocator, "bazbar", "plaintext");
    defer test_model.deinit();

    var matches = try test_model.model.findMatches("(foo)?bar", null, true, true, null, true, 100);
    defer {
        for (matches.items) |*match| match.free(allocator);
        matches.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expect(matches.items[0].matches != null);
    try std.testing.expectEqualStrings("", matches.items[0].matches.?[1]);
}

test "findNextMatch: multiline search starts at the cursor column" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var test_model = try TestModel.init(allocator, "foo bar foo bar", "plaintext");
    defer test_model.deinit();

    const first = (try test_model.model.findNextMatch("foo\\Wbar", Position.init(1, 1), true, true, null, false)).?;
    defer first.free(allocator);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 8), first.range);

    const second = (try test_model.model.findNextMatch("foo\\Wbar", Position.init(1, 8), true, true, null, false)).?;
    defer second.free(allocator);
    try std.testing.expectEqualDeep(Range.init(1, 9, 1, 16), second.range);
}

test "findPreviousMatch: multiline result owns no leaked matches" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var test_model = try TestModel.init(allocator, "a b a b", "plaintext");
    defer test_model.deinit();

    const match = (try test_model.model.findPreviousMatch("a\\Wb", Position.init(1, 8), true, true, null, false)).?;
    defer match.free(allocator);
    try std.testing.expectEqualDeep(Range.init(1, 5, 1, 8), match.range);
}

test "findMatches: case-insensitive non-ASCII uses the regex path" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var test_model = try TestModel.init(allocator, "\u{00C4}", "plaintext");
    defer test_model.deinit();

    var matches = try test_model.model.findMatches("\u{00E4}", null, false, false, null, false, 100);
    defer {
        for (matches.items) |*match| match.free(allocator);
        matches.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqualDeep(Range.init(1, 1, 1, 3), matches.items[0].range);
}

test "findMatchesLineByLine: reversed and oversized ranges do not panic" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;
    var test_model = try TestModel.init(allocator, "abcdef", "plaintext");
    defer test_model.deinit();

    var params = SearchParams.init("cd", false, true, null);
    const data = (try params.parseSearchRequest(allocator)).?;
    defer data.regex.deinit();

    // TextModelSearch's line-by-line path clamps reversed/oversized ranges like
    // JS substring.
    var reversed = try TextModelSearch.findMatches(test_model.model, SearchParams.init("cd", false, true, null), Range.init(1, 4, 1, 2), false, 10);
    defer reversed.deinit();

    var oversized = try TextModelSearch.findMatches(test_model.model, SearchParams.init("cd", false, true, null), Range.init(1, 2, 1, 99), false, 10);
    defer oversized.deinit();
    try std.testing.expectEqual(@as(usize, 1), oversized.items.len);
    try std.testing.expectEqualDeep(Range.init(1, 3, 1, 5), oversized.items[0].range);
}

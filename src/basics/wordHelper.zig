const std = @import("std");
const RegExp = @import("./RegExp.zig").RegExp;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const regex = @import("./RegExp.zig");
const SearchResult = @import("./RegExp.zig").SearchResult;
const usizeSub = @import("./utils.zig").usizeSub;
const WordAtPosition = @import("./utils.zig").WordAtPosition;

pub const USUAL_WORD_SEPARATORS = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?";

// Create a word definition regular expression based on default word separators.
// Optionally provide allowed separators that should be included in words.

// The default would look like this:
// /(-?\d*\.\d\w*)|([^\`\~\!\@\#\$\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\"\,\.\<\>\/\?\s]+)/g
pub fn createWordRegExp(_allowInWords: ?[]const u8) !RegExp {
    const allowInWords = _allowInWords orelse "";

    var items = [_]u8{0} ** 1024;
    var source = std.ArrayList(u8).initBuffer(&items);
    source.appendSliceAssumeCapacity("(-?\\d*\\.\\d\\w*)|([^");
    for (USUAL_WORD_SEPARATORS) |sep| {
        if (std.mem.indexOfScalar(u8, allowInWords, sep) != null) {
            continue;
        }
        source.appendAssumeCapacity('\\');
        source.appendAssumeCapacity(sep);
    }
    source.appendSliceAssumeCapacity("\\s]+)");
    return try RegExp.init(source.items, .{});
}

// catches numbers (including floating numbers) in the first group, and alphanum in the second
// pub var DEFAULT_WORD_REGEXP = createWordRegExp(null);

pub fn ensureValidWordDefinition(_wordDefinition: ?RegExp) !RegExp {
    const result = try createWordRegExp(null);

    // if (_wordDefinition) |wordDefinition| {
    //     if (!wordDefinition.global) {
    //         var flags: regex.Options = .{
    //             .singleline = true, // js regexes are singleline by default
    //         };
    //         if (wordDefinition.ignoreCase) {
    //             flags.ignore_case = true;
    //         }
    //         if (wordDefinition.multiline) {
    //             flags.singleline = false;
    //         }
    //         if (wordDefinition.unicode) {
    //             // flags += 'u';
    //             // FIXME: what is the 'u' flag in oniguruma?
    //             flags.word_is_ascii = false;
    //         }
    //         result = RegExp.init(wordDefinition.source, flags);
    //     } else {
    //         result = wordDefinition;
    //     }
    // }

    return _wordDefinition orelse result;
}

pub const IGetWordAtTextConfig = struct {
    maxLen: usize,
    windowSize: usize,
    timeBudget: i64,
};

const _defaultConfig = IGetWordAtTextConfig{
    .maxLen = 1000,
    .windowSize = 15,
    .timeBudget = 150,
};

pub fn getWordAtText(allocator: Allocator, column: usize, _wordDefinition: RegExp, text: []const u8, _textOffset: usize, _config: ?IGetWordAtTextConfig) !?WordAtPosition {
    var textOffset = _textOffset;
    // Ensure the regex has the 'g' flag, otherwise this will loop forever
    const wordDefinition = try ensureValidWordDefinition(_wordDefinition);
    const config = _config orelse _defaultConfig;

    if (text.len > config.maxLen) {
        // don't throw strings that long at the regexp
        // but use a sub-string in which a word must occur
        var start = column - config.maxLen / 2;
        if (start < 0) {
            start = 0;
        } else {
            textOffset += start;
        }
        return try getWordAtText(allocator, column, wordDefinition, text[start .. column + config.maxLen / 2], textOffset, config);
    }

    const t1 = std.time.milliTimestamp();
    const pos = column - 1 - textOffset;

    var prevRegexIndex: isize = -1;
    var match: ?SearchResult = null;

    for (1..10000000) |i| {
        // check time budget
        if (std.time.milliTimestamp() - t1 >= config.timeBudget) {
            break;
        }

        // reset the index at which the regexp should start matching, also know where it
        // should stop so that subsequent search don't repeat previous searches
        const regexIndex = usizeSub(pos, config.windowSize * i);
        const thisMatch = try _findRegexMatchEnclosingPosition(
            wordDefinition,
            @max(0, regexIndex),
            text,
            pos,
            prevRegexIndex,
        );

        if (thisMatch == null and match != null) {
            // stop: we have something
            break;
        }

        match = thisMatch;

        // stop: searched at start
        if (regexIndex <= 0) {
            break;
        }
        prevRegexIndex = regexIndex;
    }

    if (match) |m| {
        return WordAtPosition{
            .word = m.groupN(0),
            .startColumn = textOffset + 1 + m.index(),
            .endColumn = textOffset + 1 + m.index() + m.length(),
        };
    }

    return null;
}

fn _findRegexMatchEnclosingPosition(wordDefinition: RegExp, start: usize, text: []const u8, pos: usize, stopPos: isize) !?SearchResult {
    var iter = wordDefinition.searchIterator(text, start);
    while (true) {
        var match = iter.next();
        if (match == null) break;

        const matchIndex = match.?.index();
        if (matchIndex <= pos and iter._lastIndex >= pos) {
            return match;
        } else if (stopPos > 0 and @as(isize, @intCast(matchIndex)) > stopPos) {
            return null;
        }
    }
    return null;
}

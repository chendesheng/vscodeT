const std = @import("std");
const IAutoClosingPair = @import("../languageConfiguration.zig").IAutoClosingPair;
const StandardAutoClosingPairConditional = @import("../languageConfiguration.zig").StandardAutoClosingPairConditional;
const LanguageConfiguration = @import("../languageConfiguration.zig").LanguageConfiguration;

const DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_QUOTES: []const u8 = ";:.,=}])> \n\t";
const DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_BRACKETS: []const u8 = "'`\":.,=}])> \n\t";
const DEFAULT_AUTOCLOSE_BEFORE_WHITESPACE: []const u8 = " \n\t";

const Self = @This();

_autoClosingPairs: []StandardAutoClosingPairConditional,
_surroundingPairs: []IAutoClosingPair,
_autoCloseBeforeForQuotes: []const u8,
_autoCloseBeforeForBrackets: []const u8,

pub fn init(config: LanguageConfiguration) Self {
    var items = [_]StandardAutoClosingPairConditional{undefined} ** 100;
    var autoClosingPairs = std.ArrayList(StandardAutoClosingPairConditional).initBuffer(&items);
    if (config.autoClosingPairs) |autoClosingPairsConfig| {
        std.debug.assert(autoClosingPairsConfig.len < 100);

        for (autoClosingPairsConfig) |el| {
            autoClosingPairs.appendAssumeCapacity(StandardAutoClosingPairConditional.init(el));
        }
    } else if (config.brackets) |brackets| {
        std.debug.assert(brackets.len < 100);

        for (brackets) |b| {
            autoClosingPairs.appendAssumeCapacity(StandardAutoClosingPairConditional.init(.{ .open = b[0], .close = b[1], .notIn = null }));
        }
    }

    // if (config.__electricCharacterSupport) |electricCharacterSupport| {
    //     if (electricCharacterSupport.docComment) |docComment| {
    //         // IDocComment is legacy, only partially supported
    //         autoClosingPairs.appendAssumeCapacity(StandardAutoClosingPairConditional.init(.{
    //             .open = docComment.open,
    //             .close = docComment.close orelse "",
    //             .notIn = null,
    //         }));
    //     }
    // }

    return Self{
        ._autoClosingPairs = autoClosingPairs,
        ._surroundingPairs = config.surroundingPairs orelse autoClosingPairs.items,
        ._autoCloseBeforeForQuotes = config.autoCloseBefore orelse DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_QUOTES,
        ._autoCloseBeforeForBrackets = config.autoCloseBefore orelse DEFAULT_AUTOCLOSE_BEFORE_LANGUAGE_DEFINED_BRACKETS,
    };
}

pub fn getAutoClosingPairs(self: *Self) []StandardAutoClosingPairConditional {
    return self._autoClosingPairs;
}

pub fn getAutoCloseBeforeSet(self: *Self, forQuotes: bool) []const u8 {
    return if (forQuotes) self._autoCloseBeforeForQuotes else self._autoCloseBeforeForBrackets;
}

pub fn getSurroundingPairs(self: *Self) []IAutoClosingPair {
    return self._surroundingPairs;
}

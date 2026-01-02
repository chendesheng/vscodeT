const std = @import("std");
const RegExp = @import("./RegExp.zig").RegExp;
const regex = @import("./RegExp.zig");

pub const USUAL_WORD_SEPARATORS = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?";

// Word inside a model.
pub const IWordAtPosition = struct {
    // The word.
    word: []const u8,
    // The column where the word starts.
    startColumn: usize,
    // The column where the word ends.
    endColumn: usize,
};

// Create a word definition regular expression based on default word separators.
// Optionally provide allowed separators that should be included in words.

// The default would look like this:
// /(-?\d*\.\d\w*)|([^\`\~\!\@\#\$\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\"\,\.\<\>\/\?\s]+)/g
pub fn createWordRegExp(allowInWords: ?[]const u8) RegExp {
    const source = "(-?\\d*\\.\\d\\w*)|([^";
    for (USUAL_WORD_SEPARATORS) |sep| {
        if (allowInWords.indexOf(sep) >= 0) {
            continue;
        }
        source += '\\' + sep;
    }
    source += "\\s]+)";
    return RegExp.init(source);
}

// catches numbers (including floating numbers) in the first group, and alphanum in the second
pub const DEFAULT_WORD_REGEXP = createWordRegExp(null);

pub fn ensureValidWordDefinition(wordDefinition: ?RegExp) RegExp {
    var result: RegExp = DEFAULT_WORD_REGEXP;

    if (wordDefinition != null) {
        if (!wordDefinition.global) {
            var flags: regex.Options = .{
                .singleline = true, // js regexes are singleline by default
            };
            if (wordDefinition.ignoreCase) {
                flags.ignore_case = true;
            }
            if (wordDefinition.multiline) {
                flags.singleline = false;
            }
            if (wordDefinition.unicode) {
                // flags += 'u';
                // FIXME: what is the 'u' flag in oniguruma?
                flags.word_is_ascii = false;
            }
            result = RegExp.init(wordDefinition.source, flags);
        } else {
            result = wordDefinition;
        }
    }

    result.lastIndex = 0;

    return result;
}

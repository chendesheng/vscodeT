const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const RegExp = @import("../../../../support/regexp.zig").RegExp;

pub const LineCommentConfig = struct {
    // The line comment token, like `//`
    comment: []const u8,
    // Whether the comment token should not be indented and placed at the first column.
    // Defaults to false.
    noIndent: ?bool,
};

// Describes how comments for a language work.
pub const CommentRule = struct {
    // The line comment token, like `// this is a comment`.
    // Can be a string or an object with comment and optional noIndent properties.
    lineComment: ?LineCommentConfig,
    // The block comment character pair, like `/* block comment *&#47;`
    blockComment: ?CharacterPair,
};

// The language configuration interface defines the contract between extensions and
// various editor features, like automatic bracket insertion, automatic indentation etc.
pub const LanguageConfiguration = struct {
    // The language's comment settings.
    comments: ?CommentRule,
    // The language's brackets.
    // This configuration implicitly affects pressing Enter around these brackets.
    brackets: ?[]CharacterPair,
    // The language's word definition.
    // If the language supports Unicode identifiers (e.g. JavaScript), it is preferable
    // * to provide a word definition that uses exclusion of known separators.
    // * e.g.: A regex that matches anything except known separators (and dot is allowed to occur in a floating point number):
    //   /(-?\d*\.\d\w*)|([^\`\~\!\@\#\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\"\,\.\<\>\/\?\s]+)/g
    wordPattern: ?RegExp,
    // The language's indentation settings.
    indentationRules: ?IndentationRule,
    // The language's rules to be evaluated when pressing Enter.
    onEnterRules: ?[]OnEnterRule,
    // The language's auto closing pairs. The 'close' character is automatically inserted with the
    // 'open' character is typed. If not set, the configured brackets will be used.
    autoClosingPairs: ?[]IAutoClosingPairConditional,
    // The language's surrounding pairs. When the 'open' character is typed on a selection, the
    // selected string is surrounded by the open and close characters. If not set, the autoclosing pairs
    // settings will be used.
    surroundingPairs: ?[]IAutoClosingPair,
    // Defines a list of bracket pairs that are colorized depending on their nesting level.
    // If not set, the configured brackets will be used.
    colorizedBracketPairs: ?[]CharacterPair,
    // Defines what characters must be after the cursor for bracket or quote autoclosing to occur when using the \'languageDefined\' autoclosing setting.
    // This is typically the set of characters which can not start an expression, such as whitespace, closing brackets, non-unary operators, etc.
    autoCloseBefore: ?[]const u8,
    // The language's folding rules.
    folding: ?FoldingRules,

    // **Deprecated** Do not use.
    // @deprecated Will be replaced by a better API soon.
    // __electricCharacterSupport: ?struct {
    //     docComment: ?IDocComment,
    // },

    /// Frees the compiled regexes owned by a configuration. Plain slices
    /// (comment tokens, bracket pairs) stay owned by whoever allocated them,
    /// matching the upstream split between configuration data and its
    /// language-configuration service.
    pub fn deinit(self: *LanguageConfiguration) void {
        if (self.wordPattern) |*pattern| pattern.deinit();
        self.wordPattern = null;
        if (self.indentationRules) |*rules| {
            if (rules.decreaseIndentPattern) |*pattern| pattern.deinit();
            if (rules.increaseIndentPattern) |*pattern| pattern.deinit();
            if (rules.indentNextLinePattern) |*pattern| pattern.deinit();
            if (rules.unIndentedLinePattern) |*pattern| pattern.deinit();
            self.indentationRules = null;
        }
        if (self.onEnterRules) |rules| {
            for (rules) |*rule| {
                rule.beforeText.deinit();
                if (rule.afterText) |*pattern| pattern.deinit();
                if (rule.previousLineText) |*pattern| pattern.deinit();
            }
            self.onEnterRules = null;
        }
        if (self.folding) |*folding| {
            if (folding.markers) |*markers| {
                markers.start.deinit();
                markers.end.deinit();
            }
            self.folding = null;
        }
    }
};

// Describes indentation rules for a language.
pub const IndentationRule = struct {
    // If a line matches this pattern, then all the lines after it should be unindented once (until another rule matches).
    decreaseIndentPattern: ?RegExp,
    // If a line matches this pattern, then all the lines after it should be indented once (until another rule matches).
    increaseIndentPattern: ?RegExp,
    // If a line matches this pattern, then **only the next line** after it should be indented once.
    indentNextLinePattern: ?RegExp,
    // If a line matches this pattern, then its indentation should not be changed and it should not be evaluated against the other rules.
    unIndentedLinePattern: ?RegExp,
};

// Describes language specific folding markers such as '#region' and '#endregion'.
// The start and end regexes will be tested against the contents of all lines and must be designed efficiently:
// - the regex should start with '^'
// - regexp flags (i, g) are ignored
pub const FoldingMarkers = struct {
    start: RegExp,
    end: RegExp,
};

// Describes folding rules for a language.
pub const FoldingRules = struct {
    // Used by the indentation based strategy to decide whether empty lines belong to the previous or the next block.
    // A language adheres to the off-side rule if blocks in that language are expressed by their indentation.
    // See [wikipedia](https://en.wikipedia.org/wiki/Off-side_rule) for more information.
    // If not set, `false` is used and empty lines belong to the previous block.
    offSide: ?bool,
    // Region markers used by the language.
    markers: ?FoldingMarkers,
};

// Describes a rule to be evaluated when pressing Enter.
pub const OnEnterRule = struct {
    // This rule will only execute if the text before the cursor matches this regular expression.
    beforeText: RegExp,
    // This rule will only execute if the text after the cursor matches this regular expression.
    afterText: ?RegExp,
    // This rule will only execute if the text above the this line matches this regular expression.
    previousLineText: ?RegExp,
    // The action to execute.
    action: EnterAction,
};

// Definition of documentation comments (e.g. Javadoc/JSdoc)
pub const IDocComment = struct {
    // The string that starts a doc comment (e.g. '/**')
    open: []const u8,
    // The string that appears on the last line and closes the doc comment (e.g. ' * /').
    close: ?[]const u8,
};

// A tuple of two characters, like a pair of
// opening and closing brackets.
pub const CharacterPair = [2][]const u8;

pub const IAutoClosingPair = struct {
    open: []const u8,
    close: []const u8,
};

pub const IAutoClosingPairConditional = struct {
    open: []const u8,
    close: []const u8,
    notIn: ?[]const []const u8,
};

// Describes what to do with the indentation when pressing Enter.
pub const IndentAction = enum(u2) {
    // Insert new line and copy the previous line's indentation.
    None = 0,
    // Insert new line and indent once (relative to the previous line's indentation).
    Indent = 1,
    // Insert two new lines:
    //  - the first one indented which will hold the cursor
    //  - the second one at the same indentation level
    IndentOutdent = 2,
    // Insert new line and outdent once (relative to the previous line's indentation).
    Outdent = 3,
};

// Describes what to do when pressing Enter.
pub const EnterAction = struct {
    // Describe what to do with the indentation.
    indentAction: IndentAction,
    // Describes text to be appended after the new line and after the indentation.
    appendText: ?[]const u8,
    // Describes the number of characters to remove from the new line's indentation.
    removeText: ?usize,
};

// @internal
pub const CompleteEnterAction = struct {
    // Describe what to do with the indentation.
    indentAction: IndentAction,
    // Describes text to be appended after the new line and after the indentation.
    appendText: []u8,
    // Describes the number of characters to remove from the new line's indentation.
    removeText: usize,
    // The line's indentation minus removeText
    indentation: []const u8,
};

// @internal
pub const StandardAutoClosingPairConditional = struct {
    open: []const u8,
    close: []const u8,
    _inString: bool,
    _inComment: bool,
    _inRegEx: bool,
    neutralCharacter: ?[]const u8,
    neutralCharacterSearched: bool,

    pub fn init(source: IAutoClosingPairConditional) StandardAutoClosingPairConditional {
        // initially allowed in all tokens
        var self = StandardAutoClosingPairConditional{
            .open = source.open,
            .close = source.close,
            ._inString = true,
            ._inComment = true,
            ._inRegEx = true,
            .neutralCharacter = null,
            .neutralCharacterSearched = false,
        };

        if (source.notIn) |not_in| {
            for (not_in) |notIn| {
                if (std.mem.eql(u8, notIn, "string")) {
                    self._inString = false;
                } else if (std.mem.eql(u8, notIn, "comment")) {
                    self._inComment = false;
                } else if (std.mem.eql(u8, notIn, "regex")) {
                    self._inRegEx = false;
                }
            }
        }
        return self;
    }

    pub fn isOK(self: *const StandardAutoClosingPairConditional, standardToken: StandardTokenType) bool {
        switch (standardToken) {
            StandardTokenType.Other => return true,
            StandardTokenType.Comment => return self._inComment,
            StandardTokenType.String => return self._inString,
            StandardTokenType.RegEx => return self._inRegEx,
        }
    }

    // pub fn shouldAutoClose(self: *StandardAutoClosingPairConditional, context: ScopedLineTokens, column: usize) bool {
    //     // Always complete on empty line
    //     if (context.getTokenCount() == 0) {
    //         return true;
    //     }

    //     const tokenIndex = context.findTokenIndexAtOffset(column - 2);
    //     const standardTokenType = context.getStandardTokenType(tokenIndex);
    //     return self.isOK(standardTokenType);
    // }

    fn _findNeutralCharacterInRange(self: *StandardAutoClosingPairConditional, fromCharCode: u8, toCharCode: u8) ?[]const u8 {
        for (fromCharCode..toCharCode) |charCode| {
            const character = std.fmt.asBytes(charCode);
            if (std.mem.indexOf(u8, self.open, character) != null and std.mem.indexOf(u8, self.close, character) != null) {
                return character;
            }
        }
        return null;
    }

    // Find a character in the range [0-9a-zA-Z] that does not appear in the open or close
    pub fn findNeutralCharacter(self: *StandardAutoClosingPairConditional) ?[]const u8 {
        if (!self._neutralCharacterSearched) {
            self._neutralCharacterSearched = true;
            if (!self._neutralCharacter) {
                self._neutralCharacter = self._findNeutralCharacterInRange('0', '9');
            }
            if (!self._neutralCharacter) {
                self._neutralCharacter = self._findNeutralCharacterInRange('a', 'z');
            }
            if (!self._neutralCharacter) {
                self._neutralCharacter = self._findNeutralCharacterInRange('A', 'Z');
            }
        }
        return self._neutralCharacter;
    }
};

// @internal
pub const AutoClosingPairs = struct {
    // it is useful to be able to get pairs using either end of open and close

    // Key is first character of open
    autoClosingPairsOpenByStart: StringHashMap([]StandardAutoClosingPairConditional),
    // Key is last character of open
    autoClosingPairsOpenByEnd: StringHashMap([]StandardAutoClosingPairConditional),
    // Key is first character of close
    autoClosingPairsCloseByStart: StringHashMap([]StandardAutoClosingPairConditional),
    // Key is last character of close
    autoClosingPairsCloseByEnd: StringHashMap([]StandardAutoClosingPairConditional),
    // Key is close. Only has pairs that are a single character
    autoClosingPairsCloseSingleChar: StringHashMap([]StandardAutoClosingPairConditional),

    pub fn init(allocator: Allocator, autoClosingPairs: []StandardAutoClosingPairConditional) AutoClosingPairs {
        var autoClosingPairsOpenByStart = StringHashMap([]StandardAutoClosingPairConditional).init(allocator);
        var autoClosingPairsOpenByEnd = StringHashMap([]StandardAutoClosingPairConditional).init(allocator);
        var autoClosingPairsCloseByStart = StringHashMap([]StandardAutoClosingPairConditional).init(allocator);
        var autoClosingPairsCloseByEnd = StringHashMap([]StandardAutoClosingPairConditional).init(allocator);
        var autoClosingPairsCloseSingleChar = StringHashMap([]StandardAutoClosingPairConditional).init(allocator);

        for (autoClosingPairs) |pair| {
            appendEntry(&autoClosingPairsOpenByStart, pair.open[0], pair);
            appendEntry(&autoClosingPairsOpenByEnd, pair.open[pair.open.len - 1], pair);
            appendEntry(&autoClosingPairsCloseByStart, pair.close[0], pair);
            appendEntry(&autoClosingPairsCloseByEnd, pair.close[pair.close.len - 1], pair);
            if (pair.close.len == 1 and pair.open.len == 1) {
                appendEntry(&autoClosingPairsCloseSingleChar, pair.close, pair);
            }
        }
        return .{
            .autoClosingPairsOpenByStart = autoClosingPairsOpenByStart,
            .autoClosingPairsOpenByEnd = autoClosingPairsOpenByEnd,
            .autoClosingPairsCloseByStart = autoClosingPairsCloseByStart,
            .autoClosingPairsCloseByEnd = autoClosingPairsCloseByEnd,
            .autoClosingPairsCloseSingleChar = autoClosingPairsCloseSingleChar,
        };
    }
};

fn appendEntry(target: *StringHashMap([]StandardAutoClosingPairConditional), key: []const u8, value: StandardAutoClosingPairConditional) void {
    if (target.get(key)) |values| {
        try values.append(value);
    } else {
        target.put(key, &[_]StandardAutoClosingPairConditional{value}) catch unreachable;
    }
}

pub fn empty() LanguageConfiguration {
    return .{
        .comments = null,
        .brackets = null,
        .wordPattern = null,
        .indentationRules = null,
        .onEnterRules = null,
        .autoClosingPairs = null,
        .surroundingPairs = null,
        .colorizedBracketPairs = null,
        .autoCloseBefore = null,
        .folding = null,
    };
}

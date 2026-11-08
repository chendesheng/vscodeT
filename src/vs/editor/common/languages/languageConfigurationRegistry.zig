const std = @import("std");
const Allocator = std.mem.Allocator;
const RegExp = @import("../../../../support/regexp.zig").RegExp;
const LanguageConfiguration = @import("./languageConfiguration.zig").LanguageConfiguration;
const CharacterPairSupport = @import("./supports/characterPair.zig");
const IndentRulesSupport = @import("./supports/indentRules.zig").IndentRulesSupport;
const IndentationRule = @import("./languageConfiguration.zig").IndentationRule;
const FoldingRules = @import("./languageConfiguration.zig").FoldingRules;
const LanguageBracketsConfiguration = @import("./supports/languageBracketsConfiguration.zig").LanguageBracketsConfiguration;
const ensureValidWordDefinition = @import("../core/wordHelper.zig").ensureValidWordDefinition;
const defaultWordRegExp = @import("../core/wordHelper.zig").defaultWordRegExp;
const EditorAutoIndentStrategy = @import("../config/editorOptions.zig").EditorAutoIndentStrategy;
const EnterAction = @import("./languageConfiguration.zig").EnterAction;
const AutoClosingPairs = @import("./languageConfiguration.zig").AutoClosingPairs;
const IAutoClosingPair = @import("./languageConfiguration.zig").IAutoClosingPair;

// Interface used to support insertion of mode specific comments.
pub const ICommentsConfiguration = struct {
    lineCommentToken: ?[]const u8 = null,
    lineCommentNoIndent: ?bool = null,
    blockCommentStartToken: ?[]const u8 = null,
    blockCommentEndToken: ?[]const u8 = null,
};

pub const ILanguageConfigurationService = struct {
    onDidChange: *const fn (LanguageConfigurationServiceChangeEvent) void,
    // @param priority Use a higher number for higher priority
    register: *const fn (languageId: []const u8, configuration: LanguageConfiguration, priority: ?usize) void,
    getLanguageConfiguration: *const fn (languageId: []const u8) ResolvedLanguageConfiguration,
};

pub const LanguageConfigurationServiceChangeEvent = struct {
    languageId: ?[]const u8,

    pub fn affects(self: *LanguageConfigurationServiceChangeEvent, languageId: []const u8) bool {
        if (self.languageId) |id| {
            return std.mem.eql(u8, id, languageId);
        }
        return true;
    }
};

pub const ResolvedLanguageConfiguration = struct {
    // _brackets: ?RichEditBrackets,
    // _electricCharacter: ?BracketElectricCharacterSupport,
    // _onEnterSupport: ?OnEnterSupport,

    comments: ?ICommentsConfiguration,
    characterPair: CharacterPairSupport,
    wordDefinition: RegExp,
    indentRulesSupport: ?IndentRulesSupport,
    indentationRules: ?IndentationRule,
    foldingRules: FoldingRules,
    bracketsNew: LanguageBracketsConfiguration,
    languageId: []const u8,
    underlyingConfig: LanguageConfiguration,

    pub fn init(allocator: Allocator, languageId: []const u8, underlyingConfig: LanguageConfiguration) !ResolvedLanguageConfiguration {
        //this._onEnterSupport =
        //    underlyingConfig.brackets or
        //    underlyingConfig.indentationRules or
        //    if (underlyingConfig.onEnterRules) OnEnterSupport.init(underlyingConfig) else null;

        return .{
            .languageId = languageId,
            .underlyingConfig = underlyingConfig,
            .comments = ResolvedLanguageConfiguration._handleComments(underlyingConfig),
            .characterPair = try CharacterPairSupport.init(underlyingConfig),
            .wordDefinition = underlyingConfig.wordPattern orelse defaultWordRegExp(),
            .indentationRules = underlyingConfig.indentationRules,
            .indentRulesSupport = if (underlyingConfig.indentationRules) |rules| IndentRulesSupport.init(rules) else null,
            .foldingRules = underlyingConfig.folding orelse .{ .offSide = null, .markers = null },
            .bracketsNew = try LanguageBracketsConfiguration.init(allocator, languageId, underlyingConfig),
        };
    }

    pub fn getWordDefinition(self: *ResolvedLanguageConfiguration) RegExp {
        return ensureValidWordDefinition(self.wordDefinition);
    }

    // TODO: Implement this
    // pub fn getBrackets(self: *ResolvedLanguageConfiguration) ?RichEditBrackets {
    //     if (!self._brackets and self.underlyingConfig.brackets) {
    //         self._brackets = RichEditBrackets.init(self.languageId, self.underlyingConfig.brackets);
    //     }
    //     return self._brackets;
    // }

    // pub fn getElectricCharacter(self: *ResolvedLanguageConfiguration) ?BracketElectricCharacterSupport {
    //     if (!self._electricCharacter) {
    //         self._electricCharacter = BracketElectricCharacterSupport.init(self.brackets);
    //     }
    //     return self._electricCharacter;
    // }

    pub fn onEnter(autoIndent: EditorAutoIndentStrategy, previousLineText: []const u8, beforeEnterText: []const u8, afterEnterText: []const u8) ?EnterAction {
        _ = autoIndent;
        _ = previousLineText;
        _ = beforeEnterText;
        _ = afterEnterText;
        return null;
        // TODO: Implement this
        // if (!self._onEnterSupport) {
        //     return null;
        // }
        // return self._onEnterSupport.onEnter(autoIndent, previousLineText, beforeEnterText, afterEnterText);
    }

    pub fn getAutoClosingPairs(self: *ResolvedLanguageConfiguration) AutoClosingPairs {
        return AutoClosingPairs.init(self.characterPair.getAutoClosingPairs());
    }

    pub fn getAutoCloseBeforeSet(self: *ResolvedLanguageConfiguration, forQuotes: bool) []const u8 {
        return self.characterPair.getAutoCloseBeforeSet(forQuotes);
    }

    pub fn getSurroundingPairs(self: *ResolvedLanguageConfiguration) []IAutoClosingPair {
        return self.characterPair.getSurroundingPairs();
    }

    pub fn _handleComments(config: LanguageConfiguration) ?ICommentsConfiguration {
        const comment_rule = config.comments orelse return null;

        var comments: ICommentsConfiguration = .{};
        if (comment_rule.lineComment) |line_comment| {
            comments.lineCommentToken = line_comment.comment;
            comments.lineCommentNoIndent = line_comment.noIndent;
        }
        if (comment_rule.blockComment) |block_comment| {
            comments.blockCommentStartToken = block_comment[0];
            comments.blockCommentEndToken = block_comment[1];
        }
        return comments;
    }
};

/// Returns the indentation that precedes the given position.
pub fn getIndentationAtPosition(allocator: Allocator, model: *@import("../model/textModel.zig").TextModel, lineNumber: usize, column: usize) ![]u8 {
    const line_text = try model.getLineContent(lineNumber);
    defer line_text.deinit();
    return getIndentationAtColumn(allocator, line_text.items, column);
}

fn getIndentationAtColumn(allocator: Allocator, lineText: []const u8, column: usize) ![]u8 {
    const end = @min(column -| 1, lineText.len);
    var start = end;
    while (start > 0 and (lineText[start - 1] == ' ' or lineText[start - 1] == '\t')) {
        start -= 1;
    }
    return allocator.dupe(u8, lineText[start..end]);
}

const std = @import("std");
const RegExp = @import("../basics/RegExp.zig").RegExp;
const LanguageConfiguration = @import("./languageConfiguration.zig").LanguageConfiguration;
const CharacterPairSupport = @import("./supports/characterPair.zig");
const IndentRulesSupport = @import("./supports/indentRules.zig").IndentRulesSupport;
const IndentationRule = @import("./languageConfiguration.zig").IndentationRule;
const FoldingRules = @import("./languageConfiguration.zig").FoldingRules;
const LanguageBracketsConfiguration = @import("./supports/languageBracketsConfiguration.zig").LanguageBracketsConfiguration;
const ensureValidWordDefinition = @import("../basics/wordHelper.zig").ensureValidWordDefinition;
const defaultWordRegExp = @import("../basics/wordHelper.zig").defaultWordRegExp;
const EditorAutoIndentStrategy = @import("../editorOptions.zig").EditorAutoIndentStrategy;
const EnterAction = @import("./languageConfiguration.zig").EnterAction;
const AutoClosingPairs = @import("./languageConfiguration.zig").AutoClosingPairs;
const IAutoClosingPair = @import("./languageConfiguration.zig").IAutoClosingPair;

// Interface used to support insertion of mode specific comments.
pub const ICommentsConfiguration = struct {
    lineCommentToken: ?[]const u8,
    lineCommentNoIndent: ?bool,
    blockCommentStartToken: ?[]const u8,
    blockCommentEndToken: ?[]const u8,
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

    pub fn init(languageId: []const u8, underlyingConfig: LanguageConfiguration) ResolvedLanguageConfiguration {
        //this._onEnterSupport =
        //    underlyingConfig.brackets or
        //    underlyingConfig.indentationRules or
        //    if (underlyingConfig.onEnterRules) OnEnterSupport.init(underlyingConfig) else null;

        return .{
            .languageId = languageId,
            .underlyingConfig = underlyingConfig,
            ._brackets = null,
            ._electricCharacter = null,
            ._onEnterSupport = null,
            .comments = ResolvedLanguageConfiguration._handleComments(underlyingConfig),
            .characterPair = CharacterPairSupport.init(underlyingConfig),
            .wordDefinition = underlyingConfig.wordPattern orelse defaultWordRegExp(),
            .indentationRules = underlyingConfig.indentationRules,
            .indentRulesSupport = if (underlyingConfig.indentationRules) IndentRulesSupport.init(underlyingConfig.indentationRules) else null,
            .foldingRules = underlyingConfig.folding orelse .{},
            .bracketsNew = LanguageBracketsConfiguration.init(languageId, underlyingConfig),
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

    pub fn _handleComments(self: *ResolvedLanguageConfiguration) ?ICommentsConfiguration {
        if (self.underlyingConfig.comments) |commentRule| {

            // comment configuration
            const comments: ICommentsConfiguration = {};

            if (commentRule.lineComment) |lineComment| {
                if (std.mem.eql(u8, lineComment, "string")) {
                    comments.lineCommentToken = lineComment;
                } else {
                    comments.lineCommentToken = lineComment.comment;
                    comments.lineCommentNoIndent = lineComment.noIndent;
                }
            }
            if (commentRule.blockComment) |comment| {
                comments.blockCommentStartToken = comment[0];
                comments.blockCommentEndToken = comment[1];
            }

            return comments;
        } else {
            return null;
        }
    }
};

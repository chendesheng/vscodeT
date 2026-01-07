const std = @import("std");
const RegExp = @import("../basics/RegExp.zig").RegExp;
const LanguageConfiguration = @import("./languageConfiguration.zig").LanguageConfiguration;
const CharacterPairSupport = @import("./supports/characterPair.zig");
const IndentRulesSupport = @import("./supports/indentRules.zig").IndentRulesSupport;
const IndentationRule = @import("./languageConfiguration.zig").IndentationRule;
const FoldingRules = @import("./languageConfiguration.zig").FoldingRules;
const LanguageBracketsConfiguration = @import("./supports/languageBracketsConfiguration.zig").LanguageBracketsConfiguration;
const ensureValidWordDefinition = @import("../basics/wordHelper.zig").ensureValidWordDefinition;
const DEFAULT_WORD_REGEXP = @import("../basics/wordHelper.zig").DEFAULT_WORD_REGEXP;
const EditorAutoIndentStrategy = @import("../editorOptions.zig").EditorAutoIndentStrategy;
const EnterAction = @import("./languageConfiguration.zig").EnterAction;
const AutoClosingPairs = @import("./languageConfiguration.zig").AutoClosingPairs;
const IAutoClosingPair = @import("./languageConfiguration.zig").IAutoClosingPair;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const Emitter = @import("../basics/event.zig").Emitter;
const PLAINTEXT_LANGUAGE_ID = @import("../services/languageRegistry.zig").PLAINTEXT_LANGUAGE_ID;
const CharacterPair = @import("./languageConfiguration.zig").CharacterPair;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const strings = @import("../basics/strings.zig");
const IConfigurationService = @import("./configuration.zig").IConfigurationService;
const Set = @import("../basics/Set.zig").Set;
const ILanguageService = @import("./language.zig").ILanguageService;

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

pub const LanguageConfigurationService = struct {
    // _serviceBrand: undefined,

    _registry: LanguageConfigurationRegistry, // = this._register(new LanguageConfigurationRegistry());

    onDidChangeEmitter: Emitter(LanguageConfigurationServiceChangeEvent),

    configurations: StringHashMap(ResolvedLanguageConfiguration), // = new Map<string, ResolvedLanguageConfiguration>();

    pub fn init(configurationService: IConfigurationService, languageService: ILanguageService) LanguageConfigurationService {
        _ = configurationService;
        _ = languageService;

        // const languageConfigKeys = Set.init(Object.values(customizedLanguageConfigKeys));

        // self._register(self.configurationService.onDidChangeConfiguration((e) => {
        // const globalConfigChanged = e.change.keys.some((k) =>
        //languageConfigKeys.has(k)
        //);
        //const localConfigChanged = e.change.overrides
        //.filter(([overrideLangName, keys]) =>
        //keys.some((k) => languageConfigKeys.has(k))
        //)
        //.map(([overrideLangName]) => overrideLangName);

        //if (globalConfigChanged) {
        //self.configurations.clear();
        //self.onDidChangeEmitter.fire(new LanguageConfigurationServiceChangeEvent(undefined));
        //} else {
        //for (const languageId of localConfigChanged) {
        //if (self.languageService.isRegisteredLanguageId(languageId)) {
        //self.configurations.delete(languageId);
        //self.onDidChangeEmitter.fire(new LanguageConfigurationServiceChangeEvent(languageId));
        //}
        //}
        //}
        //}));

        // self._register(self._registry.onDidChange((e) => {
        //self.configurations.delete(e.languageId);
        //self.onDidChangeEmitter.fire(new LanguageConfigurationServiceChangeEvent(e.languageId));
        // }));

        return .{
            ._registry = undefined,
            .configurations = undefined,
            .onDidChangeEmitter = undefined,
        };
    }

    pub fn register(self: *LanguageConfigurationService, languageId: []const u8, configuration: LanguageConfiguration, priority: ?usize) !void {
        return self._registry.register(languageId, configuration, priority);
    }

    pub fn getLanguageConfiguration(self: *LanguageConfigurationService, languageId: []const u8) ResolvedLanguageConfiguration {
        var result = self.configurations.get(languageId);
        if (!result) {
            result = computeConfig(languageId, self._registry, self.configurationService, self.languageService);
            self.configurations.set(languageId, result);
        }
        return result;
    }
};

fn computeConfig(
    languageId: []const u8,
    registry: LanguageConfigurationRegistry,
    configurationService: IConfigurationService,
    languageService: ILanguageService,
) ResolvedLanguageConfiguration {
    var languageConfig = registry.getLanguageConfiguration(languageId);

    if (languageConfig == null) {
        if (!languageService.isRegisteredLanguageId(languageId)) {
            // this happens for the null language, which can be returned by monarch.
            // Instead of throwing an error, we just return a default config.
            return ResolvedLanguageConfiguration.init(languageId, .{});
        }
        languageConfig = ResolvedLanguageConfiguration.init(languageId, .{});
    }

    const customizedConfig = getCustomizedLanguageConfig(languageConfig.languageId, configurationService);
    const data = combineLanguageConfigurations(&[_]LanguageConfiguration{ languageConfig.underlyingConfig, customizedConfig });
    const config = ResolvedLanguageConfiguration.init(languageConfig.languageId, data);
    return config;
}

const customizedLanguageConfigKeys = struct {
    const brackets = "editor.language.brackets";
    const colorizedBracketPairs = "editor.language.colorizedBracketPairs";
};

fn getCustomizedLanguageConfig(languageId: []const u8, configurationService: IConfigurationService) LanguageConfiguration {
    _ = languageId;
    _ = configurationService;
    // const brackets = configurationService.getValue(customizedLanguageConfigKeys.brackets, {
    //overrideIdentifier: languageId,
    // });

    // const colorizedBracketPairs = configurationService.getValue(customizedLanguageConfigKeys.colorizedBracketPairs, {
    //overrideIdentifier: languageId,
    // });
    return .{};
}

// fn validateBracketPairs(data: unknown) ![]CharacterPair {
// if (!Array.isArray(data)) {
//return undefined;
// }
// return data.map(pair => {
//if (!Array.isArray(pair) || pair.length !== 2) {
//return undefined;
//}
//return [pair[0], pair[1]] as CharacterPair;
//}).filter((p): p is CharacterPair => !!p);
// return undefined;
// }

pub fn getIndentationAtPosition(model: *TextModel, lineNumber: usize, column: usize) ![]const u8 {
    const lineText = try model.getLineContent(lineNumber);
    var indentation = strings.getLeadingWhitespace(lineText, null, null);
    if (indentation.len > column - 1) {
        indentation = indentation[0 .. column - 1];
    }
    return indentation;
}

const ComposedLanguageConfiguration = struct {
    _entries: ArrayList(LanguageConfigurationContribution),
    _order: usize,
    _resolved: ?ResolvedLanguageConfiguration,

    languageId: []const u8,

    pub fn init(allocator: Allocator, languageId: []const u8) ComposedLanguageConfiguration {
        return ComposedLanguageConfiguration{
            ._entries = ArrayList(LanguageConfigurationContribution).init(allocator),
            ._order = 0,
            ._resolved = null,
            .languageId = languageId,
        };
    }

    pub fn register(self: *ComposedLanguageConfiguration, configuration: LanguageConfiguration, priority: usize) !void {
        self._order += 1;
        const entry = LanguageConfigurationContribution{
            configuration,
            priority,
            self._order,
        };
        try self._entries.append(entry);
        self._resolved = null;
    }

    pub fn getResolvedConfiguration(self: *ComposedLanguageConfiguration) ?ResolvedLanguageConfiguration {
        if (self._resolved == null) {
            const config = self._resolve();
            if (config) {
                self._resolved = ResolvedLanguageConfiguration.init(self.languageId, config);
            }
        }
        return self._resolved;
    }

    fn _resolve(self: *ComposedLanguageConfiguration) ?LanguageConfiguration {
        if (self._entries.len == 0) {
            return null;
        }
        std.sort.sort(LanguageConfigurationContribution, self._entries.items, {}, LanguageConfigurationContribution.lessThan);
        return combineLanguageConfigurations(self._entries.items);
    }
};

fn combineLanguageConfigurations(configs: []const LanguageConfiguration) LanguageConfiguration {
    var result: LanguageConfiguration = .{};
    for (configs) |entry| {
        result.comments = entry.comments orelse result.comments;
        result.brackets = entry.brackets orelse result.brackets;
        result.wordPattern = entry.wordPattern orelse result.wordPattern;
        result.indentationRules = entry.indentationRules orelse result.indentationRules;
        result.onEnterRules = entry.onEnterRules orelse result.onEnterRules;
        result.autoClosingPairs = entry.autoClosingPairs orelse result.autoClosingPairs;
        result.surroundingPairs = entry.surroundingPairs orelse result.surroundingPairs;
        result.autoCloseBefore = entry.autoCloseBefore orelse result.autoCloseBefore;
        result.folding = entry.folding orelse result.folding;
        result.colorizedBracketPairs = entry.colorizedBracketPairs orelse result.colorizedBracketPairs;
        // result.__electricCharacterSupport = entry.__electricCharacterSupport orelse result.__electricCharacterSupport,
    }

    return result;
}

pub const LanguageConfigurationContribution = struct {
    configuration: LanguageConfiguration,
    priority: usize,
    order: usize,

    pub fn lessThan(a: LanguageConfigurationContribution, b: LanguageConfigurationContribution) bool {
        if (a.priority == b.priority) {
            // higher order last
            return a.order < b.order;
        }
        // higher priority last
        return a.priority < b.priority;
    }
};

pub const LanguageConfigurationChangeEvent = struct {
    languageId: []const u8,
};

pub const LanguageConfigurationRegistry = struct {
    _entries: StringHashMap(ComposedLanguageConfiguration),

    _onDidChange: Emitter(LanguageConfigurationChangeEvent),

    pub fn init(allocator: Allocator) LanguageConfigurationRegistry {
        var self = LanguageConfigurationRegistry{
            ._entries = StringHashMap(ComposedLanguageConfiguration).init(allocator),
            ._onDidChange = Emitter(LanguageConfigurationChangeEvent).init(allocator),
        };
        try self.register(PLAINTEXT_LANGUAGE_ID, .{
            .brackets = &[_]CharacterPair{
                .{ '(', ')' },
                .{ '[', ']' },
                .{ '{', '}' },
            },
            .surroundingPairs = &[_]IAutoClosingPair{
                .{ .open = '{', .close = '{' },
                .{ .open = '[', .close = ']' },
                .{ .open = '(', .close = ')' },
                .{ .open = '<', .close = '>' },
                .{ .open = '"', .close = '"' },
                .{ .open = '\'', .close = '\'' },
                .{ .open = '`', .close = '`' },
            },
            .colorizedBracketPairs = &[_]CharacterPair{},
            .folding = .{ .offSide = true },
        }, null);
    }

    // @param priority Use a higher number for higher priority
    pub fn register(self: *LanguageConfigurationRegistry, languageId: []const u8, configuration: LanguageConfiguration, _priority: ?usize) !void {
        const priority = _priority orelse 0;
        const entries = self._entries.get(languageId);
        if (!entries) {
            entries = ComposedLanguageConfiguration.init(languageId);
            try self._entries.put(languageId, entries);
        }

        try entries.?.register(configuration, priority);
        self._onDidChange.fire(.{ .languageId = languageId });

        //return markAsSingleton(toDisposable(() => {
        //disposable.dispose();
        //this._onDidChange.fire(new LanguageConfigurationChangeEvent(languageId));
        //}));
    }

    pub fn getLanguageConfiguration(self: *LanguageConfigurationRegistry, languageId: []const u8) ?ResolvedLanguageConfiguration {
        if (self._entries.get(languageId)) |entries| {
            return entries.getResolvedConfiguration();
        }
        return null;
    }
};

// Immutable.
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
            .wordDefinition = underlyingConfig.wordPattern orelse DEFAULT_WORD_REGEXP,
            .indentationRules = underlyingConfig.indentationRules,
            .indentRulesSupport = if (underlyingConfig.indentationRules) IndentRulesSupport.init(underlyingConfig.indentationRules) else null,
            .foldingRules = underlyingConfig.folding orelse .{},
            .bracketsNew = LanguageBracketsConfiguration.init(languageId, underlyingConfig),
        };
    }

    pub fn getWordDefinition(self: *const ResolvedLanguageConfiguration, allocator: Allocator) !RegExp {
        return try ensureValidWordDefinition(allocator, self.wordDefinition);
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

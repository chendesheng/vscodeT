const std = @import("std");
const RegExp = @import("../basics/RegExp.zig").RegExp;
const LanguageConfiguration = @import("./languageConfiguration.zig").LanguageConfiguration;
const LanguageService = @import("./languageService.zig").LanguageService;
const CharacterPairSupport = @import("./supports/characterPair.zig");
const IndentRulesSupport = @import("./supports/indentRules.zig").IndentRulesSupport;
const IndentationRule = @import("./languageConfiguration.zig").IndentationRule;
const FoldingRules = @import("./languageConfiguration.zig").FoldingRules;
const LanguageBracketsConfiguration = @import("./supports/languageBracketsConfiguration.zig").LanguageBracketsConfiguration;
const ensureValidWordDefinition = @import("../basics/wordHelper.zig").ensureValidWordDefinition;
const createWordRegExp = @import("../basics/wordHelper.zig").createWordRegExp;
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
    configurationService: *IConfigurationService,
    languageService: *LanguageService,

    pub fn init(allocator: Allocator, configurationService: *IConfigurationService, languageService: *LanguageService) !LanguageConfigurationService {
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
            ._registry = try LanguageConfigurationRegistry.init(allocator),
            .configurations = StringHashMap(ResolvedLanguageConfiguration).init(allocator),
            .onDidChangeEmitter = Emitter(LanguageConfigurationServiceChangeEvent).init(allocator),
            .configurationService = configurationService,
            .languageService = languageService,
        };
    }

    pub fn create(
        allocator: Allocator,
        configurationService: *IConfigurationService,
        languageService: *LanguageService,
    ) !*LanguageConfigurationService {
        const self = try allocator.create(LanguageConfigurationService);
        self.* = try LanguageConfigurationService.init(allocator, configurationService, languageService);
        return self;
    }

    pub fn deinit(self: *LanguageConfigurationService) void {
        self._registry.deinit();
        self.onDidChangeEmitter.deinit();
        self.configurations.deinit();
    }

    pub fn register(self: *LanguageConfigurationService, languageId: []const u8, configuration: LanguageConfiguration, priority: ?usize) !void {
        return self._registry.register(languageId, configuration, priority);
    }

    pub fn getLanguageConfiguration(self: *LanguageConfigurationService, languageId: []const u8) !ResolvedLanguageConfiguration {
        var result = self.configurations.get(languageId);
        if (result == null) {
            result = try computeConfig(languageId, self._registry, self.configurationService, self.languageService);
            try self.configurations.put(languageId, result.?);
        }
        return result.?;
    }
};

fn computeConfig(
    languageId: []const u8,
    registry: LanguageConfigurationRegistry,
    configurationService: *IConfigurationService,
    languageService: *LanguageService,
) !ResolvedLanguageConfiguration {
    var languageConfig = try registry.getLanguageConfiguration(languageId);

    if (languageConfig == null) {
        if (!languageService.isRegisteredLanguageId(languageId)) {
            // this happens for the null language, which can be returned by monarch.
            // Instead of throwing an error, we just return a default config.
            return try ResolvedLanguageConfiguration.init(languageId, .{});
        }
        languageConfig = try ResolvedLanguageConfiguration.init(languageId, .{});
    }

    const customizedConfig = getCustomizedLanguageConfig(languageConfig.?.languageId, configurationService);
    const data = combineLanguageConfigurations(&[_]LanguageConfiguration{ languageConfig.?.underlyingConfig, customizedConfig });
    return try ResolvedLanguageConfiguration.init(languageConfig.?.languageId, data);
}

const customizedLanguageConfigKeys = struct {
    const brackets = "editor.language.brackets";
    const colorizedBracketPairs = "editor.language.colorizedBracketPairs";
};

fn getCustomizedLanguageConfig(languageId: []const u8, configurationService: *IConfigurationService) LanguageConfiguration {
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

    pub fn deinit(self: *ComposedLanguageConfiguration) void {
        self._entries.deinit();
    }

    pub fn register(self: *ComposedLanguageConfiguration, configuration: LanguageConfiguration, priority: usize) !void {
        self._order += 1;
        try self._entries.append(.{
            .configuration = configuration,
            .priority = priority,
            .order = self._order,
        });
        self._resolved = null;
    }

    pub fn getResolvedConfiguration(_self: *const ComposedLanguageConfiguration) !?ResolvedLanguageConfiguration {
        var self: *ComposedLanguageConfiguration = @constCast(_self);
        if (self._resolved == null) {
            if (try self._resolve()) |config| {
                self._resolved = try ResolvedLanguageConfiguration.init(self.languageId, config);
            }
        }
        return self._resolved;
    }

    fn _resolve(self: *ComposedLanguageConfiguration) !?LanguageConfiguration {
        if (self._entries.items.len == 0) {
            return null;
        }
        std.sort.block(LanguageConfigurationContribution, self._entries.items, {}, LanguageConfigurationContribution.lessThan);

        var configs = ArrayList(LanguageConfiguration).init(self._entries.allocator);
        defer configs.deinit();
        for (self._entries.items) |entry| {
            try configs.append(entry.configuration);
        }
        return combineLanguageConfigurations(configs.items);
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

    pub fn lessThan(_: void, a: LanguageConfigurationContribution, b: LanguageConfigurationContribution) bool {
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

    pub fn init(allocator: Allocator) !LanguageConfigurationRegistry {
        var self = LanguageConfigurationRegistry{
            ._entries = StringHashMap(ComposedLanguageConfiguration).init(allocator),
            ._onDidChange = Emitter(LanguageConfigurationChangeEvent).init(allocator),
        };
        try self.register(PLAINTEXT_LANGUAGE_ID, .{
            .brackets = try allocator.dupe(CharacterPair, &[_]CharacterPair{
                .{ "(", ")" },
                .{ "[", "]" },
                .{ "{", "}" },
            }),
            .surroundingPairs = try allocator.dupe(IAutoClosingPair, &[_]IAutoClosingPair{
                .{ .open = "{", .close = "{" },
                .{ .open = "[", .close = "]" },
                .{ .open = "(", .close = ")" },
                .{ .open = "<", .close = ">" },
                .{ .open = "\"", .close = "\"" },
                .{ .open = "'", .close = "'" },
                .{ .open = "`", .close = "`" },
            }),
            .colorizedBracketPairs = &[_]CharacterPair{},
            .folding = .{ .offSide = true },
        }, null);
        return self;
    }

    pub fn deinit(self: *LanguageConfigurationRegistry) void {
        const allocator = self._entries.allocator;
        var entriesValues = self._entries.valueIterator();
        while (entriesValues.next()) |node| {
            for (node._entries.items) |entry| {
                if (entry.configuration.brackets) |brackets| {
                    allocator.free(brackets);
                }
                if (entry.configuration.surroundingPairs) |surroundingPairs| {
                    allocator.free(surroundingPairs);
                }
            }
            node.deinit();
        }
        self._entries.deinit();
        self._onDidChange.deinit();
    }

    // @param priority Use a higher number for higher priority
    pub fn register(self: *LanguageConfigurationRegistry, languageId: []const u8, configuration: LanguageConfiguration, _priority: ?usize) !void {
        const allocator = self._entries.allocator;
        const priority = _priority orelse 0;
        var entries_ptr = self._entries.getPtr(languageId);
        if (entries_ptr == null) {
            // Create and insert a new entry first, then get the pointer
            try self._entries.put(languageId, ComposedLanguageConfiguration.init(allocator, languageId));
            entries_ptr = self._entries.getPtr(languageId);
        }

        try entries_ptr.?.register(configuration, priority);
        self._onDidChange.fire(.{ .languageId = languageId });

        //return markAsSingleton(toDisposable(() => {
        //disposable.dispose();
        //this._onDidChange.fire(new LanguageConfigurationChangeEvent(languageId));
        //}));
    }

    pub fn getLanguageConfiguration(self: *const LanguageConfigurationRegistry, languageId: []const u8) !?ResolvedLanguageConfiguration {
        if (self._entries.get(languageId)) |*entries| {
            return try entries.getResolvedConfiguration();
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

    pub fn init(languageId: []const u8, underlyingConfig: LanguageConfiguration) !ResolvedLanguageConfiguration {
        //this._onEnterSupport =
        //    underlyingConfig.brackets or
        //    underlyingConfig.indentationRules or
        //    if (underlyingConfig.onEnterRules) OnEnterSupport.init(underlyingConfig) else null;

        return .{
            .languageId = languageId,
            .underlyingConfig = underlyingConfig,
            // ._brackets = null,
            // ._electricCharacter = null,
            // ._onEnterSupport = null,
            .comments = undefined, // ResolvedLanguageConfiguration._handleComments(underlyingConfig),
            .characterPair = CharacterPairSupport.init(underlyingConfig),
            .wordDefinition = underlyingConfig.wordPattern orelse (try createWordRegExp(null)),
            .indentationRules = underlyingConfig.indentationRules,
            .indentRulesSupport = if (underlyingConfig.indentationRules != null) IndentRulesSupport.init(underlyingConfig.indentationRules.?) else null,
            .foldingRules = underlyingConfig.folding orelse FoldingRules{},
            .bracketsNew = undefined, // try LanguageBracketsConfiguration.init(undefined, languageId, underlyingConfig),
        };
    }

    pub fn getWordDefinition(self: *const ResolvedLanguageConfiguration) !RegExp {
        return try ensureValidWordDefinition(self.wordDefinition);
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

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
const OnEnterSupport = @import("./supports/onEnter.zig").OnEnterSupport;
const RichEditBrackets = @import("./supports/richEditBrackets.zig").RichEditBrackets;
const BracketElectricCharacterSupport = @import("./supports/electricCharacter.zig").BracketElectricCharacterSupport;
const AutoClosingPairs = @import("./languageConfiguration.zig").AutoClosingPairs;
const IAutoClosingPair = @import("./languageConfiguration.zig").IAutoClosingPair;
const Emitter = @import("../../../base/common/event.zig").Emitter;

// Interface used to support insertion of mode specific comments.
pub const ICommentsConfiguration = struct {
    lineCommentToken: ?[]const u8 = null,
    lineCommentNoIndent: ?bool = null,
    blockCommentStartToken: ?[]const u8 = null,
    blockCommentEndToken: ?[]const u8 = null,
};

pub const ILanguageConfigurationService = struct {
    context: *anyopaque,
    on_did_change_fn: *const fn (context: *anyopaque, event: LanguageConfigurationServiceChangeEvent) void,
    register_fn: *const fn (context: *anyopaque, languageId: []const u8, configuration: LanguageConfiguration, priority: ?usize) void,
    get_language_configuration_fn: *const fn (context: *anyopaque, languageId: []const u8) ResolvedLanguageConfiguration,

    pub fn onDidChange(self: ILanguageConfigurationService, event: LanguageConfigurationServiceChangeEvent) void {
        self.on_did_change_fn(self.context, event);
    }

    /// @param priority Use a higher number for higher priority.
    pub fn register(self: ILanguageConfigurationService, languageId: []const u8, configuration: LanguageConfiguration, priority: ?usize) void {
        self.register_fn(self.context, languageId, configuration, priority);
    }

    pub fn getLanguageConfiguration(self: ILanguageConfigurationService, languageId: []const u8) ResolvedLanguageConfiguration {
        return self.get_language_configuration_fn(self.context, languageId);
    }
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
    allocator: Allocator,
    brackets: ?RichEditBrackets,
    electric_character: ?BracketElectricCharacterSupport,
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
    on_enter_support: ?OnEnterSupport,

    pub fn init(allocator: Allocator, languageId: []const u8, underlyingConfig: LanguageConfiguration) !ResolvedLanguageConfiguration {
        const brackets: ?RichEditBrackets = if (underlyingConfig.brackets) |raw_brackets|
            (RichEditBrackets.init(allocator, languageId, raw_brackets) catch null)
        else
            null;
        const electric_character: ?BracketElectricCharacterSupport = if (brackets) |*rich_brackets|
            BracketElectricCharacterSupport.init(rich_brackets)
        else
            null;

        const on_enter_support: ?OnEnterSupport = if (underlyingConfig.brackets != null or
            underlyingConfig.indentationRules != null or
            underlyingConfig.onEnterRules != null)
            (OnEnterSupport.init(allocator, .{
                .brackets = underlyingConfig.brackets,
                .onEnterRules = underlyingConfig.onEnterRules,
            }) catch null)
        else
            null;

        return .{
            .allocator = allocator,
            .brackets = brackets,
            .electric_character = electric_character,
            .languageId = languageId,
            .underlyingConfig = underlyingConfig,
            .on_enter_support = on_enter_support,
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

    /// Rich bracket groups for the language, built eagerly during resolution
    /// (upstream builds them lazily; resolved configurations are cached here).
    pub fn getBrackets(self: *const ResolvedLanguageConfiguration) ?*const RichEditBrackets {
        return if (self.brackets) |*brackets| brackets else null;
    }

    pub fn getElectricCharacter(self: *const ResolvedLanguageConfiguration) ?*const BracketElectricCharacterSupport {
        return if (self.electric_character) |*electric_character| electric_character else null;
    }

    pub fn onEnter(self: *const ResolvedLanguageConfiguration, autoIndent: EditorAutoIndentStrategy, previousLineText: []const u8, beforeEnterText: []const u8, afterEnterText: []const u8) ?EnterAction {
        const support = self.on_enter_support orelse return null;
        return support.onEnter(autoIndent, previousLineText, beforeEnterText, afterEnterText);
    }

    /// Frees resources owned by the resolved configuration (the bracket/rule
    /// regexes); the struct memory itself is registry-arena owned.
    pub fn deinit(self: *ResolvedLanguageConfiguration) void {
        if (self.on_enter_support) |*support| support.deinit();
        self.on_enter_support = null;
        if (self.brackets) |*brackets| brackets.deinit();
        self.brackets = null;
        self.electric_character = null;
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

var plaintext_brackets = [_]@import("./languageConfiguration.zig").CharacterPair{
    .{ "(", ")" },
    .{ "[", "]" },
    .{ "{", "}" },
};
var plaintext_surrounding_pairs = [_]IAutoClosingPair{
    .{ .open = "{", .close = "}" },
    .{ .open = "[", .close = "]" },
    .{ .open = "(", .close = ")" },
    .{ .open = "<", .close = ">" },
    .{ .open = "\"", .close = "\"" },
    .{ .open = "'", .close = "'" },
    .{ .open = "`", .close = "`" },
};
var plaintext_colorized_brackets = [_]@import("./languageConfiguration.zig").CharacterPair{};

//#region LanguageConfigurationRegistry

pub const LanguageConfigurationChangeEvent = struct {
    languageId: []const u8,
};

/// A registered configuration contribution. The configuration's slices are
/// borrowed from the caller, matching upstream's object references.
const LanguageConfigurationContribution = struct {
    configuration: LanguageConfiguration,
    priority: i64,
    order: i64,
};

fn contributionLessThan(_: void, a: LanguageConfigurationContribution, b: LanguageConfigurationContribution) bool {
    if (a.priority == b.priority) return a.order < b.order;
    return a.priority < b.priority;
}

/// Upstream `combineLanguageConfigurations`: later (higher-priority) entries
/// override earlier ones field by field.
fn combineLanguageConfigurations(configs: []const LanguageConfiguration) LanguageConfiguration {
    var result = @import("./languageConfiguration.zig").empty();
    for (configs) |config| {
        if (config.comments) |value| result.comments = value;
        if (config.brackets) |value| result.brackets = value;
        if (config.wordPattern) |value| result.wordPattern = value;
        if (config.indentationRules) |value| result.indentationRules = value;
        if (config.onEnterRules) |value| result.onEnterRules = value;
        if (config.autoClosingPairs) |value| result.autoClosingPairs = value;
        if (config.surroundingPairs) |value| result.surroundingPairs = value;
        if (config.autoCloseBefore) |value| result.autoCloseBefore = value;
        if (config.folding) |value| result.folding = value;
        if (config.colorizedBracketPairs) |value| result.colorizedBracketPairs = value;
    }
    return result;
}

/// Upstream `ComposedLanguageConfiguration`.
const ComposedLanguageConfiguration = struct {
    languageId: []const u8,
    entries: std.array_list.Managed(LanguageConfigurationContribution),
    order: i64 = 0,
    resolved: ?*ResolvedLanguageConfiguration = null,

    fn init(allocator: Allocator, language_id: []const u8) ComposedLanguageConfiguration {
        return .{
            .languageId = language_id,
            .entries = std.array_list.Managed(LanguageConfigurationContribution).init(allocator),
        };
    }

    fn deinit(self: *ComposedLanguageConfiguration) void {
        self.clearResolved();
        self.entries.deinit();
    }

    fn clearResolved(self: *ComposedLanguageConfiguration) void {
        if (self.resolved) |resolved| resolved.deinit();
        self.resolved = null;
    }

    fn getResolvedConfiguration(self: *ComposedLanguageConfiguration, registry: *LanguageConfigurationRegistry) ?*const ResolvedLanguageConfiguration {
        if (self.resolved) |resolved| return resolved;
        if (self.entries.items.len == 0) return null;

        std.mem.sort(LanguageConfigurationContribution, self.entries.items, {}, contributionLessThan);

        var configs = std.array_list.Managed(LanguageConfiguration).init(registry.allocator);
        defer configs.deinit();
        for (self.entries.items) |contribution| {
            configs.append(contribution.configuration) catch return null;
        }
        const combined = combineLanguageConfigurations(configs.items);

        const arena = registry.arena.allocator();
        const resolved = arena.create(ResolvedLanguageConfiguration) catch return null;
        resolved.* = ResolvedLanguageConfiguration.init(arena, self.languageId, combined) catch return null;
        // `init` builds the electric-character support against its local
        // `brackets` value; repoint it at the final resolved struct so the
        // pointer does not dangle after the return-by-value move.
        if (resolved.brackets) |*brackets| {
            resolved.electric_character = BracketElectricCharacterSupport.init(brackets);
        }
        self.resolved = resolved;
        return resolved;
    }
};

/// Disposable returned by `LanguageConfigurationRegistry.register`.
pub const LanguageConfigurationRegistration = struct {
    registry: *LanguageConfigurationRegistry,
    languageId: []const u8,
    order: i64,
    disposed: bool = false,

    pub fn dispose(self: *LanguageConfigurationRegistration) void {
        if (self.disposed) return;
        self.disposed = true;
        self.registry.unregister(self.languageId, self.order);
    }
};

/// Upstream `LanguageConfigurationRegistry`. Resolved configurations are
/// arena-owned for the registry lifetime (upstream relies on GC); invalidating
/// them only drops the cache so the next lookup rebuilds.
pub const LanguageConfigurationRegistry = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMap(*ComposedLanguageConfiguration),
    on_did_change: Emitter(LanguageConfigurationChangeEvent),
    order: i64 = 0,

    pub fn init(allocator: Allocator) !LanguageConfigurationRegistry {
        var self = LanguageConfigurationRegistry{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = std.StringHashMap(*ComposedLanguageConfiguration).init(allocator),
            .on_did_change = Emitter(LanguageConfigurationChangeEvent).init(allocator),
        };
        errdefer self.deinit();

        const plaintext = LanguageConfiguration{
            .comments = null,
            .brackets = &plaintext_brackets,
            .wordPattern = null,
            .indentationRules = null,
            .onEnterRules = null,
            .autoClosingPairs = null,
            .surroundingPairs = &plaintext_surrounding_pairs,
            .colorizedBracketPairs = &plaintext_colorized_brackets,
            .autoCloseBefore = null,
            .folding = .{ .offSide = true, .markers = null },
        };
        var registration = try self.register("plaintext", plaintext, 0);
        registration.disposed = true;
        return self;
    }

    pub fn deinit(self: *LanguageConfigurationRegistry) void {
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| {
            entry.*.deinit();
            self.allocator.destroy(entry.*);
        }
        var key_iterator = self.entries.keyIterator();
        while (key_iterator.next()) |key| self.allocator.free(key.*);
        self.entries.deinit();
        self.on_did_change.deinit();
        self.arena.deinit();
    }

    /// @param priority Use a higher number for higher priority.
    pub fn register(
        self: *LanguageConfigurationRegistry,
        language_id: []const u8,
        configuration: LanguageConfiguration,
        priority: ?i64,
    ) !LanguageConfigurationRegistration {
        const composed = try self.getOrCreate(language_id);
        self.order += 1;
        try composed.entries.append(.{
            .configuration = configuration,
            .priority = priority orelse 0,
            .order = self.order,
        });
        composed.clearResolved();
        try self.on_did_change.fire(.{ .languageId = composed.languageId });
        return .{
            .registry = self,
            .languageId = composed.languageId,
            .order = self.order,
        };
    }

    fn unregister(self: *LanguageConfigurationRegistry, language_id: []const u8, order: i64) void {
        const composed = self.entries.get(language_id) orelse return;
        for (composed.entries.items, 0..) |contribution, index| {
            if (contribution.order == order) {
                _ = composed.entries.orderedRemove(index);
                composed.clearResolved();
                self.on_did_change.fire(.{ .languageId = composed.languageId }) catch {};
                return;
            }
        }
    }

    fn getOrCreate(self: *LanguageConfigurationRegistry, language_id: []const u8) !*ComposedLanguageConfiguration {
        if (self.entries.get(language_id)) |composed| return composed;

        const composed = try self.allocator.create(ComposedLanguageConfiguration);
        errdefer self.allocator.destroy(composed);
        const key = try self.allocator.dupe(u8, language_id);
        errdefer self.allocator.free(key);
        composed.* = ComposedLanguageConfiguration.init(self.allocator, key);
        errdefer composed.deinit();
        try self.entries.put(key, composed);
        return composed;
    }

    pub fn getLanguageConfiguration(self: *LanguageConfigurationRegistry, language_id: []const u8) ?*const ResolvedLanguageConfiguration {
        const composed = self.entries.get(language_id) orelse return null;
        return composed.getResolvedConfiguration(self);
    }

    /// Test helper: the number of entries for a language.
    pub fn entryCount(self: *LanguageConfigurationRegistry, language_id: []const u8) usize {
        const composed = self.entries.get(language_id) orelse return 0;
        return composed.entries.items.len;
    }
};

//#endregion

/// Upstream `LanguageConfigurationService`, the concrete
/// `ILanguageConfigurationService` implementation. It wraps the registry and
/// promotes configurations registered on the editor `LanguageService` on first
/// lookup, modelling upstream's lazy configuration registration.
pub const LanguageConfigurationService = struct {
    allocator: Allocator,
    language_service: *@import("../services/languageService.zig").LanguageService,
    registry: LanguageConfigurationRegistry,

    pub fn init(allocator: Allocator, language_service: *@import("../services/languageService.zig").LanguageService) !LanguageConfigurationService {
        return .{
            .allocator = allocator,
            .language_service = language_service,
            .registry = try LanguageConfigurationRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *LanguageConfigurationService) void {
        self.registry.deinit();
    }

    pub fn interface(self: *LanguageConfigurationService) ILanguageConfigurationService {
        return .{
            .context = self,
            .on_did_change_fn = onDidChange,
            .register_fn = register,
            .get_language_configuration_fn = getLanguageConfiguration,
        };
    }

    /// Returns the registry-owned resolved configuration. The pointer is
    /// stable until the registry re-resolves that language; callers that only
    /// use it for the duration of a command can borrow it.
    pub fn resolved(self: *LanguageConfigurationService, language_id: []const u8) ?*const ResolvedLanguageConfiguration {
        if (self.registry.getLanguageConfiguration(language_id)) |configuration| return configuration;

        // Promote the editor language service's configuration into the
        // registry so priority merging and invalidation use the upstream path.
        if (self.language_service.getLanguageConfiguration(language_id)) |config| {
            var registration = self.registry.register(language_id, config, 0) catch
                return self.registry.getLanguageConfiguration("plaintext");
            registration.disposed = true;
            return self.registry.getLanguageConfiguration(language_id);
        }
        return self.registry.getLanguageConfiguration("plaintext");
    }

    fn get(self: *LanguageConfigurationService, language_id: []const u8) ResolvedLanguageConfiguration {
        if (self.resolved(language_id)) |configuration| return configuration.*;
        return self.plaintext();
    }

    fn plaintext(self: *LanguageConfigurationService) ResolvedLanguageConfiguration {
        const configuration = self.registry.getLanguageConfiguration("plaintext") orelse unreachable;
        return configuration.*;
    }
};

fn onDidChange(_: *anyopaque, _: LanguageConfigurationServiceChangeEvent) void {}

fn register(context: *anyopaque, language_id: []const u8, configuration: LanguageConfiguration, priority: ?usize) void {
    const self: *LanguageConfigurationService = @ptrCast(@alignCast(context));
    var registration = self.registry.register(language_id, configuration, if (priority) |value| @intCast(value) else 0) catch return;
    registration.disposed = true;
}

fn getLanguageConfiguration(context: *anyopaque, language_id: []const u8) ResolvedLanguageConfiguration {
    const self: *LanguageConfigurationService = @ptrCast(@alignCast(context));
    return self.get(language_id);
}

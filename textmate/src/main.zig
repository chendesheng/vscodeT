// Port of `../vscode-textmate/src/main.ts` (microsoft/vscode-textmate
// v9.3.2).
//
// Adaptation: the TypeScript API returns Promises; this port is synchronous.
// `loadGrammar` therefore returns the grammar directly, and grammar loading
// walks the dependency graph with `ScopeDependencyProcessor`.
const std = @import("std");
const grammar = @import("grammar/grammar.zig");
const rawGrammar = @import("rawGrammar.zig");
const theme = @import("theme.zig");
const registry = @import("registry.zig");
const dependencies = @import("grammar/grammarDependencies.zig");
const onigLib = @import("onigLib.zig");
const diff = @import("diffStateStacks.zig");
const parseRawGrammarModule = @import("parseRawGrammar.zig");
const Allocator = std.mem.Allocator;

pub const IOnigLib = onigLib.IOnigLib;
pub const OnigLib = onigLib.OnigLib;
pub const IRawGrammar = rawGrammar.RawGrammar;
pub const IRawTheme = theme.RawTheme;
pub const StateStack = grammar.StateStackImpl;
pub const INITIAL: *grammar.StateStackImpl = grammar.StateStackImpl.NULL;
pub const IGrammar = grammar.Grammar;
pub const IToken = grammar.IToken;
pub const ITokenizeLineResult = grammar.ITokenizeLineResult;
pub const ITokenizeLineResult2 = grammar.ITokenizeLineResult2;
pub const IFontInfo = grammar.FontInfo;
pub const EmbeddedLanguage = @import("grammar/basicScopesAttributeProvider.zig").EmbeddedLanguage;
pub const IEmbeddedLanguagesMap = grammar.EmbeddedLanguagesMap;
pub const ITokenTypeMap = []const grammar.TokenTypeEntry;

pub const RegistryOptions = struct {
    onig_lib: onigLib.IOnigLib,
    theme: ?*const theme.RawTheme = null,
    color_map: ?[]const []const u8 = null,
    context: *anyopaque = undefined,
    load_grammar: *const fn (context: *anyopaque, scope_name: []const u8) anyerror!?*rawGrammar.RawGrammar,
    get_injections: ?*const fn (context: *anyopaque, scope_name: []const u8) ?[]const []const u8 = null,
};

pub const IGrammarConfiguration = struct {
    embedded_languages: grammar.EmbeddedLanguagesMap = &.{},
    token_types: []const grammar.TokenTypeEntry = &.{},
    balanced_bracket_selectors: []const []const u8 = &.{},
    unbalanced_bracket_selectors: []const []const u8 = &.{},
};

pub const Registry = struct {
    allocator: Allocator,
    options: RegistryOptions,
    sync_registry: registry.SyncRegistry,
    loaded_scopes: std.StringHashMap(void),

    pub fn init(allocator: Allocator, options: RegistryOptions) !*Registry {
        const initial_theme = try theme.Theme.createFromRawTheme(allocator, options.theme, options.color_map);
        const self = try allocator.create(Registry);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .options = options,
            .sync_registry = registry.SyncRegistry.init(allocator, initial_theme, options.onig_lib),
            .loaded_scopes = std.StringHashMap(void).init(allocator),
        };
        return self;
    }

    pub fn dispose(self: *Registry) void {
        self.sync_registry.dispose();
        self.loaded_scopes.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn setTheme(self: *Registry, raw_theme: *const theme.RawTheme, color_map: ?[]const []const u8) !void {
        const new_theme = try theme.Theme.createFromRawTheme(self.allocator, raw_theme, color_map);
        self.sync_registry.setTheme(new_theme);
    }

    pub fn getColorMap(self: *const Registry) []const []const u8 {
        return self.sync_registry.getColorMap();
    }

    pub fn loadGrammarWithEmbeddedLanguages(
        self: *Registry,
        initial_scope_name: []const u8,
        initial_language: u32,
        embedded_languages: grammar.EmbeddedLanguagesMap,
    ) !?*grammar.Grammar {
        return self.loadGrammarWithConfiguration(initial_scope_name, initial_language, .{
            .embedded_languages = embedded_languages,
        });
    }

    pub fn loadGrammarWithConfiguration(
        self: *Registry,
        initial_scope_name: []const u8,
        initial_language: u32,
        configuration: IGrammarConfiguration,
    ) !?*grammar.Grammar {
        return self.loadGrammarInternal(
            initial_scope_name,
            initial_language,
            configuration.embedded_languages,
            configuration.token_types,
            configuration.balanced_bracket_selectors,
            configuration.unbalanced_bracket_selectors,
        );
    }

    pub fn loadGrammar(self: *Registry, initial_scope_name: []const u8) !?*grammar.Grammar {
        return self.loadGrammarInternal(initial_scope_name, 0, &.{}, &.{}, &.{}, &.{});
    }

    fn loadGrammarInternal(
        self: *Registry,
        initial_scope_name: []const u8,
        initial_language: u32,
        embedded_languages: grammar.EmbeddedLanguagesMap,
        token_types: []const grammar.TokenTypeEntry,
        balanced_bracket_selectors: []const []const u8,
        unbalanced_bracket_selectors: []const []const u8,
    ) !?*grammar.Grammar {
        var processor = try dependencies.ScopeDependencyProcessor.init(
            self.allocator,
            self.sync_registry.repositoryInterface(),
            initial_scope_name,
        );
        defer processor.deinit();

        while (processor.hasPending()) {
            for (processor.queue.items) |request| {
                const scope_name = switch (request) {
                    .top_level => |reference| reference.scope_name,
                    .top_level_repository => |reference| reference.scope_name,
                };
                if (self.loaded_scopes.contains(scope_name)) continue;
                try self.loaded_scopes.put(scope_name, {});

                const loaded = try self.options.load_grammar(self.options.context, scope_name);
                if (loaded) |raw_grammar| {
                    const injections = if (self.options.get_injections) |callback|
                        callback(self.options.context, scope_name)
                    else
                        null;
                    try self.sync_registry.addGrammar(raw_grammar, injections);
                }
            }
            try processor.processQueue();
        }

        return self.sync_registry.grammarForScopeName(
            initial_scope_name,
            initial_language,
            embedded_languages,
            token_types,
            balanced_bracket_selectors,
            unbalanced_bracket_selectors,
        );
    }

    pub fn addGrammar(
        self: *Registry,
        raw_grammar: *rawGrammar.RawGrammar,
        injections: ?[]const []const u8,
        initial_language: u32,
        embedded_languages: grammar.EmbeddedLanguagesMap,
    ) !*grammar.Grammar {
        try self.sync_registry.addGrammar(raw_grammar, injections);
        const result = try self.sync_registry.grammarForScopeName(
            raw_grammar.scopeName(),
            initial_language,
            embedded_languages,
            &.{},
            &.{},
            &.{},
        );
        return result.?;
    }
};

pub const parseRawGrammar = parseRawGrammarModule.parseRawGrammar;
pub const diffStateStacksRefEq = diff.diffStateStacksRefEq;
pub const applyStateStackDiff = diff.applyStateStackDiff;
pub const StackDiff = diff.StackDiff;

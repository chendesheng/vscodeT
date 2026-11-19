// Port of `vscode-textmate/src/registry.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const grammar = @import("grammar/grammar.zig");
const rawGrammar = @import("rawGrammar.zig");
const theme = @import("theme.zig");
const dependencies = @import("grammar/grammarDependencies.zig");
const onigLib = @import("onigLib.zig");
const Allocator = std.mem.Allocator;
const Object = rawGrammar.Object;

pub const SyncRegistry = struct {
    allocator: Allocator,
    grammars: std.StringHashMap(*grammar.Grammar),
    raw_grammars: std.StringHashMap(*rawGrammar.RawGrammar),
    injection_grammars: std.StringHashMap([]const []const u8),
    theme: *theme.Theme,
    onig: onigLib.IOnigLib,

    pub fn init(allocator: Allocator, initial_theme: *theme.Theme, onig: onigLib.IOnigLib) SyncRegistry {
        return .{
            .allocator = allocator,
            .grammars = std.StringHashMap(*grammar.Grammar).init(allocator),
            .raw_grammars = std.StringHashMap(*rawGrammar.RawGrammar).init(allocator),
            .injection_grammars = std.StringHashMap([]const []const u8).init(allocator),
            .theme = initial_theme,
            .onig = onig,
        };
    }

    pub fn dispose(self: *SyncRegistry) void {
        var grammar_iterator = self.grammars.valueIterator();
        while (grammar_iterator.next()) |value| value.*.deinit();
        self.grammars.deinit();
        self.raw_grammars.deinit();
        self.injection_grammars.deinit();
        self.theme.deinit();
    }

    pub fn setTheme(self: *SyncRegistry, new_theme: *theme.Theme) void {
        if (self.theme != new_theme) self.theme.deinit();
        self.theme = new_theme;
    }

    pub fn getColorMap(self: *const SyncRegistry) []const []const u8 {
        return self.theme.getColorMap();
    }

    pub fn addGrammar(self: *SyncRegistry, raw_grammar: *rawGrammar.RawGrammar, injection_scope_names: ?[]const []const u8) !void {
        try self.raw_grammars.put(raw_grammar.scopeName(), raw_grammar);
        if (injection_scope_names) |names| {
            try self.injection_grammars.put(raw_grammar.scopeName(), names);
        }
    }

    pub fn lookup(self: *SyncRegistry, scope_name: []const u8) ?*Object {
        const raw = self.raw_grammars.get(scope_name) orelse return null;
        return raw.root;
    }

    pub fn injections(self: *SyncRegistry, target_scope: []const u8) ?[]const []const u8 {
        return self.injection_grammars.get(target_scope);
    }

    pub fn getDefaults(self: *SyncRegistry) theme.StyleAttributes {
        return self.theme.getDefaults();
    }

    pub fn themeMatch(self: *SyncRegistry, scope_path: ?*const theme.ScopeStack) anyerror!?theme.StyleAttributes {
        return self.theme.match(scope_path);
    }

    pub fn repositoryInterface(self: *SyncRegistry) dependencies.IGrammarRepository {
        return .{
            .context = self,
            .vtable = &.{
                .lookup = repositoryLookup,
                .injections = repositoryInjections,
            },
        };
    }

    pub fn themeProviderInterface(self: *SyncRegistry) grammar.IThemeProvider {
        return .{
            .context = self,
            .vtable = &.{
                .theme_match = themeMatchThunk,
                .get_defaults = getDefaultsThunk,
            },
        };
    }

    fn repositoryLookup(context: *anyopaque, scope_name: []const u8) ?*Object {
        const self: *SyncRegistry = @ptrCast(@alignCast(context));
        return self.lookup(scope_name);
    }

    fn repositoryInjections(context: *anyopaque, scope_name: []const u8) ?[]const []const u8 {
        const self: *SyncRegistry = @ptrCast(@alignCast(context));
        return self.injections(scope_name);
    }

    fn themeMatchThunk(context: *anyopaque, scope_path: ?*const theme.ScopeStack) anyerror!?theme.StyleAttributes {
        const self: *SyncRegistry = @ptrCast(@alignCast(context));
        return self.themeMatch(scope_path);
    }

    fn getDefaultsThunk(context: *anyopaque) theme.StyleAttributes {
        const self: *SyncRegistry = @ptrCast(@alignCast(context));
        return self.getDefaults();
    }

    pub fn grammarForScopeName(
        self: *SyncRegistry,
        scope_name: []const u8,
        initial_language: u32,
        embedded_languages: grammar.EmbeddedLanguagesMap,
        token_types: []const grammar.TokenTypeEntry,
        balanced_bracket_selectors: []const []const u8,
        unbalanced_bracket_selectors: []const []const u8,
    ) !?*grammar.Grammar {
        if (self.grammars.get(scope_name)) |existing| return existing;
        const raw = self.raw_grammars.get(scope_name) orelse return null;

        const result = try grammar.Grammar.create(self.allocator, .{
            .scope_name = scope_name,
            .grammar = raw.root,
            .initial_language = initial_language,
            .embedded_languages = embedded_languages,
            .token_types = token_types,
            .balanced_bracket_selectors = balanced_bracket_selectors,
            .unbalanced_bracket_selectors = unbalanced_bracket_selectors,
            .repository = self.repositoryInterface(),
            .theme_provider = self.themeProviderInterface(),
            .onig = self.onig,
        });
        try self.grammars.put(scope_name, result);
        return result;
    }
};

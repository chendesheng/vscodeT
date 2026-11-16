// Port of `../vscode-textmate/src/grammar/grammar.ts`
// (microsoft/vscode-textmate v9.3.2).
//
// Adaptation notes:
//  * `Grammar` owns an arena for its cloned raw grammar, rule objects,
//    attributed scope stacks and state stacks. Token arrays use a separate
//    scratch arena that is reset at the start of every `tokenizeLine*` call;
//    the returned tokens are valid until the next call on the same grammar.
//  * TypeScript callbacks/interfaces become explicit function-pointer
//    interfaces (`IThemeProvider`) or concrete methods.
//  * `BalancedBracketSelectors` is built by the grammar from the selector
//    names; it owns its matcher sets through the grammar.
//  * Token indices and `linePos` are UTF-16 code units, matching the JS
//    implementation. Only `OnigString` converts at the Oniguruma boundary.
const std = @import("std");
const onigLib = @import("../onigLib.zig");
const rawGrammar = @import("../rawGrammar.zig");
const matcher = @import("../matcher.zig");
const rule = @import("../rule.zig");
const theme = @import("../theme.zig");
const utils = @import("../utils.zig");
const encoded = @import("../encodedTokenAttributes.zig");
const dependencies = @import("grammarDependencies.zig");
const basic = @import("basicScopesAttributeProvider.zig");
const tokenizeString = @import("tokenizeString.zig");
const Allocator = std.mem.Allocator;
const Object = rawGrammar.Object;
const Value = rawGrammar.Value;
const RuleId = rule.RuleId;
const endRuleId = rule.endRuleId;
pub const StateStackFrame = struct {
    rule_id: RuleId,
    enter_pos: ?i32 = null,
    anchor_pos: ?i32 = null,
    begin_rule_captured_eol: bool,
    end_rule: ?[]const u8,
    name_scopes_list: []AttributedScopeStackFrame,
    content_name_scopes_list: []AttributedScopeStackFrame,
};

pub const AttributedScopeStackFrame = struct {
    encoded_token_attributes: u32,
    scope_names: []const []const u8,
};

pub const ScopeName = []const u8;
pub const ScopePath = []const u8;
pub const ScopeArray = []const []const u8;
pub const MatcherType = matcher.Matcher(ScopeArray);
pub const MatcherSetType = matcher.MatcherSet(ScopeArray);

pub const IThemeProvider = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        theme_match: *const fn (context: *anyopaque, scope_path: ?*const theme.ScopeStack) anyerror!?theme.StyleAttributes,
        get_defaults: *const fn (context: *anyopaque) theme.StyleAttributes,
    };

    pub fn themeMatch(self: IThemeProvider, scope_path: ?*const theme.ScopeStack) anyerror!?theme.StyleAttributes {
        return self.vtable.theme_match(self.context, scope_path);
    }

    pub fn getDefaults(self: IThemeProvider) theme.StyleAttributes {
        return self.vtable.get_defaults(self.context);
    }
};

pub const EmbeddedLanguagesMap = []const basic.EmbeddedLanguage;

pub const TokenTypeEntry = struct {
    selector: []const u8,
    token_type: u8,
};

pub const Injection = struct {
    debug_selector: []const u8,
    matcher: *const MatcherType,
    priority: i8,
    rule_id: RuleId,
    grammar: *Object,
    order: usize = 0,
};

pub const TokenTypeMatcher = struct {
    matcher: *const MatcherType,
    token_type: u8,
};

pub const GrammarOptions = struct {
    scope_name: ScopeName,
    grammar: *Object,
    initial_language: u32 = 0,
    embedded_languages: EmbeddedLanguagesMap = &.{},
    token_types: []const TokenTypeEntry = &.{},
    balanced_bracket_selectors: []const []const u8 = &.{},
    unbalanced_bracket_selectors: []const []const u8 = &.{},
    repository: dependencies.IGrammarRepository,
    theme_provider: IThemeProvider,
    onig: onigLib.IOnigLib,
};

pub const Grammar = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    token_arena: std.heap.ArenaAllocator,
    line_arena: std.heap.ArenaAllocator,
    root_scope_name: ScopeName,
    root_id: RuleId = -1,
    last_rule_id: usize = 0,
    rule_id2desc: std.ArrayList(?*rule.Rule) = .empty,
    included_grammars: std.StringHashMap(*Object),
    grammar_repository: dependencies.IGrammarRepository,
    theme_provider: IThemeProvider,
    grammar: *Object,
    injections: ?[]Injection = null,
    basic_scope_attributes_provider: basic.BasicScopeAttributesProvider,
    token_type_matchers: []TokenTypeMatcher,
    balanced_bracket_selectors: ?*BalancedBracketSelectors,
    onig: onigLib.IOnigLib,
    matcher_sets: std.ArrayList(*MatcherSetType) = .empty,

    pub fn create(allocator: Allocator, options: GrammarOptions) !*Grammar {
        const self = try allocator.create(Grammar);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .token_arena = std.heap.ArenaAllocator.init(allocator),
            .line_arena = std.heap.ArenaAllocator.init(allocator),
            .root_scope_name = options.scope_name,
            .included_grammars = std.StringHashMap(*Object).init(allocator),
            .grammar_repository = options.repository,
            .theme_provider = options.theme_provider,
            .grammar = undefined,
            .basic_scope_attributes_provider = undefined,
            .token_type_matchers = &.{},
            .balanced_bracket_selectors = null,
            .onig = options.onig,
        };
        errdefer self.arena.deinit();
        errdefer self.token_arena.deinit();
        errdefer self.line_arena.deinit();

        const arena = self.arena.allocator();
        self.grammar = try initGrammar(arena, options.grammar, null);
        try self.rule_id2desc.append(arena, null);
        self.basic_scope_attributes_provider = try basic.BasicScopeAttributesProvider.init(
            arena,
            options.initial_language,
            options.embedded_languages,
        );

        var token_matchers: std.ArrayList(TokenTypeMatcher) = .empty;
        for (options.token_types) |entry| {
            const set = try matcher.createMatchers(ScopeArray, arena, entry.selector, nameMatcher);
            const set_pointer = try arena.create(MatcherSetType);
            set_pointer.* = set;
            try self.matcher_sets.append(arena, set_pointer);
            for (set_pointer.matchers) |entry_matcher| {
                try token_matchers.append(arena, .{
                    .matcher = entry_matcher.matcher,
                    .token_type = entry.token_type,
                });
            }
        }
        self.token_type_matchers = try token_matchers.toOwnedSlice(arena);

        if (options.balanced_bracket_selectors.len != 0 or options.unbalanced_bracket_selectors.len != 0) {
            self.balanced_bracket_selectors = try BalancedBracketSelectors.init(
                arena,
                options.balanced_bracket_selectors,
                options.unbalanced_bracket_selectors,
                &self.matcher_sets,
            );
        }

        return self;
    }

    pub fn deinit(self: *Grammar) void {
        for (self.rule_id2desc.items) |maybe_rule| {
            if (maybe_rule) |value| value.dispose();
        }
        for (self.matcher_sets.items) |set| set.deinit();
        self.rule_id2desc.deinit(self.arena.allocator());
        self.included_grammars.deinit();
        self.line_arena.deinit();
        self.token_arena.deinit();
        self.arena.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn getMetadataForScope(self: *Grammar, scope: ScopeName) !basic.BasicScopeAttributes {
        return self.basic_scope_attributes_provider.getBasicScopeAttributes(scope);
    }

    pub fn createOnigScanner(self: *Grammar, sources: []const []const u8) !*onigLib.OnigScanner {
        return self.onig.createOnigScanner(sources);
    }

    pub fn createOnigString(self: *Grammar, content: []const u8) !*onigLib.OnigString {
        return self.onig.createOnigString(content);
    }

    pub fn ruleRegistry(self: *Grammar) rule.RuleRegistry {
        return .{
            .context = self,
            .vtable = &.{
                .allocator = registryAllocator,
                .get_rule = registryGetRule,
            },
            .onig = self.onig,
        };
    }

    pub fn ruleFactoryHelper(self: *Grammar) rule.RuleFactoryHelper {
        return .{
            .registry = self.ruleRegistry(),
            .context = self,
            .vtable = &.{
                .reserve_rule = factoryReserveRule,
                .set_rule = factorySetRule,
                .get_external_grammar = factoryGetExternalGrammar,
            },
        };
    }

    fn registryAllocator(context: *anyopaque) Allocator {
        const self: *Grammar = @ptrCast(@alignCast(context));
        return self.arena.allocator();
    }

    fn registryGetRule(context: *anyopaque, rule_id: RuleId) ?*rule.Rule {
        const self: *Grammar = @ptrCast(@alignCast(context));
        return self.getRuleMaybe(rule_id);
    }

    fn factoryReserveRule(context: *anyopaque) RuleId {
        const self: *Grammar = @ptrCast(@alignCast(context));
        self.last_rule_id += 1;
        self.rule_id2desc.append(self.arena.allocator(), null) catch @panic("out of memory");
        return @intCast(self.last_rule_id);
    }

    fn factorySetRule(context: *anyopaque, rule_id: RuleId, value: *rule.Rule) void {
        const self: *Grammar = @ptrCast(@alignCast(context));
        self.rule_id2desc.items[@intCast(rule_id)] = value;
    }

    fn factoryGetExternalGrammar(context: *anyopaque, scope_name: []const u8, repository: ?*Object) anyerror!?*Object {
        const self: *Grammar = @ptrCast(@alignCast(context));
        return self.getExternalGrammar(scope_name, repository);
    }

    pub fn registerRule(self: *Grammar, value: *rule.Rule) RuleId {
        _ = self;
        _ = value;
        unreachable;
    }

    pub fn getRuleMaybe(self: *Grammar, rule_id: RuleId) ?*rule.Rule {
        const index: usize = @intCast(rule_id);
        if (index >= self.rule_id2desc.items.len) return null;
        return self.rule_id2desc.items[index];
    }

    pub fn getRule(self: *Grammar, rule_id: RuleId) *rule.Rule {
        return self.getRuleMaybe(rule_id) orelse @panic("rule id not registered");
    }

    pub fn getExternalGrammar(
        self: *Grammar,
        scope_name: ScopeName,
        repository: ?*Object,
    ) !?*Object {
        if (self.included_grammars.get(scope_name)) |included| return included;
        const raw_included = self.grammar_repository.lookup(scope_name) orelse return null;
        const base = if (repository) |repo| repo.getObject("$base") else null;
        const included = try initGrammar(self.arena.allocator(), raw_included, base);
        try self.included_grammars.put(try self.arena.allocator().dupe(u8, scope_name), included);
        return included;
    }

    pub fn getInjections(self: *Grammar) []Injection {
        if (self.injections) |injections| return injections;
        const result = self.collectInjections() catch @panic("out of memory collecting injections");
        self.injections = result;
        return result;
    }

    fn collectInjections(self: *Grammar) ![]Injection {
        var result: std.ArrayList(Injection) = .empty;
        const arena = self.arena.allocator();

        const local_grammar = self.grammar;
        if (local_grammar.getObject("injections")) |raw_injections| {
            for (raw_injections.map.keys(), raw_injections.map.values()) |expression, value| {
                const injection_rule = switch (value) {
                    .object => |object| object,
                    else => continue,
                };
                try self.collectInjection(&result, expression, injection_rule, local_grammar, local_grammar);
            }
        }

        if (self.grammar_repository.injections(self.root_scope_name)) |injection_scope_names| {
            for (injection_scope_names) |injection_scope_name| {
                const injection_grammar = try self.getExternalGrammar(injection_scope_name, null) orelse continue;
                const selector = injection_grammar.getString("injectionSelector") orelse continue;
                try self.collectInjection(&result, selector, injection_grammar, injection_grammar, injection_grammar);
            }
        }

        for (result.items, 0..) |*injection, index| injection.order = index;
        std.mem.sort(Injection, result.items, {}, struct {
            fn lessThan(_: void, a: Injection, b: Injection) bool {
                if (a.priority != b.priority) return a.priority < b.priority;
                return a.order < b.order;
            }
        }.lessThan);

        return result.toOwnedSlice(arena);
    }

    fn collectInjection(
        self: *Grammar,
        result: *std.ArrayList(Injection),
        selector: []const u8,
        injection_rule: *Object,
        grammar_object: *Object,
        repository_grammar: *Object,
    ) !void {
        const arena = self.arena.allocator();
        const matchers = try matcher.createMatchers(ScopeArray, arena, selector, nameMatcher);
        const set_pointer = try arena.create(MatcherSetType);
        set_pointer.* = matchers;
        try self.matcher_sets.append(arena, set_pointer);

        const repository = repository_grammar.getObject("repository") orelse return;
        const helper = self.ruleFactoryHelper();
        const rule_id = try rule.RuleFactory.getCompiledRuleId(helper, injection_rule, repository);
        for (set_pointer.matchers) |entry| {
            try result.append(arena, .{
                .debug_selector = selector,
                .matcher = entry.matcher,
                .priority = entry.priority,
                .rule_id = rule_id,
                .grammar = grammar_object,
            });
        }
    }

    pub fn tokenizeLine(
        self: *Grammar,
        line_text: []const u8,
        prev_state: ?*StateStackImpl,
        time_limit: i64,
    ) !ITokenizeLineResult {
        const result = try self.tokenizeInternal(line_text, prev_state, false, time_limit);
        return .{
            .tokens = result.token_handler.getTokenResult(result.rule_stack, result.line_length),
            .fonts = result.token_handler.getFontResult(),
            .rule_stack = result.rule_stack,
            .stopped_early = result.stopped_early,
        };
    }

    pub fn tokenizeLine2(
        self: *Grammar,
        line_text: []const u8,
        prev_state: ?*StateStackImpl,
        time_limit: i64,
    ) !ITokenizeLineResult2 {
        const result = try self.tokenizeInternal(line_text, prev_state, true, time_limit);
        return .{
            .tokens = result.token_handler.getBinaryTokenResult(result.rule_stack, result.line_length),
            .fonts = result.token_handler.getFontResult(),
            .rule_stack = result.rule_stack,
            .stopped_early = result.stopped_early,
        };
    }

    const InternalResult = struct {
        line_length: usize,
        token_handler: *TokenHandler,
        rule_stack: *StateStackImpl,
        stopped_early: bool,
    };

    fn tokenizeInternal(
        self: *Grammar,
        line_text: []const u8,
        prev_state: ?*StateStackImpl,
        emit_binary: bool,
        time_limit: i64,
    ) !InternalResult {
        _ = self.token_arena.reset(.retain_capacity);
        _ = self.line_arena.reset(.retain_capacity);
        const scratch = self.token_arena.allocator();
        const line_alloc = self.line_arena.allocator();

        if (self.root_id == -1) {
            const helper = self.ruleFactoryHelper();
            self.root_id = try rule.RuleFactory.getCompiledRuleId(helper, self.grammar.getObject("repository").?.getObject("$self").?, self.grammar.getObject("repository").?);
            _ = self.getInjections();
        }

        var stack = prev_state;
        const is_first_line = stack == null or stack == StateStackImpl.NULL;
        if (is_first_line) {
            const raw_default_metadata = self.basic_scope_attributes_provider.getDefaultAttributes();
            const default_style = self.theme_provider.getDefaults();
            const default_metadata = encoded.set(
                0,
                raw_default_metadata.language_id,
                raw_default_metadata.token_type,
                null,
                default_style.font_style,
                default_style.foreground_id,
                default_style.background_id,
            );
            const font_attribute = try line_alloc.create(FontAttribute);
            font_attribute.* = .{
                .font_family = default_style.font_family,
                .font_size = default_style.font_size,
                .line_height = default_style.line_height,
            };
            const root_rule = self.getRule(self.root_id);
            const root_scope_name = (try root_rule.getName(line_alloc, null, null)) orelse null;
            const scope_list = if (root_scope_name) |name|
                try AttributedScopeStack.createRootAndLookUpScopeName(line_alloc, self, name, default_metadata, font_attribute)
            else
                try AttributedScopeStack.createRoot(line_alloc, "unknown", default_metadata, font_attribute);
            stack = try StateStackImpl.create(line_alloc, null, self.root_id, -1, -1, false, null, scope_list, scope_list);
        } else {
            stack.?.reset();
        }

        const line_with_newline = try std.fmt.allocPrint(scratch, "{s}\n", .{line_text});
        const onig_line_text = try self.createOnigString(line_with_newline);
        defer onig_line_text.deinit();
        const line_length = onig_line_text.utf16_len;

        const token_handler = try scratch.create(TokenHandler);
        token_handler.* = TokenHandler.init(
            scratch,
            emit_binary,
            line_text,
            self.token_type_matchers,
            self.balanced_bracket_selectors,
        );

        const outcome = try tokenizeString.tokenizeString(
            self,
            onig_line_text,
            is_first_line,
            0,
            stack.?,
            token_handler,
            true,
            time_limit,
        );

        const persistent_stack = (try copyStateStack(self.arena.allocator(), outcome.stack)).?;

        return .{
            .line_length = line_length,
            .token_handler = token_handler,
            .rule_stack = persistent_stack,
            .stopped_early = outcome.stopped_early,
        };
    }
};

fn initGrammar(allocator: Allocator, grammar: *Object, base: ?*Object) !*Object {
    const cloned = try rawGrammar.cloneObject(allocator, grammar);
    var repository = cloned.getObject("repository");
    if (repository == null) {
        const new_repository = try Object.create(allocator);
        try cloned.put(allocator, "repository", .{ .object = new_repository });
        repository = new_repository;
    }

    const self_rule = try Object.create(allocator);
    self_rule.location = cloned.location;
    try self_rule.put(allocator, "patterns", cloned.get("patterns") orelse .{ .array = &.{} });
    try self_rule.put(allocator, "name", .{ .string = cloned.getString("scopeName") orelse "" });

    try repository.?.put(allocator, "$self", .{ .object = self_rule });
    try repository.?.put(allocator, "$base", .{ .object = base orelse self_rule });
    return cloned;
}

pub fn nameMatcherForScopes(identifiers: ScopeArray, scopes: ScopeArray) bool {
    return nameMatcher(identifiers, scopes);
}

fn nameMatcher(identifiers: ScopeArray, scopes: ScopeArray) bool {
    if (scopes.len < identifiers.len) return false;
    var last_index: usize = 0;
    for (identifiers) |identifier| {
        var found = false;
        var index = last_index;
        while (index < scopes.len) : (index += 1) {
            if (scopesAreMatching(scopes[index], identifier)) {
                last_index = index + 1;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn scopesAreMatching(this_scope_name: ScopeName, scope_name: ScopeName) bool {
    if (this_scope_name.len == 0) return false;
    if (std.mem.eql(u8, this_scope_name, scope_name)) return true;
    return this_scope_name.len > scope_name.len and
        std.mem.startsWith(u8, this_scope_name, scope_name) and
        this_scope_name[scope_name.len] == '.';
}

pub const FontAttribute = struct {
    font_family: ?[]const u8,
    font_size: ?f64,
    line_height: ?f64,

    pub fn from(font_family: ?[]const u8, font_size: ?f64, line_height: ?f64) FontAttribute {
        return .{ .font_family = font_family, .font_size = font_size, .line_height = line_height };
    }

    pub fn with(
        self: *const FontAttribute,
        allocator: Allocator,
        style: ?theme.StyleAttributes,
    ) !*FontAttribute {
        const attributes = style orelse return @constCast(self);
        const result = try allocator.create(FontAttribute);
        result.* = .{
            .font_family = if (attributes.font_family.len != 0) attributes.font_family else self.font_family,
            .font_size = if (attributes.font_size != 0) attributes.font_size else self.font_size,
            .line_height = if (attributes.line_height != 0) attributes.line_height else self.line_height,
        };
        return result;
    }
};

pub const AttributedScopeStack = struct {
    parent: ?*AttributedScopeStack,
    scope_path: *theme.ScopeStack,
    token_attributes: u32,
    font_attributes: ?*FontAttribute,
    style_attributes: ?theme.StyleAttributes,
    scope_names: []const []const u8,
    persistent: bool = false,

    pub fn createRoot(
        allocator: Allocator,
        scope_name: ScopeName,
        token_attributes: u32,
        font_attribute: *FontAttribute,
    ) !*AttributedScopeStack {
        const path = try allocator.create(theme.ScopeStack);
        path.* = .{ .parent = null, .scope_name = scope_name };
        const names = try allocator.alloc([]const u8, 1);
        names[0] = scope_name;
        return createNode(allocator, null, path, token_attributes, font_attribute, null, names);
    }

    pub fn createRootAndLookUpScopeName(
        allocator: Allocator,
        grammar: *Grammar,
        scope_name: ScopeName,
        token_attributes: u32,
        font_attribute: *FontAttribute,
    ) !*AttributedScopeStack {
        const raw_metadata = try grammar.getMetadataForScope(scope_name);
        const path = try allocator.create(theme.ScopeStack);
        path.* = .{ .parent = null, .scope_name = scope_name };
        const root_style = try grammar.theme_provider.themeMatch(path);
        const resolved_attributes = mergeAttributes(token_attributes, raw_metadata, root_style);
        const resolved_font = try font_attribute.with(allocator, root_style);
        const names = try allocator.alloc([]const u8, 1);
        names[0] = scope_name;
        return createNode(allocator, null, path, resolved_attributes, resolved_font, root_style, names);
    }

    fn createNode(
        allocator: Allocator,
        parent: ?*AttributedScopeStack,
        scope_path: *theme.ScopeStack,
        token_attributes: u32,
        font_attributes: ?*FontAttribute,
        style_attributes: ?theme.StyleAttributes,
        scope_names: []const []const u8,
    ) !*AttributedScopeStack {
        const result = try allocator.create(AttributedScopeStack);
        result.* = .{
            .parent = parent,
            .scope_path = scope_path,
            .token_attributes = token_attributes,
            .font_attributes = font_attributes,
            .style_attributes = style_attributes,
            .scope_names = scope_names,
            .persistent = false,
        };
        return result;
    }

    pub fn fromExtension(
        allocator: Allocator,
        names_scope_list: ?*AttributedScopeStack,
        content_name_scopes_list: []const AttributedScopeStackFrame,
    ) !?*AttributedScopeStack {
        var current = names_scope_list;
        var current_path: ?*theme.ScopeStack = if (names_scope_list) |list| list.scope_path else null;
        for (content_name_scopes_list) |frame| {
            for (frame.scope_names) |scope_name| {
                const node = try allocator.create(theme.ScopeStack);
                node.* = .{ .parent = current_path, .scope_name = scope_name, .persistent = true };
                current_path = node;
            }
            const names = try appendScopeName(allocator, if (current) |list| list.scope_names else &.{}, frame.scope_names);
            current = try createNode(
                allocator,
                current,
                current_path.?,
                frame.encoded_token_attributes,
                null,
                null,
                names,
            );
            current.?.persistent = true;
        }
        return current;
    }

    pub fn scopeName(self: *const AttributedScopeStack) ScopeName {
        return self.scope_path.scope_name;
    }

    pub fn getScopeNames(self: *const AttributedScopeStack) []const []const u8 {
        return self.scope_names;
    }

    pub fn equals(a: ?*const AttributedScopeStack, b: ?*const AttributedScopeStack) bool {
        var left = a;
        var right = b;
        while (true) {
            if (left == right) return true;
            if (left == null and right == null) return true;
            if (left == null or right == null) return false;
            if (!std.mem.eql(u8, left.?.scopeName(), right.?.scopeName()) or
                left.?.token_attributes != right.?.token_attributes)
            {
                return false;
            }
            left = left.?.parent;
            right = right.?.parent;
        }
    }

    pub fn pushAttributed(
        self: *AttributedScopeStack,
        allocator: Allocator,
        grammar: *Grammar,
        scope_path: ?ScopePath,
    ) !*AttributedScopeStack {
        const path = scope_path orelse return self;
        if (std.mem.indexOfScalar(u8, path, ' ') == null) {
            return self.pushOne(allocator, grammar, path);
        }

        var result = self;
        var iterator = std.mem.splitScalar(u8, path, ' ');
        while (iterator.next()) |scope_name| {
            result = try result.pushOne(allocator, grammar, scope_name);
        }
        return result;
    }

    fn pushOne(
        self: *AttributedScopeStack,
        allocator: Allocator,
        grammar: *Grammar,
        scope_name: ScopeName,
    ) !*AttributedScopeStack {
        const raw_metadata = try grammar.getMetadataForScope(scope_name);
        const new_path = try allocator.create(theme.ScopeStack);
        new_path.* = .{ .parent = self.scope_path, .scope_name = scope_name };
        const scope_theme_match = try grammar.theme_provider.themeMatch(new_path);
        const metadata = mergeAttributes(self.token_attributes, raw_metadata, scope_theme_match);
        const font_attributes = if (self.font_attributes) |font|
            try font.with(allocator, scope_theme_match)
        else
            null;
        const names = try appendScopeName(allocator, self.scope_names, &.{scope_name});
        return createNode(allocator, self, new_path, metadata, font_attributes, scope_theme_match, names);
    }

    pub fn getExtensionIfDefined(
        self: *const AttributedScopeStack,
        allocator: Allocator,
        base: ?*const AttributedScopeStack,
    ) !?[]AttributedScopeStackFrame {
        var frames: std.ArrayList(AttributedScopeStackFrame) = .empty;
        errdefer frames.deinit(allocator);
        var current: ?*const AttributedScopeStack = self;
        while (current != null and current != base) : (current = current.?.parent) {
            const scope_names = try current.?.scope_path.getExtensionIfDefined(
                allocator,
                if (current.?.parent) |parent| parent.scope_path else null,
            ) orelse return null;
            try frames.append(allocator, .{
                .encoded_token_attributes = current.?.token_attributes,
                .scope_names = scope_names,
            });
        }
        if (current != base) return null;
        std.mem.reverse(AttributedScopeStackFrame, frames.items);
        return try frames.toOwnedSlice(allocator);
    }
};

fn appendScopeName(
    allocator: Allocator,
    existing: []const []const u8,
    added: []const []const u8,
) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, existing.len + added.len);
    @memcpy(result[0..existing.len], existing);
    @memcpy(result[existing.len..], added);
    return result;
}

fn mergeAttributes(
    existing_attributes: u32,
    basic_attributes: basic.BasicScopeAttributes,
    style_attributes: ?theme.StyleAttributes,
) u32 {
    var font_style: i32 = theme.FontStyle.not_set;
    var foreground: u32 = 0;
    var background: u32 = 0;
    if (style_attributes) |style| {
        font_style = style.font_style;
        foreground = style.foreground_id;
        background = style.background_id;
    }
    return encoded.set(
        existing_attributes,
        basic_attributes.language_id,
        basic_attributes.token_type,
        null,
        font_style,
        foreground,
        background,
    );
}

fn copyScopeStack(allocator: Allocator, source: *const theme.ScopeStack) !*theme.ScopeStack {
    if (source.persistent) return @constCast(source);
    const parent: ?*const theme.ScopeStack = if (source.parent) |parent_node|
        try copyScopeStack(allocator, parent_node)
    else
        null;
    const result = try allocator.create(theme.ScopeStack);
    result.* = .{
        .parent = parent,
        .scope_name = try allocator.dupe(u8, source.scope_name),
        .persistent = true,
    };
    return result;
}

fn copyAttributedStack(
    allocator: Allocator,
    source: ?*AttributedScopeStack,
) !?*AttributedScopeStack {
    const stack = source orelse return null;
    if (stack.persistent) return stack;

    const parent = try copyAttributedStack(allocator, stack.parent);
    const path = try copyScopeStack(allocator, stack.scope_path);
    const names = try allocator.alloc([]const u8, stack.scope_names.len);
    for (stack.scope_names, 0..) |name, index| names[index] = try allocator.dupe(u8, name);
    const font = if (stack.font_attributes) |font_attributes| blk: {
        const copied = try allocator.create(FontAttribute);
        copied.* = font_attributes.*;
        break :blk copied;
    } else null;

    const result = try allocator.create(AttributedScopeStack);
    result.* = .{
        .parent = parent,
        .scope_path = path,
        .token_attributes = stack.token_attributes,
        .font_attributes = font,
        .style_attributes = stack.style_attributes,
        .scope_names = names,
        .persistent = true,
    };
    return result;
}

fn copyStateStack(
    allocator: Allocator,
    source: ?*StateStackImpl,
) !?*StateStackImpl {
    const stack = source orelse return null;
    if (stack.persistent) return stack;

    const parent = try copyStateStack(allocator, stack.parent);
    const name_scopes = try copyAttributedStack(allocator, stack.name_scopes_list);
    const content_scopes = if (stack.content_name_scopes_list == stack.name_scopes_list)
        name_scopes
    else
        try copyAttributedStack(allocator, stack.content_name_scopes_list);
    const end_rule = if (stack.end_rule) |rule_source| try allocator.dupe(u8, rule_source) else null;

    const result = try allocator.create(StateStackImpl);
    result.* = .{
        .parent = parent,
        .rule_id = stack.rule_id,
        .enter_pos = stack.enter_pos,
        .anchor_pos = stack.anchor_pos,
        .begin_rule_captured_eol = stack.begin_rule_captured_eol,
        .end_rule = end_rule,
        .name_scopes_list = name_scopes,
        .content_name_scopes_list = content_scopes,
        .depth = stack.depth,
        .persistent = true,
    };
    return result;
}

pub const StateStackImpl = struct {
    parent: ?*StateStackImpl,
    rule_id: RuleId,
    enter_pos: i32,
    anchor_pos: i32,
    begin_rule_captured_eol: bool,
    end_rule: ?[]const u8,
    name_scopes_list: ?*AttributedScopeStack,
    content_name_scopes_list: ?*AttributedScopeStack,
    depth: usize,
    persistent: bool = false,

    pub fn create(
        allocator: Allocator,
        parent: ?*StateStackImpl,
        rule_id: RuleId,
        enter_pos: i32,
        anchor_pos: i32,
        begin_rule_captured_eol: bool,
        end_rule: ?[]const u8,
        name_scopes_list: ?*AttributedScopeStack,
        content_name_scopes_list: ?*AttributedScopeStack,
    ) !*StateStackImpl {
        const result = try allocator.create(StateStackImpl);
        result.* = .{
            .parent = parent,
            .rule_id = rule_id,
            .enter_pos = enter_pos,
            .anchor_pos = anchor_pos,
            .begin_rule_captured_eol = begin_rule_captured_eol,
            .end_rule = end_rule,
            .name_scopes_list = name_scopes_list,
            .content_name_scopes_list = content_name_scopes_list,
            .depth = if (parent) |node| node.depth + 1 else 1,
            .persistent = false,
        };
        return result;
    }

    pub const NULL: *StateStackImpl = &null_stack_instance;
    var null_stack_instance: StateStackImpl = .{
        .parent = null,
        .rule_id = 0,
        .enter_pos = 0,
        .anchor_pos = 0,
        .begin_rule_captured_eol = false,
        .end_rule = null,
        .name_scopes_list = null,
        .content_name_scopes_list = null,
        .depth = 1,
        .persistent = true,
    };

    pub fn equals(self: *const StateStackImpl, other: *const StateStackImpl) bool {
        if (self == other) return true;
        if (!structuralEquals(self, other)) return false;
        return AttributedScopeStack.equals(self.content_name_scopes_list, other.content_name_scopes_list);
    }

    fn structuralEquals(a_start: ?*const StateStackImpl, b_start: ?*const StateStackImpl) bool {
        var a = a_start;
        var b = b_start;
        while (true) {
            if (a == b) return true;
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            if (a.?.depth != b.?.depth or a.?.rule_id != b.?.rule_id or
                !optionalStringEqual(a.?.end_rule, b.?.end_rule))
            {
                return false;
            }
            a = a.?.parent;
            b = b.?.parent;
        }
    }

    pub fn reset(self: *StateStackImpl) void {
        var item: ?*StateStackImpl = self;
        while (item) |node| : (item = node.parent) {
            node.enter_pos = -1;
            node.anchor_pos = -1;
        }
    }

    pub fn pop(self: *StateStackImpl) ?*StateStackImpl {
        return self.parent;
    }

    pub fn safePop(self: *StateStackImpl) *StateStackImpl {
        return self.parent orelse self;
    }

    pub fn push(
        self: *StateStackImpl,
        allocator: Allocator,
        rule_id: RuleId,
        enter_pos: i32,
        anchor_pos: i32,
        begin_rule_captured_eol: bool,
        end_rule: ?[]const u8,
        name_scopes_list: ?*AttributedScopeStack,
        content_name_scopes_list: ?*AttributedScopeStack,
    ) !*StateStackImpl {
        return create(allocator, self, rule_id, enter_pos, anchor_pos, begin_rule_captured_eol, end_rule, name_scopes_list, content_name_scopes_list);
    }

    pub fn getEnterPos(self: *const StateStackImpl) i32 {
        return self.enter_pos;
    }

    pub fn getAnchorPos(self: *const StateStackImpl) i32 {
        return self.anchor_pos;
    }

    pub fn getRule(self: *const StateStackImpl, grammar: *Grammar) *rule.Rule {
        return grammar.getRule(self.rule_id);
    }

    pub fn withContentNameScopesList(
        self: *StateStackImpl,
        allocator: Allocator,
        content_name_scopes_list: *AttributedScopeStack,
    ) !*StateStackImpl {
        if (self.content_name_scopes_list == content_name_scopes_list) return self;
        if (self.parent) |parent| {
            return parent.push(
                allocator,
                self.rule_id,
                self.enter_pos,
                self.anchor_pos,
                self.begin_rule_captured_eol,
                self.end_rule,
                self.name_scopes_list,
                content_name_scopes_list,
            );
        }
        return create(allocator, null, self.rule_id, self.enter_pos, self.anchor_pos, self.begin_rule_captured_eol, self.end_rule, self.name_scopes_list, content_name_scopes_list);
    }

    pub fn withEndRule(self: *StateStackImpl, allocator: Allocator, end_rule: []const u8) !*StateStackImpl {
        if (self.end_rule != null and std.mem.eql(u8, self.end_rule.?, end_rule)) return self;
        return create(allocator, self.parent, self.rule_id, self.enter_pos, self.anchor_pos, self.begin_rule_captured_eol, end_rule, self.name_scopes_list, self.content_name_scopes_list);
    }

    pub fn hasSameRuleAs(self: *const StateStackImpl, other: *const StateStackImpl) bool {
        var element: ?*const StateStackImpl = self;
        while (element) |node| {
            if (node.enter_pos != other.enter_pos) break;
            if (node.rule_id == other.rule_id) return true;
            element = node.parent;
        }
        return false;
    }

    pub fn toStateStackFrame(self: *const StateStackImpl, allocator: Allocator) !StateStackFrame {
        return .{
            .rule_id = self.rule_id,
            .begin_rule_captured_eol = self.begin_rule_captured_eol,
            .end_rule = self.end_rule,
            .name_scopes_list = if (self.name_scopes_list) |names|
                (try names.getExtensionIfDefined(
                    allocator,
                    if (self.parent) |parent| parent.name_scopes_list else null,
                )) orelse &.{}
            else
                &.{},
            .content_name_scopes_list = if (self.content_name_scopes_list) |content|
                (try content.getExtensionIfDefined(allocator, self.name_scopes_list)) orelse &.{}
            else
                &.{},
        };
    }

    pub fn pushFrame(
        allocator: Allocator,
        self: ?*StateStackImpl,
        frame: StateStackFrame,
    ) !*StateStackImpl {
        const names = try AttributedScopeStack.fromExtension(
            allocator,
            if (self) |stack| stack.name_scopes_list else null,
            frame.name_scopes_list,
        );
        const content = try AttributedScopeStack.fromExtension(allocator, names, frame.content_name_scopes_list);
        const result = try create(
            allocator,
            self,
            frame.rule_id,
            frame.enter_pos orelse -1,
            frame.anchor_pos orelse -1,
            frame.begin_rule_captured_eol,
            frame.end_rule,
            names,
            content,
        );
        result.persistent = true;
        return result;
    }
};

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const BalancedBracketSelectors = struct {
    balanced_bracket_scopes: []const *const MatcherType,
    unbalanced_bracket_scopes: []const *const MatcherType,
    allow_any: bool,

    pub fn init(
        allocator: Allocator,
        balanced: []const []const u8,
        unbalanced: []const []const u8,
        matcher_sets: *std.ArrayList(*MatcherSetType),
    ) !*BalancedBracketSelectors {
        var balanced_matchers: std.ArrayList(*const MatcherType) = .empty;
        var unbalanced_matchers: std.ArrayList(*const MatcherType) = .empty;
        var allow_any = false;

        for (balanced) |selector| {
            if (std.mem.eql(u8, selector, "*")) {
                allow_any = true;
                continue;
            }
            const set = try matcher.createMatchers(ScopeArray, allocator, selector, nameMatcher);
            const set_pointer = try allocator.create(MatcherSetType);
            set_pointer.* = set;
            try matcher_sets.append(allocator, set_pointer);
            for (set_pointer.matchers) |entry| try balanced_matchers.append(allocator, entry.matcher);
        }
        for (unbalanced) |selector| {
            const set = try matcher.createMatchers(ScopeArray, allocator, selector, nameMatcher);
            const set_pointer = try allocator.create(MatcherSetType);
            set_pointer.* = set;
            try matcher_sets.append(allocator, set_pointer);
            for (set_pointer.matchers) |entry| try unbalanced_matchers.append(allocator, entry.matcher);
        }

        const result = try allocator.create(BalancedBracketSelectors);
        result.* = .{
            .balanced_bracket_scopes = try balanced_matchers.toOwnedSlice(allocator),
            .unbalanced_bracket_scopes = try unbalanced_matchers.toOwnedSlice(allocator),
            .allow_any = allow_any,
        };
        return result;
    }

    pub fn matchesAlways(self: *const BalancedBracketSelectors) bool {
        return self.allow_any and self.unbalanced_bracket_scopes.len == 0;
    }

    pub fn matchesNever(self: *const BalancedBracketSelectors) bool {
        return self.balanced_bracket_scopes.len == 0 and !self.allow_any;
    }

    pub fn match(self: *const BalancedBracketSelectors, scopes: ScopeArray) bool {
        for (self.unbalanced_bracket_scopes) |excluder| {
            if (excluder.evaluate(nameMatcher, scopes)) return false;
        }
        for (self.balanced_bracket_scopes) |includer| {
            if (includer.evaluate(nameMatcher, scopes)) return true;
        }
        return self.allow_any;
    }
};

pub const IToken = struct {
    start_index: usize,
    end_index: usize,
    scopes: []const []const u8,
};

pub const FontInfo = struct {
    start_index: usize,
    end_index: usize,
    font_family: ?[]const u8,
    font_size_multiplier: ?f64,
    line_height_multiplier: ?f64,

    pub fn optionsEqual(self: *const FontInfo, other: *const FontInfo) bool {
        return optionalStringEqual(self.font_family, other.font_family) and
            optionalNumberEqual(self.font_size_multiplier, other.font_size_multiplier) and
            optionalNumberEqual(self.line_height_multiplier, other.line_height_multiplier);
    }
};

fn optionalNumberEqual(a: ?f64, b: ?f64) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

pub const LineTokens = struct {
    allocator: Allocator,
    emit_binary_tokens: bool,
    line_text: []const u8,
    tokens: std.ArrayList(IToken) = .empty,
    binary_tokens: std.ArrayList(u32) = .empty,
    last_token_end_index: usize = 0,
    token_type_overrides: []TokenTypeMatcher,
    balanced_bracket_selectors: ?*BalancedBracketSelectors,
    merge_consecutive_tokens_with_equal_metadata: bool,

    pub fn init(
        allocator: Allocator,
        emit_binary_tokens: bool,
        line_text: []const u8,
        token_type_overrides: []TokenTypeMatcher,
        balanced_bracket_selectors: ?*BalancedBracketSelectors,
    ) LineTokens {
        return .{
            .allocator = allocator,
            .emit_binary_tokens = emit_binary_tokens,
            .line_text = line_text,
            .token_type_overrides = token_type_overrides,
            .balanced_bracket_selectors = balanced_bracket_selectors,
            .merge_consecutive_tokens_with_equal_metadata = !utils.containsRTL(line_text),
        };
    }

    pub fn produceFromScopes(self: *LineTokens, scopes_list: ?*AttributedScopeStack, end_index: usize) !void {
        if (self.last_token_end_index >= end_index) return;

        if (self.emit_binary_tokens) {
            var metadata: u32 = if (scopes_list) |scopes| scopes.token_attributes else 0;
            var contains_balanced_brackets = false;
            if (self.balanced_bracket_selectors) |selectors| {
                if (selectors.matchesAlways()) contains_balanced_brackets = true;
            }

            if (self.token_type_overrides.len > 0 or
                (self.balanced_bracket_selectors != null and
                    !self.balanced_bracket_selectors.?.matchesAlways() and
                    !self.balanced_bracket_selectors.?.matchesNever()))
            {
                const scopes = if (scopes_list) |list| list.getScopeNames() else &.{};
                for (self.token_type_overrides) |override| {
                    if (override.matcher.evaluate(nameMatcher, scopes)) {
                        metadata = encoded.set(metadata, 0, override.token_type, null, theme.FontStyle.not_set, 0, 0);
                    }
                }
                if (self.balanced_bracket_selectors) |selectors| {
                    contains_balanced_brackets = selectors.match(scopes);
                }
            }

            if (contains_balanced_brackets) {
                metadata = encoded.set(metadata, 0, encoded.OptionalStandardTokenType.not_set, true, theme.FontStyle.not_set, 0, 0);
            }

            if (self.merge_consecutive_tokens_with_equal_metadata and self.binary_tokens.items.len > 0 and
                self.binary_tokens.items[self.binary_tokens.items.len - 1] == metadata)
            {
                self.last_token_end_index = end_index;
                return;
            }

            try self.binary_tokens.append(self.allocator, @intCast(self.last_token_end_index));
            try self.binary_tokens.append(self.allocator, metadata);
            self.last_token_end_index = end_index;
            return;
        }

        const scopes = if (scopes_list) |list| list.getScopeNames() else &.{};
        try self.tokens.append(self.allocator, .{
            .start_index = self.last_token_end_index,
            .end_index = end_index,
            .scopes = scopes,
        });
        self.last_token_end_index = end_index;
    }

    pub fn getResult(self: *LineTokens, stack: *StateStackImpl, line_length: usize) []IToken {
        if (self.tokens.items.len > 0 and self.tokens.items[self.tokens.items.len - 1].start_index == line_length - 1) {
            _ = self.tokens.pop();
        }
        if (self.tokens.items.len == 0) {
            self.last_token_end_index = 0;
            self.produceFromScopes(stack.content_name_scopes_list, line_length) catch @panic("out of memory");
            if (self.tokens.items.len > 0) self.tokens.items[self.tokens.items.len - 1].start_index = 0;
        }
        return self.tokens.items;
    }

    pub fn getBinaryResult(self: *LineTokens, stack: *StateStackImpl, line_length: usize) []const u32 {
        if (self.binary_tokens.items.len > 0 and self.binary_tokens.items[self.binary_tokens.items.len - 2] == line_length - 1) {
            _ = self.binary_tokens.pop();
            _ = self.binary_tokens.pop();
        }
        if (self.binary_tokens.items.len == 0) {
            self.last_token_end_index = 0;
            self.produceFromScopes(stack.content_name_scopes_list, line_length) catch @panic("out of memory");
            if (self.binary_tokens.items.len >= 2) self.binary_tokens.items[self.binary_tokens.items.len - 2] = 0;
        }
        return self.binary_tokens.items;
    }
};

pub const LineFonts = struct {
    allocator: Allocator,
    fonts: std.ArrayList(FontInfo) = .empty,
    last_index: usize = 0,

    pub fn init(allocator: Allocator) LineFonts {
        return .{ .allocator = allocator };
    }

    pub fn produceFromScopes(self: *LineFonts, scopes_list: ?*AttributedScopeStack, end_index: usize) !void {
        const font_attributes = if (scopes_list) |scopes| scopes.font_attributes else null;
        const attributes = font_attributes orelse {
            self.last_index = end_index;
            return;
        };
        if (attributes.font_family == null and attributes.font_size == null and attributes.line_height == null) {
            self.last_index = end_index;
            return;
        }

        const font_family: ?[]const u8 = if (attributes.font_family) |family|
            if (family.len == 0) null else family
        else
            null;
        const font_size: ?f64 = if (attributes.font_size) |size| if (size == 0) null else size else null;
        const line_height: ?f64 = if (attributes.line_height) |height| if (height == 0) null else height else null;
        if (font_family == null and font_size == null and line_height == null) {
            self.last_index = end_index;
            return;
        }

        const font = FontInfo{
            .start_index = self.last_index,
            .end_index = end_index,
            .font_family = font_family,
            .font_size_multiplier = font_size,
            .line_height_multiplier = line_height,
        };
        if (self.fonts.items.len > 0) {
            const last = &self.fonts.items[self.fonts.items.len - 1];
            if (last.end_index == self.last_index and last.optionsEqual(&font)) {
                last.end_index = end_index;
                self.last_index = end_index;
                return;
            }
        }
        try self.fonts.append(self.allocator, font);
        self.last_index = end_index;
    }

    pub fn getResult(self: *LineFonts) []FontInfo {
        return self.fonts.items;
    }
};

pub const TokenHandler = struct {
    line_tokens: LineTokens,
    line_fonts: LineFonts,

    pub fn init(
        allocator: Allocator,
        emit_binary_tokens: bool,
        line_text: []const u8,
        token_type_overrides: []TokenTypeMatcher,
        balanced_bracket_selectors: ?*BalancedBracketSelectors,
    ) TokenHandler {
        return .{
            .line_tokens = LineTokens.init(allocator, emit_binary_tokens, line_text, token_type_overrides, balanced_bracket_selectors),
            .line_fonts = LineFonts.init(allocator),
        };
    }

    pub fn handle(self: *TokenHandler, scopes: ?*AttributedScopeStack, end_index: usize) void {
        self.line_tokens.produceFromScopes(scopes, end_index) catch @panic("out of memory");
        self.line_fonts.produceFromScopes(scopes, end_index) catch @panic("out of memory");
    }

    pub fn getTokenResult(self: *TokenHandler, stack: *StateStackImpl, line_length: usize) []IToken {
        return self.line_tokens.getResult(stack, line_length);
    }

    pub fn getBinaryTokenResult(self: *TokenHandler, stack: *StateStackImpl, line_length: usize) []const u32 {
        return self.line_tokens.getBinaryResult(stack, line_length);
    }

    pub fn getFontResult(self: *TokenHandler) []FontInfo {
        return self.line_fonts.getResult();
    }
};

pub const ITokenizeLineResult = struct {
    tokens: []IToken,
    fonts: []FontInfo,
    rule_stack: *StateStackImpl,
    stopped_early: bool,
};

pub const ITokenizeLineResult2 = struct {
    tokens: []const u32,
    fonts: []FontInfo,
    rule_stack: *StateStackImpl,
    stopped_early: bool,
};

test "grammar tokenizes a simple match rule" {
    const parseRawGrammar = @import("../parseRawGrammar.zig");
    const allocator = std.testing.allocator;

    var raw = try parseRawGrammar.parseRawGrammar(
        allocator,
        "{\"scopeName\":\"source.test\",\"patterns\":[{\"match\":\"foo\",\"name\":\"keyword.control.test\"}]}",
        "test.json",
    );
    defer raw.deinit();

    const test_theme = try theme.Theme.createFromRawTheme(allocator, null, null);
    defer test_theme.deinit();

    const Context = struct {
        raw: *Object,
        theme: *theme.Theme,

        fn lookup(context: *anyopaque, scope_name: []const u8) ?*Object {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, scope_name, self.raw.getString("scopeName").?)) return self.raw;
            return null;
        }
        fn injections(context: *anyopaque, scope_name: []const u8) ?[]const []const u8 {
            _ = context;
            _ = scope_name;
            return null;
        }
        fn themeMatch(context: *anyopaque, scope_path: ?*const theme.ScopeStack) anyerror!?theme.StyleAttributes {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.theme.match(scope_path);
        }
        fn getDefaults(context: *anyopaque) theme.StyleAttributes {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.theme.getDefaults();
        }
    };

    var context = Context{ .raw = raw.root, .theme = test_theme };
    var onig_lib = onigLib.OnigLib.init(allocator);
    const grammar = try Grammar.create(allocator, .{
        .scope_name = "source.test",
        .grammar = raw.root,
        .repository = .{
            .context = &context,
            .vtable = &.{ .lookup = Context.lookup, .injections = Context.injections },
        },
        .theme_provider = .{
            .context = &context,
            .vtable = &.{ .theme_match = Context.themeMatch, .get_defaults = Context.getDefaults },
        },
        .onig = onig_lib.interface(),
    });
    defer grammar.deinit();

    const result = try grammar.tokenizeLine("foo", null, 0);
    try std.testing.expectEqual(@as(usize, 1), result.tokens.len);
    try std.testing.expectEqualStrings("foo", "foo");
    try std.testing.expectEqual(@as(usize, 0), result.tokens[0].start_index);
    try std.testing.expectEqual(@as(usize, 3), result.tokens[0].end_index);
}

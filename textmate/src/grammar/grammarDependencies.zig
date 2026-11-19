// Port of `vscode-textmate/src/grammar/grammarDependencies.ts`
// (microsoft/vscode-textmate v9.3.2).
//
// `IGrammarRepository` lives here rather than in `grammar.zig` to avoid an
// import cycle; the contract is the same.
const std = @import("std");
const rawGrammar = @import("../rawGrammar.zig");
const Allocator = std.mem.Allocator;
const Object = rawGrammar.Object;

pub const ScopeName = []const u8;

pub const IGrammarRepository = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        lookup: *const fn (context: *anyopaque, scope_name: ScopeName) ?*Object,
        injections: *const fn (context: *anyopaque, scope_name: ScopeName) ?[]const ScopeName,
    };

    pub fn lookup(self: IGrammarRepository, scope_name: ScopeName) ?*Object {
        return self.vtable.lookup(self.context, scope_name);
    }

    pub fn injections(self: IGrammarRepository, scope_name: ScopeName) ?[]const ScopeName {
        return self.vtable.injections(self.context, scope_name);
    }
};

pub const AbsoluteRuleReference = union(enum) {
    top_level: TopLevelRuleReference,
    top_level_repository: TopLevelRepositoryRuleReference,
};

pub const TopLevelRuleReference = struct {
    scope_name: ScopeName,
};

pub const TopLevelRepositoryRuleReference = struct {
    scope_name: ScopeName,
    rule_name: []const u8,
};

pub fn toKey(allocator: Allocator, reference: AbsoluteRuleReference) ![]u8 {
    return switch (reference) {
        .top_level => |ref| allocator.dupe(u8, ref.scope_name),
        .top_level_repository => |ref| std.fmt.allocPrint(allocator, "{s}#{s}", .{ ref.scope_name, ref.rule_name }),
    };
}

pub const ExternalReferenceCollector = struct {
    allocator: Allocator,
    scratch: std.heap.ArenaAllocator,
    references_list: std.ArrayList(AbsoluteRuleReference) = .empty,
    seen_reference_keys: std.StringHashMap(void),
    visited_rule: std.AutoHashMap(*Object, void),

    pub fn init(allocator: Allocator) ExternalReferenceCollector {
        return .{
            .allocator = allocator,
            .scratch = std.heap.ArenaAllocator.init(allocator),
            .seen_reference_keys = std.StringHashMap(void).init(allocator),
            .visited_rule = std.AutoHashMap(*Object, void).init(allocator),
        };
    }

    pub fn deinit(self: *ExternalReferenceCollector) void {
        self.references_list.deinit(self.allocator);
        var key_iterator = self.seen_reference_keys.keyIterator();
        while (key_iterator.next()) |key| self.allocator.free(key.*);
        self.seen_reference_keys.deinit();
        self.visited_rule.deinit();
        self.scratch.deinit();
    }

    pub fn getReferences(self: *const ExternalReferenceCollector) []const AbsoluteRuleReference {
        return self.references_list.items;
    }

    pub fn add(self: *ExternalReferenceCollector, reference: AbsoluteRuleReference) !void {
        const key = try toKey(self.allocator, reference);
        const gop = try self.seen_reference_keys.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(key);
            return;
        }
        try self.references_list.append(self.allocator, reference);
    }
};

pub const ScopeDependencyProcessor = struct {
    allocator: Allocator,
    repo: IGrammarRepository,
    initial_scope_name: ScopeName,
    seen_full_scope_requests: std.StringHashMap(void),
    seen_partial_scope_requests: std.StringHashMap(void),
    queue: std.ArrayList(AbsoluteRuleReference) = .empty,

    pub fn init(allocator: Allocator, repo: IGrammarRepository, initial_scope_name: ScopeName) !*ScopeDependencyProcessor {
        const self = try allocator.create(ScopeDependencyProcessor);
        self.* = .{
            .allocator = allocator,
            .repo = repo,
            .initial_scope_name = initial_scope_name,
            .seen_full_scope_requests = std.StringHashMap(void).init(allocator),
            .seen_partial_scope_requests = std.StringHashMap(void).init(allocator),
        };
        try self.seen_full_scope_requests.put(initial_scope_name, {});
        try self.queue.append(allocator, .{ .top_level = .{ .scope_name = initial_scope_name } });
        return self;
    }

    pub fn deinit(self: *ScopeDependencyProcessor) void {
        self.queue.deinit(self.allocator);
        self.seen_full_scope_requests.deinit();
        var partial_iterator = self.seen_partial_scope_requests.keyIterator();
        while (partial_iterator.next()) |key| self.allocator.free(key.*);
        self.seen_partial_scope_requests.deinit();
        self.allocator.destroy(self);
    }

    pub fn hasPending(self: *const ScopeDependencyProcessor) bool {
        return self.queue.items.len > 0;
    }

    pub fn processQueue(self: *ScopeDependencyProcessor) !void {
        const current = try self.queue.toOwnedSlice(self.allocator);
        defer self.allocator.free(current);

        var dependencies = ExternalReferenceCollector.init(self.allocator);
        defer dependencies.deinit();

        for (current) |dependency| {
            try collectReferencesOfReference(dependency, self.initial_scope_name, self.repo, &dependencies);
        }

        for (dependencies.getReferences()) |dependency| {
            switch (dependency) {
                .top_level => |ref| {
                    if (self.seen_full_scope_requests.contains(ref.scope_name)) continue;
                    try self.seen_full_scope_requests.put(ref.scope_name, {});
                    try self.queue.append(self.allocator, dependency);
                },
                .top_level_repository => |ref| {
                    if (self.seen_full_scope_requests.contains(ref.scope_name)) continue;
                    const key = try toKey(self.allocator, dependency);
                    if (self.seen_partial_scope_requests.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try self.seen_partial_scope_requests.put(key, {});
                    try self.queue.append(self.allocator, .{
                        .top_level_repository = .{
                            .scope_name = ref.scope_name,
                            .rule_name = ref.rule_name,
                        },
                    });
                },
            }
        }
    }
};

fn collectReferencesOfReference(
    reference: AbsoluteRuleReference,
    base_grammar_scope_name: ScopeName,
    repo: IGrammarRepository,
    result: *ExternalReferenceCollector,
) anyerror!void {
    const reference_scope_name = switch (reference) {
        .top_level => |ref| ref.scope_name,
        .top_level_repository => |ref| ref.scope_name,
    };

    const self_grammar = repo.lookup(reference_scope_name) orelse {
        if (std.mem.eql(u8, reference_scope_name, base_grammar_scope_name)) {
            return error.NoGrammarProvided;
        }
        return;
    };
    const base_grammar = repo.lookup(base_grammar_scope_name) orelse return error.NoGrammarProvided;

    switch (reference) {
        .top_level => try collectExternalReferencesInTopLevelRule(
            .{ .base_grammar = base_grammar, .self_grammar = self_grammar },
            result,
        ),
        .top_level_repository => |ref| try collectExternalReferencesInTopLevelRepositoryRule(
            ref.rule_name,
            .{
                .base_grammar = base_grammar,
                .self_grammar = self_grammar,
                .repository = self_grammar.getObject("repository"),
            },
            result,
        ),
    }

    if (repo.injections(reference_scope_name)) |injections| {
        for (injections) |injection| {
            try result.add(.{ .top_level = .{ .scope_name = injection } });
        }
    }
}

const Context = struct {
    base_grammar: *Object,
    self_grammar: *Object,
};

const ContextWithRepository = struct {
    base_grammar: *Object,
    self_grammar: *Object,
    repository: ?*Object,
};

fn collectExternalReferencesInTopLevelRepositoryRule(
    rule_name: []const u8,
    context: ContextWithRepository,
    result: *ExternalReferenceCollector,
) anyerror!void {
    if (context.repository) |repository| {
        const rule = repository.getObject(rule_name) orelse return;
        try collectExternalReferencesInRules(&.{.{ .object = rule }}, context, result);
    }
}

fn collectExternalReferencesInTopLevelRule(context: Context, result: *ExternalReferenceCollector) anyerror!void {
    if (context.self_grammar.getArray("patterns")) |patterns| {
        try collectExternalReferencesInRules(patterns, .{
            .base_grammar = context.base_grammar,
            .self_grammar = context.self_grammar,
            .repository = context.self_grammar.getObject("repository"),
        }, result);
    }
    if (context.self_grammar.getObject("injections")) |injections| {
        var values = std.ArrayList(rawGrammar.Value).empty;
        defer values.deinit(result.allocator);
        try values.appendSlice(result.allocator, injections.map.values());
        try collectExternalReferencesInRules(values.items, .{
            .base_grammar = context.base_grammar,
            .self_grammar = context.self_grammar,
            .repository = context.self_grammar.getObject("repository"),
        }, result);
    }
}

fn collectExternalReferencesInRules(
    rules: []const rawGrammar.Value,
    context: ContextWithRepository,
    result: *ExternalReferenceCollector,
) anyerror!void {
    for (rules) |value| {
        const rule = switch (value) {
            .object => |object| object,
            else => continue,
        };
        if (result.visited_rule.contains(rule)) continue;
        try result.visited_rule.put(rule, {});

        const pattern_repository = if (rule.getObject("repository")) |repository|
            try rawGrammar.mergeObjects(result.scratch.allocator(), context.repository, repository)
        else
            context.repository;

        if (rule.getArray("patterns")) |patterns| {
            try collectExternalReferencesInRules(patterns, .{
                .base_grammar = context.base_grammar,
                .self_grammar = context.self_grammar,
                .repository = pattern_repository,
            }, result);
        }

        const include = rule.getString("include") orelse continue;
        const reference = parseInclude(include);

        switch (reference) {
            .base => try collectExternalReferencesInTopLevelRule(.{
                .base_grammar = context.base_grammar,
                .self_grammar = context.base_grammar,
            }, result),
            .self => try collectExternalReferencesInTopLevelRule(.{
                .base_grammar = context.base_grammar,
                .self_grammar = context.self_grammar,
            }, result),
            .relative => |rule_name| try collectExternalReferencesInTopLevelRepositoryRule(rule_name, .{
                .base_grammar = context.base_grammar,
                .self_grammar = context.self_grammar,
                .repository = pattern_repository,
            }, result),
            .top_level => |scope_name| {
                if (std.mem.eql(u8, scope_name, context.self_grammar.getString("scopeName") orelse "")) {
                    try collectExternalReferencesInTopLevelRule(.{
                        .base_grammar = context.base_grammar,
                        .self_grammar = context.self_grammar,
                    }, result);
                } else if (std.mem.eql(u8, scope_name, context.base_grammar.getString("scopeName") orelse "")) {
                    try collectExternalReferencesInTopLevelRule(.{
                        .base_grammar = context.base_grammar,
                        .self_grammar = context.base_grammar,
                    }, result);
                } else {
                    try result.add(.{ .top_level = .{ .scope_name = scope_name } });
                }
            },
            .top_level_repository => |ref| {
                if (std.mem.eql(u8, ref.scope_name, context.self_grammar.getString("scopeName") orelse "")) {
                    try collectExternalReferencesInTopLevelRepositoryRule(ref.rule_name, .{
                        .base_grammar = context.base_grammar,
                        .self_grammar = context.self_grammar,
                        .repository = pattern_repository,
                    }, result);
                } else if (std.mem.eql(u8, ref.scope_name, context.base_grammar.getString("scopeName") orelse "")) {
                    try collectExternalReferencesInTopLevelRepositoryRule(ref.rule_name, .{
                        .base_grammar = context.base_grammar,
                        .self_grammar = context.base_grammar,
                        .repository = pattern_repository,
                    }, result);
                } else {
                    try result.add(.{ .top_level_repository = .{
                        .scope_name = ref.scope_name,
                        .rule_name = ref.rule_name,
                    } });
                }
            },
        }
    }
}

pub const IncludeReference = union(enum) {
    base,
    self,
    relative: []const u8,
    top_level: []const u8,
    top_level_repository: struct {
        scope_name: []const u8,
        rule_name: []const u8,
    },
};

pub fn parseInclude(include: []const u8) IncludeReference {
    if (std.mem.eql(u8, include, "$base")) return .base;
    if (std.mem.eql(u8, include, "$self")) return .self;
    const sharp = std.mem.indexOfScalar(u8, include, '#') orelse
        return .{ .top_level = include };
    if (sharp == 0) return .{ .relative = include[1..] };
    return .{ .top_level_repository = .{
        .scope_name = include[0..sharp],
        .rule_name = include[sharp + 1 ..],
    } };
}

test "include references parse like upstream" {
    try std.testing.expect(parseInclude("$base") == .base);
    try std.testing.expect(parseInclude("$self") == .self);
    try std.testing.expectEqualStrings("foo", parseInclude("#foo").relative);
    try std.testing.expectEqualStrings("source.js", parseInclude("source.js").top_level);
    const reference = parseInclude("source.js#foo");
    try std.testing.expectEqualStrings("source.js", reference.top_level_repository.scope_name);
    try std.testing.expectEqualStrings("foo", reference.top_level_repository.rule_name);
}

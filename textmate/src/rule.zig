// Port of `../vscode-textmate/src/rule.ts` (microsoft/vscode-textmate
// v9.3.2).
//
// Adaptation notes:
//  * The TypeScript class hierarchy becomes a tagged union. `instanceof`
//    checks map to `switch` on the union.
//  * `IOnigLib` and the rule registry are explicit interfaces instead of
//    TypeScript structural typing. `RuleRegistry` carries the allocator, rule
//    lookup and Oniguruma binding used by compiled rules.
//  * `getName`/`getContentName` take the `OnigString` so capture slices can be
//    read in UTF-16 coordinates, exactly like JS `substring`.
//  * Compiled scanner caches are owned by rules and released by
//    `Rule.dispose`.
const std = @import("std");
const onigLib = @import("onigLib.zig");
const rawGrammar = @import("rawGrammar.zig");
const utils = @import("utils.zig");
const dependencies = @import("grammar/grammarDependencies.zig");
const Allocator = std.mem.Allocator;
const Object = rawGrammar.Object;
const Value = rawGrammar.Value;
const Location = rawGrammar.Location;
const CaptureIndex = onigLib.CaptureIndex;
const OnigString = onigLib.OnigString;
const OnigScanner = onigLib.OnigScanner;
const IOnigLib = onigLib.IOnigLib;

pub const RuleId = i32;
pub const endRuleId: RuleId = -1;
pub const whileRuleId: RuleId = -2;

pub const RuleRegistry = struct {
    context: *anyopaque,
    vtable: *const VTable,
    onig: IOnigLib,

    pub const VTable = struct {
        allocator: *const fn (context: *anyopaque) Allocator,
        get_rule: *const fn (context: *anyopaque, rule_id: RuleId) ?*Rule,
    };

    pub fn allocator(self: RuleRegistry) Allocator {
        return self.vtable.allocator(self.context);
    }

    pub fn getRule(self: RuleRegistry, rule_id: RuleId) ?*Rule {
        return self.vtable.get_rule(self.context, rule_id);
    }
};

pub const RuleFactoryHelper = struct {
    registry: RuleRegistry,
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reserve_rule: *const fn (context: *anyopaque) RuleId,
        set_rule: *const fn (context: *anyopaque, rule_id: RuleId, rule: *Rule) void,
        get_external_grammar: *const fn (context: *anyopaque, scope_name: []const u8, repository: ?*Object) anyerror!?*Object,
    };

    pub fn reserveRule(self: RuleFactoryHelper) RuleId {
        return self.vtable.reserve_rule(self.context);
    }

    pub fn setRule(self: RuleFactoryHelper, rule_id: RuleId, rule: *Rule) void {
        self.vtable.set_rule(self.context, rule_id, rule);
    }

    pub fn getExternalGrammar(self: RuleFactoryHelper, scope_name: []const u8, repository: ?*Object) anyerror!?*Object {
        return self.vtable.get_external_grammar(self.context, scope_name, repository);
    }

    pub fn allocator(self: RuleFactoryHelper) Allocator {
        return self.registry.allocator();
    }
};

pub const RuleBase = struct {
    location: ?Location,
    id: RuleId,
    name: ?[]const u8,
    name_is_capturing: bool,
    content_name: ?[]const u8,
    content_name_is_capturing: bool,

    pub fn init(
        location: ?Location,
        id: RuleId,
        name: ?[]const u8,
        content_name: ?[]const u8,
    ) RuleBase {
        return .{
            .location = location,
            .id = id,
            .name = name,
            .name_is_capturing = utils.hasCaptures(name),
            .content_name = content_name,
            .content_name_is_capturing = utils.hasCaptures(content_name),
        };
    }
};

pub const CaptureRule = struct {
    base: RuleBase,
    retokenize_captured_with_rule_id: RuleId,
};

pub const MatchRule = struct {
    base: RuleBase,
    match: RegExpSource,
    captures: []?*CaptureRule,
    cached_compiled_patterns: ?*RegExpSourceList = null,
};

pub const IncludeOnlyRule = struct {
    base: RuleBase,
    has_missing_patterns: bool,
    patterns: []RuleId,
    cached_compiled_patterns: ?*RegExpSourceList = null,
};

pub const BeginEndRule = struct {
    base: RuleBase,
    begin: RegExpSource,
    begin_captures: []?*CaptureRule,
    end: RegExpSource,
    end_has_back_references: bool,
    end_captures: []?*CaptureRule,
    apply_end_pattern_last: bool,
    has_missing_patterns: bool,
    patterns: []RuleId,
    cached_compiled_patterns: ?*RegExpSourceList = null,
};

pub const BeginWhileRule = struct {
    base: RuleBase,
    begin: RegExpSource,
    begin_captures: []?*CaptureRule,
    while_source: RegExpSource,
    while_captures: []?*CaptureRule,
    while_has_back_references: bool,
    has_missing_patterns: bool,
    patterns: []RuleId,
    cached_compiled_patterns: ?*RegExpSourceList = null,
    cached_compiled_while_patterns: ?*RegExpSourceList = null,
};

pub const Rule = union(enum) {
    capture: CaptureRule,
    match: MatchRule,
    include_only: IncludeOnlyRule,
    begin_end: BeginEndRule,
    begin_while: BeginWhileRule,

    pub fn base(self: *const Rule) *const RuleBase {
        return switch (self.*) {
            .capture => |*rule| &rule.base,
            .match => |*rule| &rule.base,
            .include_only => |*rule| &rule.base,
            .begin_end => |*rule| &rule.base,
            .begin_while => |*rule| &rule.base,
        };
    }

    pub fn id(self: *const Rule) RuleId {
        return self.base().id;
    }

    pub fn debugTypeName(self: *const Rule) []const u8 {
        return switch (self.*) {
            .capture => "CaptureRule",
            .match => "MatchRule",
            .include_only => "IncludeOnlyRule",
            .begin_end => "BeginEndRule",
            .begin_while => "BeginWhileRule",
        };
    }

    pub fn debugName(self: *const Rule, allocator: Allocator) ![]u8 {
        const rule_base = self.base();
        if (rule_base.location) |location| {
            const filename = location.filename orelse "";
            return std.fmt.allocPrint(allocator, "{s}#{d} @ {s}:{d}", .{
                self.debugTypeName(),
                rule_base.id,
                utils.basename(filename),
                location.line,
            });
        }
        return std.fmt.allocPrint(allocator, "{s}#{d} @ unknown", .{ self.debugTypeName(), rule_base.id });
    }

    pub fn getName(
        self: *const Rule,
        allocator: Allocator,
        line_text: ?*const OnigString,
        capture_indices: ?[]const CaptureIndex,
    ) !?[]const u8 {
        return getNameForBase(allocator, self.base(), line_text, capture_indices);
    }

    pub fn getContentName(
        self: *const Rule,
        allocator: Allocator,
        line_text: ?*const OnigString,
        capture_indices: ?[]const CaptureIndex,
    ) !?[]const u8 {
        return getContentNameForBase(allocator, self.base(), line_text, capture_indices);
    }

    pub fn collectPatterns(self: *Rule, registry: RuleRegistry, out: *RegExpSourceList) void {
        switch (self.*) {
            .capture => unreachable,
            .match => |*rule| out.push(&rule.match),
            .include_only => |*rule| {
                for (rule.patterns) |pattern| {
                    if (registry.getRule(pattern)) |child| child.collectPatterns(registry, out);
                }
            },
            .begin_end => |*rule| out.push(&rule.begin),
            .begin_while => |*rule| out.push(&rule.begin),
        }
    }

    pub fn compile(self: *Rule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*CompiledRule {
        return switch (self.*) {
            .capture => error.NotSupported,
            .match => |*value| try matchRuleCompile(value, registry, end_regex_source),
            .include_only => |*value| try includeOnlyCompile(value, registry, end_regex_source),
            .begin_end => |*value| try beginEndCompile(value, registry, end_regex_source),
            .begin_while => |*value| try beginWhileCompile(value, registry, end_regex_source),
        };
    }

    pub fn compileAG(
        self: *Rule,
        registry: RuleRegistry,
        end_regex_source: ?[]const u8,
        allow_a: bool,
        allow_g: bool,
    ) !*CompiledRule {
        return switch (self.*) {
            .capture => error.NotSupported,
            .match => |*value| try matchRuleCompile(value, registry, end_regex_source),
            .include_only => |*value| try includeOnlyCompileAG(value, registry, end_regex_source, allow_a, allow_g),
            .begin_end => |*value| try beginEndCompileAG(value, registry, end_regex_source, allow_a, allow_g),
            .begin_while => |*value| try beginWhileCompileAG(value, registry, end_regex_source, allow_a, allow_g),
        };
    }

    pub fn dispose(self: *Rule) void {
        switch (self.*) {
            .capture => {},
            .match => |*rule| {
                if (rule.cached_compiled_patterns) |patterns| patterns.dispose();
            },
            .include_only => |*rule| {
                if (rule.cached_compiled_patterns) |patterns| patterns.dispose();
            },
            .begin_end => |*rule| {
                if (rule.cached_compiled_patterns) |patterns| patterns.dispose();
            },
            .begin_while => |*rule| {
                if (rule.cached_compiled_patterns) |patterns| patterns.dispose();
                if (rule.cached_compiled_while_patterns) |patterns| patterns.dispose();
            },
        }
    }
};

pub fn getNameForBase(
    allocator: Allocator,
    base: *const RuleBase,
    line_text: ?*const OnigString,
    capture_indices: ?[]const CaptureIndex,
) !?[]const u8 {
    if (!base.name_is_capturing or base.name == null or line_text == null or capture_indices == null) return base.name;
    return try replaceCaptures(allocator, line_text.?, base.name.?, capture_indices.?);
}

pub fn getContentNameForBase(
    allocator: Allocator,
    base: *const RuleBase,
    line_text: ?*const OnigString,
    capture_indices: ?[]const CaptureIndex,
) !?[]const u8 {
    if (!base.content_name_is_capturing or base.content_name == null or line_text == null or capture_indices == null) return base.content_name;
    return try replaceCaptures(allocator, line_text.?, base.content_name.?, capture_indices.?);
}

fn replaceCaptures(
    allocator: Allocator,
    line_text: *const OnigString,
    source: []const u8,
    capture_indices: []const CaptureIndex,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < source.len) {
        if (source[index] != '$') {
            try out.append(allocator, source[index]);
            index += 1;
            continue;
        }

        var cursor = index + 1;
        var capture_number: ?usize = null;
        var command: ?u8 = null;
        var braced = false;

        if (cursor < source.len and source[cursor] == '{') {
            braced = true;
            cursor += 1;
            const digits_start = cursor;
            while (cursor < source.len and std.ascii.isDigit(source[cursor])) cursor += 1;
            if (cursor > digits_start) {
                capture_number = std.fmt.parseInt(usize, source[digits_start..cursor], 10) catch null;
                if (cursor < source.len and source[cursor] == ':' and
                    cursor + 2 < source.len and source[cursor + 1] == '/' and
                    (source[cursor + 2] == 'd' or source[cursor + 2] == 'u'))
                {
                    command = source[cursor + 2];
                    const command_length: usize = if (command.? == 'd') "downcase".len else "upcase".len;
                    cursor += 2 + command_length + 1; // :/command + closing brace
                } else if (braced and cursor < source.len and source[cursor] == '}') {
                    cursor += 1;
                }
            }
        } else {
            const digits_start = cursor;
            while (cursor < source.len and std.ascii.isDigit(source[cursor])) cursor += 1;
            if (cursor > digits_start) {
                capture_number = std.fmt.parseInt(usize, source[digits_start..cursor], 10) catch null;
            }
        }

        if (capture_number) |number| {
            if (number < capture_indices.len) {
                const capture = capture_indices[number];
                var value = line_text.sliceUtf16(capture.start, capture.end);
                while (value.len > 0 and value[0] == '.') value = value[1..];
                if (command) |name| {
                    for (value) |ch| {
                        try out.append(allocator, if (name == 'd') std.ascii.toLower(ch) else std.ascii.toUpper(ch));
                    }
                } else {
                    try out.appendSlice(allocator, value);
                }
                index = cursor;
                continue;
            }
        }

        try out.append(allocator, source[index]);
        index += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn appendCodepoint(out: *std.ArrayList(u8), allocator: Allocator, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch 1;
    try out.appendSlice(allocator, buffer[0..length]);
}

fn hasBackReferences(source: []const u8) bool {
    var index: usize = 0;
    while (index + 1 < source.len) : (index += 1) {
        if (source[index] == '\\' and std.ascii.isDigit(source[index + 1])) return true;
    }
    return false;
}

pub const RegExpSource = struct {
    source: []const u8,
    rule_id: RuleId,
    has_anchor: bool,
    has_back_references: bool,
    anchor_cache: ?AnchorCache = null,

    const AnchorCache = struct {
        a0_g0: []const u8,
        a0_g1: []const u8,
        a1_g0: []const u8,
        a1_g1: []const u8,
    };

    pub fn init(allocator: Allocator, reg_exp_source: []const u8, rule_id: RuleId) !RegExpSource {
        var source = reg_exp_source;
        var has_anchor = false;

        if (reg_exp_source.len > 0) {
            var output: std.ArrayList(u8) = .empty;
            errdefer output.deinit(allocator);
            var last_pushed_pos: usize = 0;
            var pos: usize = 0;
            while (pos < reg_exp_source.len) : (pos += 1) {
                if (reg_exp_source[pos] != '\\') continue;
                if (pos + 1 >= reg_exp_source.len) break;
                const next = reg_exp_source[pos + 1];
                if (next == 'z') {
                    try output.appendSlice(allocator, reg_exp_source[last_pushed_pos..pos]);
                    try output.appendSlice(allocator, "$(?!\\n)(?<!\\n)");
                    last_pushed_pos = pos + 2;
                } else if (next == 'A' or next == 'G') {
                    has_anchor = true;
                }
                pos += 1;
            }
            if (last_pushed_pos != 0) {
                try output.appendSlice(allocator, reg_exp_source[last_pushed_pos..]);
                source = try output.toOwnedSlice(allocator);
            } else {
                output.deinit(allocator);
            }
        }

        var self = RegExpSource{
            .source = source,
            .rule_id = rule_id,
            .has_anchor = has_anchor,
            .has_back_references = hasBackReferences(source),
            .anchor_cache = null,
        };
        if (has_anchor) self.anchor_cache = try self.buildAnchorCache(allocator);
        return self;
    }

    pub fn clone(self: *const RegExpSource, allocator: Allocator) !RegExpSource {
        return init(allocator, self.source, self.rule_id);
    }

    pub fn setSource(self: *RegExpSource, allocator: Allocator, new_source: []const u8) !void {
        if (std.mem.eql(u8, self.source, new_source)) return;
        self.source = new_source;
        if (self.has_anchor) self.anchor_cache = try self.buildAnchorCache(allocator);
        self.has_back_references = hasBackReferences(new_source);
    }

    pub fn resolveBackReferences(
        self: *const RegExpSource,
        allocator: Allocator,
        line_text: *const OnigString,
        capture_indices: []const CaptureIndex,
    ) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var index: usize = 0;
        while (index < self.source.len) {
            if (self.source[index] == '\\' and index + 1 < self.source.len and std.ascii.isDigit(self.source[index + 1])) {
                var end = index + 1;
                while (end < self.source.len and std.ascii.isDigit(self.source[end])) end += 1;
                const number = std.fmt.parseInt(usize, self.source[index + 1 .. end], 10) catch 0;
                if (number < capture_indices.len) {
                    const capture = capture_indices[number];
                    const value = line_text.sliceUtf16(capture.start, capture.end);
                    for (value) |ch| {
                        switch (ch) {
                            '\\', '|', '(', '[', '{', '}', ']', ')', '.', '?', '*', '+', '^', '$' => {
                                try out.append(allocator, '\\');
                                try out.append(allocator, ch);
                            },
                            else => try out.append(allocator, ch),
                        }
                    }
                }
                index = end;
                continue;
            }
            try out.append(allocator, self.source[index]);
            index += 1;
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn resolveAnchors(self: *const RegExpSource, allow_a: bool, allow_g: bool) []const u8 {
        if (!self.has_anchor or self.anchor_cache == null) return self.source;
        const cache = self.anchor_cache.?;
        if (allow_a) {
            return if (allow_g) cache.a1_g1 else cache.a1_g0;
        }
        return if (allow_g) cache.a0_g1 else cache.a0_g0;
    }

    fn buildAnchorCache(self: *const RegExpSource, allocator: Allocator) !AnchorCache {
        var a0_g0: std.ArrayList(u8) = .empty;
        var a0_g1: std.ArrayList(u8) = .empty;
        var a1_g0: std.ArrayList(u8) = .empty;
        var a1_g1: std.ArrayList(u8) = .empty;
        errdefer {
            a0_g0.deinit(allocator);
            a0_g1.deinit(allocator);
            a1_g0.deinit(allocator);
            a1_g1.deinit(allocator);
        }

        var pos: usize = 0;
        while (pos < self.source.len) : (pos += 1) {
            const ch = self.source[pos];
            if (ch != '\\' or pos + 1 >= self.source.len) {
                try a0_g0.append(allocator, ch);
                try a0_g1.append(allocator, ch);
                try a1_g0.append(allocator, ch);
                try a1_g1.append(allocator, ch);
                continue;
            }

            const next = self.source[pos + 1];
            const a0_g0_replacement: []const u8 = if (next == 'A') "\u{FFFF}" else if (next == 'G') "\u{FFFF}" else self.source[pos .. pos + 2];
            const a0_g1_replacement: []const u8 = if (next == 'A') "\u{FFFF}" else self.source[pos .. pos + 2];
            const a1_g0_replacement: []const u8 = if (next == 'G') "\u{FFFF}" else self.source[pos .. pos + 2];
            const a1_g1_replacement: []const u8 = self.source[pos .. pos + 2];
            try a0_g0.appendSlice(allocator, a0_g0_replacement);
            try a0_g1.appendSlice(allocator, a0_g1_replacement);
            try a1_g0.appendSlice(allocator, a1_g0_replacement);
            try a1_g1.appendSlice(allocator, a1_g1_replacement);
            pos += 1;
        }

        return .{
            .a0_g0 = try a0_g0.toOwnedSlice(allocator),
            .a0_g1 = try a0_g1.toOwnedSlice(allocator),
            .a1_g0 = try a1_g0.toOwnedSlice(allocator),
            .a1_g1 = try a1_g1.toOwnedSlice(allocator),
        };
    }
};

pub const CompiledRule = struct {
    scanner: *OnigScanner,
    regexps: []const []const u8,
    rules: []const RuleId,

    pub fn init(
        allocator: Allocator,
        onig: IOnigLib,
        regexps: []const []const u8,
        rules: []const RuleId,
    ) !*CompiledRule {
        const self = try allocator.create(CompiledRule);
        errdefer allocator.destroy(self);
        self.* = .{
            .scanner = try onig.createOnigScanner(regexps),
            .regexps = regexps,
            .rules = rules,
        };
        return self;
    }

    pub fn dispose(self: *CompiledRule) void {
        self.scanner.deinit();
    }

    pub fn findNextMatchSync(
        self: *CompiledRule,
        string: *const OnigString,
        start_position: usize,
        options: u32,
    ) !?FindNextMatchResult {
        const match = (try self.scanner.findNextMatchSync(string, start_position, options)) orelse return null;
        return .{
            .rule_id = self.rules[match.index],
            .capture_indices = match.capture_indices,
        };
    }
};

pub const FindNextMatchResult = struct {
    rule_id: RuleId,
    capture_indices: []CaptureIndex,

    pub fn deinit(self: *const FindNextMatchResult, allocator: Allocator) void {
        allocator.free(self.capture_indices);
    }
};

pub const RegExpSourceList = struct {
    allocator: Allocator,
    items: std.ArrayList(*RegExpSource) = .empty,
    has_anchors: bool = false,
    cached: ?*CompiledRule = null,
    anchor_cache: [4]?*CompiledRule = .{ null, null, null, null },

    pub fn init(allocator: Allocator) RegExpSourceList {
        return .{ .allocator = allocator };
    }

    pub fn dispose(self: *RegExpSourceList) void {
        self.disposeCaches();
        self.items.deinit(self.allocator);
    }

    fn disposeCaches(self: *RegExpSourceList) void {
        if (self.cached) |compiled| {
            compiled.dispose();
            self.cached = null;
        }
        for (&self.anchor_cache) |*entry| {
            if (entry.*) |compiled| {
                compiled.dispose();
                entry.* = null;
            }
        }
    }

    pub fn push(self: *RegExpSourceList, item: *RegExpSource) void {
        self.items.append(self.allocator, item) catch unreachable;
        self.has_anchors = self.has_anchors or item.has_anchor;
    }

    pub fn unshift(self: *RegExpSourceList, item: *RegExpSource) void {
        self.items.insert(self.allocator, 0, item) catch unreachable;
        self.has_anchors = self.has_anchors or item.has_anchor;
    }

    pub fn length(self: *const RegExpSourceList) usize {
        return self.items.items.len;
    }

    pub fn setSource(self: *RegExpSourceList, index: usize, new_source: []const u8) !void {
        if (!std.mem.eql(u8, self.items.items[index].source, new_source)) {
            self.disposeCaches();
            try self.items.items[index].setSource(self.allocator, new_source);
        }
    }

    pub fn compile(self: *RegExpSourceList, registry: RuleRegistry) !*CompiledRule {
        if (self.cached == null) {
            var regexps = try self.allocator.alloc([]const u8, self.items.items.len);
            errdefer self.allocator.free(regexps);
            var rules = try self.allocator.alloc(RuleId, self.items.items.len);
            errdefer self.allocator.free(rules);
            for (self.items.items, 0..) |item, i| {
                regexps[i] = item.source;
                rules[i] = item.rule_id;
            }
            self.cached = try CompiledRule.init(self.allocator, registry.onig, regexps, rules);
        }
        return self.cached.?;
    }

    pub fn compileAG(
        self: *RegExpSourceList,
        registry: RuleRegistry,
        allow_a: bool,
        allow_g: bool,
    ) !*CompiledRule {
        if (!self.has_anchors) return self.compile(registry);
        const slot: usize = (if (allow_a) @as(usize, 2) else 0) + (if (allow_g) @as(usize, 1) else 0);
        if (self.anchor_cache[slot] == null) {
            self.anchor_cache[slot] = try self.resolveAnchors(registry, allow_a, allow_g);
        }
        return self.anchor_cache[slot].?;
    }

    fn resolveAnchors(
        self: *RegExpSourceList,
        registry: RuleRegistry,
        allow_a: bool,
        allow_g: bool,
    ) !*CompiledRule {
        var regexps = try self.allocator.alloc([]const u8, self.items.items.len);
        errdefer self.allocator.free(regexps);
        var rules = try self.allocator.alloc(RuleId, self.items.items.len);
        errdefer self.allocator.free(rules);
        for (self.items.items, 0..) |item, i| {
            regexps[i] = item.resolveAnchors(allow_a, allow_g);
            rules[i] = item.rule_id;
        }
        return CompiledRule.init(self.allocator, registry.onig, regexps, rules);
    }
};

fn cachedCompiledPatterns(
    allocator: Allocator,
    slot: *?*RegExpSourceList,
    registry: RuleRegistry,
    patterns: []const RuleId,
) !*RegExpSourceList {
    if (slot.* == null) {
        const list = try allocator.create(RegExpSourceList);
        list.* = RegExpSourceList.init(allocator);
        for (patterns) |pattern| {
            if (registry.getRule(pattern)) |child| child.collectPatterns(registry, list);
        }
        slot.* = list;
    }
    return slot.*.?;
}

fn compileList(
    allocator: Allocator,
    slot: *?*RegExpSourceList,
    registry: RuleRegistry,
    patterns: []const RuleId,
) !*CompiledRule {
    const list = try cachedCompiledPatterns(allocator, slot, registry, patterns);
    return list.compile(registry);
}

fn compileListAG(
    allocator: Allocator,
    slot: *?*RegExpSourceList,
    registry: RuleRegistry,
    patterns: []const RuleId,
    allow_a: bool,
    allow_g: bool,
) !*CompiledRule {
    const list = try cachedCompiledPatterns(allocator, slot, registry, patterns);
    return list.compileAG(registry, allow_a, allow_g);
}

pub fn matchRuleCompile(self: *MatchRule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*CompiledRule {
    _ = end_regex_source;
    const allocator = registry.allocator();
    if (self.cached_compiled_patterns == null) {
        const list = try allocator.create(RegExpSourceList);
        list.* = RegExpSourceList.init(allocator);
        list.push(&self.match);
        self.cached_compiled_patterns = list;
    }
    return self.cached_compiled_patterns.?.compile(registry);
}

pub fn includeOnlyCompile(self: *IncludeOnlyRule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*CompiledRule {
    _ = end_regex_source;
    return compileList(registry.allocator(), &self.cached_compiled_patterns, registry, self.patterns);
}

pub fn includeOnlyCompileAG(self: *IncludeOnlyRule, registry: RuleRegistry, end_regex_source: ?[]const u8, allow_a: bool, allow_g: bool) !*CompiledRule {
    _ = end_regex_source;
    return compileListAG(registry.allocator(), &self.cached_compiled_patterns, registry, self.patterns, allow_a, allow_g);
}

pub fn beginEndCompile(self: *BeginEndRule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*CompiledRule {
    const list = try beginEndList(self, registry, end_regex_source);
    return list.compile(registry);
}

pub fn beginEndCompileAG(self: *BeginEndRule, registry: RuleRegistry, end_regex_source: ?[]const u8, allow_a: bool, allow_g: bool) !*CompiledRule {
    const list = try beginEndList(self, registry, end_regex_source);
    return list.compileAG(registry, allow_a, allow_g);
}

fn beginEndList(self: *BeginEndRule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*RegExpSourceList {
    const allocator = registry.allocator();
    if (self.cached_compiled_patterns == null) {
        const list = try allocator.create(RegExpSourceList);
        list.* = RegExpSourceList.init(allocator);
        for (self.patterns) |pattern| {
            if (registry.getRule(pattern)) |child| child.collectPatterns(registry, list);
        }
        if (self.apply_end_pattern_last) {
            list.push(if (self.end.has_back_references) try cloneSource(allocator, &self.end) else &self.end);
        } else {
            list.unshift(if (self.end.has_back_references) try cloneSource(allocator, &self.end) else &self.end);
        }
        self.cached_compiled_patterns = list;
    }
    if (self.end.has_back_references) {
        const source = end_regex_source orelse "";
        if (self.apply_end_pattern_last) {
            try self.cached_compiled_patterns.?.setSource(self.cached_compiled_patterns.?.length() - 1, source);
        } else {
            try self.cached_compiled_patterns.?.setSource(0, source);
        }
    }
    return self.cached_compiled_patterns.?;
}

pub fn beginEndGetContentName(
    self: *BeginEndRule,
    allocator: Allocator,
    line_text: ?*const OnigString,
    capture_indices: ?[]const CaptureIndex,
) !?[]const u8 {
    return getContentNameForBase(allocator, &self.base, line_text, capture_indices);
}

pub fn beginWhileGetContentName(
    self: *BeginWhileRule,
    allocator: Allocator,
    line_text: ?*const OnigString,
    capture_indices: ?[]const CaptureIndex,
) !?[]const u8 {
    return getContentNameForBase(allocator, &self.base, line_text, capture_indices);
}

pub fn beginEndGetEndWithResolvedBackReferences(
    self: *BeginEndRule,
    allocator: Allocator,
    line_text: *const OnigString,
    capture_indices: []const CaptureIndex,
) ![]const u8 {
    return self.end.resolveBackReferences(allocator, line_text, capture_indices);
}

pub fn beginWhileCompile(self: *BeginWhileRule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*CompiledRule {
    _ = end_regex_source;
    return compileList(registry.allocator(), &self.cached_compiled_patterns, registry, self.patterns);
}

pub fn beginWhileCompileAG(self: *BeginWhileRule, registry: RuleRegistry, end_regex_source: ?[]const u8, allow_a: bool, allow_g: bool) !*CompiledRule {
    _ = end_regex_source;
    return compileListAG(registry.allocator(), &self.cached_compiled_patterns, registry, self.patterns, allow_a, allow_g);
}

pub fn beginWhileCompileWhile(self: *BeginWhileRule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*CompiledRule {
    const list = try beginWhileWhileList(self, registry, end_regex_source);
    return list.compile(registry);
}

pub fn beginWhileCompileWhileAG(self: *BeginWhileRule, registry: RuleRegistry, end_regex_source: ?[]const u8, allow_a: bool, allow_g: bool) !*CompiledRule {
    const list = try beginWhileWhileList(self, registry, end_regex_source);
    return list.compileAG(registry, allow_a, allow_g);
}

fn beginWhileWhileList(self: *BeginWhileRule, registry: RuleRegistry, end_regex_source: ?[]const u8) !*RegExpSourceList {
    const allocator = registry.allocator();
    if (self.cached_compiled_while_patterns == null) {
        const list = try allocator.create(RegExpSourceList);
        list.* = RegExpSourceList.init(allocator);
        list.push(if (self.while_source.has_back_references) try cloneSource(allocator, &self.while_source) else &self.while_source);
        self.cached_compiled_while_patterns = list;
    }
    if (self.while_source.has_back_references) {
        try self.cached_compiled_while_patterns.?.setSource(0, end_regex_source orelse "");
    }
    return self.cached_compiled_while_patterns.?;
}

pub fn beginWhileGetWhileWithResolvedBackReferences(
    self: *BeginWhileRule,
    allocator: Allocator,
    line_text: *const OnigString,
    capture_indices: []const CaptureIndex,
) ![]const u8 {
    return self.while_source.resolveBackReferences(allocator, line_text, capture_indices);
}

pub const CompilePatternsResult = struct {
    patterns: []RuleId,
    has_missing_patterns: bool,
};

pub const RuleFactory = struct {
    pub fn createCaptureRule(
        helper: RuleFactoryHelper,
        location: ?Location,
        name: ?[]const u8,
        content_name: ?[]const u8,
        retokenize_captured_with_rule_id: RuleId,
    ) anyerror!*CaptureRule {
        const id = helper.reserveRule();
        const allocator = helper.allocator();
        const rule = try allocator.create(Rule);
        rule.* = .{ .capture = .{
            .base = RuleBase.init(location, id, name, content_name),
            .retokenize_captured_with_rule_id = retokenize_captured_with_rule_id,
        } };
        helper.setRule(id, rule);
        return &rule.capture;
    }

    pub fn getCompiledRuleId(
        helper: RuleFactoryHelper,
        desc: *Object,
        repository: *Object,
    ) anyerror!RuleId {
        if (desc.id) |id| return id;

        const id = helper.reserveRule();
        desc.id = id;
        const allocator = helper.allocator();

        if (desc.getString("match")) |match| {
            const captures = try compileCaptures(desc.getObject("captures"), helper, repository);
            const rule = try allocator.create(Rule);
            rule.* = .{ .match = .{
                .base = RuleBase.init(desc.location, id, desc.getString("name"), null),
                .match = try RegExpSource.init(allocator, match, id),
                .captures = captures,
            } };
            helper.setRule(id, rule);
            return id;
        }

        if (desc.getString("begin") == null) {
            var effective_repository = repository;
            if (desc.getObject("repository")) |local_repository| {
                effective_repository = try rawGrammar.mergeObjects(allocator, repository, local_repository);
            }

            var patterns = desc.getArray("patterns");
            var synthetic_patterns: ?[]Value = null;
            if (patterns == null) {
                if (desc.getString("include")) |include| {
                    const include_object = try Object.create(allocator);
                    try include_object.put(allocator, "include", .{ .string = include });
                    synthetic_patterns = try allocator.alloc(Value, 1);
                    synthetic_patterns.?[0] = .{ .object = include_object };
                    patterns = synthetic_patterns;
                }
            }

            const compiled = try compilePatterns(patterns, helper, effective_repository);
            const rule = try allocator.create(Rule);
            rule.* = .{ .include_only = .{
                .base = RuleBase.init(desc.location, id, desc.getString("name"), desc.getString("contentName")),
                .patterns = compiled.patterns,
                .has_missing_patterns = compiled.has_missing_patterns,
            } };
            helper.setRule(id, rule);
            return id;
        }

        const begin = desc.getString("begin").?;
        const begin_captures = try compileCaptures(
            desc.getObject("beginCaptures") orelse desc.getObject("captures"),
            helper,
            repository,
        );

        if (desc.getString("while")) |while_source| {
            const while_captures = try compileCaptures(
                desc.getObject("whileCaptures") orelse desc.getObject("captures"),
                helper,
                repository,
            );
            const compiled = try compilePatterns(desc.getArray("patterns"), helper, repository);
            const rule = try allocator.create(Rule);
            rule.* = .{ .begin_while = .{
                .base = RuleBase.init(desc.location, id, desc.getString("name"), desc.getString("contentName")),
                .begin = try RegExpSource.init(allocator, begin, id),
                .begin_captures = begin_captures,
                .while_source = try RegExpSource.init(allocator, while_source, whileRuleId),
                .while_captures = while_captures,
                .while_has_back_references = hasBackReferences(while_source),
                .patterns = compiled.patterns,
                .has_missing_patterns = compiled.has_missing_patterns,
            } };
            helper.setRule(id, rule);
            return id;
        }

        const end_source = desc.getString("end") orelse "";
        const end_captures = try compileCaptures(
            desc.getObject("endCaptures") orelse desc.getObject("captures"),
            helper,
            repository,
        );
        const compiled = try compilePatterns(desc.getArray("patterns"), helper, repository);
        const rule = try allocator.create(Rule);
        rule.* = .{ .begin_end = .{
            .base = RuleBase.init(desc.location, id, desc.getString("name"), desc.getString("contentName")),
            .begin = try RegExpSource.init(allocator, begin, id),
            .begin_captures = begin_captures,
            .end = try RegExpSource.init(allocator, end_source, endRuleId),
            .end_has_back_references = hasBackReferences(end_source),
            .end_captures = end_captures,
            .apply_end_pattern_last = truthy(desc, "applyEndPatternLast"),
            .patterns = compiled.patterns,
            .has_missing_patterns = compiled.has_missing_patterns,
        } };
        helper.setRule(id, rule);
        return id;
    }

    fn compileCaptures(
        captures: ?*Object,
        helper: RuleFactoryHelper,
        repository: *Object,
    ) anyerror![]?*CaptureRule {
        const allocator = helper.allocator();
        const object = captures orelse return try allocator.alloc(?*CaptureRule, 0);

        var maximum_capture_id: usize = 0;
        for (object.map.keys()) |capture_id| {
            if (std.mem.eql(u8, capture_id, "$vscodeTextmateLocation")) continue;
            const numeric = parseIntPrefix(capture_id) orelse continue;
            if (numeric > maximum_capture_id) maximum_capture_id = numeric;
        }

        const result = try allocator.alloc(?*CaptureRule, maximum_capture_id + 1);
        @memset(result, null);

        for (object.map.keys(), object.map.values()) |capture_id, capture_value| {
            if (std.mem.eql(u8, capture_id, "$vscodeTextmateLocation")) continue;
            const numeric = parseIntPrefix(capture_id) orelse continue;
            const capture = switch (capture_value) {
                .object => |capture_object| capture_object,
                else => continue,
            };
            var retokenize_id: RuleId = 0;
            if (capture.getArray("patterns") != null) {
                retokenize_id = try getCompiledRuleId(helper, capture, repository);
            }
            result[numeric] = try createCaptureRule(
                helper,
                capture.location,
                capture.getString("name"),
                capture.getString("contentName"),
                retokenize_id,
            );
        }

        return result;
    }

    fn compilePatterns(
        patterns: ?[]const Value,
        helper: RuleFactoryHelper,
        repository: *Object,
    ) anyerror!CompilePatternsResult {
        const allocator = helper.allocator();
        var result: std.ArrayList(RuleId) = .empty;
        errdefer result.deinit(allocator);

        const pattern_list = patterns orelse &[_]Value{};
        for (pattern_list) |value| {
            const pattern = switch (value) {
                .object => |object| object,
                else => continue,
            };
            var rule_id: RuleId = -1;

            if (pattern.getString("include")) |include| {
                const reference = dependencies.parseInclude(include);
                switch (reference) {
                    .base, .self => {
                        if (repository.getObject(include)) |self_rule| {
                            rule_id = try getCompiledRuleId(helper, self_rule, repository);
                        }
                    },
                    .relative => |rule_name| {
                        if (repository.getObject(rule_name)) |local_rule| {
                            rule_id = try getCompiledRuleId(helper, local_rule, repository);
                        }
                    },
                    .top_level => |scope_name| {
                        if (try helper.getExternalGrammar(scope_name, repository)) |external_grammar| {
                            if (external_grammar.getObject("repository")) |external_repository| {
                                if (external_repository.getObject("$self")) |self_rule| {
                                    rule_id = try getCompiledRuleId(helper, self_rule, external_repository);
                                }
                            }
                        }
                    },
                    .top_level_repository => |ref| {
                        if (try helper.getExternalGrammar(ref.scope_name, repository)) |external_grammar| {
                            if (external_grammar.getObject("repository")) |external_repository| {
                                if (external_repository.getObject(ref.rule_name)) |external_rule| {
                                    rule_id = try getCompiledRuleId(helper, external_rule, external_repository);
                                }
                            }
                        }
                    },
                }
            } else {
                rule_id = try getCompiledRuleId(helper, pattern, repository);
            }

            if (rule_id != -1) {
                if (helper.registry.getRule(rule_id)) |rule| {
                    var skip_rule = false;
                    switch (rule.*) {
                        .include_only, .begin_end, .begin_while => {
                            const missing = switch (rule.*) {
                                .include_only => |*r| r.has_missing_patterns and r.patterns.len == 0,
                                .begin_end => |*r| r.has_missing_patterns and r.patterns.len == 0,
                                .begin_while => |*r| r.has_missing_patterns and r.patterns.len == 0,
                                else => false,
                            };
                            skip_rule = missing;
                        },
                        else => {},
                    }
                    if (skip_rule) continue;
                }
                try result.append(allocator, rule_id);
            }
        }

        const result_length = result.items.len;
        return .{
            .patterns = try result.toOwnedSlice(allocator),
            .has_missing_patterns = pattern_list.len != result_length,
        };
    }
};

fn cloneSource(allocator: Allocator, source: *const RegExpSource) !*RegExpSource {
    const cloned = try allocator.create(RegExpSource);
    cloned.* = try source.clone(allocator);
    return cloned;
}

fn truthy(object: *Object, key: []const u8) bool {
    if (object.getBool(key)) |value| return value;
    if (object.getNumber(key)) |value| return value != 0;
    return false;
}

fn parseIntPrefix(text: []const u8) ?usize {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(usize, text[0..end], 10) catch null;
}

test "regexp source rewrites end anchor and tracks back references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try RegExpSource.init(allocator, "foo\\z", 1);
    try std.testing.expectEqualStrings("foo$(?!\\n)(?<!\\n)", source.source);
    try std.testing.expect(!source.has_back_references);

    const backref = try RegExpSource.init(allocator, "foo\\1", 1);
    try std.testing.expect(backref.has_back_references);
}

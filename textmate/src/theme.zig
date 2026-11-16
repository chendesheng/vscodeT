// Port of `../vscode-textmate/src/theme.ts` (microsoft/vscode-textmate
// v9.3.2).
//
// Adaptation notes:
//  * `IRawTheme` is represented by typed structs so tests and the registry can
//    build themes without a JSON value. `rawThemeFromValue` converts a parsed
//    JSON/plist value into that representation.
//  * Scope stacks are linked nodes allocated in the grammar/theme arena, like
//    the immutable linked objects in the TypeScript code.
//  * A theme owns an arena for its trie, parsed rules and match cache; callers
//    can release the raw theme immediately after creation.
const std = @import("std");
const rawGrammar = @import("rawGrammar.zig");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;
const Value = rawGrammar.Value;

pub const ScopeName = []const u8;
pub const ScopePath = []const u8;
pub const ScopePattern = []const u8;

pub const FontStyle = struct {
    pub const not_set: i32 = -1;
    pub const none: i32 = 0;
    pub const italic: i32 = 1;
    pub const bold: i32 = 2;
    pub const underline: i32 = 4;
    pub const strikethrough: i32 = 8;
};

pub const RawThemeSettings = struct {
    font_style: ?[]const u8 = null,
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    font_family: ?[]const u8 = null,
    font_size: ?f64 = null,
    line_height: ?f64 = null,
};

pub const ScopeSpec = union(enum) {
    single: []const u8,
    list: []const []const u8,
};

pub const RawThemeSetting = struct {
    name: ?[]const u8 = null,
    scope: ?ScopeSpec = null,
    settings: RawThemeSettings = .{},
};

pub const RawTheme = struct {
    name: ?[]const u8 = null,
    settings: []const RawThemeSetting = &.{},

    pub fn deinit(self: *RawTheme, allocator: Allocator) void {
        for (self.settings) |setting| {
            if (setting.scope) |scope| switch (scope) {
                .list => |list| allocator.free(list),
                .single => {},
            };
        }
        allocator.free(self.settings);
    }
};

/// Convert a parsed theme object (`IRawTheme`) into the typed representation.
/// Strings are borrowed from `value`; arrays are allocated with `allocator`.
pub fn rawThemeFromValue(allocator: Allocator, value: Value) !RawTheme {
    const root = switch (value) {
        .object => |object| object,
        else => return .{},
    };

    const name = root.getString("name");
    const settings_value = root.getArray("settings") orelse return .{ .name = name };

    const settings = try allocator.alloc(RawThemeSetting, settings_value.len);
    errdefer allocator.free(settings);

    for (settings_value, 0..) |setting_value, i| {
        const object = switch (setting_value) {
            .object => |object| object,
            else => {
                settings[i] = .{};
                continue;
            },
        };

        var scope_spec: ?ScopeSpec = null;
        if (object.get("scope")) |scope_value| {
            switch (scope_value) {
                .string => |scope| scope_spec = .{ .single = scope },
                .array => |array| {
                    const list = try allocator.alloc([]const u8, array.len);
                    errdefer allocator.free(list);
                    for (array, 0..) |item, j| {
                        list[j] = switch (item) {
                            .string => |string| string,
                            else => "",
                        };
                    }
                    scope_spec = .{ .list = list };
                },
                else => {},
            }
        }

        const settings_object = object.getObject("settings");
        settings[i] = .{
            .name = object.getString("name"),
            .scope = scope_spec,
            .settings = if (settings_object) |settings_value_object| .{
                .font_style = settings_value_object.getString("fontStyle"),
                .foreground = settings_value_object.getString("foreground"),
                .background = settings_value_object.getString("background"),
                .font_family = settings_value_object.getString("fontFamily"),
                .font_size = settings_value_object.getNumber("fontSize"),
                .line_height = settings_value_object.getNumber("lineHeight"),
            } else .{},
        };
    }

    return .{ .name = name, .settings = settings };
}

pub const StyleAttributes = struct {
    font_style: i32,
    foreground_id: u32,
    background_id: u32,
    font_family: []const u8,
    font_size: f64,
    line_height: f64,
};

pub const ScopeStack = struct {
    parent: ?*const ScopeStack,
    scope_name: ScopeName,
    /// Set for nodes owned by a grammar's persistent arena. Tokenization
    /// copies live stacks out of its per-line arena until it reaches such a
    /// node.
    persistent: bool = false,

    pub fn push(self: *const ScopeStack, allocator: Allocator, scope_name: ScopeName) !*ScopeStack {
        const result = try allocator.create(ScopeStack);
        result.* = .{ .parent = self, .scope_name = scope_name };
        return result;
    }

    pub fn from(allocator: Allocator, segments: []const ScopeName) !?*ScopeStack {
        var result: ?*ScopeStack = null;
        for (segments) |segment| {
            const node = try allocator.create(ScopeStack);
            node.* = .{ .parent = result, .scope_name = segment };
            result = node;
        }
        return result;
    }

    pub fn getSegments(self: *const ScopeStack, allocator: Allocator) ![]const ScopeName {
        var count: usize = 0;
        var item: ?*const ScopeStack = self;
        while (item) |node| : (item = node.parent) count += 1;
        const result = try allocator.alloc(ScopeName, count);
        item = self;
        var index = count;
        while (item) |node| : (item = node.parent) {
            index -= 1;
            result[index] = node.scope_name;
        }
        return result;
    }

    pub fn toString(self: *const ScopeStack, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const segments = try self.getSegments(allocator);
        defer allocator.free(segments);
        for (segments, 0..) |segment, i| {
            if (i != 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, segment);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn extendsScope(self: *const ScopeStack, other: *const ScopeStack) bool {
        if (self == other) return true;
        if (self.parent == null) return false;
        return self.parent.?.extendsScope(other);
    }

    pub fn getExtensionIfDefined(
        self: *const ScopeStack,
        allocator: Allocator,
        base: ?*const ScopeStack,
    ) !?[]const ScopeName {
        var count: usize = 0;
        var item: ?*const ScopeStack = self;
        while (item != null and item != base) : (item = item.?.parent) count += 1;
        if (item != base) return null;
        const result = try allocator.alloc(ScopeName, count);
        item = self;
        var index = count;
        while (item != null and item != base) : (item = item.?.parent) {
            index -= 1;
            result[index] = item.?.scope_name;
        }
        return result;
    }
};

fn scopePathMatchesParentScopes(scope_path_start: ?*const ScopeStack, parent_scopes: []const ScopeName) bool {
    if (parent_scopes.len == 0) return true;

    var scope_path = scope_path_start;
    var index: usize = 0;
    while (index < parent_scopes.len) : (index += 1) {
        var scope_pattern = parent_scopes[index];
        var scope_must_match = false;

        if (std.mem.eql(u8, scope_pattern, ">")) {
            if (index == parent_scopes.len - 1) return false;
            index += 1;
            scope_pattern = parent_scopes[index];
            scope_must_match = true;
        }

        while (scope_path) |node| {
            if (matchesScope(node.scope_name, scope_pattern)) break;
            if (scope_must_match) return false;
            scope_path = node.parent;
        }

        if (scope_path == null) return false;
        scope_path = scope_path.?.parent;
    }
    return true;
}

fn matchesScope(scope_name: ScopeName, scope_pattern: ScopeName) bool {
    if (std.mem.eql(u8, scope_pattern, scope_name)) return true;
    return scope_name.len > scope_pattern.len and
        std.mem.startsWith(u8, scope_name, scope_pattern) and
        scope_name[scope_pattern.len] == '.';
}

pub const ParsedThemeRule = struct {
    scope: ScopeName,
    parent_scopes: ?[]const ScopeName,
    index: usize,
    font_style: i32,
    foreground: ?[]const u8,
    background: ?[]const u8,
    font_family: []const u8,
    font_size: f64,
    line_height: f64,
};

pub fn parseTheme(allocator: Allocator, source: ?*const RawTheme) ![]ParsedThemeRule {
    const theme = source orelse return try allocator.alloc(ParsedThemeRule, 0);

    var result: std.ArrayList(ParsedThemeRule) = .empty;
    errdefer result.deinit(allocator);

    for (theme.settings, 0..) |setting, setting_index| {
        const scope_value: ScopeSpec = setting.scope orelse .{ .single = "" };
        const scopes: []const []const u8 = switch (scope_value) {
            .single => |single| blk: {
                var trimmed = single;
                trimmed = std.mem.trimStart(u8, trimmed, ",");
                trimmed = std.mem.trimEnd(u8, trimmed, ",");
                var list: std.ArrayList([]const u8) = .empty;
                var iterator = std.mem.splitScalar(u8, trimmed, ',');
                while (iterator.next()) |scope| try list.append(allocator, scope);
                break :blk try list.toOwnedSlice(allocator);
            },
            .list => |list| list,
        };
        defer switch (scope_value) {
            .single => allocator.free(scopes),
            .list => {},
        };

        var font_style: i32 = FontStyle.not_set;
        if (setting.settings.font_style) |style| {
            font_style = FontStyle.none;
            var iterator = std.mem.splitScalar(u8, style, ' ');
            while (iterator.next()) |segment| {
                if (std.mem.eql(u8, segment, "italic")) font_style |= FontStyle.italic;
                if (std.mem.eql(u8, segment, "bold")) font_style |= FontStyle.bold;
                if (std.mem.eql(u8, segment, "underline")) font_style |= FontStyle.underline;
                if (std.mem.eql(u8, segment, "strikethrough")) font_style |= FontStyle.strikethrough;
            }
        }

        const foreground: ?[]const u8 = if (setting.settings.foreground) |color|
            if (utils.isValidHexColor(color)) color else null
        else
            null;
        const background: ?[]const u8 = if (setting.settings.background) |color|
            if (utils.isValidHexColor(color)) color else null
        else
            null;
        const font_family = setting.settings.font_family orelse "";
        const font_size = setting.settings.font_size orelse 0;
        const line_height = setting.settings.line_height orelse 0;

        for (scopes) |scope_text| {
            const trimmed = std.mem.trim(u8, scope_text, " \t\r\n");
            var segments: std.ArrayList([]const u8) = .empty;
            defer segments.deinit(allocator);
            var iterator = std.mem.splitScalar(u8, trimmed, ' ');
            while (iterator.next()) |segment| try segments.append(allocator, segment);
            if (segments.items.len == 0) continue;

            const scope = segments.items[segments.items.len - 1];
            var parent_scopes: ?[]const ScopeName = null;
            if (segments.items.len > 1) {
                const parents = try allocator.alloc(ScopeName, segments.items.len - 1);
                var i: usize = 0;
                while (i < parents.len) : (i += 1) {
                    parents[i] = segments.items[parents.len - 1 - i];
                }
                parent_scopes = parents;
            }

            try result.append(allocator, .{
                .scope = scope,
                .parent_scopes = parent_scopes,
                .index = setting_index,
                .font_style = font_style,
                .foreground = foreground,
                .background = background,
                .font_family = font_family,
                .font_size = font_size,
                .line_height = line_height,
            });
        }
    }

    return result.toOwnedSlice(allocator);
}

pub const ColorMap = struct {
    allocator: Allocator,
    is_frozen: bool,
    last_color_id: u32 = 0,
    id2color: std.ArrayList([]const u8) = .empty,
    color2id: std.StringHashMap(u32),

    pub fn init(allocator: Allocator, color_map: ?[]const []const u8) !ColorMap {
        var self = ColorMap{
            .allocator = allocator,
            .is_frozen = color_map != null,
            .color2id = std.StringHashMap(u32).init(allocator),
        };
        if (color_map) |colors| {
            for (colors, 0..) |color, i| {
                try self.id2color.append(allocator, color);
                try self.color2id.put(color, @intCast(i));
            }
        } else {
            // Id 0 means "not set" and must occupy slot 0.
            try self.id2color.append(allocator, "");
        }
        return self;
    }

    pub fn deinit(self: *ColorMap) void {
        self.id2color.deinit(self.allocator);
        self.color2id.deinit();
    }

    pub fn getId(self: *ColorMap, color: ?[]const u8) !u32 {
        const value = color orelse return 0;
        const upper = try self.allocator.dupe(u8, value);
        for (upper) |*ch| ch.* = std.ascii.toUpper(ch.*);

        if (self.color2id.get(upper)) |id| {
            self.allocator.free(upper);
            return id;
        }
        if (self.is_frozen) {
            self.allocator.free(upper);
            return error.MissingColor;
        }
        const id = self.last_color_id + 1;
        self.last_color_id = id;
        try self.color2id.put(upper, id);
        try self.id2color.append(self.allocator, upper);
        return id;
    }

    pub fn getColorMap(self: *const ColorMap) []const []const u8 {
        return self.id2color.items;
    }
};

pub const ThemeTrieElementRule = struct {
    scope_depth: usize,
    parent_scopes: []const ScopeName,
    font_style: i32,
    foreground: u32,
    background: u32,
    font_family: []const u8,
    font_size: f64,
    line_height: f64,

    pub fn clone(self: *const ThemeTrieElementRule) ThemeTrieElementRule {
        return self.*;
    }

    pub fn acceptOverwrite(
        self: *ThemeTrieElementRule,
        scope_depth: usize,
        font_style: i32,
        foreground: u32,
        background: u32,
        font_family: []const u8,
        font_size: f64,
        line_height: f64,
    ) void {
        if (self.scope_depth <= scope_depth) self.scope_depth = scope_depth;
        if (font_style != FontStyle.not_set) self.font_style = font_style;
        if (foreground != 0) self.foreground = foreground;
        if (background != 0) self.background = background;
        if (font_family.len != 0) self.font_family = font_family;
        if (font_size != 0) self.font_size = font_size;
        if (line_height != 0) self.line_height = line_height;
    }
};

pub const ThemeTrieElement = struct {
    main_rule: ThemeTrieElementRule,
    rules_with_parent_scopes: std.ArrayList(*ThemeTrieElementRule) = .empty,
    children: std.StringArrayHashMapUnmanaged(*ThemeTrieElement),

    pub fn init(main_rule: ThemeTrieElementRule) ThemeTrieElement {
        return .{
            .main_rule = main_rule,
            .children = .empty,
        };
    }

    fn cmpBySpecificity(_: void, a: *const ThemeTrieElementRule, b: *const ThemeTrieElementRule) bool {
        if (a.scope_depth != b.scope_depth) return a.scope_depth > b.scope_depth;

        var a_parent_index: usize = 0;
        var b_parent_index: usize = 0;
        while (true) {
            if (a_parent_index < a.parent_scopes.len and std.mem.eql(u8, a.parent_scopes[a_parent_index], ">")) {
                a_parent_index += 1;
            }
            if (b_parent_index < b.parent_scopes.len and std.mem.eql(u8, b.parent_scopes[b_parent_index], ">")) {
                b_parent_index += 1;
            }
            if (a_parent_index >= a.parent_scopes.len or b_parent_index >= b.parent_scopes.len) break;

            const a_len = a.parent_scopes[a_parent_index].len;
            const b_len = b.parent_scopes[b_parent_index].len;
            if (a_len != b_len) return a_len > b_len;

            a_parent_index += 1;
            b_parent_index += 1;
        }
        return a.parent_scopes.len > b.parent_scopes.len;
    }

    pub fn match(self: *ThemeTrieElement, allocator: Allocator, scope: ScopeName) ![]*ThemeTrieElementRule {
        if (scope.len != 0) {
            if (std.mem.indexOfScalar(u8, scope, '.')) |dot_index| {
                const head = scope[0..dot_index];
                const tail = scope[dot_index + 1 ..];
                if (self.children.get(head)) |child| return child.match(allocator, tail);
            } else {
                if (self.children.get(scope)) |child| return child.match(allocator, "");
            }
        }

        var rules: std.ArrayList(*ThemeTrieElementRule) = .empty;
        errdefer rules.deinit(allocator);
        try rules.appendSlice(allocator, self.rules_with_parent_scopes.items);
        try rules.append(allocator, @constCast(&self.main_rule));
        std.mem.sort(*ThemeTrieElementRule, rules.items, {}, cmpBySpecificity);
        return rules.toOwnedSlice(allocator);
    }

    pub fn insert(
        self: *ThemeTrieElement,
        allocator: Allocator,
        scope_depth: usize,
        scope: ScopeName,
        parent_scopes: ?[]const ScopeName,
        font_style: i32,
        foreground: u32,
        background: u32,
        font_family: []const u8,
        font_size: f64,
        line_height: f64,
    ) !void {
        if (scope.len == 0) {
            try self.doInsertHere(allocator, scope_depth, parent_scopes, font_style, foreground, background, font_family, font_size, line_height);
            return;
        }

        var head = scope;
        var tail: ScopeName = "";
        if (std.mem.indexOfScalar(u8, scope, '.')) |dot_index| {
            head = scope[0..dot_index];
            tail = scope[dot_index + 1 ..];
        }

        var child = self.children.get(head) orelse blk: {
            const new_child = try allocator.create(ThemeTrieElement);
            new_child.* = ThemeTrieElement.init(self.main_rule.clone());
            for (self.rules_with_parent_scopes.items) |rule| {
                const cloned_rule = try allocator.create(ThemeTrieElementRule);
                cloned_rule.* = rule.clone();
                try new_child.rules_with_parent_scopes.append(allocator, cloned_rule);
            }
            try self.children.put(allocator, try allocator.dupe(u8, head), new_child);
            break :blk new_child;
        };

        try child.insert(allocator, scope_depth + 1, tail, parent_scopes, font_style, foreground, background, font_family, font_size, line_height);
    }

    fn doInsertHere(
        self: *ThemeTrieElement,
        allocator: Allocator,
        scope_depth: usize,
        parent_scopes: ?[]const ScopeName,
        font_style: i32,
        foreground: u32,
        background: u32,
        font_family: []const u8,
        font_size: f64,
        line_height: f64,
    ) !void {
        if (parent_scopes == null) {
            self.main_rule.acceptOverwrite(scope_depth, font_style, foreground, background, font_family, font_size, line_height);
            return;
        }

        for (self.rules_with_parent_scopes.items) |rule| {
            if (utils.strArrCmp(rule.parent_scopes, parent_scopes) == 0) {
                rule.acceptOverwrite(scope_depth, font_style, foreground, background, font_family, font_size, line_height);
                return;
            }
        }

        const new_rule = ThemeTrieElementRule{
            .scope_depth = scope_depth,
            .parent_scopes = parent_scopes.?,
            .font_style = if (font_style == FontStyle.not_set) self.main_rule.font_style else font_style,
            .foreground = if (foreground == 0) self.main_rule.foreground else foreground,
            .background = if (background == 0) self.main_rule.background else background,
            .font_family = if (font_family.len == 0) self.main_rule.font_family else font_family,
            .font_size = if (font_size == 0) self.main_rule.font_size else font_size,
            .line_height = if (line_height == 0) self.main_rule.line_height else line_height,
        };
        const rule = try allocator.create(ThemeTrieElementRule);
        rule.* = new_rule;
        try self.rules_with_parent_scopes.append(allocator, rule);
    }
};

pub const Theme = struct {
    arena: std.heap.ArenaAllocator,
    color_map: ColorMap,
    defaults: StyleAttributes,
    root: *ThemeTrieElement,
    cached_match_root: std.StringHashMap([]*ThemeTrieElementRule),

    pub fn createFromRawTheme(
        child_allocator: Allocator,
        source: ?*const RawTheme,
        color_map: ?[]const []const u8,
    ) !*Theme {
        const self = try child_allocator.create(Theme);
        errdefer child_allocator.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .color_map = undefined,
            .defaults = undefined,
            .root = undefined,
            .cached_match_root = undefined,
        };
        errdefer self.arena.deinit();

        const allocator = self.arena.allocator();
        const parsed = try parseTheme(allocator, source);
        try self.resolveParsed(allocator, parsed, color_map);
        return self;
    }

    pub fn createFromParsedTheme(
        child_allocator: Allocator,
        parsed_rules: []ParsedThemeRule,
        color_map: ?[]const []const u8,
    ) !*Theme {
        const self = try child_allocator.create(Theme);
        errdefer child_allocator.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .color_map = undefined,
            .defaults = undefined,
            .root = undefined,
            .cached_match_root = undefined,
        };
        errdefer self.arena.deinit();
        try self.resolveParsed(self.arena.allocator(), parsed_rules, color_map);
        return self;
    }

    fn resolveParsed(
        self: *Theme,
        allocator: Allocator,
        parsed_rules: []ParsedThemeRule,
        color_map_input: ?[]const []const u8,
    ) !void {
        std.mem.sort(ParsedThemeRule, parsed_rules, {}, struct {
            fn lessThan(_: void, a: ParsedThemeRule, b: ParsedThemeRule) bool {
                const scope_cmp = utils.strcmp(a.scope, b.scope);
                if (scope_cmp != 0) return scope_cmp < 0;
                const parent_cmp = utils.strArrCmp(a.parent_scopes, b.parent_scopes);
                if (parent_cmp != 0) return parent_cmp < 0;
                return a.index < b.index;
            }
        }.lessThan);

        var default_font_style: i32 = FontStyle.none;
        var default_foreground: []const u8 = "#000000";
        var default_background: []const u8 = "#ffffff";
        var default_font_family: []const u8 = "";
        var default_font_size: f64 = 0;
        var default_line_height: f64 = 0;

        var rule_index: usize = 0;
        while (rule_index < parsed_rules.len and parsed_rules[rule_index].scope.len == 0) : (rule_index += 1) {
            const incoming = parsed_rules[rule_index];
            if (incoming.font_style != FontStyle.not_set) default_font_style = incoming.font_style;
            if (incoming.foreground) |foreground| default_foreground = foreground;
            if (incoming.background) |background| default_background = background;
            if (incoming.font_family.len != 0) default_font_family = incoming.font_family;
            if (incoming.font_size != 0) default_font_size = incoming.font_size;
            if (incoming.line_height != 0) default_line_height = incoming.line_height;
        }

        self.color_map = try ColorMap.init(allocator, color_map_input);
        self.defaults = StyleAttributes{
            .font_style = default_font_style,
            .foreground_id = try self.color_map.getId(default_foreground),
            .background_id = try self.color_map.getId(default_background),
            .font_family = default_font_family,
            .font_size = default_font_size,
            .line_height = default_line_height,
        };

        const root = try allocator.create(ThemeTrieElement);
        root.* = ThemeTrieElement.init(.{
            .scope_depth = 0,
            .parent_scopes = &.{},
            .font_style = FontStyle.not_set,
            .foreground = 0,
            .background = 0,
            .font_family = default_font_family,
            .font_size = default_font_size,
            .line_height = default_line_height,
        });
        self.root = root;

        while (rule_index < parsed_rules.len) : (rule_index += 1) {
            const rule = parsed_rules[rule_index];
            try root.insert(
                allocator,
                0,
                rule.scope,
                rule.parent_scopes,
                rule.font_style,
                try self.color_map.getId(rule.foreground),
                try self.color_map.getId(rule.background),
                rule.font_family,
                rule.font_size,
                rule.line_height,
            );
        }

        self.cached_match_root = std.StringHashMap([]*ThemeTrieElementRule).init(allocator);
    }

    pub fn deinit(self: *Theme) void {
        const child_allocator = self.arena.child_allocator;
        self.color_map.deinit();
        self.arena.deinit();
        child_allocator.destroy(self);
    }

    pub fn getColorMap(self: *const Theme) []const []const u8 {
        return self.color_map.getColorMap();
    }

    pub fn getDefaults(self: *const Theme) StyleAttributes {
        return self.defaults;
    }

    pub fn match(self: *Theme, scope_path: ?*const ScopeStack) !?StyleAttributes {
        const path = scope_path orelse return self.defaults;
        const scope_name = path.scope_name;

        const matching = self.cached_match_root.get(scope_name) orelse blk: {
            const rules = try self.root.match(self.arena.allocator(), scope_name);
            try self.cached_match_root.put(scope_name, rules);
            break :blk rules;
        };

        for (matching) |rule| {
            if (scopePathMatchesParentScopes(path.parent, rule.parent_scopes)) {
                return StyleAttributes{
                    .font_style = rule.font_style,
                    .foreground_id = rule.foreground,
                    .background_id = rule.background,
                    .font_family = rule.font_family,
                    .font_size = rule.font_size,
                    .line_height = rule.line_height,
                };
            }
        }
        return null;
    }
};

pub fn fontStyleToString(allocator: Allocator, font_style: i32) ![]u8 {
    if (font_style == FontStyle.not_set) return allocator.dupe(u8, "not set");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if ((font_style & FontStyle.italic) != 0) try out.appendSlice(allocator, "italic ");
    if ((font_style & FontStyle.bold) != 0) try out.appendSlice(allocator, "bold ");
    if ((font_style & FontStyle.underline) != 0) try out.appendSlice(allocator, "underline ");
    if ((font_style & FontStyle.strikethrough) != 0) try out.appendSlice(allocator, "strikethrough ");
    if (out.items.len == 0) return allocator.dupe(u8, "none");
    const result = try allocator.dupe(u8, std.mem.trimEnd(u8, out.items, " "));
    out.deinit(allocator);
    return result;
}

test "theme parses and resolves defaults" {
    const settings = [_]RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000", .background = "#200000" } },
        .{ .scope = .{ .single = "c a" }, .settings = .{ .foreground = "#300000" } },
        .{ .scope = .{ .single = "d a.b" }, .settings = .{ .foreground = "#400000" } },
        .{ .scope = .{ .single = "a" }, .settings = .{ .foreground = "#500000" } },
    };
    const raw = RawTheme{ .settings = @constCast(&settings) };
    const theme = try Theme.createFromRawTheme(std.testing.allocator, &raw, null);
    defer theme.deinit();

    var scope_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scope_arena.deinit();
    const path = (try ScopeStack.from(scope_arena.allocator(), &.{ "d", "a.b" })).?;
    const result = (try theme.match(path)).?;
    try std.testing.expectEqualStrings("#400000", theme.getColorMap()[result.foreground_id]);
}

test "theme style attributes string" {
    const text = try fontStyleToString(std.testing.allocator, FontStyle.italic | FontStyle.bold | FontStyle.strikethrough);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("italic bold strikethrough", text);
}

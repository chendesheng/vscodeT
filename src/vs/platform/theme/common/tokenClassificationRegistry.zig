// Port of the token-classification registry subset of
// `src/vs/platform/theme/common/tokenClassificationRegistry.ts`.
//
// Terminal adaptations: no JSON settings schema/NLS contribution (the terminal
// has no settings-editor schema UI); token styles and selector matching are
// kept upstream-shaped, and the default type/modifier contributions and
// default styling rules are registered explicitly instead of through the
// platform registry.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = @import("../../../base/common/color.zig").Color;

pub const token_type_wildcard = "*";
pub const language_separator = ':';
pub const modifier_separator = '.';

pub const TokenStyle = struct {
    foreground: ?Color = null,
    bold: ?bool = null,
    underline: ?bool = null,
    strikethrough: ?bool = null,
    italic: ?bool = null,

    pub fn fromSettings(
        foreground: ?[]const u8,
        font_style: ?[]const u8,
        bold: ?bool,
        underline: ?bool,
        strikethrough: ?bool,
        italic: ?bool,
    ) TokenStyle {
        var result = TokenStyle{
            .foreground = if (foreground) |value| Color.fromHex(value) catch null else null,
            .bold = bold,
            .underline = underline,
            .strikethrough = strikethrough,
            .italic = italic,
        };
        if (font_style) |style| {
            result.bold = false;
            result.italic = false;
            result.underline = false;
            result.strikethrough = false;
            var iterator = std.mem.tokenizeAny(u8, style, " ");
            while (iterator.next()) |part| {
                if (std.mem.eql(u8, part, "bold")) result.bold = true;
                if (std.mem.eql(u8, part, "italic")) result.italic = true;
                if (std.mem.eql(u8, part, "underline")) result.underline = true;
                if (std.mem.eql(u8, part, "strikethrough")) result.strikethrough = true;
            }
        }
        return result;
    }
};

pub const Contribution = struct {
    num: usize,
    id: []const u8,
    super_type: ?[]const u8 = null,
    description: []const u8,
    deprecation_message: ?[]const u8 = null,
};

pub const Selector = struct {
    type: []const u8,
    modifiers: []const []const u8,
    language: ?[]const u8,
    id: []const u8,

    pub fn match(self: Selector, token_type: []const u8, modifiers: []const []const u8, language: []const u8, registry: *const Registry) i32 {
        var score: i32 = 0;
        if (self.language) |selector_language| {
            if (!std.mem.eql(u8, selector_language, language)) return -1;
            score += 10;
        }
        if (!std.mem.eql(u8, self.type, token_type_wildcard)) {
            const hierarchy = registry.typeHierarchy(token_type) catch return -1;
            defer registry.allocator.free(hierarchy);
            var level: ?usize = null;
            for (hierarchy, 0..) |entry, index| {
                if (std.mem.eql(u8, entry, self.type)) {
                    level = index;
                    break;
                }
            }
            const found = level orelse return -1;
            score += 100 - @as(i32, @intCast(found));
        }
        for (self.modifiers) |selector_modifier| {
            var present = false;
            for (modifiers) |modifier| {
                if (std.mem.eql(u8, modifier, selector_modifier)) {
                    present = true;
                    break;
                }
            }
            if (!present) return -1;
        }
        return score + @as(i32, @intCast(self.modifiers.len)) * 100;
    }
};

pub const Defaults = struct {
    scopes_to_probe: ?[]const []const u8 = null,
    light: ?TokenStyle = null,
    dark: ?TokenStyle = null,
    hc_dark: ?TokenStyle = null,
    hc_light: ?TokenStyle = null,
};

pub const DefaultRule = struct {
    selector: Selector,
    defaults: Defaults,
};

pub const ParsedClassifier = struct {
    type: []const u8,
    modifiers: []const []const u8,
    language: ?[]const u8,
};

pub fn parseClassifierString(allocator: Allocator, text: []const u8, default_language: ?[]const u8) !ParsedClassifier {
    var modifiers = std.array_list.Managed([]const u8).init(allocator);
    errdefer modifiers.deinit();
    var language = default_language;
    var end = text.len;
    var index = text.len;
    while (index > 0) {
        index -= 1;
        const ch = text[index];
        if (ch == language_separator or ch == modifier_separator) {
            const segment = text[index + 1 .. end];
            end = index;
            if (ch == language_separator) {
                language = try allocator.dupe(u8, segment);
            } else {
                try modifiers.append(try allocator.dupe(u8, segment));
            }
        }
    }
    return .{
        .type = try allocator.dupe(u8, text[0..end]),
        .modifiers = try modifiers.toOwnedSlice(),
        .language = language,
    };
}

fn isId(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

pub const Registry = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    types: std.StringHashMap(Contribution),
    type_order: std.array_list.Managed([]const u8),
    modifiers: std.StringHashMap(Contribution),
    modifier_order: std.array_list.Managed([]const u8),
    default_rules: std.array_list.Managed(DefaultRule),
    current_type_number: usize = 0,
    current_modifier_bit: usize = 1,

    pub fn init(allocator: Allocator) Registry {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .types = std.StringHashMap(Contribution).init(allocator),
            .type_order = std.array_list.Managed([]const u8).init(allocator),
            .modifiers = std.StringHashMap(Contribution).init(allocator),
            .modifier_order = std.array_list.Managed([]const u8).init(allocator),
            .default_rules = std.array_list.Managed(DefaultRule).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.types.deinit();
        self.type_order.deinit();
        self.modifiers.deinit();
        self.modifier_order.deinit();
        self.default_rules.deinit();
        self.arena.deinit();
    }

    pub fn registerTokenType(self: *Registry, id: []const u8, description: []const u8, super_type: ?[]const u8, deprecation_message: ?[]const u8) !void {
        if (!isId(id)) return error.InvalidTokenType;
        if (super_type) |super| if (!isId(super)) return error.InvalidTokenSuperType;
        const arena = self.arena.allocator();
        const key = try arena.dupe(u8, id);
        try self.types.put(key, .{
            .num = self.current_type_number,
            .id = key,
            .super_type = if (super_type) |value| try arena.dupe(u8, value) else null,
            .description = try arena.dupe(u8, description),
            .deprecation_message = if (deprecation_message) |value| try arena.dupe(u8, value) else null,
        });
        try self.type_order.append(key);
        self.current_type_number += 1;
    }

    pub fn registerTokenModifier(self: *Registry, id: []const u8, description: []const u8, deprecation_message: ?[]const u8) !void {
        if (!isId(id)) return error.InvalidTokenModifier;
        const arena = self.arena.allocator();
        const key = try arena.dupe(u8, id);
        try self.modifiers.put(key, .{
            .num = self.current_modifier_bit,
            .id = key,
            .description = try arena.dupe(u8, description),
            .deprecation_message = if (deprecation_message) |value| try arena.dupe(u8, value) else null,
        });
        try self.modifier_order.append(key);
        self.current_modifier_bit *= 2;
    }

    pub fn deregisterTokenType(self: *Registry, id: []const u8) void {
        _ = self.types.remove(id);
    }

    pub fn deregisterTokenModifier(self: *Registry, id: []const u8) void {
        _ = self.modifiers.remove(id);
    }

    pub fn parseTokenSelector(self: *Registry, selector_string: []const u8, language: ?[]const u8) !Selector {
        const arena = self.arena.allocator();
        const parsed = try parseClassifierString(arena, selector_string, language);
        if (parsed.type.len == 0) {
            return .{ .type = "$invalid", .modifiers = &.{}, .language = null, .id = "$invalid" };
        }
        var id = std.array_list.Managed(u8).init(arena);
        try id.appendSlice(parsed.type);
        for (parsed.modifiers) |modifier| {
            try id.append(modifier_separator);
            try id.appendSlice(modifier);
        }
        if (parsed.language) |selector_language| {
            try id.append(language_separator);
            try id.appendSlice(selector_language);
        }
        return .{
            .type = parsed.type,
            .modifiers = parsed.modifiers,
            .language = parsed.language,
            .id = try id.toOwnedSlice(),
        };
    }

    pub fn registerTokenStyleDefault(self: *Registry, selector: Selector, defaults: Defaults) !void {
        try self.default_rules.append(.{ .selector = selector, .defaults = defaults });
    }

    pub fn deregisterTokenStyleDefault(self: *Registry, selector: Selector) void {
        var index: usize = 0;
        while (index < self.default_rules.items.len) {
            if (std.mem.eql(u8, self.default_rules.items[index].selector.id, selector.id)) {
                _ = self.default_rules.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn getTokenTypes(self: *Registry) []const Contribution {
        var result = std.array_list.Managed(Contribution).init(self.allocator);
        defer result.deinit();
        for (self.type_order.items) |id| {
            if (self.types.get(id)) |contribution| result.append(contribution) catch break;
        }
        return result.toOwnedSlice() catch &.{};
    }

    pub fn getTokenModifiers(self: *Registry) []const Contribution {
        var result = std.array_list.Managed(Contribution).init(self.allocator);
        defer result.deinit();
        for (self.modifier_order.items) |id| {
            if (self.modifiers.get(id)) |contribution| result.append(contribution) catch break;
        }
        return result.toOwnedSlice() catch &.{};
    }

    pub fn getTokenStylingDefaultRules(self: *Registry) []const DefaultRule {
        return self.default_rules.items;
    }

    /// Returns the type + super-type hierarchy (the type itself first).
    pub fn typeHierarchy(self: *const Registry, type_id: []const u8) ![]const []const u8 {
        var hierarchy = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer hierarchy.deinit();
        try hierarchy.append(type_id);
        var current = self.types.get(type_id);
        while (current) |contribution| {
            const super_type = contribution.super_type orelse break;
            try hierarchy.append(super_type);
            current = self.types.get(super_type);
        }
        return hierarchy.toOwnedSlice();
    }
};

pub fn createDefaultRegistry(allocator: Allocator) !Registry {
    var registry = Registry.init(allocator);
    errdefer registry.deinit();
    const arena = registry.arena.allocator();
    const defaults = [_]struct { id: []const u8, description: []const u8, scopes: []const []const u8, super_type: ?[]const u8 = null }{
        .{ .id = "comment", .description = "Style for comments.", .scopes = &.{"comment"} },
        .{ .id = "string", .description = "Style for strings.", .scopes = &.{"string"} },
        .{ .id = "keyword", .description = "Style for keywords.", .scopes = &.{"keyword.control"} },
        .{ .id = "number", .description = "Style for numbers.", .scopes = &.{"constant.numeric"} },
        .{ .id = "regexp", .description = "Style for expressions.", .scopes = &.{"constant.regexp"} },
        .{ .id = "operator", .description = "Style for operators.", .scopes = &.{"keyword.operator"} },
        .{ .id = "namespace", .description = "Style for namespaces.", .scopes = &.{"entity.name.namespace"} },
        .{ .id = "type", .description = "Style for types.", .scopes = &.{ "entity.name.type", "support.type" } },
        .{ .id = "struct", .description = "Style for structs.", .scopes = &.{"entity.name.type.struct"} },
        .{ .id = "class", .description = "Style for classes.", .scopes = &.{ "entity.name.type.class", "support.class" } },
        .{ .id = "interface", .description = "Style for interfaces.", .scopes = &.{"entity.name.type.interface"} },
        .{ .id = "enum", .description = "Style for enums.", .scopes = &.{"entity.name.type.enum"} },
        .{ .id = "typeParameter", .description = "Style for type parameters.", .scopes = &.{"entity.name.type.parameter"} },
        .{ .id = "function", .description = "Style for functions", .scopes = &.{ "entity.name.function", "support.function" } },
        .{ .id = "member", .description = "Style for member functions", .scopes = &.{}, .super_type = "method" },
        .{ .id = "method", .description = "Style for method (member functions)", .scopes = &.{ "entity.name.function.member", "support.function" } },
        .{ .id = "macro", .description = "Style for macros.", .scopes = &.{"entity.name.function.preprocessor"} },
        .{ .id = "variable", .description = "Style for variables.", .scopes = &.{ "variable.other.readwrite", "entity.name.variable" } },
        .{ .id = "parameter", .description = "Style for parameters.", .scopes = &.{"variable.parameter"} },
        .{ .id = "property", .description = "Style for properties.", .scopes = &.{"variable.other.property"} },
        .{ .id = "enumMember", .description = "Style for enum members.", .scopes = &.{"variable.other.enummember"} },
        .{ .id = "event", .description = "Style for events.", .scopes = &.{"variable.other.event"} },
        .{ .id = "decorator", .description = "Style for decorators & annotations.", .scopes = &.{ "entity.name.decorator", "entity.name.function" } },
        .{ .id = "label", .description = "Style for labels. ", .scopes = &.{} },
    };
    for (defaults) |entry| {
        try registry.registerTokenType(entry.id, entry.description, entry.super_type, null);
        if (entry.scopes.len > 0) {
            const selector = try parseStaticSelector(registry.allocator, arena, entry.id);
            try registry.registerTokenStyleDefault(selector, .{ .scopes_to_probe = entry.scopes });
        }
    }
    const modifiers = [_][]const u8{ "declaration", "documentation", "static", "abstract", "deprecated", "modification", "async", "readonly" };
    for (modifiers) |modifier| try registry.registerTokenModifier(modifier, modifier, null);
    const rules = [_]struct { id: []const u8, scopes: []const []const u8 }{
        .{ .id = "variable.readonly", .scopes = &.{"variable.other.constant"} },
        .{ .id = "property.readonly", .scopes = &.{"variable.other.constant.property"} },
        .{ .id = "type.defaultLibrary", .scopes = &.{"support.type"} },
        .{ .id = "class.defaultLibrary", .scopes = &.{"support.class"} },
        .{ .id = "interface.defaultLibrary", .scopes = &.{"support.class"} },
        .{ .id = "variable.defaultLibrary", .scopes = &.{ "support.variable", "support.other.variable" } },
        .{ .id = "variable.defaultLibrary.readonly", .scopes = &.{"support.constant"} },
        .{ .id = "property.defaultLibrary", .scopes = &.{"support.variable.property"} },
        .{ .id = "property.defaultLibrary.readonly", .scopes = &.{"support.constant.property"} },
        .{ .id = "function.defaultLibrary", .scopes = &.{"support.function"} },
        .{ .id = "member.defaultLibrary", .scopes = &.{"support.function"} },
    };
    for (rules) |rule| {
        const selector = try parseStaticSelector(registry.allocator, arena, rule.id);
        try registry.registerTokenStyleDefault(selector, .{ .scopes_to_probe = rule.scopes });
    }
    return registry;
}

fn parseStaticSelector(_: Allocator, arena: Allocator, text: []const u8) !Selector {
    const parsed = try parseClassifierString(arena, text, null);
    var id = std.array_list.Managed(u8).init(arena);
    try id.appendSlice(parsed.type);
    for (parsed.modifiers) |modifier| {
        try id.append(modifier_separator);
        try id.appendSlice(modifier);
    }
    return .{
        .type = parsed.type,
        .modifiers = parsed.modifiers,
        .language = parsed.language,
        .id = try id.toOwnedSlice(),
    };
}

test "token selectors parse, score and use the type hierarchy" {
    const allocator = std.testing.allocator;
    var registry = try createDefaultRegistry(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.types.get("comment") != null);
    try std.testing.expect(registry.types.get("member").?.super_type != null);
    try std.testing.expect(registry.getTokenStylingDefaultRules().len > 0);

    const readonly = try registry.parseTokenSelector("*.readonly", null);
    try std.testing.expect(readonly.match("variable", &.{"readonly"}, "typescript", &registry) >= 100);
    try std.testing.expectEqual(@as(i32, -1), readonly.match("variable", &.{}, "typescript", &registry));

    const typed = try registry.parseTokenSelector("member:typescript", null);
    try std.testing.expect(typed.match("member", &.{}, "typescript", &registry) >= 10);
    try std.testing.expectEqual(@as(i32, -1), typed.match("member", &.{}, "python", &registry));

    const method = try registry.parseTokenSelector("method", null);
    try std.testing.expect(method.match("member", &.{}, "typescript", &registry) > 0);

    const hierarchy = try registry.typeHierarchy("member");
    defer allocator.free(hierarchy);
    try std.testing.expectEqual(@as(usize, 2), hierarchy.len);
    try std.testing.expectEqualStrings("method", hierarchy[1]);
}

test "token styles parse font styles" {
    const style = TokenStyle.fromSettings("#ff0000", "bold italic underline", null, null, null, null);
    try std.testing.expect(style.foreground != null);
    try std.testing.expect(style.bold.?);
    try std.testing.expect(style.italic.?);
    try std.testing.expect(style.underline.?);
    try std.testing.expect(!style.strikethrough.?);
}

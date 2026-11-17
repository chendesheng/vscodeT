// Port of the color-map/token/storage subset of
// `src/vs/workbench/services/themes/common/colorThemeData.ts`.
//
// Terminal adaptations and current scope:
// - File/extension theme loading (`ensureLoaded`, plist/tmTheme parsing,
//   extension resource loader, watch) is not ported yet; only the in-memory
//   theme data, custom/transient colors and storage round-trip are.
// - The global color registry is passed explicitly, and maps are keyed by the
//   original hex strings so token backgrounds keep their authored casing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = @import("../../../../base/common/color.zig").Color;
const color_utils = @import("../../../../platform/theme/common/colorUtils.zig");
const theme_service = @import("../../../../platform/theme/common/themeService.zig");
const theme_mod = @import("../../../../platform/theme/common/theme.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");

const ColorRegistry = color_utils.ColorRegistry;
const ColorValue = color_utils.ColorValue;
const IColorTheme = theme_service.IColorTheme;
const ColorScheme = theme_mod.ColorScheme;
const InMemoryStorageService = storage_mod.InMemoryStorageService;
const plist_parser = @import("./plistParser.zig");
const token_classification = @import("../../../../platform/theme/common/tokenClassificationRegistry.zig");
const scope_matcher = @import("./textMateScopeMatcher.zig");
const TokenStyle = token_classification.TokenStyle;

pub const ResourceReader = struct {
    context: *anyopaque,
    /// Returns the file contents (borrowed for the duration of the call).
    read: *const fn (context: *anyopaque, path: []const u8) anyerror![]const u8,
};

pub const TokenStyleSettings = struct {
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    font_style: ?[]const u8 = null,
};

pub const TokenColor = struct {
    settings: TokenStyleSettings,
    scope: ?[]const []const u8 = null,
};

pub const SemanticRuleInput = struct {
    selector: []const u8,
    foreground: ?[]const u8 = null,
    font_style: ?[]const u8 = null,
    bold: ?bool = null,
    underline: ?bool = null,
    strikethrough: ?bool = null,
    italic: ?bool = null,
    language: ?[]const u8 = null,
};

pub const SemanticRule = struct {
    selector: token_classification.Selector,
    style: TokenStyle,
};

pub const ColorThemeData = struct {
    pub const STORAGE_KEY = "workbench.colorTheme";

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    registry: *ColorRegistry,
    id: []const u8,
    label: []const u8,
    settings_id: []const u8,
    theme_type: ColorScheme,
    color_map: std.StringHashMap([]const u8),
    custom_colors: std.StringHashMap([]const u8),
    transient_colors: ?std.StringHashMap(Color),
    token_colors: []TokenColor,
    theme_token_colors: []TokenColor = &.{},
    custom_token_colors: []TokenColor = &.{},
    semantic_token_rules: []SemanticRule = &.{},
    token_registry: ?*token_classification.Registry = null,
    owns_token_registry: bool = false,
    location: ?[]const u8 = null,
    is_loaded: bool = false,
    load_error_message: ?[]u8 = null,

    pub fn createUnloadedTheme(allocator: Allocator, registry: *ColorRegistry, id: []const u8, color_map: []const [2][]const u8) !*ColorThemeData {
        const self = try allocator.create(ColorThemeData);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        self.* = .{
            .allocator = allocator,
            .arena = arena,
            .registry = registry,
            .id = undefined,
            .label = undefined,
            .settings_id = undefined,
            .theme_type = themeTypeFromId(id),
            .color_map = undefined,
            .custom_colors = undefined,
            .transient_colors = null,
            .token_colors = &.{},
        };
        const arena_allocator = self.arena.allocator();
        self.id = try arena_allocator.dupe(u8, id);
        self.label = try arena_allocator.dupe(u8, "");
        self.settings_id = try prefixedId(arena_allocator, id);
        self.color_map = std.StringHashMap([]const u8).init(arena_allocator);
        self.custom_colors = std.StringHashMap([]const u8).init(arena_allocator);
        for (color_map) |entry| {
            try self.color_map.put(try arena_allocator.dupe(u8, entry[0]), try arena_allocator.dupe(u8, entry[1]));
        }
        self.token_colors = try buildTokenColors(arena_allocator, self.color_map, null, &.{});
        return self;
    }

    pub fn deinit(self: *ColorThemeData) void {
        if (self.owns_token_registry) {
            if (self.token_registry) |registry| {
                registry.deinit();
                self.allocator.destroy(registry);
            }
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn getColor(self: *ColorThemeData, color_id: []const u8, use_default: bool) ?Color {
        if (self.transient_colors) |transient| {
            if (transient.get(color_id)) |color| return color;
        }
        if (self.custom_colors.get(color_id)) |raw| return Color.fromHex(raw) catch null;
        if (self.color_map.get(color_id)) |raw| return Color.fromHex(raw) catch null;
        if (!use_default) return null;
        const iface = self.interface();
        return self.registry.resolveDefaultColor(color_id, &iface);
    }

    pub fn defines(self: *ColorThemeData, color_id: []const u8) bool {
        if (self.transient_colors) |transient| {
            if (transient.contains(color_id)) return true;
        }
        return self.custom_colors.contains(color_id) or self.color_map.contains(color_id);
    }

    pub fn getColorCustomization(self: *ColorThemeData, color_id: []const u8) ?Color {
        const raw = self.custom_colors.get(color_id) orelse return null;
        return Color.fromHex(raw) catch null;
    }

    pub fn setCustomColors(self: *ColorThemeData, colors: []const [2][]const u8) !void {
        self.custom_colors.clearRetainingCapacity();
        for (colors) |entry| {
            try self.custom_colors.put(
                try self.arena.allocator().dupe(u8, entry[0]),
                try self.arena.allocator().dupe(u8, entry[1]),
            );
        }
        try self.refreshTokenColors();
    }

    /// Replaces runtime-only colors; they are deliberately excluded from
    /// theme storage.
    pub fn setTransientColors(self: *ColorThemeData, colors: ?[]const [2][]const u8) !void {
        self.transient_colors = null;
        if (colors) |entries| {
            var transient = std.StringHashMap(Color).init(self.arena.allocator());
            for (entries) |entry| {
                try transient.put(
                    try self.arena.allocator().dupe(u8, entry[0]),
                    Color.fromHex(entry[1]) catch continue,
                );
            }
            self.transient_colors = transient;
        }
        try self.refreshTokenColors();
    }

    pub fn getBaseTheme(self: *ColorThemeData) !*ColorThemeData {
        if (self.transient_colors == null) return self;
        const theme = try self.allocator.create(ColorThemeData);
        errdefer self.allocator.destroy(theme);
        theme.* = .{
            .allocator = self.allocator,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .registry = self.registry,
            .id = undefined,
            .label = undefined,
            .settings_id = undefined,
            .theme_type = self.theme_type,
            .color_map = undefined,
            .custom_colors = undefined,
            .transient_colors = null,
            .token_colors = &.{},
        };
        const allocator = theme.arena.allocator();
        theme.id = try allocator.dupe(u8, self.id);
        theme.label = try allocator.dupe(u8, self.label);
        theme.settings_id = try allocator.dupe(u8, self.settings_id);
        theme.color_map = std.StringHashMap([]const u8).init(allocator);
        var colors = self.color_map.iterator();
        while (colors.next()) |entry| {
            try theme.color_map.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }
        theme.custom_colors = std.StringHashMap([]const u8).init(allocator);
        var custom = self.custom_colors.iterator();
        while (custom.next()) |entry| {
            try theme.custom_colors.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }
        theme.token_colors = try buildTokenColors(allocator, theme.color_map, null, &.{});
        return theme;
    }

    pub fn createLoadedEmptyTheme(allocator: Allocator, registry: *ColorRegistry, id: []const u8) !*ColorThemeData {
        const theme = try ColorThemeData.createUnloadedTheme(allocator, registry, id, &.{});
        theme.is_loaded = true;
        return theme;
    }

    pub fn setTokenRegistry(self: *ColorThemeData, registry: *token_classification.Registry) void {
        if (self.owns_token_registry) {
            if (self.token_registry) |owned| {
                owned.deinit();
                self.allocator.destroy(owned);
            }
            self.owns_token_registry = false;
        }
        self.token_registry = registry;
    }

    fn getTokenRegistry(self: *ColorThemeData) !*token_classification.Registry {
        if (self.token_registry) |registry| return registry;
        const registry = try self.allocator.create(token_classification.Registry);
        errdefer self.allocator.destroy(registry);
        registry.* = try token_classification.createDefaultRegistry(self.allocator);
        self.token_registry = registry;
        self.owns_token_registry = true;
        return registry;
    }

    pub fn setCustomSemanticTokenColors(self: *ColorThemeData, rules: []const SemanticRuleInput) !void {
        const allocator = self.arena.allocator();
        const registry = try self.getTokenRegistry();
        var result = std.array_list.Managed(SemanticRule).init(allocator);
        for (rules) |rule| {
            const selector = try registry.parseTokenSelector(rule.selector, rule.language);
            try result.append(.{
                .selector = selector,
                .style = TokenStyle.fromSettings(rule.foreground, rule.font_style, rule.bold, rule.underline, rule.strikethrough, rule.italic),
            });
        }
        self.semantic_token_rules = try result.toOwnedSlice();
    }

    pub fn setCustomTokenColors(self: *ColorThemeData, rules: []const TokenColor) !void {
        const allocator = self.arena.allocator();
        var result = std.array_list.Managed(TokenColor).init(allocator);
        for (rules) |rule| {
            var copy = TokenColor{ .settings = .{} };
            if (rule.settings.foreground) |value| copy.settings.foreground = try allocator.dupe(u8, value);
            if (rule.settings.background) |value| copy.settings.background = try allocator.dupe(u8, value);
            if (rule.settings.font_style) |value| copy.settings.font_style = try allocator.dupe(u8, value);
            if (rule.scope) |scopes| {
                var scopes_copy = std.array_list.Managed([]const u8).init(allocator);
                for (scopes) |scope| try scopes_copy.append(try allocator.dupe(u8, scope));
                copy.scope = try scopes_copy.toOwnedSlice();
            }
            try result.append(copy);
        }
        self.custom_token_colors = try result.toOwnedSlice();
    }

    /// Foreground colors of the token rules, index 1-based. Index 0 is unused
    /// (the upstream token-color index uses 0 for "no foreground").
    pub fn getTokenColorMap(self: *ColorThemeData) ![]const Color {
        var colors = std.array_list.Managed(Color).init(self.arena.allocator());
        try colors.append(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        var seen = std.array_list.Managed(Color).init(self.arena.allocator());
        defer seen.deinit();
        for (self.semantic_token_rules) |rule| {
            const color = rule.style.foreground orelse continue;
            var present = false;
            for (seen.items) |entry| {
                if (entry.r == color.r and entry.g == color.g and entry.b == color.b) {
                    present = true;
                    break;
                }
            }
            if (!present) {
                try seen.append(color);
                try colors.append(color);
            }
        }
        for (self.token_colors) |rule| {
            const foreground = rule.settings.foreground orelse continue;
            const color = Color.fromHex(foreground) catch continue;
            var present = false;
            for (seen.items) |entry| {
                if (entry.r == color.r and entry.g == color.g and entry.b == color.b) {
                    present = true;
                    break;
                }
            }
            if (!present) {
                try seen.append(color);
                try colors.append(color);
            }
        }
        return colors.toOwnedSlice();
    }

    pub fn getTokenStyleMetadata(self: *ColorThemeData, type_with_language: []const u8, modifiers: []const []const u8, default_language: []const u8) ?theme_service.ITokenStyle {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const parsed = token_classification.parseClassifierString(scratch.allocator(), type_with_language, default_language) catch return null;
        const style = self.getTokenStyle(parsed.type, modifiers, parsed.language orelse default_language) catch return null;
        var foreground: ?u32 = null;
        if (style.foreground) |color| {
            const map = self.getTokenColorMap() catch return null;
            for (map, 0..) |entry, index| {
                if (entry.r == color.r and entry.g == color.g and entry.b == color.b) {
                    foreground = @intCast(index);
                    break;
                }
            }
        }
        return .{
            .foreground = foreground,
            .bold = style.bold,
            .underline = style.underline,
            .strikethrough = style.strikethrough,
            .italic = style.italic,
        };
    }

    fn getTokenStyle(self: *ColorThemeData, type_id: []const u8, modifiers: []const []const u8, language: []const u8) !TokenStyle {
        const registry = try self.getTokenRegistry();
        var result = TokenStyle{};
        var foreground_score: i32 = -1;
        var bold_score: i32 = -1;
        var underline_score: i32 = -1;
        var strikethrough_score: i32 = -1;
        var italic_score: i32 = -1;

        for (self.semantic_token_rules) |rule| {
            const score = rule.selector.match(type_id, modifiers, language, registry);
            if (score < 0) continue;
            mergeTokenStyle(&result, rule.style, score, &foreground_score, &bold_score, &underline_score, &strikethrough_score, &italic_score);
        }

        if (foreground_score < 0 or bold_score < 0 or underline_score < 0 or strikethrough_score < 0 or italic_score < 0) {
            for (registry.getTokenStylingDefaultRules()) |rule| {
                const score = rule.selector.match(type_id, modifiers, language, registry);
                if (score < 0) continue;
                var style: ?TokenStyle = null;
                if (rule.defaults.scopes_to_probe) |probes| {
                    for (probes) |probe| {
                        if (try self.resolveScopes(probe)) |resolved| {
                            style = resolved;
                            break;
                        }
                    }
                }
                if (style == null) {
                    style = switch (self.theme_type) {
                        .LIGHT => rule.defaults.light,
                        .DARK => rule.defaults.dark,
                        .HIGH_CONTRAST_DARK => rule.defaults.hc_dark,
                        .HIGH_CONTRAST_LIGHT => rule.defaults.hc_light,
                    };
                }
                if (style) |value| mergeTokenStyle(&result, value, score, &foreground_score, &bold_score, &underline_score, &strikethrough_score, &italic_score);
            }
        }
        return result;
    }

    fn resolveScopes(self: *ColorThemeData, probe: []const u8) !?TokenStyle {
        const path = [_][]const u8{probe};
        var foreground: ?[]const u8 = null;
        var font_style: ?[]const u8 = null;
        var foreground_score: i32 = -1;
        var font_style_score: i32 = -1;
        for ([_][]const TokenColor{ self.theme_token_colors, self.custom_token_colors }) |rules| {
            for (rules) |rule| {
                const scopes = rule.scope orelse continue;
                for (scopes) |scope| {
                    const score = try scope_matcher.matchesSelector(self.allocator, scope, &path, self, scopeNameMatcher);
                    if (score < 0) continue;
                    if (score >= foreground_score and rule.settings.foreground != null) {
                        foreground = rule.settings.foreground;
                        foreground_score = score;
                    }
                    if (score >= font_style_score and rule.settings.font_style != null) {
                        font_style = rule.settings.font_style;
                        font_style_score = score;
                    }
                }
            }
        }
        if (foreground == null and font_style == null) return null;
        return TokenStyle.fromSettings(foreground, font_style, null, null, null, null);
    }

    pub fn getTokenColors(self: *const ColorThemeData) []const TokenColor {
        return self.token_colors;
    }

    fn refreshTokenColors(self: *ColorThemeData) !void {
        self.token_colors = try buildTokenColors(self.arena.allocator(), self.color_map, self.transient_colors, self.theme_token_colors);
    }

    pub fn interface(self: *ColorThemeData) IColorTheme {
        return .{
            .theme_type = self.theme_type,
            .label = self.label,
            .context = self,
            .vtable = &vtable,
        };
    }

    const vtable = IColorTheme.VTable{
        .getColor = interfaceGetColor,
        .defines = interfaceDefines,
        .getTokenStyleMetadata = interfaceGetTokenStyleMetadata,
    };

    fn interfaceGetColor(context: *anyopaque, color_id: []const u8, use_default: bool) ?Color {
        const self: *ColorThemeData = @ptrCast(@alignCast(context));
        return self.getColor(color_id, use_default);
    }

    fn interfaceDefines(context: *anyopaque, color_id: []const u8) bool {
        const self: *ColorThemeData = @ptrCast(@alignCast(context));
        return self.defines(color_id);
    }

    fn interfaceGetTokenStyleMetadata(context: *anyopaque, type_with_language: []const u8, modifiers: []const []const u8, default_language: []const u8) ?theme_service.ITokenStyle {
        const self: *ColorThemeData = @ptrCast(@alignCast(context));
        return self.getTokenStyleMetadata(type_with_language, modifiers, default_language);
    }

    pub fn errorMessage(self: *const ColorThemeData) ?[]const u8 {
        return self.load_error_message;
    }

    /// Loads a JSON color theme or a tmTheme plist through the resource reader.
    /// Zig errors carry no message, so parse failures also set
    /// `load_error_message` (the upstream thrown message).
    pub fn ensureLoaded(self: *ColorThemeData, reader: ResourceReader) !void {
        const location = self.location orelse return error.MissingThemeLocation;
        const content = try reader.read(reader.context, location);
        const allocator = self.arena.allocator();
        if (std.mem.endsWith(u8, location, ".tmTheme")) {
            const value = plist_parser.parse(allocator, content) catch return error.InvalidTheme;
            const root_object = switch (value) {
                .object => |object| object,
                else => return error.InvalidTheme,
            };
            const settings = root_object.get("settings") orelse {
                self.load_error_message = try std.fmt.allocPrint(allocator, "Problem parsing tmTheme file: {s}. Missing 'settings'.", .{location});
                return error.InvalidTheme;
            };
            if (settings != .array) {
                self.load_error_message = try std.fmt.allocPrint(allocator, "Problem parsing tmTheme file: {s}. 'settings' is not array.", .{location});
                return error.InvalidTheme;
            }
            var rules = std.array_list.Managed(TokenColor).init(allocator);
            for (settings.array.items) |entry| {
                const entry_object = switch (entry) {
                    .object => |object| object,
                    else => continue,
                };
                const settings_value = entry_object.get("settings") orelse continue;
                const settings_object = switch (settings_value) {
                    .object => |object| object,
                    else => continue,
                };
                var rule = TokenColor{ .settings = .{} };
                if (settings_object.get("foreground")) |foreground| {
                    if (foreground == .string) rule.settings.foreground = foreground.string;
                }
                if (settings_object.get("background")) |background| {
                    if (background == .string) rule.settings.background = background.string;
                }
                if (settings_object.get("fontStyle")) |font_style| {
                    if (font_style == .string) rule.settings.font_style = font_style.string;
                }
                if (entry_object.get("scope")) |scope| {
                    rule.scope = try parseScopeValue(allocator, scope);
                }
                try rules.append(rule);
            }
            self.theme_token_colors = try rules.toOwnedSlice();
            self.is_loaded = true;
            try self.refreshTokenColors();
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidTheme;
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidTheme,
        };
        if (object.get("colors")) |colors| {
            if (colors == .object) {
                var iterator = colors.object.iterator();
                while (iterator.next()) |entry| {
                    const hex = switch (entry.value_ptr.*) {
                        .string => |value| value,
                        else => continue,
                    };
                    try self.color_map.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, hex));
                }
            }
        }
        if (object.get("tokenColors")) |token_colors| {
            if (token_colors == .array) {
                var rules = std.array_list.Managed(TokenColor).init(allocator);
                for (token_colors.array.items) |entry| {
                    const rule_object = switch (entry) {
                        .object => |rule| rule,
                        else => continue,
                    };
                    if (try parseTokenColor(allocator, rule_object)) |rule| try rules.append(rule);
                }
                self.theme_token_colors = try rules.toOwnedSlice();
            }
        }
        self.is_loaded = true;
        try self.refreshTokenColors();
    }

    pub fn toStorage(self: *ColorThemeData, storage: *InMemoryStorageService) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var root = std.json.ObjectMap{};
        try root.put(allocator, "id", .{ .string = self.id });
        try root.put(allocator, "label", .{ .string = self.label });
        try root.put(allocator, "settingsId", .{ .string = self.settings_id });
        try root.put(allocator, "themeTokenColors", .{ .array = std.array_list.Managed(std.json.Value).init(allocator) });
        var colors = std.json.ObjectMap{};
        var iterator = self.color_map.iterator();
        while (iterator.next()) |entry| {
            try colors.put(allocator, entry.key_ptr.*, .{ .string = entry.value_ptr.* });
        }
        try root.put(allocator, "colorMap", .{ .object = colors });

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
        try storage.store(STORAGE_KEY, .{ .string = out.written() }, .profile, .user);
    }

    pub fn fromStorageData(allocator: Allocator, registry: *ColorRegistry, storage: *InMemoryStorageService) !?*ColorThemeData {
        const raw = storage.get(STORAGE_KEY, .profile, null) orelse return null;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const id = switch (object.get("id") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        const theme = try ColorThemeData.createUnloadedTheme(allocator, registry, id, &.{});
        if (object.get("label")) |label| {
            if (label == .string) theme.label = try theme.arena.allocator().dupe(u8, label.string);
        }
        if (object.get("settingsId")) |settings_id| {
            if (settings_id == .string) theme.settings_id = try theme.arena.allocator().dupe(u8, settings_id.string);
        }
        if (object.get("colorMap")) |color_map| {
            if (color_map == .object) {
                var iterator = color_map.object.iterator();
                while (iterator.next()) |entry| {
                    const hex = switch (entry.value_ptr.*) {
                        .string => |value| value,
                        else => continue,
                    };
                    try theme.color_map.put(
                        try theme.arena.allocator().dupe(u8, entry.key_ptr.*),
                        try theme.arena.allocator().dupe(u8, hex),
                    );
                }
            }
        }
        try theme.refreshTokenColors();
        return theme;
    }
};

fn buildTokenColors(allocator: Allocator, color_map: std.StringHashMap([]const u8), transient: ?std.StringHashMap(Color), rules: []const TokenColor) ![]TokenColor {
    const result = try allocator.alloc(TokenColor, 1 + rules.len);
    var background: ?[]const u8 = null;
    if (transient) |colors| {
        if (colors.get("editor.background")) |color| {
            background = try formatHex(color, allocator);
        }
    }
    if (background == null) {
        background = color_map.get("editor.background");
    }
    result[0] = .{ .settings = .{ .background = background } };
    @memcpy(result[1..], rules);
    return result;
}

fn mergeTokenStyle(
    result: *TokenStyle,
    style: TokenStyle,
    score: i32,
    foreground_score: *i32,
    bold_score: *i32,
    underline_score: *i32,
    strikethrough_score: *i32,
    italic_score: *i32,
) void {
    if (style.foreground != null and score >= foreground_score.*) {
        result.foreground = style.foreground;
        foreground_score.* = score;
    }
    if (style.bold != null and score >= bold_score.*) {
        result.bold = style.bold;
        bold_score.* = score;
    }
    if (style.underline != null and score >= underline_score.*) {
        result.underline = style.underline;
        underline_score.* = score;
    }
    if (style.strikethrough != null and score >= strikethrough_score.*) {
        result.strikethrough = style.strikethrough;
        strikethrough_score.* = score;
    }
    if (style.italic != null and score >= italic_score.*) {
        result.italic = style.italic;
        italic_score.* = score;
    }
}

fn scopeNameMatcher(_: *anyopaque, names: []const []const u8, scope: scope_matcher.ProbeScope) i32 {
    var score: i32 = -1;
    for (names) |name| {
        var best: i32 = -1;
        for (scope, 0..) |scope_name, index| {
            if (std.mem.eql(u8, scope_name, name) or
                (scope_name.len > name.len and std.mem.startsWith(u8, scope_name, name) and scope_name[name.len] == '.'))
            {
                best = @max(best, @as(i32, @intCast(index + 1)) * 0x10000 + @as(i32, @intCast(name.len)));
            }
        }
        if (best < 0) return -1;
        score = if (score < 0) best else @min(score, best);
    }
    return score;
}

fn parseScopeValue(allocator: Allocator, value: std.json.Value) !?[]const []const u8 {
    switch (value) {
        .string => |scope| {
            var parts = std.array_list.Managed([]const u8).init(allocator);
            var iterator = std.mem.splitScalar(u8, scope, ',');
            while (iterator.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len > 0) try parts.append(try allocator.dupe(u8, trimmed));
            }
            return try parts.toOwnedSlice();
        },
        .array => |items| {
            var parts = std.array_list.Managed([]const u8).init(allocator);
            for (items.items) |item| {
                if (item == .string) try parts.append(try allocator.dupe(u8, item.string));
            }
            return try parts.toOwnedSlice();
        },
        else => return null,
    }
}

fn parseTokenColor(allocator: Allocator, object: std.json.ObjectMap) !?TokenColor {
    const settings_value = object.get("settings") orelse return null;
    const settings_object = switch (settings_value) {
        .object => |settings| settings,
        else => return null,
    };
    var rule = TokenColor{ .settings = .{} };
    if (settings_object.get("foreground")) |foreground| {
        if (foreground == .string) rule.settings.foreground = try allocator.dupe(u8, foreground.string);
    }
    if (settings_object.get("background")) |background| {
        if (background == .string) rule.settings.background = try allocator.dupe(u8, background.string);
    }
    if (settings_object.get("fontStyle")) |font_style| {
        if (font_style == .string) rule.settings.font_style = try allocator.dupe(u8, font_style.string);
    }
    if (object.get("scope")) |scope| rule.scope = try parseScopeValue(allocator, scope);
    return rule;
}

fn formatHex(color: Color, allocator: Allocator) ![]u8 {
    const digits = "0123456789ABCDEF";
    const result = try allocator.alloc(u8, 7);
    result[0] = '#';
    result[1] = digits[color.r >> 4];
    result[2] = digits[color.r & 0xF];
    result[3] = digits[color.g >> 4];
    result[4] = digits[color.g & 0xF];
    result[5] = digits[color.b >> 4];
    result[6] = digits[color.b & 0xF];
    return result;
}

fn prefixedId(allocator: Allocator, id: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, id.len + 2);
    result[0] = '_';
    result[1] = '_';
    @memcpy(result[2..], id);
    return result;
}

fn themeTypeFromId(id: []const u8) ColorScheme {
    if (std.mem.indexOf(u8, id, "hc-black") != null) return .HIGH_CONTRAST_DARK;
    if (std.mem.indexOf(u8, id, "hc-light") != null) return .HIGH_CONTRAST_LIGHT;
    if (std.mem.indexOf(u8, id, "light") != null) return .LIGHT;
    return .DARK;
}

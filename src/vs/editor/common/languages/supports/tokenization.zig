// Port of `src/vs/editor/common/languages/supports/tokenization.ts`.
//
// Divergences from the TypeScript module:
//
//  * `FontStyle` is a packed struct in this port, so "not set" is modelled as
//    `?FontStyle` instead of the `FontStyle.NotSet` sentinel.
//  * `TokenMetadata` is a packed struct here (there is no `MetadataConsts`
//    bit-twiddling module), so rules build a `TokenMetadata` directly instead
//    of an integer mask.
//  * `IFontTokenOptions` lives in `platform/theme/common/themeService.ts`
//    upstream, which is not ported yet; it is declared here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const color_module = @import("../../../../base/common/color.zig");
const Color = color_module.Color;

const encoded_token_attributes = @import("../../encodedTokenAttributes.zig");
const ColorId = encoded_token_attributes.ColorId;
const FontStyle = encoded_token_attributes.FontStyle;
const StandardTokenType = encoded_token_attributes.StandardTokenType;
const TokenMetadata = encoded_token_attributes.TokenMetadata;

pub const ITokenThemeRule = struct {
    token: []const u8,
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    /// A space separated list of `italic`, `bold`, `underline` and
    /// `strikethrough`.
    fontStyle: ?[]const u8 = null,
};

pub const ParsedTokenThemeRule = struct {
    token: []const u8,
    index: usize,
    /// `null` means "not set", i.e. the upstream `FontStyle.NotSet`.
    fontStyle: ?FontStyle,
    foreground: ?[]const u8,
    background: ?[]const u8,

    pub fn init(
        token: []const u8,
        index: usize,
        font_style: ?FontStyle,
        foreground: ?[]const u8,
        background: ?[]const u8,
    ) ParsedTokenThemeRule {
        return .{
            .token = token,
            .index = index,
            .fontStyle = font_style,
            .foreground = foreground,
            .background = background,
        };
    }
};

/// Parse a raw theme into rules.
pub fn parseTokenTheme(allocator: Allocator, source: []const ITokenThemeRule) !ArrayList(ParsedTokenThemeRule) {
    var result = ArrayList(ParsedTokenThemeRule).init(allocator);
    errdefer result.deinit();

    for (source, 0..) |entry, i| {
        var font_style: ?FontStyle = null;
        if (entry.fontStyle) |font_style_string| {
            var style = FontStyle.None;
            var segments = std.mem.splitScalar(u8, font_style_string, ' ');
            while (segments.next()) |segment| {
                if (std.mem.eql(u8, segment, "italic")) {
                    style.italic = true;
                } else if (std.mem.eql(u8, segment, "bold")) {
                    style.bold = true;
                } else if (std.mem.eql(u8, segment, "underline")) {
                    style.underline = true;
                } else if (std.mem.eql(u8, segment, "strikethrough")) {
                    style.strikethrough = true;
                }
            }
            font_style = style;
        }

        try result.append(ParsedTokenThemeRule.init(
            entry.token,
            i,
            font_style,
            entry.foreground,
            entry.background,
        ));
    }

    return result;
}

fn lessThanParsedRule(_: void, a: ParsedTokenThemeRule, b: ParsedTokenThemeRule) bool {
    const comparison = strcmp(a.token, b.token);
    if (comparison != 0) {
        return comparison < 0;
    }
    return a.index < b.index;
}

/// Resolve rules (i.e. inheritance).
fn resolveParsedTokenThemeRules(
    allocator: Allocator,
    parsed_theme_rules: []ParsedTokenThemeRule,
    custom_token_colors: []const []const u8,
) !TokenTheme {
    // Sort rules lexicographically, and then by index if necessary
    std.mem.sort(ParsedTokenThemeRule, parsed_theme_rules, {}, lessThanParsedRule);

    // Determine defaults
    var default_font_style: ?FontStyle = null;
    var default_foreground: []const u8 = "000000";
    var default_background: []const u8 = "ffffff";
    var first_rule_index: usize = 0;
    while (first_rule_index < parsed_theme_rules.len and parsed_theme_rules[first_rule_index].token.len == 0) {
        const incoming_defaults = parsed_theme_rules[first_rule_index];
        if (incoming_defaults.fontStyle) |font_style| {
            default_font_style = font_style;
        }
        if (incoming_defaults.foreground) |foreground| {
            default_foreground = foreground;
        }
        if (incoming_defaults.background) |background| {
            default_background = background;
        }
        first_rule_index += 1;
    }

    var color_map = ColorMap.init(allocator);
    errdefer color_map.deinit();

    // start with token colors from custom token themes
    for (custom_token_colors) |color| {
        _ = try color_map.getId(color);
    }

    const foreground_color_id = try color_map.getId(default_foreground);
    const background_color_id = try color_map.getId(default_background);

    const defaults = try ThemeTrieElementRule.init(
        default_font_style,
        foreground_color_id,
        background_color_id,
    );
    var root = ThemeTrieElement.init(allocator, defaults);
    errdefer root.deinit();

    for (parsed_theme_rules[first_rule_index..]) |rule| {
        try root.insert(
            rule.token,
            rule.fontStyle,
            try color_map.getId(rule.foreground),
            try color_map.getId(rule.background),
        );
    }

    return .{
        .allocator = allocator,
        ._colorMap = color_map,
        ._root = root,
        ._cache = std.StringHashMap(IntermediateMetadata).init(allocator),
    };
}

fn isHexDigit(character: u8) bool {
    return switch (character) {
        '0'...'9', 'A'...'F', 'a'...'f' => true,
        else => false,
    };
}

/// Maps `#RRGGBB` colors (without the `#`) to their `ColorId`.
pub const ColorMap = struct {
    allocator: Allocator,
    _lastColorId: u9,
    _id2color: ArrayList(Color),
    _color2id: std.StringHashMap(u9),

    pub fn init(allocator: Allocator) ColorMap {
        var id2color = ArrayList(Color).init(allocator);
        // `ColorId.None` occupies index 0; upstream leaves it undefined.
        id2color.append(Color.black) catch unreachable;
        return .{
            .allocator = allocator,
            ._lastColorId = 0,
            ._id2color = id2color,
            ._color2id = std.StringHashMap(u9).init(allocator),
        };
    }

    pub fn deinit(self: *ColorMap) void {
        var iterator = self._color2id.keyIterator();
        while (iterator.next()) |key| {
            self.allocator.free(key.*);
        }
        self._color2id.deinit();
        self._id2color.deinit();
    }

    /// `null` maps to `ColorId.None` (0). Any other value must be a
    /// `#RRGGBB`/`RRGGBB` string.
    pub fn getId(self: *ColorMap, color: ?[]const u8) !u9 {
        const raw_color = color orelse return ColorId.None;

        const digits = if (raw_color.len > 0 and raw_color[0] == '#') raw_color[1..] else raw_color;
        const rgb = digits[0..@min(digits.len, 6)];
        if (rgb.len != 6) {
            return error.IllegalValueForTokenColor;
        }
        for (rgb) |character| {
            if (!isHexDigit(character)) {
                return error.IllegalValueForTokenColor;
            }
        }
        if (digits.len != 6 and digits.len != 8) {
            return error.IllegalValueForTokenColor;
        }

        // Work on the uppercase form, like `match[1].toUpperCase()` upstream.
        var uppercase: [6]u8 = undefined;
        for (rgb, 0..) |character, i| {
            uppercase[i] = std.ascii.toUpper(character);
        }

        if (self._color2id.get(&uppercase)) |value| {
            return value;
        }

        self._lastColorId += 1;
        const stored = try self.allocator.dupe(u8, &uppercase);
        errdefer self.allocator.free(stored);

        try self._color2id.put(stored, self._lastColorId);
        errdefer _ = self._color2id.remove(&uppercase);

        try self._id2color.append(try Color.fromHex(&uppercase));
        return self._lastColorId;
    }

    /// The colors, indexed by `ColorId`. Index 0 is unused.
    pub fn getColorMap(self: *const ColorMap) []const Color {
        return self._id2color.items;
    }

    pub fn size(self: *const ColorMap) usize {
        return self._id2color.items.len;
    }
};

/// The subset of `TokenMetadata` that a theme rule participates in: the theme
/// trie caches this part and adds the token type and language id on `match`.
const IntermediateMetadata = u32;

pub const TokenTheme = struct {
    allocator: Allocator,
    _colorMap: ColorMap,
    _root: ThemeTrieElement,
    /// The cache contains the metadata without the language bits set.
    _cache: std.StringHashMap(IntermediateMetadata),

    pub fn createFromRawTokenTheme(
        allocator: Allocator,
        source: []const ITokenThemeRule,
        custom_token_colors: []const []const u8,
    ) !TokenTheme {
        var parsed = try parseTokenTheme(allocator, source);
        defer parsed.deinit();
        return createFromParsedTokenTheme(allocator, parsed.items, custom_token_colors);
    }

    pub fn createFromParsedTokenTheme(
        allocator: Allocator,
        source: []ParsedTokenThemeRule,
        custom_token_colors: []const []const u8,
    ) !TokenTheme {
        return resolveParsedTokenThemeRules(allocator, source, custom_token_colors);
    }

    pub fn deinit(self: *TokenTheme) void {
        var iterator = self._cache.keyIterator();
        while (iterator.next()) |key| {
            self.allocator.free(key.*);
        }
        self._cache.deinit();
        self._root.deinit();
        self._colorMap.deinit();
    }

    pub fn getColorMap(self: *const TokenTheme) []const Color {
        return self._colorMap.getColorMap();
    }

    /// used for testing purposes
    pub fn getThemeTrieElement(self: *const TokenTheme) ExternalThemeTrieElement {
        return self._root.toExternalThemeTrieElement(self.allocator) catch unreachable;
    }

    pub fn _match(self: *const TokenTheme, token: []const u8) *const ThemeTrieElementRule {
        return self._root.match(token);
    }

    pub fn match(self: *TokenTheme, language_id: u8, token: []const u8) !TokenMetadata {
        const cached = if (self._cache.get(token)) |value| value else blk: {
            const rule = self._match(token);
            const standard_token = toStandardTokenType(token);
            const value: IntermediateMetadata = @bitCast(TokenMetadata{
                .languageId = 0,
                .tokenType = standard_token,
                .balancedBrackets = false,
                .fontStyle = rule.getFontStyle(),
                .foreground = rule.getForeground(),
                .background = @intCast(rule.getBackground()),
            });
            const key = try self.allocator.dupe(u8, token);
            errdefer self.allocator.free(key);
            try self._cache.put(key, value);
            break :blk value;
        };
        var metadata: TokenMetadata = @bitCast(cached);
        metadata.languageId = language_id;
        return metadata;
    }
};

/// The process-wide token theme used by the editor's tokenizer. The theme
/// service owns the theme and replaces this pointer on theme changes.
var active_token_theme: ?*TokenTheme = null;

pub fn setActiveTokenTheme(theme: ?*TokenTheme) void {
    active_token_theme = theme;
}

pub fn getActiveTokenTheme() ?*TokenTheme {
    return active_token_theme;
}

pub fn toStandardTokenType(token_type: []const u8) StandardTokenType {
    // Port of `/\b(comment|string|regex|regexp)\b/`.
    var index: usize = 0;
    while (index < token_type.len) {
        if (isWordBoundaryBefore(token_type, index)) {
            for ([_][]const u8{ "comment", "string", "regex", "regexp" }) |candidate| {
                if (std.mem.startsWith(u8, token_type[index..], candidate) and
                    isWordBoundaryBefore(token_type, index + candidate.len))
                {
                    if (std.mem.eql(u8, candidate, "comment")) return .Comment;
                    if (std.mem.eql(u8, candidate, "string")) return .String;
                    return .RegEx;
                }
            }
        }
        index += 1;
    }
    return .Other;
}

/// True when a `\b` anchor matches right before `index`, i.e. either the
/// string starts here or the previous character is not a word character.
fn isWordBoundaryBefore(text: []const u8, index: usize) bool {
    if (index == 0) {
        return true;
    }
    if (index >= text.len) {
        // End of the string: a boundary unless the last character was not a
        // word character, which cannot match the trailing `\b` either.
        return true;
    }
    return !isWordCharacter(text[index - 1]) or !isWordCharacter(text[index]);
}

fn isWordCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_';
}

pub fn strcmp(a: []const u8, b: []const u8) isize {
    if (std.mem.lessThan(u8, a, b)) {
        return -1;
    }
    if (std.mem.lessThan(u8, b, a)) {
        return 1;
    }
    return 0;
}

pub const ThemeTrieElementRule = struct {
    _fontStyle: ?FontStyle,
    _foreground: u9,
    _background: u9,

    pub fn init(font_style: ?FontStyle, foreground: u9, background: u9) !ThemeTrieElementRule {
        return .{
            ._fontStyle = font_style,
            ._foreground = foreground,
            ._background = background,
        };
    }

    pub fn getFontStyle(self: *const ThemeTrieElementRule) FontStyle {
        return self._fontStyle orelse FontStyle.None;
    }

    pub fn getForeground(self: *const ThemeTrieElementRule) u9 {
        return self._foreground;
    }

    pub fn getBackground(self: *const ThemeTrieElementRule) u9 {
        return self._background;
    }

    pub fn clone(self: *const ThemeTrieElementRule) ThemeTrieElementRule {
        return .{
            ._fontStyle = self._fontStyle,
            ._foreground = self._foreground,
            ._background = self._background,
        };
    }

    pub fn acceptOverwrite(self: *ThemeTrieElementRule, font_style: ?FontStyle, foreground: u9, background: u9) void {
        if (font_style) |style| {
            self._fontStyle = style;
        }
        if (foreground != ColorId.None) {
            self._foreground = foreground;
        }
        if (background != ColorId.None) {
            self._background = background;
        }
    }
};

pub const ExternalThemeTrieElement = struct {
    mainRule: ThemeTrieElementRule,
    children: std.StringHashMap(ExternalThemeTrieElement),

    pub fn deinit(self: *ExternalThemeTrieElement, allocator: Allocator) void {
        var iterator = self.children.keyIterator();
        while (iterator.next()) |key| {
            allocator.free(key.*);
        }
        var value_iterator = self.children.valueIterator();
        while (value_iterator.next()) |value| {
            value.deinit(allocator);
        }
        self.children.deinit();
    }
};

pub const ThemeTrieElement = struct {
    allocator: Allocator,
    _mainRule: ThemeTrieElementRule,
    _children: std.StringHashMap(*ThemeTrieElement),

    pub fn init(allocator: Allocator, main_rule: ThemeTrieElementRule) ThemeTrieElement {
        return .{
            .allocator = allocator,
            ._mainRule = main_rule,
            ._children = std.StringHashMap(*ThemeTrieElement).init(allocator),
        };
    }

    pub fn deinit(self: *ThemeTrieElement) void {
        var iterator = self._children.keyIterator();
        while (iterator.next()) |key| {
            self.allocator.free(key.*);
        }
        var value_iterator = self._children.valueIterator();
        while (value_iterator.next()) |value| {
            value.*.deinit();
            self.allocator.destroy(value.*);
        }
        self._children.deinit();
    }

    /// used for testing purposes
    pub fn toExternalThemeTrieElement(self: *const ThemeTrieElement, allocator: Allocator) !ExternalThemeTrieElement {
        var children = std.StringHashMap(ExternalThemeTrieElement).init(allocator);
        errdefer children.deinit();

        var iterator = self._children.iterator();
        while (iterator.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            try children.put(key, try entry.value_ptr.*.toExternalThemeTrieElement(allocator));
        }

        return .{ .mainRule = self._mainRule, .children = children };
    }

    pub fn match(self: *const ThemeTrieElement, token: []const u8) *const ThemeTrieElementRule {
        if (token.len == 0) {
            return &self._mainRule;
        }

        const split = splitToken(token);
        if (self._children.get(split.head)) |child| {
            return child.match(split.tail);
        }

        return &self._mainRule;
    }

    pub fn insert(
        self: *ThemeTrieElement,
        token: []const u8,
        font_style: ?FontStyle,
        foreground: u9,
        background: u9,
    ) !void {
        if (token.len == 0) {
            // Merge into the main rule
            self._mainRule.acceptOverwrite(font_style, foreground, background);
            return;
        }

        const split = splitToken(token);
        var child = self._children.get(split.head);
        if (child == null) {
            const element = try self.allocator.create(ThemeTrieElement);
            errdefer self.allocator.destroy(element);
            element.* = ThemeTrieElement.init(self.allocator, self._mainRule.clone());

            const key = try self.allocator.dupe(u8, split.head);
            errdefer self.allocator.free(key);

            try self._children.put(key, element);
            child = element;
        }

        try child.?.insert(split.tail, font_style, foreground, background);
    }
};

const TokenSplit = struct {
    head: []const u8,
    tail: []const u8,
};

fn splitToken(token: []const u8) TokenSplit {
    const dot_index = std.mem.indexOfScalar(u8, token, '.') orelse
        return .{ .head = token, .tail = "" };
    return .{
        .head = token[0..dot_index],
        .tail = token[dot_index + 1 ..],
    };
}

pub fn generateTokensCSSForColorMap(allocator: Allocator, color_map: []const Color) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 1;
    while (i < color_map.len) : (i += 1) {
        const css_color = try color_map[i].toCssString(allocator);
        defer allocator.free(css_color);
        const rule = try std.fmt.allocPrint(allocator, ".mtk{d} {{ color: {s}; }}\n", .{ i, css_color });
        defer allocator.free(rule);
        try result.appendSlice(rule);
    }
    try result.appendSlice(".mtki { font-style: italic; }\n");
    try result.appendSlice(".mtkb { font-weight: bold; }\n");
    try result.appendSlice(".mtku { text-decoration: underline; text-underline-position: under; }\n");
    try result.appendSlice(".mtks { text-decoration: line-through; }\n");
    try result.appendSlice(".mtks.mtku { text-decoration: underline line-through; text-underline-position: under; }");
    return result.toOwnedSlice();
}

/// Declared in `platform/theme/common/themeService.ts` upstream.
pub const IFontTokenOptions = struct {
    fontFamily: ?[]const u8 = null,
    fontSizeMultiplier: ?f32 = null,
};

pub fn generateTokensCSSForFontMap(allocator: Allocator, font_map: []const IFontTokenOptions) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var fonts = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = fonts.keyIterator();
        while (iterator.next()) |key| {
            allocator.free(key.*);
        }
        fonts.deinit();
    }

    var i: usize = 1;
    while (i < font_map.len) : (i += 1) {
        const font = font_map[i];
        if (font.fontFamily == null and font.fontSizeMultiplier == null) {
            continue;
        }
        const class_name = try classNameForFontTokenDecorations(
            allocator,
            font.fontFamily orelse "",
            font.fontSizeMultiplier orelse 0,
        );
        defer allocator.free(class_name);

        if (fonts.contains(class_name)) {
            continue;
        }
        const key = try allocator.dupe(u8, class_name);
        errdefer allocator.free(key);
        try fonts.put(key, {});

        const prefix = try std.fmt.allocPrint(allocator, ".{s} {{", .{class_name});
        defer allocator.free(prefix);
        try result.appendSlice(prefix);
        if (font.fontFamily) |font_family| {
            const font_family_rule = try std.fmt.allocPrint(allocator, "font-family: {s};", .{font_family});
            defer allocator.free(font_family_rule);
            try result.appendSlice(font_family_rule);
        }
        if (font.fontSizeMultiplier) |font_size_multiplier| {
            const font_size_rule = try std.fmt.allocPrint(allocator, "font-size: calc(var(--editor-font-size)*{});", .{font_size_multiplier});
            defer allocator.free(font_size_rule);
            try result.appendSlice(font_size_rule);
        }
        try result.appendSlice("}\n");
    }

    return result.toOwnedSlice();
}

pub fn classNameForFontTokenDecorations(allocator: Allocator, font_family: []const u8, font_size: f32) ![]u8 {
    const safe_font_family = try sanitizeFontFamilyForClassName(allocator, font_family);
    defer allocator.free(safe_font_family);

    const raw = try std.fmt.allocPrint(allocator, "font-decoration-{s}-{}", .{ safe_font_family, font_size });
    defer allocator.free(raw);
    return cleanClassName(allocator, raw);
}

/// Replaces every character outside `[a-z0-9-_]` with a space, like the
/// private `cleanClassName` helper of `tokenization.ts`.
fn cleanClassName(allocator: Allocator, class_name: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, class_name);
    for (result) |*character| {
        const is_valid = switch (character.*) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => true,
            else => false,
        };
        if (!is_valid) {
            character.* = ' ';
        }
    }
    return result;
}

fn sanitizeFontFamilyForClassName(allocator: Allocator, font_family: []const u8) ![]u8 {
    const normalized = try std.ascii.allocLowerString(allocator, std.mem.trim(u8, font_family, " \t\r\n"));
    defer allocator.free(normalized);
    if (normalized.len == 0) {
        return allocator.dupe(u8, "default");
    }
    return cleanClassName(allocator, normalized);
}

test "parseTokenTheme: parses font styles and colors" {
    const allocator = std.testing.allocator;

    var parsed = try parseTokenTheme(allocator, &.{
        .{ .token = "", .foreground = "111111", .background = "ffffff" },
        .{ .token = "keyword", .fontStyle = "italic bold", .foreground = "0000FF" },
        .{ .token = "string", .fontStyle = "underline" },
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    try std.testing.expectEqual(@as(?FontStyle, null), parsed.items[0].fontStyle);
    try std.testing.expect(parsed.items[1].fontStyle.?.italic);
    try std.testing.expect(parsed.items[1].fontStyle.?.bold);
    try std.testing.expect(!parsed.items[1].fontStyle.?.underline);
    try std.testing.expect(parsed.items[2].fontStyle.?.underline);
}

test "ColorMap: assigns ids and deduplicates" {
    const allocator = std.testing.allocator;

    var color_map = ColorMap.init(allocator);
    defer color_map.deinit();

    try std.testing.expectEqual(ColorId.None, try color_map.getId(null));
    const first = try color_map.getId("FF0000");
    const second = try color_map.getId("#ff0000");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u9, 1), first);
    try std.testing.expectEqual(@as(u9, 2), try color_map.getId("#00FF00"));
    try std.testing.expectEqual(@as(u8, 0xFF), color_map.getColorMap()[1].r);
    try std.testing.expectError(error.IllegalValueForTokenColor, color_map.getId("nope"));
}

test "toStandardTokenType: matches the upstream regex" {
    try std.testing.expectEqual(StandardTokenType.Other, toStandardTokenType("keyword"));
    // The regex matches `string` before the `.`, so the token is a string.
    try std.testing.expectEqual(StandardTokenType.String, toStandardTokenType("string.regex"));
    try std.testing.expectEqual(StandardTokenType.Comment, toStandardTokenType("comment"));
    try std.testing.expectEqual(StandardTokenType.Comment, toStandardTokenType("comment.double-slash"));
    try std.testing.expectEqual(StandardTokenType.Comment, toStandardTokenType("my.comment"));
    try std.testing.expectEqual(StandardTokenType.String, toStandardTokenType("string"));
    try std.testing.expectEqual(StandardTokenType.RegEx, toStandardTokenType("regex"));
    try std.testing.expectEqual(StandardTokenType.RegEx, toStandardTokenType("regexp"));
    // `comments` does not match the `comment` alternative because of the word
    // boundary.
    try std.testing.expectEqual(StandardTokenType.Other, toStandardTokenType("comments"));
}

test "TokenTheme: resolves defaults and inherits rules" {
    const allocator = std.testing.allocator;

    var theme = try TokenTheme.createFromRawTokenTheme(allocator, &.{
        .{ .token = "", .foreground = "111111", .background = "222222" },
        .{ .token = "keyword", .foreground = "333333", .fontStyle = "bold" },
        .{ .token = "keyword.control", .fontStyle = "italic" },
    }, &.{});
    defer theme.deinit();

    const color_map = theme.getColorMap();
    try std.testing.expectEqual(@as(usize, 4), color_map.len); // index 0 is unused

    const default_metadata = try theme.match(1, "");
    try std.testing.expectEqual(@as(u8, 1), default_metadata.languageId);
    const default_foreground = theme._match("").getForeground();
    try std.testing.expectEqual(default_foreground, default_metadata.foreground);

    // `keyword.control` has no foreground of its own, so it inherits from
    // `keyword` (the trie clones the parent rule when a child is created).
    const control_metadata = try theme.match(0, "keyword.control");
    const keyword_metadata = try theme.match(0, "keyword");
    try std.testing.expectEqual(keyword_metadata.foreground, control_metadata.foreground);
    // `acceptOverwrite` replaces the whole font style, so the `italic` of
    // `keyword.control` wins over the `bold` of `keyword`.
    try std.testing.expect(control_metadata.fontStyle.italic);
    try std.testing.expect(!control_metadata.fontStyle.bold);
    try std.testing.expect(keyword_metadata.fontStyle.bold);
}

test "TokenTheme: token type is part of the metadata" {
    const allocator = std.testing.allocator;

    var theme = try TokenTheme.createFromRawTokenTheme(allocator, &.{
        .{ .token = "", .foreground = "111111" },
    }, &.{});
    defer theme.deinit();

    const comment_metadata = try theme.match(0, "comment");
    try std.testing.expectEqual(StandardTokenType.Comment, comment_metadata.tokenType);

    const other_metadata = try theme.match(0, "variable");
    try std.testing.expectEqual(StandardTokenType.Other, other_metadata.tokenType);
}

test "generateTokensCSSForColorMap: one rule per color" {
    const allocator = std.testing.allocator;

    const color_map = [_]Color{
        Color.black,
        try Color.fromHex("#FF0000"),
        try Color.fromHex("#00ff00"),
    };
    const css = try generateTokensCSSForColorMap(allocator, &color_map);
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".mtk1 { color: #FF0000; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".mtk2 { color: #00FF00; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".mtki { font-style: italic; }") != null);
    try std.testing.expect(std.mem.endsWith(u8, css, ".mtks.mtku { text-decoration: underline line-through; text-underline-position: under; }"));
}

test "classNameForFontTokenDecorations: sanitizes the font family" {
    const allocator = std.testing.allocator;

    const class_name = try classNameForFontTokenDecorations(allocator, "Fira Code", 1.5);
    defer allocator.free(class_name);
    // Characters outside `[a-z0-9-_]` become spaces, like upstream. That also
    // hits the decimal point of the size multiplier.
    try std.testing.expectEqualStrings("font-decoration-fira code-1 5", class_name);

    const default_class_name = try classNameForFontTokenDecorations(allocator, "", 0);
    defer allocator.free(default_class_name);
    try std.testing.expectEqualStrings("font-decoration-default-0", default_class_name);
}

test "generateTokensCSSForFontMap: skips empty fonts and deduplicates" {
    const allocator = std.testing.allocator;

    const font_map = [_]IFontTokenOptions{
        .{},
        .{ .fontFamily = "Fira Code" },
        .{ .fontFamily = "Fira Code" },
        .{ .fontSizeMultiplier = 2 },
        .{},
    };
    const css = try generateTokensCSSForFontMap(allocator, &font_map);
    defer allocator.free(css);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, css, "font-decoration-fira code-0"));
    try std.testing.expect(std.mem.indexOf(u8, css, "font-size: calc(var(--editor-font-size)*2);") != null);
}

// Port of `../vscode-textmate/src/tests/themes.test.ts` unit tests.
const std = @import("std");
const theme = @import("../theme.zig");

const MatchInfo = struct {
    font_style: []const u8,
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
};

fn matchInfo(allocator: std.mem.Allocator, value: *theme.Theme, path: []const []const u8) !?MatchInfo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scope_path = (try theme.ScopeStack.from(arena.allocator(), path)).?;
    const result = (try value.match(scope_path)) orelse return null;
    return .{
        .font_style = try theme.fontStyleToString(allocator, result.font_style),
        .foreground = if (result.foreground_id != 0) value.getColorMap()[result.foreground_id] else null,
        .background = if (result.background_id != 0) value.getColorMap()[result.background_id] else null,
    };
}

fn expectMatch(allocator: std.mem.Allocator, value: *theme.Theme, path: []const []const u8, expected: MatchInfo) !void {
    const actual = (try matchInfo(allocator, value, path)) orelse {
        std.debug.print("no match for path\n", .{});
        return error.TestUnexpectedResult;
    };
    defer allocator.free(actual.font_style);
    try std.testing.expectEqualStrings(expected.font_style, actual.font_style);
    try expectOptionalString(expected.foreground, actual.foreground);
    try expectOptionalString(expected.background, actual.background);
}

fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null and actual == null) return;
    if (expected == null or actual == null) return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected.?, actual.?);
}

fn createTheme(allocator: std.mem.Allocator, settings: []const theme.RawThemeSetting) !*theme.Theme {
    var raw = theme.RawTheme{ .settings = @constCast(settings) };
    return theme.Theme.createFromRawTheme(allocator, &raw, null);
}

test "Theme matching gives higher priority to deeper matches" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000", .background = "#200000" } },
        .{ .scope = .{ .single = "punctuation.definition.string.begin.html" }, .settings = .{ .foreground = "#300000" } },
        .{ .scope = .{ .single = "meta.tag punctuation.definition.string" }, .settings = .{ .foreground = "#400000" } },
    };
    const value = try createTheme(std.testing.allocator, &settings);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{"punctuation.definition.string.begin.html"}, .{
        .font_style = "not set",
        .foreground = "#300000",
    });
}

test "Theme matching gives higher priority to parent matches 1" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000", .background = "#200000" } },
        .{ .scope = .{ .single = "c a" }, .settings = .{ .foreground = "#300000" } },
        .{ .scope = .{ .single = "d a.b" }, .settings = .{ .foreground = "#400000" } },
        .{ .scope = .{ .single = "a" }, .settings = .{ .foreground = "#500000" } },
    };
    const value = try createTheme(std.testing.allocator, &settings);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{ "d", "a.b" }, .{
        .font_style = "not set",
        .foreground = "#400000",
    });
}

test "Theme matching gives higher priority to parent matches 2" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000", .background = "#200000" } },
        .{ .scope = .{ .single = "meta.tag entity" }, .settings = .{ .foreground = "#300000" } },
        .{ .scope = .{ .single = "meta.selector.css entity.name.tag" }, .settings = .{ .foreground = "#400000" } },
        .{ .scope = .{ .single = "entity" }, .settings = .{ .foreground = "#500000" } },
    };
    const value = try createTheme(std.testing.allocator, &settings);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{
        "text.html.cshtml",
        "meta.tag.structure.any.html",
        "entity.name.tag.structure.any.html",
    }, .{
        .font_style = "not set",
        .foreground = "#300000",
    });
}

test "Theme matching can match" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#F8F8F2", .background = "#272822" } },
        .{ .scope = .{ .single = "source, something" }, .settings = .{ .background = "#100000" } },
        .{ .scope = .{ .list = &.{ "bar", "baz" } }, .settings = .{ .background = "#200000" } },
        .{ .scope = .{ .single = "source.css selector bar" }, .settings = .{ .font_style = "bold" } },
        .{ .scope = .{ .single = "constant" }, .settings = .{ .font_style = "italic", .foreground = "#300000" } },
        .{ .scope = .{ .single = "constant.numeric" }, .settings = .{ .foreground = "#400000" } },
        .{ .scope = .{ .single = "constant.numeric.hex" }, .settings = .{ .font_style = "bold" } },
        .{ .scope = .{ .single = "constant.numeric.oct" }, .settings = .{ .font_style = "bold italic underline" } },
        .{ .scope = .{ .single = "constant.numeric.dec" }, .settings = .{ .font_style = "", .foreground = "#500000" } },
        .{ .scope = .{ .single = "storage.object.bar" }, .settings = .{ .font_style = "", .foreground = "#600000" } },
    };
    const value = try createTheme(std.testing.allocator, &settings);
    defer value.deinit();
    const allocator = std.testing.allocator;

    try expectMatch(allocator, value, &.{"source"}, .{ .font_style = "not set", .background = "#100000" });
    try expectMatch(allocator, value, &.{"source.ts"}, .{ .font_style = "not set", .background = "#100000" });
    try expectMatch(allocator, value, &.{"source.tss"}, .{ .font_style = "not set", .background = "#100000" });
    try expectMatch(allocator, value, &.{"something"}, .{ .font_style = "not set", .background = "#100000" });
    try expectMatch(allocator, value, &.{"something.ts"}, .{ .font_style = "not set", .background = "#100000" });
    try expectMatch(allocator, value, &.{"something.tss"}, .{ .font_style = "not set", .background = "#100000" });
    try expectMatch(allocator, value, &.{"baz"}, .{ .font_style = "not set", .background = "#200000" });
    try expectMatch(allocator, value, &.{"baz.ts"}, .{ .font_style = "not set", .background = "#200000" });
    try expectMatch(allocator, value, &.{"baz.tss"}, .{ .font_style = "not set", .background = "#200000" });
    try expectMatch(allocator, value, &.{"constant"}, .{ .font_style = "italic", .foreground = "#300000" });
    try expectMatch(allocator, value, &.{"constant.string"}, .{ .font_style = "italic", .foreground = "#300000" });
    try expectMatch(allocator, value, &.{"constant.hex"}, .{ .font_style = "italic", .foreground = "#300000" });
    try expectMatch(allocator, value, &.{"constant.numeric"}, .{ .font_style = "italic", .foreground = "#400000" });
    try expectMatch(allocator, value, &.{"constant.numeric.baz"}, .{ .font_style = "italic", .foreground = "#400000" });
    try expectMatch(allocator, value, &.{"constant.numeric.hex"}, .{ .font_style = "bold", .foreground = "#400000" });
    try expectMatch(allocator, value, &.{"constant.numeric.hex.baz"}, .{ .font_style = "bold", .foreground = "#400000" });
    try expectMatch(allocator, value, &.{"constant.numeric.oct"}, .{ .font_style = "italic bold underline", .foreground = "#400000" });
    try expectMatch(allocator, value, &.{"constant.numeric.oct.baz"}, .{ .font_style = "italic bold underline", .foreground = "#400000" });
    try expectMatch(allocator, value, &.{"constant.numeric.dec"}, .{ .font_style = "none", .foreground = "#500000" });
    try expectMatch(allocator, value, &.{"constant.numeric.dec.baz"}, .{ .font_style = "none", .foreground = "#500000" });
    try expectMatch(allocator, value, &.{"storage.object.bar"}, .{ .font_style = "none", .foreground = "#600000" });
    try expectMatch(allocator, value, &.{"storage.object.bar.baz"}, .{ .font_style = "none", .foreground = "#600000" });
    try expectMatch(allocator, value, &.{"storage.object.bart"}, .{ .font_style = "not set" });
    try expectMatch(allocator, value, &.{"storage.object"}, .{ .font_style = "not set" });
    try expectMatch(allocator, value, &.{"storage"}, .{ .font_style = "not set" });
    try expectMatch(allocator, value, &.{""}, .{ .font_style = "not set" });
    try expectMatch(allocator, value, &.{"bazz"}, .{ .font_style = "not set" });
    try expectMatch(allocator, value, &.{"asdfg"}, .{ .font_style = "not set" });
    try expectMatch(allocator, value, &.{"bar"}, .{ .font_style = "not set", .background = "#200000" });
    try expectMatch(allocator, value, &.{ "source.css", "selector", "bar" }, .{ .font_style = "bold", .background = "#200000" });
}

test "Theme matching Microsoft/vscode#23460" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#aec2e0", .background = "#14191f" } },
        .{ .name = "JSON String", .scope = .{ .single = "meta.structure.dictionary.json string.quoted.double.json" }, .settings = .{ .foreground = "#FF410D" } },
        .{ .scope = .{ .single = "meta.structure.dictionary.json string.quoted.double.json" }, .settings = .{ .foreground = "#ffffff" } },
        .{ .scope = .{ .single = "meta.structure.dictionary.value.json string.quoted.double.json" }, .settings = .{ .foreground = "#FF410D" } },
    };
    const value = try createTheme(std.testing.allocator, &settings);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{
        "source.json",
        "meta.structure.dictionary.json",
        "meta.structure.dictionary.value.json",
        "string.quoted.double.json",
    }, .{
        .font_style = "not set",
        .foreground = "#FF410D",
    });
}

test "Theme parsing can parse" {
    const allocator = std.testing.allocator;
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#F8F8F2", .background = "#272822" } },
        .{ .scope = .{ .single = "source, something" }, .settings = .{ .background = "#100000" } },
        .{ .scope = .{ .list = &.{ "bar", "baz" } }, .settings = .{ .background = "#010000" } },
        .{ .scope = .{ .single = "source.css selector bar" }, .settings = .{ .font_style = "bold" } },
        .{ .scope = .{ .single = "constant" }, .settings = .{ .font_style = "italic", .foreground = "#ff0000" } },
        .{ .scope = .{ .single = "constant.numeric" }, .settings = .{ .foreground = "#00ff00" } },
        .{ .scope = .{ .single = "constant.numeric.hex" }, .settings = .{ .font_style = "bold" } },
        .{ .scope = .{ .single = "constant.numeric.oct" }, .settings = .{ .font_style = "bold italic underline" } },
        .{ .scope = .{ .single = "constant.numeric.bin" }, .settings = .{ .font_style = "bold strikethrough" } },
        .{ .scope = .{ .single = "constant.numeric.dec" }, .settings = .{ .font_style = "", .foreground = "#0000ff" } },
        .{ .scope = .{ .single = "foo" }, .settings = .{ .font_style = "", .foreground = "#CFA" } },
    };
    var raw = theme.RawTheme{ .settings = @constCast(&settings) };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try theme.parseTheme(arena.allocator(), &raw);

    const Expected = struct {
        scope: []const u8,
        parents: ?[]const []const u8,
        index: usize,
        font_style: i32,
        foreground: ?[]const u8,
        background: ?[]const u8,
    };
    const expected = [_]Expected{
        .{ .scope = "", .parents = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#F8F8F2", .background = "#272822" },
        .{ .scope = "source", .parents = null, .index = 1, .font_style = theme.FontStyle.not_set, .foreground = null, .background = "#100000" },
        .{ .scope = "something", .parents = null, .index = 1, .font_style = theme.FontStyle.not_set, .foreground = null, .background = "#100000" },
        .{ .scope = "bar", .parents = null, .index = 2, .font_style = theme.FontStyle.not_set, .foreground = null, .background = "#010000" },
        .{ .scope = "baz", .parents = null, .index = 2, .font_style = theme.FontStyle.not_set, .foreground = null, .background = "#010000" },
        .{ .scope = "bar", .parents = &.{ "selector", "source.css" }, .index = 3, .font_style = theme.FontStyle.bold, .foreground = null, .background = null },
        .{ .scope = "constant", .parents = null, .index = 4, .font_style = theme.FontStyle.italic, .foreground = "#ff0000", .background = null },
        .{ .scope = "constant.numeric", .parents = null, .index = 5, .font_style = theme.FontStyle.not_set, .foreground = "#00ff00", .background = null },
        .{ .scope = "constant.numeric.hex", .parents = null, .index = 6, .font_style = theme.FontStyle.bold, .foreground = null, .background = null },
        .{ .scope = "constant.numeric.oct", .parents = null, .index = 7, .font_style = theme.FontStyle.bold | theme.FontStyle.italic | theme.FontStyle.underline, .foreground = null, .background = null },
        .{ .scope = "constant.numeric.bin", .parents = null, .index = 8, .font_style = theme.FontStyle.bold | theme.FontStyle.strikethrough, .foreground = null, .background = null },
        .{ .scope = "constant.numeric.dec", .parents = null, .index = 9, .font_style = theme.FontStyle.none, .foreground = "#0000ff", .background = null },
        .{ .scope = "foo", .parents = null, .index = 10, .font_style = theme.FontStyle.none, .foreground = "#CFA", .background = null },
    };
    try std.testing.expectEqual(expected.len, parsed.len);
    for (expected, parsed) |expectation, actual| {
        try std.testing.expectEqualStrings(expectation.scope, actual.scope);
        try std.testing.expectEqual(expectation.index, actual.index);
        try std.testing.expectEqual(expectation.font_style, actual.font_style);
        try expectOptionalString(expectation.foreground, actual.foreground);
        try expectOptionalString(expectation.background, actual.background);
        if (expectation.parents) |parents| {
            try std.testing.expect(actual.parent_scopes != null);
            try std.testing.expectEqual(parents.len, actual.parent_scopes.?.len);
            for (parents, actual.parent_scopes.?) |parent, actual_parent| try std.testing.expectEqualStrings(parent, actual_parent);
        } else {
            try std.testing.expect(actual.parent_scopes == null);
        }
    }
}

test "Theme resolving strcmp works" {
    var values = [_][]const u8{ "bar", "z", "zu", "a", "ab", "" };
    std.mem.sort([]const u8, &values, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return @import("../utils.zig").strcmp(a, b) < 0;
        }
    }.lessThan);
    const expected = [_][]const u8{ "", "a", "ab", "bar", "z", "zu" };
    for (expected, values) |expectation, actual| try std.testing.expectEqualStrings(expectation, actual);
}

test "Theme resolving strArrCmp works" {
    const utils = @import("../utils.zig");
    try std.testing.expectEqual(@as(i32, 0), utils.strArrCmp(null, null));
    try std.testing.expectEqual(@as(i32, -1), utils.strArrCmp(null, &.{}));
    try std.testing.expectEqual(@as(i32, -1), utils.strArrCmp(null, &.{"a"}));
    try std.testing.expectEqual(@as(i32, 1), utils.strArrCmp(&.{}, null));
    try std.testing.expectEqual(@as(i32, 1), utils.strArrCmp(&.{"a"}, null));
    try std.testing.expectEqual(@as(i32, 0), utils.strArrCmp(&.{}, &.{}));
    try std.testing.expectEqual(@as(i32, -1), utils.strArrCmp(&.{}, &.{"a"}));
    try std.testing.expectEqual(@as(i32, 1), utils.strArrCmp(&.{"a"}, &.{}));
    try std.testing.expectEqual(@as(i32, 0), utils.strArrCmp(&.{"a"}, &.{"a"}));
    try std.testing.expectEqual(@as(i32, 1), utils.strArrCmp(&.{ "a", "b" }, &.{"a"}));
    try std.testing.expectEqual(@as(i32, -1), utils.strArrCmp(&.{"a"}, &.{ "a", "b" }));
    try std.testing.expectEqual(@as(i32, 0), utils.strArrCmp(&.{ "a", "b" }, &.{ "a", "b" }));
    try std.testing.expectEqual(@as(i32, -1), utils.strArrCmp(&.{ "a", "b" }, &.{ "a", "c" }));
    try std.testing.expectEqual(@as(i32, 1), utils.strArrCmp(&.{ "a", "c" }, &.{ "a", "b" }));
}

test "Theme resolving always has defaults" {
    const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, &.{}, null);
    defer value.deinit();
    const defaults = value.getDefaults();
    try std.testing.expectEqual(theme.FontStyle.none, defaults.font_style);
    try std.testing.expectEqualStrings("#000000", value.getColorMap()[defaults.foreground_id]);
    try std.testing.expectEqualStrings("#FFFFFF", value.getColorMap()[defaults.background_id]);
}

test "Theme resolving respects incoming defaults" {
    const default_rule = theme.ParsedThemeRule{
        .scope = "",
        .parent_scopes = null,
        .index = 0,
        .font_style = theme.FontStyle.not_set,
        .foreground = null,
        .background = null,
        .font_family = "",
        .font_size = 0,
        .line_height = 0,
    };
    const cases = [_]struct {
        foreground: ?[]const u8,
        background: ?[]const u8,
        font_style: i32,
        expected_foreground: []const u8,
        expected_background: []const u8,
    }{
        .{ .foreground = null, .background = null, .font_style = theme.FontStyle.not_set, .expected_foreground = "#000000", .expected_background = "#FFFFFF" },
        .{ .foreground = null, .background = null, .font_style = theme.FontStyle.none, .expected_foreground = "#000000", .expected_background = "#FFFFFF" },
        .{ .foreground = null, .background = null, .font_style = theme.FontStyle.bold, .expected_foreground = "#000000", .expected_background = "#FFFFFF" },
        .{ .foreground = "#ff0000", .background = null, .font_style = theme.FontStyle.not_set, .expected_foreground = "#FF0000", .expected_background = "#FFFFFF" },
        .{ .foreground = null, .background = "#ff0000", .font_style = theme.FontStyle.not_set, .expected_foreground = "#000000", .expected_background = "#FF0000" },
    };
    for (cases) |case| {
        var rule = default_rule;
        rule.foreground = case.foreground;
        rule.background = case.background;
        rule.font_style = case.font_style;
        var rules = [_]theme.ParsedThemeRule{rule};
        const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, &rules, null);
        defer value.deinit();
        const defaults = value.getDefaults();
        try std.testing.expectEqualStrings(case.expected_foreground, value.getColorMap()[defaults.foreground_id]);
        try std.testing.expectEqualStrings(case.expected_background, value.getColorMap()[defaults.background_id]);
    }
}

test "Theme resolving can merge incoming defaults" {
    var rules = [_]theme.ParsedThemeRule{
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = null, .background = "#ff0000", .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#00ff00", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.bold, .foreground = null, .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
    };
    const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, &rules, null);
    defer value.deinit();
    const defaults = value.getDefaults();
    try std.testing.expectEqual(theme.FontStyle.bold, defaults.font_style);
    try std.testing.expectEqualStrings("#00FF00", value.getColorMap()[defaults.foreground_id]);
    try std.testing.expectEqualStrings("#FF0000", value.getColorMap()[defaults.background_id]);
}

test "Theme resolving defaults are inherited" {
    var rules = [_]theme.ParsedThemeRule{
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#F8F8F2", .background = "#272822", .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#ff0000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
    };
    const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, &rules, null);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{"var"}, .{ .font_style = "not set", .foreground = "#FF0000" });
}

test "Theme resolving same rules get merged" {
    var rules = [_]theme.ParsedThemeRule{
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#F8F8F2", .background = "#272822", .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var", .parent_scopes = null, .index = 1, .font_style = theme.FontStyle.bold, .foreground = null, .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#ff0000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
    };
    const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, &rules, null);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{"var"}, .{ .font_style = "bold", .foreground = "#FF0000" });
}

test "Theme resolving rules are inherited" {
    var rules = [_]theme.ParsedThemeRule{
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#F8F8F2", .background = "#272822", .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.bold, .foreground = "#ff0000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var.identifier", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#00ff00", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "constant", .parent_scopes = null, .index = 4, .font_style = theme.FontStyle.italic, .foreground = "#100000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "constant.numeric", .parent_scopes = null, .index = 5, .font_style = theme.FontStyle.not_set, .foreground = "#200000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "constant.numeric.hex", .parent_scopes = null, .index = 6, .font_style = theme.FontStyle.bold, .foreground = null, .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "constant.numeric.oct", .parent_scopes = null, .index = 7, .font_style = theme.FontStyle.bold | theme.FontStyle.italic | theme.FontStyle.underline, .foreground = null, .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "constant.numeric.dec", .parent_scopes = null, .index = 8, .font_style = theme.FontStyle.none, .foreground = "#300000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
    };
    const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, &rules, null);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{"var.identifier"}, .{ .font_style = "bold", .foreground = "#00FF00" });
    try expectMatch(std.testing.allocator, value, &.{"constant.numeric.hex"}, .{ .font_style = "bold", .foreground = "#200000" });
    try expectMatch(std.testing.allocator, value, &.{"constant.numeric.oct"}, .{ .font_style = "italic bold underline", .foreground = "#200000" });
    try expectMatch(std.testing.allocator, value, &.{"constant.numeric.dec"}, .{ .font_style = "none", .foreground = "#300000" });
}

test "Theme resolving rules with parent scopes" {
    var rules = [_]theme.ParsedThemeRule{
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#F8F8F2", .background = "#272822", .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.bold, .foreground = "#100000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var.identifier", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#200000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var", .parent_scopes = &.{"source.css"}, .index = 1, .font_style = theme.FontStyle.italic, .foreground = "#300000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
        .{ .scope = "var", .parent_scopes = &.{"source.css"}, .index = 2, .font_style = theme.FontStyle.underline, .foreground = null, .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
    };
    const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, &rules, null);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{ "source.css", "var" }, .{ .font_style = "underline", .foreground = "#300000" });
}

test "Theme resolving a rule with child combinator" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000" } },
        .{ .scope = .{ .single = "b a" }, .settings = .{ .foreground = "#200000" } },
        .{ .scope = .{ .single = "b > a" }, .settings = .{ .foreground = "#300000" } },
        .{ .scope = .{ .single = "c > b > a" }, .settings = .{ .foreground = "#400000" } },
        .{ .scope = .{ .single = "a" }, .settings = .{ .foreground = "#500000" } },
    };
    const value = try createTheme(std.testing.allocator, &settings);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{ "b", "a" }, .{ .font_style = "not set", .foreground = "#300000" });
    try expectMatch(std.testing.allocator, value, &.{ "b", "c", "a" }, .{ .font_style = "not set", .foreground = "#200000" });
    try expectMatch(std.testing.allocator, value, &.{ "c", "b", "a" }, .{ .font_style = "not set", .foreground = "#400000" });
    try expectMatch(std.testing.allocator, value, &.{ "c", "b", "d", "a" }, .{ .font_style = "not set", .foreground = "#200000" });
}

test "Theme resolving should give deeper scopes higher specificity (#233)" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000" } },
        .{ .scope = .{ .single = "y.z a.b" }, .settings = .{ .foreground = "#200000" } },
        .{ .scope = .{ .single = "x y a.b" }, .settings = .{ .foreground = "#300000" } },
    };
    const value = try createTheme(std.testing.allocator, &settings);
    defer value.deinit();
    try expectMatch(std.testing.allocator, value, &.{ "x", "a.b" }, .{ .font_style = "not set" });
    try expectMatch(std.testing.allocator, value, &.{ "y", "a.b" }, .{ .font_style = "not set" });
    try expectMatch(std.testing.allocator, value, &.{ "y.z", "a" }, .{ .font_style = "not set" });
    try expectMatch(std.testing.allocator, value, &.{ "x", "y", "a.b" }, .{ .font_style = "not set", .foreground = "#300000" });
    try expectMatch(std.testing.allocator, value, &.{ "x", "y.z", "a.b" }, .{ .font_style = "not set", .foreground = "#200000" });
}

test "Theme resolving issue #38: ignores rules with invalid colors" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .background = "#222222", .foreground = "#cccccc" } },
        .{ .name = "Variable", .scope = .{ .single = "variable" }, .settings = .{ .font_style = "" } },
        .{ .name = "Function argument", .scope = .{ .single = "variable.parameter" }, .settings = .{ .font_style = "italic", .foreground = "" } },
        .{ .name = "Library variable", .scope = .{ .single = "support.other.variable" }, .settings = .{ .font_style = "" } },
        .{ .name = "Function argument", .scope = .{ .single = "variable.other" }, .settings = .{ .foreground = "", .font_style = "normal" } },
        .{ .name = "Coffeescript Function argument", .scope = .{ .single = "variable.parameter.function.coffee" }, .settings = .{ .foreground = "#F9D423", .font_style = "italic" } },
    };
    var raw = theme.RawTheme{ .settings = @constCast(&settings) };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try theme.parseTheme(arena.allocator(), &raw);
    try std.testing.expectEqual(@as(usize, 6), parsed.len);
    try std.testing.expectEqualStrings("variable.parameter", parsed[2].scope);
    try std.testing.expect(parsed[2].foreground == null);
    try std.testing.expectEqualStrings("variable.other", parsed[4].scope);
    try std.testing.expect(parsed[4].foreground == null);
    try std.testing.expectEqualStrings("#F9D423", parsed[5].foreground.?);
}

test "Theme resolving issue #35: trailing comma in a tmTheme scope selector" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .background = "#25292C", .foreground = "#EFEFEF" } },
        .{ .name = "CSS at-rule keyword control", .scope = .{ .single = "meta.at-rule.return.scss,\nmeta.at-rule.return.scss punctuation.definition,\nmeta.at-rule.else.scss,\nmeta.at-rule.else.scss punctuation.definition,\nmeta.at-rule.if.scss,\nmeta.at-rule.if.scss punctuation.definition," }, .settings = .{ .foreground = "#CC7832" } },
    };
    var raw = theme.RawTheme{ .settings = @constCast(&settings) };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try theme.parseTheme(arena.allocator(), &raw);
    try std.testing.expectEqual(@as(usize, 7), parsed.len);
    try std.testing.expectEqualStrings("meta.at-rule.return.scss", parsed[1].scope);
    try std.testing.expectEqualStrings("punctuation.definition", parsed[2].scope);
    try std.testing.expectEqualStrings("meta.at-rule.return.scss", parsed[2].parent_scopes.?[0]);
}

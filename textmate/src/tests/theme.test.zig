// Port of `../vscode-textmate/src/tests/themes.test.ts` unit tests that do not
// need the on-disk theme fixtures.
const std = @import("std");
const theme = @import("../theme.zig");

fn theme_value_background(theme_value: *theme.Theme, path: []const []const u8) []const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scope_path = (theme.ScopeStack.from(arena.allocator(), path) catch unreachable).?;
    const result = (theme_value.match(scope_path) catch unreachable).?;
    return theme_value.getColorMap()[result.background_id];
}

fn matchColor(theme_value: *theme.Theme, path: []const []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scope_path = (try theme.ScopeStack.from(arena.allocator(), path)).?;
    const result = (try theme_value.match(scope_path)) orelse return null;
    return theme_value.getColorMap()[result.foreground_id];
}

test "Theme matching gives higher priority to deeper matches" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000", .background = "#200000" } },
        .{ .scope = .{ .single = "punctuation.definition.string.begin.html" }, .settings = .{ .foreground = "#300000" } },
        .{ .scope = .{ .single = "meta.tag punctuation.definition.string" }, .settings = .{ .foreground = "#400000" } },
    };
    var raw = theme.RawTheme{ .settings = @constCast(&settings) };
    const value = try theme.Theme.createFromRawTheme(std.testing.allocator, &raw, null);
    defer value.deinit();
    try std.testing.expectEqualStrings("#300000", (try matchColor(value, &.{"punctuation.definition.string.begin.html"})).?);
}

test "Theme matching gives higher priority to parent matches" {
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#100000", .background = "#200000" } },
        .{ .scope = .{ .single = "c a" }, .settings = .{ .foreground = "#300000" } },
        .{ .scope = .{ .single = "d a.b" }, .settings = .{ .foreground = "#400000" } },
        .{ .scope = .{ .single = "a" }, .settings = .{ .foreground = "#500000" } },
    };
    var raw = theme.RawTheme{ .settings = @constCast(&settings) };
    const value = try theme.Theme.createFromRawTheme(std.testing.allocator, &raw, null);
    defer value.deinit();
    try std.testing.expectEqualStrings("#400000", (try matchColor(value, &.{ "d", "a.b" })).?);
}

test "Theme matching can match simple scopes" {
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
    var raw = theme.RawTheme{ .settings = @constCast(&settings) };
    const value = try theme.Theme.createFromRawTheme(std.testing.allocator, &raw, null);
    defer value.deinit();

    try std.testing.expectEqualStrings("#100000", theme_value_background(value, &.{"source.ts"}));
    try std.testing.expectEqualStrings("#200000", theme_value_background(value, &.{"baz.ts"}));
    try std.testing.expectEqualStrings("#300000", (try matchColor(value, &.{"constant.string"})).?);
    try std.testing.expectEqualStrings("#400000", (try matchColor(value, &.{"constant.numeric.hex"})).?);
    try std.testing.expectEqualStrings("#500000", (try matchColor(value, &.{"constant.numeric.dec"})).?);
    try std.testing.expectEqualStrings("#600000", (try matchColor(value, &.{"storage.object.bar.baz"})).?);
    try std.testing.expectEqualStrings("", (try matchColor(value, &.{"storage"})).?);
}

test "Theme resolving respects incoming defaults" {
    const rules = [_]theme.ParsedThemeRule{
        .{ .scope = "", .parent_scopes = null, .index = 0, .font_style = theme.FontStyle.not_set, .foreground = "#ff0000", .background = null, .font_family = "", .font_size = 0, .line_height = 0 },
    };
    const value = try theme.Theme.createFromParsedTheme(std.testing.allocator, @constCast(&rules), null);
    defer value.deinit();
    try std.testing.expectEqualStrings("#FF0000", value.getColorMap()[value.getDefaults().foreground_id]);
    try std.testing.expectEqualStrings("#FFFFFF", value.getColorMap()[value.getDefaults().background_id]);
}

test "Theme parsing can parse" {
    const allocator = std.testing.allocator;
    const settings = [_]theme.RawThemeSetting{
        .{ .settings = .{ .foreground = "#F8F8F2", .background = "#272822" } },
        .{ .scope = .{ .single = "source, something" }, .settings = .{ .background = "#100000" } },
        .{ .scope = .{ .list = &.{ "bar", "baz" } }, .settings = .{ .background = "#010000" } },
        .{ .scope = .{ .single = "source.css selector bar" }, .settings = .{ .font_style = "bold" } },
        .{ .scope = .{ .single = "constant" }, .settings = .{ .font_style = "italic", .foreground = "#ff0000" } },
    };
    var raw = theme.RawTheme{ .settings = @constCast(&settings) };
    const parsed = try theme.parseTheme(allocator, &raw);
    defer {
        for (parsed) |rule| if (rule.parent_scopes) |parents| allocator.free(parents);
        allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(usize, 7), parsed.len);
}

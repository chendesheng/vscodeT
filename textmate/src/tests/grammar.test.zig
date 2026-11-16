// Port of `../vscode-textmate/src/tests/grammar.test.ts`
// (microsoft/vscode-textmate v9.3.2).
const std = @import("std");
const encoded = @import("../encodedTokenAttributes.zig");
const main = @import("../main.zig");
const theme = @import("../theme.zig");
const onigLib = @import("../onigLib.zig");
const parseRawGrammar = @import("../parseRawGrammar.zig");

fn noLoad(_: *anyopaque, _: []const u8) anyerror!?*@import("../rawGrammar.zig").RawGrammar {
    return null;
}

fn expectMetadata(
    metadata: u32,
    language_id: u32,
    token_type: u8,
    contains_balanced_brackets: bool,
    font_style: i32,
    foreground: u32,
    background: u32,
) !void {
    try std.testing.expectEqual(language_id, encoded.getLanguageId(metadata));
    try std.testing.expectEqual(token_type, encoded.getTokenType(metadata));
    try std.testing.expectEqual(contains_balanced_brackets, encoded.containsBalancedBrackets(metadata));
    try std.testing.expectEqual(@as(u32, @intCast(font_style)), encoded.getFontStyle(metadata));
    try std.testing.expectEqual(foreground, encoded.getForeground(metadata));
    try std.testing.expectEqual(background, encoded.getBackground(metadata));
}

test "StackElementMetadata works" {
    const value = encoded.set(0, 1, encoded.OptionalStandardTokenType.regex, false, theme.FontStyle.underline | theme.FontStyle.bold, 101, 102);
    try expectMetadata(value, 1, encoded.StandardTokenType.regex, false, theme.FontStyle.underline | theme.FontStyle.bold, 101, 102);
}

test "StackElementMetadata can overwrite fields" {
    const initial = encoded.set(0, 1, encoded.OptionalStandardTokenType.regex, false, theme.FontStyle.underline | theme.FontStyle.bold, 101, 102);
    try expectMetadata(initial, 1, encoded.StandardTokenType.regex, false, theme.FontStyle.underline | theme.FontStyle.bold, 101, 102);

    try expectMetadata(encoded.set(initial, 2, encoded.OptionalStandardTokenType.not_set, false, theme.FontStyle.not_set, 0, 0), 2, encoded.StandardTokenType.regex, false, theme.FontStyle.underline | theme.FontStyle.bold, 101, 102);
    try expectMetadata(encoded.set(initial, 0, encoded.OptionalStandardTokenType.comment, false, theme.FontStyle.not_set, 0, 0), 1, encoded.StandardTokenType.comment, false, theme.FontStyle.underline | theme.FontStyle.bold, 101, 102);
    try expectMetadata(encoded.set(initial, 0, encoded.OptionalStandardTokenType.not_set, false, theme.FontStyle.none, 0, 0), 1, encoded.StandardTokenType.regex, false, theme.FontStyle.none, 101, 102);
    try expectMetadata(encoded.set(initial, 0, encoded.OptionalStandardTokenType.not_set, false, theme.FontStyle.not_set, 5, 0), 1, encoded.StandardTokenType.regex, false, theme.FontStyle.underline | theme.FontStyle.bold, 5, 102);
    try expectMetadata(encoded.set(initial, 0, encoded.OptionalStandardTokenType.not_set, false, theme.FontStyle.not_set, 0, 7), 1, encoded.StandardTokenType.regex, false, theme.FontStyle.underline | theme.FontStyle.bold, 101, 7);
    try expectMetadata(encoded.set(initial, 0, encoded.OptionalStandardTokenType.not_set, true, theme.FontStyle.not_set, 0, 0), 1, encoded.StandardTokenType.regex, true, theme.FontStyle.underline | theme.FontStyle.bold, 101, 102);
}

test "Fonts are correctly set" {
    const allocator = std.testing.allocator;
    var raw = try parseRawGrammar.parseRawGrammar(
        allocator,
        "{\"scopeName\":\"source.test\",\"repository\":{},\"patterns\":[{\"match\":\"\\\\bbar\\\\b\",\"name\":\"bar.test\"}]}",
        "test.json",
    );
    defer raw.deinit();

    const settings = [_]theme.RawThemeSetting{
        .{ .scope = .{ .single = "bar.test" }, .settings = .{ .font_family = "monospace", .font_size = 1.2, .line_height = 3 } },
    };
    var raw_theme = theme.RawTheme{ .settings = @constCast(&settings) };

    var onig_lib = onigLib.OnigLib.init(allocator);
    const registry = try main.Registry.init(allocator, .{
        .onig_lib = onig_lib.interface(),
        .load_grammar = noLoad,
    });
    defer registry.dispose();
    try registry.setTheme(&raw_theme, null);
    const grammar = try registry.addGrammar(&raw, null, 1, &.{});

    const result = try grammar.tokenizeLine2("bar hello", null, 0);
    try std.testing.expectEqual(@as(usize, 1), result.fonts.len);
    try std.testing.expectEqual(@as(usize, 0), result.fonts[0].start_index);
    try std.testing.expectEqual(@as(usize, 3), result.fonts[0].end_index);
    try std.testing.expectEqualStrings("monospace", result.fonts[0].font_family.?);
    try std.testing.expectEqual(@as(f64, 1.2), result.fonts[0].font_size_multiplier.?);
    try std.testing.expectEqual(@as(f64, 3), result.fonts[0].line_height_multiplier.?);
}

test "Fonts are correctly set 2" {
    const allocator = std.testing.allocator;
    var raw = try parseRawGrammar.parseRawGrammar(
        allocator,
        "{\"scopeName\":\"source.ts\",\"repository\":{},\"patterns\":[{\"match\":\"g\",\"name\":\"entity.name.function.ts\"}]}",
        "test.json",
    );
    defer raw.deinit();

    const settings = [_]theme.RawThemeSetting{
        .{ .scope = .{ .single = "entity.name.function.ts" }, .settings = .{ .font_family = "Times New Roman", .font_size = 1.3, .line_height = 3 } },
    };
    var raw_theme = theme.RawTheme{ .settings = @constCast(&settings) };

    var onig_lib = onigLib.OnigLib.init(allocator);
    const registry = try main.Registry.init(allocator, .{
        .onig_lib = onig_lib.interface(),
        .load_grammar = noLoad,
    });
    defer registry.dispose();
    try registry.setTheme(&raw_theme, null);
    const grammar = try registry.addGrammar(&raw, null, 1, &.{});

    const result = try grammar.tokenizeLine2("function g() {}", null, 0);
    try std.testing.expectEqual(@as(usize, 1), result.fonts.len);
    try std.testing.expectEqual(@as(usize, 9), result.fonts[0].start_index);
    try std.testing.expectEqual(@as(usize, 10), result.fonts[0].end_index);
    try std.testing.expectEqualStrings("Times New Roman", result.fonts[0].font_family.?);
    try std.testing.expectEqual(@as(f64, 1.3), result.fonts[0].font_size_multiplier.?);
    try std.testing.expectEqual(@as(f64, 3), result.fonts[0].line_height_multiplier.?);
}

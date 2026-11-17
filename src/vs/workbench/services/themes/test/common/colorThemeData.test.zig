// Port of `src/vs/workbench/services/themes/test/common/colorThemeData.test.ts`
// (in-memory/transient/storage cases). The plist-loading case needs the
// extension resource loader + URI/tmTheme parsing, which are not ported yet.
const std = @import("std");
const Color = @import("../../../../../base/common/color.zig").Color;
const color_utils = @import("../../../../../platform/theme/common/colorUtils.zig");
const storage_mod = @import("../../../../../platform/storage/common/storage.zig");
const ColorThemeData = @import("../../common/colorThemeData.zig").ColorThemeData;
const TokenStyle = @import("../../../../../platform/theme/common/tokenClassificationRegistry.zig").TokenStyle;

const foreground = "foreground";
const editor_background = "editor.background";
const input_background = "input.background";
const input_foreground = "input.foreground";

const Fixture = struct {
    registry: color_utils.ColorRegistry,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var registry = color_utils.ColorRegistry.init(allocator);
        _ = try registry.registerColor(foreground, .{
            .dark = .{ .string = "#CCCCCC" },
            .light = .{ .string = "#616161" },
        }, null, "Overall foreground", false);
        _ = try registry.registerColor(editor_background, .{
            .dark = .{ .string = "#1E1E1E" },
            .light = .{ .string = "#FFFFFF" },
        }, null, "Editor background", false);
        _ = try registry.registerColor(input_background, .{
            .dark = .{ .string = "#3C3C3C" },
            .light = .{ .string = "#DDDDDD" },
        }, null, "Input background", false);
        _ = try registry.registerColor(input_foreground, null, .{ .string = foreground }, "Input foreground", false);
        return .{ .registry = registry };
    }

    fn deinit(self: *Fixture) void {
        self.registry.deinit();
    }
};

fn expectHex(color: ?Color, r: u8, g: u8, b: u8) !void {
    const value = color orelse return error.MissingColor;
    try std.testing.expectEqual(r, value.r);
    try std.testing.expectEqual(g, value.g);
    try std.testing.expectEqual(b, value.b);
}

test "updates programmatic colors, derived defaults and token caches" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    const theme = try ColorThemeData.createUnloadedTheme(allocator, &fixture.registry, "vs-dark", &.{
        .{ foreground, "#eeeeee" },
        .{ editor_background, "#202020" },
    });
    defer theme.deinit();

    const before_tokens = theme.getTokenColors().ptr;
    try theme.setTransientColors(&.{
        .{ foreground, "#ddccbb" },
        .{ editor_background, "#28221e" },
    });

    try expectHex(theme.getColor(foreground, false), 0xdd, 0xcc, 0xbb);
    try expectHex(theme.getColor(input_foreground, true), 0xdd, 0xcc, 0xbb);
    try std.testing.expect(theme.defines(foreground));
    try std.testing.expectEqualStrings("#28221E", theme.getTokenColors()[0].settings.background.?);
    try std.testing.expect(theme.getTokenColors().ptr != before_tokens);
}

test "clearing runtime colors restores theme and user-customized colors" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    const theme = try ColorThemeData.createUnloadedTheme(allocator, &fixture.registry, "vs-dark", &.{
        .{ editor_background, "#202020" },
    });
    defer theme.deinit();

    try theme.setCustomColors(&.{.{ input_background, "#123456" }});
    try theme.setTransientColors(&.{
        .{ input_background, "#654321" },
        .{ editor_background, "#28221e" },
    });
    try theme.setTransientColors(null);

    try expectHex(theme.getColor(editor_background, true), 0x20, 0x20, 0x20);
    try expectHex(theme.getColor(input_background, true), 0x12, 0x34, 0x56);
    try expectHex(theme.getColorCustomization(input_background), 0x12, 0x34, 0x56);
}

test "exposes untinted startup colors without changing the active theme" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    const theme = try ColorThemeData.createUnloadedTheme(allocator, &fixture.registry, "vs-dark", &.{
        .{ editor_background, "#202020" },
    });
    defer theme.deinit();

    try theme.setCustomColors(&.{.{ input_background, "#123456" }});
    try theme.setTransientColors(&.{
        .{ input_background, "#654321" },
        .{ editor_background, "#28221e" },
    });
    const base_theme = try theme.getBaseTheme();
    defer base_theme.deinit();

    try expectHex(theme.getColor(editor_background, true), 0x28, 0x22, 0x1e);
    try expectHex(base_theme.getColor(editor_background, true), 0x20, 0x20, 0x20);
    try expectHex(base_theme.getColor(input_background, true), 0x12, 0x34, 0x56);
    try std.testing.expectEqualStrings("#28221E", theme.getTokenColors()[0].settings.background.?);
    try std.testing.expectEqualStrings("#202020", base_theme.getTokenColors()[0].settings.background.?);
}

test "does not persist generated colors or affect another theme instance" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    var storage = storage_mod.InMemoryStorageService.init(allocator);
    defer storage.deinit();

    const theme = try ColorThemeData.createUnloadedTheme(allocator, &fixture.registry, "vs-dark", &.{
        .{ editor_background, "#202020" },
    });
    defer theme.deinit();

    try theme.toStorage(&storage);
    const original_storage = try allocator.dupe(u8, storage.get(ColorThemeData.STORAGE_KEY, .profile, null) orelse return error.MissingStorage);
    defer allocator.free(original_storage);

    const other_window = (try ColorThemeData.fromStorageData(allocator, &fixture.registry, &storage)).?;
    defer other_window.deinit();

    try theme.setTransientColors(&.{.{ editor_background, "#28221e" }});
    try theme.toStorage(&storage);

    const restored = (try ColorThemeData.fromStorageData(allocator, &fixture.registry, &storage)).?;
    defer restored.deinit();

    try expectHex(theme.getColor(editor_background, true), 0x28, 0x22, 0x1e);
    try expectHex(other_window.getColor(editor_background, true), 0x20, 0x20, 0x20);
    try expectHex(restored.getColor(editor_background, true), 0x20, 0x20, 0x20);
    try std.testing.expectEqualStrings(original_storage, storage.get(ColorThemeData.STORAGE_KEY, .profile, null).?);
}

test "includes the theme location when plist settings are not an array" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();

    const theme = try ColorThemeData.createUnloadedTheme(allocator, &fixture.registry, "vs-dark", &.{});
    defer theme.deinit();
    theme.location = "/themes/invalid.tmTheme";

    const Loader = struct {
        fn read(_: *anyopaque, _: []const u8) anyerror![]const u8 {
            return "<plist><dict><key>settings</key><string>invalid</string></dict></plist>";
        }
    };
    var loader_state: u8 = 0;
    const reader = @import("../../common/colorThemeData.zig").ResourceReader{
        .context = &loader_state,
        .read = Loader.read,
    };
    try std.testing.expectError(error.InvalidTheme, theme.ensureLoaded(reader));
    try std.testing.expectEqualStrings(
        "Problem parsing tmTheme file: /themes/invalid.tmTheme. 'settings' is not array.",
        theme.errorMessage().?,
    );
}

const token_theme_json =
    \\{
    \\  "type": "dark",
    \\  "editor.background": "#1E1E1E",
    \\  "tokenColors": [
    \\    { "scope": "comment", "settings": { "foreground": "#000000" } },
    \\    { "scope": "string", "settings": { "foreground": "#444444" } },
    \\    { "scope": "constant.numeric", "settings": { "foreground": "#555555" } },
    \\    { "scope": "variable", "settings": { "fontStyle": "", "foreground": "#111111" } },
    \\    { "scope": "keyword", "settings": { "foreground": "#666666" } },
    \\    { "scope": "entity.name.type, support.type", "settings": { "fontStyle": "underline", "foreground": "#333333" } },
    \\    { "scope": "entity.name.function", "settings": { "fontStyle": "", "foreground": "#333333" } }
    \\  ]
    \\}
;

const TokenFixture = struct {
    text: []const u8,
    fn read(context: *anyopaque, _: []const u8) anyerror![]const u8 {
        const self: *TokenFixture = @ptrCast(@alignCast(context));
        return self.text;
    }
};

fn expectTokenColor(theme: *ColorThemeData, type_name: []const u8, expected_hex: ?[]const u8) !void {
    const metadata = theme.getTokenStyleMetadata(type_name, &.{}, "typescript") orelse return error.TestUnexpectedResult;
    if (expected_hex == null) {
        try std.testing.expect(metadata.foreground == null);
        return;
    }
    const index = metadata.foreground orelse return error.TestUnexpectedResult;
    const map = try theme.getTokenColorMap();
    const color = map[index];
    const expected = try Color.fromHex(expected_hex.?);
    try std.testing.expectEqual(expected.r, color.r);
    try std.testing.expectEqual(expected.g, color.g);
    try std.testing.expectEqual(expected.b, color.b);
}

test "ColorThemeData: token color defaults resolve" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const theme = try ColorThemeData.createUnloadedTheme(allocator, &fixture.registry, "test-dark", &.{});
    defer theme.deinit();
    theme.location = "color-theme.json";
    var reader = TokenFixture{ .text = token_theme_json };
    try theme.ensureLoaded(.{ .context = &reader, .read = TokenFixture.read });

    try expectTokenColor(theme, "comment", "#000000");
    try expectTokenColor(theme, "string", "#444444");
    try expectTokenColor(theme, "number", "#555555");
    try expectTokenColor(theme, "keyword", "#666666");
    const type_style = theme.getTokenStyleMetadata("type", &.{}, "typescript").?;
    try std.testing.expectEqual(@as(?bool, false), type_style.bold);
    try std.testing.expectEqual(@as(?bool, true), type_style.underline);
    const variable_style = theme.getTokenStyleMetadata("variable", &.{}, "typescript").?;
    try std.testing.expectEqual(@as(?bool, false), variable_style.bold);
    try std.testing.expectEqual(@as(?bool, false), variable_style.underline);
}

test "ColorThemeData: semantic token rules merge by score" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const theme = try ColorThemeData.createLoadedEmptyTheme(allocator, &fixture.registry, "test-dark");
    defer theme.deinit();
    try theme.setCustomSemanticTokenColors(&.{
        .{ .selector = "type", .foreground = "#ff0000" },
        .{ .selector = "class", .foreground = "#0000ff", .italic = true },
        .{ .selector = "*.static", .bold = true },
        .{ .selector = "*.declaration", .italic = true },
    });

    try expectTokenColor(theme, "type", "#ff0000");
    try expectTokenColor(theme, "class", "#0000ff");
    const class_static = theme.getTokenStyleMetadata("class", &.{"static"}, "typescript").?;
    try std.testing.expectEqual(@as(?bool, true), class_static.italic);
    try std.testing.expectEqual(@as(?bool, true), class_static.bold);
}

fn assertResolvedStyle(theme: *ColorThemeData, probe: []const []const u8, expected_hex: ?[]const u8, expected_font: ?[]const u8) !void {
    const style = try theme.resolveScopes(&.{probe});
    if (expected_hex == null and expected_font == null) {
        try std.testing.expect(style == null);
        return;
    }
    const resolved = style orelse return error.TestUnexpectedResult;
    if (expected_hex) |hex| {
        const expected = try Color.fromHex(hex);
        const actual = resolved.foreground orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(expected.r, actual.r);
        try std.testing.expectEqual(expected.g, actual.g);
        try std.testing.expectEqual(expected.b, actual.b);
    } else try std.testing.expect(resolved.foreground == null);
    if (expected_font) |font| {
        const expected = TokenStyle.fromSettings(null, font, null, null, null, null);
        try std.testing.expectEqual(expected.bold, resolved.bold);
        try std.testing.expectEqual(expected.italic, resolved.italic);
        try std.testing.expectEqual(expected.underline, resolved.underline);
    }
}

test "ColorThemeData: resolveScopes matches rule scopes and specificity" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit();
    const theme = try ColorThemeData.createLoadedEmptyTheme(allocator, &fixture.registry, "test-dark");
    defer theme.deinit();
    try theme.setCustomTokenColors(&.{
        .{ .scope = &.{"variable"}, .settings = .{ .foreground = "#F8F8F2", .font_style = "" } },
        .{ .scope = &.{"keyword.operator"}, .settings = .{ .foreground = "#F92672", .font_style = "italic bold underline" } },
        .{ .scope = &.{"storage"}, .settings = .{ .foreground = "#F92672", .font_style = "italic" } },
        .{ .scope = &.{ "storage.type", "meta.structure.dictionary.json string.quoted.double.json" }, .settings = .{ .foreground = "#66D9EF" } },
        .{ .scope = &.{"entity.name.type"}, .settings = .{ .foreground = "#A6E22E", .font_style = "underline" } },
        .{ .scope = &.{"entity.name.type.class"}, .settings = .{ .foreground = "#FF00FF" } },
        .{ .scope = &.{"entity.name"}, .settings = .{ .foreground = "#FFFFFF" } },
    });

    try assertResolvedStyle(theme, &.{"variable"}, "#F8F8F2", "");
    try assertResolvedStyle(theme, &.{"keyword.operator"}, "#F92672", "italic bold underline");
    try assertResolvedStyle(theme, &.{"keyword"}, null, null);
    try assertResolvedStyle(theme, &.{"keyword.operators"}, null, null);
    try assertResolvedStyle(theme, &.{"storage.type"}, "#66D9EF", "italic");
    try assertResolvedStyle(theme, &.{ "meta.structure.dictionary.json", "string.quoted.double.json" }, "#66D9EF", null);
    try assertResolvedStyle(theme, &.{"entity.name.type.class"}, "#FF00FF", "underline");
}

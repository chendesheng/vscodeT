// Port of `src/vs/workbench/services/themes/test/common/colorThemeData.test.ts`
// (in-memory/transient/storage cases). The plist-loading case needs the
// extension resource loader + URI/tmTheme parsing, which are not ported yet.
const std = @import("std");
const Color = @import("../../../../../base/common/color.zig").Color;
const color_utils = @import("../../../../../platform/theme/common/colorUtils.zig");
const storage_mod = @import("../../../../../platform/storage/common/storage.zig");
const ColorThemeData = @import("../../common/colorThemeData.zig").ColorThemeData;

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

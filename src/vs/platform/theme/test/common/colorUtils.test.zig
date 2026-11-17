// Port of `src/vs/platform/theme/test/common/colorUtils.test.ts`.
const std = @import("std");
const Color = @import("../../../../base/common/color.zig").Color;
const theme_mod = @import("../../common/themeService.zig");
const theme = @import("../../common/theme.zig");
const color_utils = @import("../../common/colorUtils.zig");

const TestColorTheme = struct {
    colors: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) TestColorTheme {
        return .{ .colors = std.StringHashMap([]const u8).init(allocator) };
    }

    fn deinit(self: *TestColorTheme) void {
        self.colors.deinit();
    }

    fn put(self: *TestColorTheme, id: []const u8, value: []const u8) !void {
        try self.colors.put(id, value);
    }

    fn interface(self: *TestColorTheme) theme_mod.IColorTheme {
        return .{
            .theme_type = .DARK,
            .label = "test",
            .context = self,
            .vtable = &vtable,
        };
    }

    const vtable = theme_mod.IColorTheme.VTable{
        .getColor = getColor,
        .defines = defines,
        .getTokenStyleMetadata = getTokenStyleMetadata,
    };

    fn getColor(context: *anyopaque, id: []const u8, _: bool) ?Color {
        const self: *TestColorTheme = @ptrCast(@alignCast(context));
        const value = self.colors.get(id) orelse return null;
        return Color.fromHex(value) catch null;
    }

    fn defines(context: *anyopaque, id: []const u8) bool {
        const self: *TestColorTheme = @ptrCast(@alignCast(context));
        return self.colors.contains(id);
    }

    fn getTokenStyleMetadata(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) ?theme_mod.ITokenStyle {
        return null;
    }
};

fn expectRgba(color: Color, r: u8, g: u8, b: u8, a: f32) !void {
    try std.testing.expectEqual(r, color.r);
    try std.testing.expectEqual(g, color.g);
    try std.testing.expectEqual(b, color.b);
    try std.testing.expectApproxEqAbs(a, color.a, 0.001);
}

test "withOpacity replaces alpha without changing RGB" {
    const allocator = std.testing.allocator;
    var test_theme = TestColorTheme.init(allocator);
    defer test_theme.deinit();
    const theme_value = test_theme.interface();

    const colors = [_][]const u8{ "#123456", "#12345622", "#12345600" };
    for (colors) |hex| {
        const transform = color_utils.withOpacity(.{ .string = hex }, 0.8);
        const color = color_utils.executeTransform(transform, &theme_value).?;
        try expectRgba(color, 18, 52, 86, 0.8);
    }
}

test "withOpacity resolves theme colours, nested transforms and missing colours" {
    const allocator = std.testing.allocator;
    var test_theme = TestColorTheme.init(allocator);
    defer test_theme.deinit();
    try test_theme.put("source", "#12345622");
    const theme_value = test_theme.interface();

    const plain = color_utils.executeTransform(color_utils.withOpacity(.{ .string = "source" }, 0.8), &theme_value).?;
    try expectRgba(plain, 18, 52, 86, 0.8);

    const inner = color_utils.lighten(.{ .string = "source" }, 1);
    const nested = color_utils.executeTransform(color_utils.withOpacity(.{ .transform = &inner }, 0.6), &theme_value).?;
    try expectRgba(nested, 36, 104, 172, 0.6);

    try std.testing.expect(color_utils.executeTransform(color_utils.withOpacity(.{ .string = "missing" }, 0.8), &theme_value) == null);
}

test "withOpacity clamps alpha to its valid range" {
    const allocator = std.testing.allocator;
    var test_theme = TestColorTheme.init(allocator);
    defer test_theme.deinit();
    const theme_value = test_theme.interface();

    const opacities = [_]f32{ 0, 1, -1, 2 };
    const expected = [_]f32{ 0, 1, 0, 1 };
    for (opacities, expected) |opacity, alpha| {
        const color = color_utils.executeTransform(color_utils.withOpacity(.{ .string = "#12345622" }, opacity), &theme_value).?;
        try expectRgba(color, 18, 52, 86, alpha);
    }
}

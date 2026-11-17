// Port of `src/vs/platform/theme/test/common/sizeRegistry.test.ts`.
//
// The customization-schema case and the base-size registration case still need
// the base size contribution files/schema data and are not ported yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const size_utils = @import("../../common/sizeUtils.zig");
const theme_mod = @import("../../common/themeService.zig");
const theme = @import("../../common/theme.zig");

const TestTheme = struct {
    theme_type: theme.ColorScheme = .DARK,

    fn interface(self: *TestTheme) theme_mod.IColorTheme {
        return .{
            .theme_type = self.theme_type,
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

    fn getColor(_: *anyopaque, _: []const u8, _: bool) ?@import("../../../../base/common/color.zig").Color {
        return null;
    }
    fn defines(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn getTokenStyleMetadata(_: *anyopaque, _: []const u8, _: []const []const u8, _: []const u8) ?theme_mod.ITokenStyle {
        return null;
    }
};

test "sizeValueToCss converts values" {
    const allocator = std.testing.allocator;
    inline for (.{
        .{ 10.0, .px, "10px" },
        .{ 1.5, .rem, "1.5rem" },
        .{ 100.0, .percent, "100%" },
        .{ 1.2, .em, "1.2em" },
    }) |spec| {
        const css = try size_utils.sizeValueToCss(allocator, .{ .value = spec[0], .unit = spec[1] });
        defer allocator.free(css);
        try std.testing.expectEqualStrings(spec[2], css);
    }
}

test "css variable helpers replace dots" {
    const allocator = std.testing.allocator;
    const name = try size_utils.asCssVariableName(allocator, "corner.radius");
    defer allocator.free(name);
    try std.testing.expectEqualStrings("--vscode-corner-radius", name);

    const variable = try size_utils.asCssVariable(allocator, "fontSize");
    defer allocator.free(variable);
    try std.testing.expectEqualStrings("var(--vscode-fontSize)", variable);
}

test "registerSize registers and deregisters a size token" {
    const allocator = std.testing.allocator;
    var registry = size_utils.SizeRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.registerSize("test.size", .{ .defaults = size_utils.sizeForAllThemes(10, .px) }, "Test size", null, null);
    const sizes = try registry.getSizes(allocator);
    defer allocator.free(sizes);
    var found = false;
    for (sizes) |contribution| {
        if (std.mem.eql(u8, contribution.id, "test.size")) {
            try std.testing.expectEqualStrings("Test size", contribution.description);
            found = true;
        }
    }
    try std.testing.expect(found);

    registry.deregisterSize("test.size");
    const after = try registry.getSizes(allocator);
    defer allocator.free(after);
    for (after) |contribution| {
        try std.testing.expect(!std.mem.eql(u8, contribution.id, "test.size"));
    }
}

test "references retain per-theme primitive defaults" {
    const allocator = std.testing.allocator;
    var registry = size_utils.SizeRegistry.init(allocator);
    defer registry.deinit();

    _ = try registry.registerSize("test.schemeSize", .{ .defaults = .{
        .light = size_utils.size(3, .px),
        .dark = size_utils.size(4, .px),
        .hc_dark = size_utils.size(5, .px),
        .hc_light = size_utils.size(6, .px),
    } }, "Test", null, null);
    _ = try registry.registerSize("test.schemeAlias", .{ .reference = "test.schemeSize" }, "Test", null, null);

    const expected = [_]f64{ 3, 4, 5, 6 };
    const types = [_]theme.ColorScheme{ .LIGHT, .DARK, .HIGH_CONTRAST_DARK, .HIGH_CONTRAST_LIGHT };
    for (types, expected) |theme_type, value| {
        var test_theme = TestTheme{ .theme_type = theme_type };
        const resolved = (try registry.resolveDefaultSize("test.schemeAlias", &test_theme.interface())).?;
        try std.testing.expectEqual(value, resolved.value);
    }
}

test "circular references are detected" {
    const allocator = std.testing.allocator;
    var registry = size_utils.SizeRegistry.init(allocator);
    defer registry.deinit();
    _ = try registry.registerSize("test.cycle", .{ .reference = "test.cycle" }, "Test", null, null);
    var test_theme = TestTheme{};
    try std.testing.expectError(error.CircularSizeTokenReference, registry.resolveDefaultSize("test.cycle", &test_theme.interface()));
}

test "sizeForAllThemes creates the same value for all themes" {
    const defaults = size_utils.sizeForAllThemes(10, .px);
    try std.testing.expectEqual(@as(f64, 10), defaults.light.?.value);
    try std.testing.expectEqual(@as(f64, 10), defaults.dark.?.value);
    try std.testing.expectEqual(@as(f64, 10), defaults.hc_dark.?.value);
    try std.testing.expectEqual(@as(f64, 10), defaults.hc_light.?.value);
    try std.testing.expectEqual(size_utils.SizeUnit.px, defaults.dark.?.unit);
}

test "customizations resolve in specificity order through references" {
    const allocator = std.testing.allocator;
    var registry = size_utils.SizeRegistry.init(allocator);
    defer registry.deinit();

    const range = size_utils.SizeCustomization{ .minimum = 0, .maximum = 8 };
    _ = try registry.registerSize("cornerRadius.large", .{ .defaults = size_utils.sizeForAllThemes(8, .px) }, "Large", null, null);
    _ = try registry.registerSize("panels.cornerRadius", .{ .reference = "cornerRadius.large" }, "Panels", null, range);
    _ = try registry.registerSize("toolsPanel.cornerRadius", .{ .reference = "panels.cornerRadius" }, "Tools", null, range);
    _ = try registry.registerSize("primarySideBar.cornerRadius", .{ .reference = "panels.cornerRadius" }, "Sidebar", null, range);
    _ = try registry.registerSize("activityBar.cornerRadius", .{ .reference = "primarySideBar.cornerRadius" }, "Activity", null, range);

    const ids = [_][]const u8{
        "cornerRadius.large", "panels.cornerRadius", "toolsPanel.cornerRadius", "primarySideBar.cornerRadius", "activityBar.cornerRadius",
    };
    var test_theme = TestTheme{};

    const Resolve = struct {
        fn run(registry_value: *size_utils.SizeRegistry, theme_value: *const theme_mod.IColorTheme, alloc: Allocator, id_values: []const []const u8, entries: []const [2][]const u8) ![]const f64 {
            var customizations = std.StringHashMap(i64).init(alloc);
            defer customizations.deinit();
            for (entries) |entry| try customizations.put(entry[0], std.fmt.parseInt(i64, entry[1], 10) catch unreachable);
            const result = try alloc.alloc(f64, id_values.len);
            for (id_values, 0..) |id, index| {
                const size_value = (try registry_value.resolveSize(id, theme_value, &customizations)).?;
                result[index] = size_value.value;
            }
            return result;
        }
    };

    const defaults = try Resolve.run(&registry, &test_theme.interface(), allocator, &ids, &.{});
    defer allocator.free(defaults);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8, 8, 8, 8 }, defaults);

    const panels = try Resolve.run(&registry, &test_theme.interface(), allocator, &ids, &.{.{ "panels.cornerRadius", "6" }});
    defer allocator.free(panels);
    try std.testing.expectEqualSlices(f64, &.{ 8, 6, 6, 6, 6 }, panels);

    const component = try Resolve.run(&registry, &test_theme.interface(), allocator, &ids, &.{
        .{ "panels.cornerRadius", "4" },
        .{ "primarySideBar.cornerRadius", "2" },
    });
    defer allocator.free(component);
    try std.testing.expectEqualSlices(f64, &.{ 8, 4, 4, 2, 2 }, component);

    const rail = try Resolve.run(&registry, &test_theme.interface(), allocator, &ids, &.{
        .{ "primarySideBar.cornerRadius", "2" },
        .{ "activityBar.cornerRadius", "0" },
    });
    defer allocator.free(rail);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8, 8, 2, 0 }, rail);

    const ignored = try Resolve.run(&registry, &test_theme.interface(), allocator, &ids, &.{.{ "cornerRadius.large", "0" }});
    defer allocator.free(ignored);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8, 8, 8, 8 }, ignored);
}

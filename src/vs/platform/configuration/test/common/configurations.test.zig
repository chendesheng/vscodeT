// Port of the DefaultConfiguration registration cases of
// `src/vs/platform/configuration/test/common/configurations.test.ts`,
// adapted to the explicit registry/model lifecycle.
const std = @import("std");
const configurationRegistry = @import("../../common/configurationRegistry.zig");
const configurations = @import("../../common/configurations.zig");

test "registering a property before initialize" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();

    try registry.registerConfiguration("test", &.{.{ .key = "test.prop", .default = std.json.Value{ .string = "default" } }});
    try defaults.initialize();
    try std.testing.expectEqualStrings("default", defaults.configurationModel().getValue("test.prop").?.string);
}

test "registering a property and not initializing" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try registry.registerConfiguration("test", &.{.{ .key = "test.prop", .default = std.json.Value{ .string = "default" } }});
    try std.testing.expect(defaults.configurationModel().getValue("test.prop") == null);
}

test "registering a property after initialize" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    try registry.registerConfiguration("test", &.{.{ .key = "test.prop", .default = std.json.Value{ .string = "default" } }});
    try defaults.onDidUpdateConfiguration(&.{"test.prop"});
    try std.testing.expectEqualStrings("default", defaults.configurationModel().getValue("test.prop").?.string);
}

test "registering nested properties" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try registry.registerConfiguration("test", &.{
        .{ .key = "a.b.c", .default = std.json.Value{ .integer = 1 } },
        .{ .key = "a.b.d", .default = std.json.Value{ .integer = 2 } },
    });
    try defaults.initialize();
    try std.testing.expectEqual(@as(i64, 1), defaults.configurationModel().getValue("a.b.c").?.integer);
    try std.testing.expectEqual(@as(i64, 2), defaults.configurationModel().getValue("a.b.d").?.integer);
}

test "registering the same property again replaces its default" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try registry.registerConfiguration("test", &.{.{ .key = "test.prop", .default = std.json.Value{ .string = "first" } }});
    try registry.registerConfiguration("test2", &.{.{ .key = "test.prop", .default = std.json.Value{ .string = "second" } }});
    try defaults.initialize();
    try std.testing.expectEqualStrings("second", defaults.configurationModel().getValue("test.prop").?.string);
}

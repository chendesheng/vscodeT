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

fn jsonValue(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "registering an override identifier" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();

    try registry.registerDefaultConfigurations(&.{.{ .key = "[a]", .value = try jsonValue(arena.allocator(), "{\"b\":true}") }});
    try defaults.initialize();
    const model = defaults.configurationModel();
    try std.testing.expect(model.getValue("[a]") != null);
    try std.testing.expectEqual(@as(usize, 1), model.overrides.len);
    try std.testing.expectEqualStrings("a", model.overrides[0].identifiers[0]);
    try std.testing.expectEqual(@as(usize, 1), model.overrides[0].keys.len);
    try std.testing.expectEqualStrings("b", model.overrides[0].keys[0]);
    try std.testing.expectEqual(@as(bool, true), model.overrides[0].contents.object.get("b").?.bool);
    try std.testing.expectEqualStrings("[a]", model.getKeys()[0]);
    var overridden = try model.override(allocator, "a");
    defer overridden.deinit();
    try std.testing.expectEqual(@as(bool, true), overridden.getValue("b").?.bool);
}

test "registering a normal property and override identifier" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();

    try registry.registerConfiguration("a", &.{.{ .key = "b", .value_type = "boolean", .default = std.json.Value{ .bool = false } }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "[a]", .value = try jsonValue(arena.allocator(), "{\"b\":true}") }});
    try defaults.initialize();
    const model = defaults.configurationModel();
    try std.testing.expectEqual(@as(bool, false), model.getValue("b").?.bool);
    try std.testing.expect(model.getValue("[a]") != null);
    try std.testing.expectEqual(@as(usize, 1), model.overrides.len);
    try std.testing.expectEqual(@as(usize, 2), model.getKeys().len);
}

test "register override identifier and property after initialize" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();

    try registry.registerConfiguration("a", &.{.{ .key = "b", .value_type = "boolean", .default = std.json.Value{ .bool = false } }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "[a]", .value = try jsonValue(arena.allocator(), "{\"b\":true}") }});
    try defaults.onDidUpdateConfiguration(&.{ "b", "[a]" });
    const model = defaults.configurationModel();
    try std.testing.expectEqual(@as(bool, false), model.getValue("b").?.bool);
    try std.testing.expect(model.getValue("[a]") != null);
    try std.testing.expectEqual(@as(usize, 1), model.overrides.len);
}

test "deregistering a property removes it from defaults" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try registry.registerConfiguration("a", &.{.{ .key = "a", .value_type = "boolean", .default = std.json.Value{ .bool = false } }});
    try defaults.initialize();
    try std.testing.expect(defaults.configurationModel().getValue("a") != null);
    registry.deregisterConfigurations("a");
    try defaults.onDidUpdateConfiguration(&.{"a"});
    try std.testing.expect(defaults.configurationModel().getValue("a") == null);
    try std.testing.expectEqual(@as(usize, 0), defaults.configurationModel().getKeys().len);
}

test "deregistering an override identifier removes the override" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try registry.registerConfiguration("a", &.{.{ .key = "b", .value_type = "boolean", .default = std.json.Value{ .bool = false } }});
    const entries = [_]configurationRegistry.DefaultOverride{.{ .key = "[a]", .value = try jsonValue(arena.allocator(), "{\"b\":true}") }};
    try registry.registerDefaultConfigurations(&entries);
    try defaults.initialize();
    try std.testing.expect(defaults.configurationModel().getValue("[a]") != null);
    try registry.deregisterDefaultConfigurations(&entries, null);
    try defaults.onDidUpdateConfiguration(&.{"[a]"});
    try std.testing.expect(defaults.configurationModel().getValue("[a]") == null);
    try std.testing.expectEqual(@as(usize, 0), defaults.configurationModel().overrides.len);
    try std.testing.expectEqual(@as(usize, 1), defaults.configurationModel().getKeys().len);
}

test "hidden experimental defaults update and unregister" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();

    try registry.registerConfiguration("test", &.{.{
        .key = "hidden.experimental",
        .value_type = "string",
        .default = std.json.Value{ .string = "value" },
        .included = false,
        .experiment_mode = "auto",
    }});
    try defaults.initialize();
    try std.testing.expectEqualStrings("value", defaults.configurationModel().getValue("hidden.experimental").?.string);

    registry.deregisterConfigurations("test");
    try defaults.onDidUpdateConfiguration(&.{"hidden.experimental"});
    try std.testing.expect(defaults.configurationModel().getValue("hidden.experimental") == null);
}

test "deregistering a merged language object setting" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try registry.registerConfiguration("b", &.{.{ .key = "b", .value_type = "object", .default = std.json.Value{ .object = .{} } }});

    const source1 = configurationRegistry.ConfigurationDefaultSource{ .extension = .{ .id = "source1", .display_name = "source1" } };
    const source2 = configurationRegistry.ConfigurationDefaultSource{ .extension = .{ .id = "source2", .display_name = "source2" } };
    const node1 = [_]configurationRegistry.DefaultOverride{.{ .key = "[a]", .value = try jsonValue(arena.allocator(), "{\"b\":{\"aa\":\"1\",\"bb\":\"2\"}}") }};
    const node2 = [_]configurationRegistry.DefaultOverride{.{ .key = "[a]", .value = try jsonValue(arena.allocator(), "{\"b\":{\"bb\":\"20\",\"cc\":\"30\"}}") }};
    try registry.registerDefaultConfigurationsWithSource(&node1, source1);
    try registry.registerDefaultConfigurationsWithSource(&node2, source2);
    try defaults.initialize();
    try registry.deregisterDefaultConfigurations(&node1, source1);
    try defaults.onDidUpdateConfiguration(&.{"[a]"});

    const model = defaults.configurationModel();
    const override_value = model.getValue("[a]").?;
    try std.testing.expectEqualStrings("20", override_value.object.get("b").?.object.get("bb").?.string);
    try std.testing.expectEqualStrings("30", override_value.object.get("b").?.object.get("cc").?.string);
    try std.testing.expect(override_value.object.get("b").?.object.get("aa") == null);
    try std.testing.expectEqual(@as(usize, 1), model.overrides.len);
    try std.testing.expectEqual(@as(usize, 2), model.getKeys().len);
    var overridden = try model.override(allocator, "a");
    defer overridden.deinit();
    try std.testing.expectEqualStrings("20", overridden.getValue("b.bb").?.string);
}

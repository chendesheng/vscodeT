// Port of the DefaultConfiguration registration cases of
// `src/vs/platform/configuration/test/common/configurations.test.ts`,
// adapted to the explicit registry/model lifecycle.
const std = @import("std");
const configurationRegistry = @import("../../common/configurationRegistry.zig");
const configurations = @import("../../common/configurations.zig");
const configurationModels = @import("../../common/configurationModels.zig");

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

test "registering the same property again keeps the first default" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try registry.registerConfiguration("test", &.{.{ .key = "test.prop", .default = std.json.Value{ .string = "first" } }});
    try registry.registerConfiguration("test2", &.{.{ .key = "test.prop", .default = std.json.Value{ .string = "second" } }});
    try defaults.initialize();
    try std.testing.expectEqualStrings("first", defaults.configurationModel().getValue("test.prop").?.string);
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

test "registry changes update the default configuration automatically" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    try std.testing.expect(defaults.configurationModel().getValue("auto.prop") == null);

    try registry.registerConfiguration("auto", &.{.{ .key = "auto.prop", .default = std.json.Value{ .string = "value" } }});
    try std.testing.expectEqualStrings("value", defaults.configurationModel().getValue("auto.prop").?.string);

    registry.deregisterConfigurations("auto");
    try std.testing.expect(defaults.configurationModel().getValue("auto.prop") == null);
}

test "hidden experimental settings registered after initialization become visible" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    try std.testing.expect(defaults.configurationModel().getValue("hidden.late") == null);

    try registry.registerConfiguration("hidden", &.{.{
        .key = "hidden.late",
        .value_type = "boolean",
        .default = std.json.Value{ .bool = true },
        .included = false,
        .experiment_mode = "auto",
    }});
    try std.testing.expectEqual(@as(bool, true), defaults.configurationModel().getValue("hidden.late").?.bool);
}

test "property registered before initialize is part of the model" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("before", &.{.{ .key = "before.prop", .value_type = "boolean", .default = std.json.Value{ .bool = false } }});
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    try std.testing.expectEqual(@as(bool, false), defaults.configurationModel().getValue("before.prop").?.bool);
}

test "deregistering a property removes it from the model" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    try registry.registerConfiguration("deregister", &.{.{ .key = "deregister.prop", .value_type = "boolean", .default = std.json.Value{ .bool = true } }});
    try std.testing.expectEqual(@as(bool, true), defaults.configurationModel().getValue("deregister.prop").?.bool);
    registry.deregisterConfigurations("deregister");
    try std.testing.expect(defaults.configurationModel().getValue("deregister.prop") == null);
}

test "deregistering an unknown or already removed node is a no-op" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    try registry.registerConfiguration("removed", &.{.{ .key = "removed.prop", .default = std.json.Value{ .bool = true } }});
    registry.deregisterConfigurations("removed");
    registry.deregisterConfigurations("removed");
    registry.deregisterConfigurations("missing");
    try std.testing.expect(defaults.configurationModel().getValue("removed.prop") == null);
}

test "registered properties stay out of the model until initialize" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("later", &.{.{ .key = "later.prop", .value_type = "boolean", .default = std.json.Value{ .bool = false } }});
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try std.testing.expect(defaults.configurationModel().getValue("later.prop") == null);
    try defaults.initialize();
    try std.testing.expectEqual(@as(bool, false), defaults.configurationModel().getValue("later.prop").?.bool);
}

test "policy configuration applies policy values and changes" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("policy", &.{
        .{ .key = "policy.a", .value_type = "string", .default = std.json.Value{ .string = "default" }, .policy = "PolicyA" },
        .{ .key = "policy.obj", .value_type = "object", .default = std.json.Value{ .object = std.json.ObjectMap{} }, .policy = "PolicyObject" },
        .{ .key = "policy.arr", .value_type = "array", .default = std.json.Value{ .array = std.json.Array.init(allocator) }, .policy = "PolicyArray" },
        .{ .key = "policy.bool", .value_type = "boolean", .default = std.json.Value{ .bool = true }, .policy = "PolicyBool" },
        .{ .key = "policy.plain", .value_type = "boolean", .default = std.json.Value{ .bool = true } },
    });
    var policy_service = @import("../../../../platform/policy/common/policy.zig").InMemoryPolicyService.init(allocator);
    defer policy_service.deinit();
    try policy_service.setPolicyValue("PolicyA", .{ .string = "on" });
    try policy_service.setPolicyValue("PolicyObject", .{ .string = "{\"key\":1}" });
    try policy_service.setPolicyValue("PolicyArray", .{ .string = "[1,2]" });
    try policy_service.setPolicyValue("PolicyBool", .{ .boolean = false });

    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    var policy_config = try configurations.PolicyConfiguration.init(allocator, &defaults, &policy_service);
    defer policy_config.deinit();
    try policy_config.initialize();

    const model = policy_config.configurationModel();
    try std.testing.expectEqualStrings("on", model.getValue("policy.a").?.string);
    try std.testing.expectEqual(@as(i64, 1), model.getValue("policy.obj").?.object.get("key").?.integer);
    try std.testing.expectEqual(@as(usize, 2), model.getValue("policy.arr").?.array.items.len);
    try std.testing.expectEqual(@as(bool, false), model.getValue("policy.bool").?.bool);
    try std.testing.expect(model.getValue("policy.plain") == null);

    const Listener = struct {
        fn onChange(_: configurationModels.ConfigurationModel, count: *usize) anyerror!void {
            count.* += 1;
        }
    };
    var changes: usize = 0;
    _ = try policy_config.onDidChangeConfiguration.listen(&changes, Listener.onChange);
    try policy_service.setPolicyValue("PolicyA", .{ .string = "off" });
    try std.testing.expectEqualStrings("off", policy_config.configurationModel().getValue("policy.a").?.string);
    try std.testing.expectEqual(@as(usize, 1), changes);

    try policy_service.setPolicyValue("PolicyA", null);
    try std.testing.expect(policy_config.configurationModel().getValue("policy.a") == null);
}

test "policy configuration follows owner/reference registration changes" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("reference", &.{.{
        .key = "policy.ref",
        .value_type = "string",
        .default = std.json.Value{ .string = "default" },
        .policy_reference = "LatePolicy",
    }});
    var policy_service = @import("../../../../platform/policy/common/policy.zig").InMemoryPolicyService.init(allocator);
    defer policy_service.deinit();
    try policy_service.setPolicyValue("LatePolicy", .{ .string = "123" });
    var defaults = try configurations.DefaultConfiguration.init(allocator, registry);
    defer defaults.deinit();
    try defaults.initialize();
    var policy_config = try configurations.PolicyConfiguration.init(allocator, &defaults, &policy_service);
    defer policy_config.deinit();
    try policy_config.initialize();
    try std.testing.expectEqualStrings("123", policy_config.configurationModel().getValue("policy.ref").?.string);

    try registry.registerConfiguration("owner", &.{.{
        .key = "policy.owner",
        .value_type = "number",
        .default = std.json.Value{ .integer = 0 },
        .policy = "LatePolicy",
    }});
    try std.testing.expectEqual(@as(i64, 123), policy_config.configurationModel().getValue("policy.owner").?.integer);
}

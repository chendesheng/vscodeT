// Port of the default-override and policy cases of
// `src/vs/platform/configuration/test/common/configurationRegistry.test.ts`.
const std = @import("std");
const configuration_registry = @import("../../common/configurationRegistry.zig");

fn value(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

fn valueEquals(a: std.json.Value, b: std.json.Value) !bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value_a| value_a == b.bool,
        .integer => |value_a| value_a == b.integer,
        .float => |value_a| value_a == b.float,
        .number_string => |value_a| std.mem.eql(u8, value_a, b.number_string),
        .string => |value_a| std.mem.eql(u8, value_a, b.string),
        .array => |array_a| blk: {
            if (array_a.items.len != b.array.items.len) break :blk false;
            for (array_a.items, b.array.items) |item_a, item_b| {
                if (!try valueEquals(item_a, item_b)) break :blk false;
            }
            break :blk true;
        },
        .object => |object_a| blk: {
            if (object_a.count() != b.object.count()) break :blk false;
            var iterator = object_a.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!try valueEquals(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn expectDefault(props: *std.StringHashMap(configuration_registry.Property), key: []const u8, text: []const u8, arena: std.mem.Allocator) !void {
    const property = props.get(key) orelse return error.MissingProperty;
    const expected = try value(arena, text);
    try std.testing.expect(try valueEquals(expected, property.default));
}

test "configuration override merges object defaults" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerConfiguration("_test_default", &.{.{ .key = "config" }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "config", .value = try value(arena.allocator(), "{\"a\":1,\"b\":2}") }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "[lang]", .value = try value(arena.allocator(), "{\"a\":2,\"c\":3}") }});

    const props = registry.getConfigurationProperties();
    try expectDefault(props, "config", "{\"a\":1,\"b\":2}", arena.allocator());
    try expectDefault(props, "[lang]", "{\"a\":2,\"c\":3}", arena.allocator());
}

test "configuration override defaults prevent overriding the default value" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerConfiguration("_test_default", &.{.{
        .key = "config.preventDefaultValueOverride",
        .default = try value(arena.allocator(), "{\"a\":0}"),
        .disallow_configuration_default = true,
    }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "config.preventDefaultValueOverride", .value = try value(arena.allocator(), "{\"a\":1,\"b\":2}") }});
    try expectDefault(registry.getConfigurationProperties(), "config.preventDefaultValueOverride", "{\"a\":0}", arena.allocator());
}

test "configuration overrides merge defaults" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerDefaultConfigurations(&.{.{ .key = "[lang]", .value = try value(arena.allocator(), "{\"a\":1,\"b\":2}") }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "[lang]", .value = try value(arena.allocator(), "{\"a\":2,\"c\":3}") }});
    try expectDefault(registry.getConfigurationProperties(), "[lang]", "{\"a\":2,\"b\":2,\"c\":3}", arena.allocator());
}

test "configuration defaults merge object default overrides" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerConfiguration("_test_default", &.{.{ .key = "config" }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "config", .value = try value(arena.allocator(), "{\"a\":1,\"b\":2}") }});
    try registry.registerDefaultConfigurations(&.{.{ .key = "config", .value = try value(arena.allocator(), "{\"a\":2,\"c\":3}") }});
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":2,\"b\":2,\"c\":3}", arena.allocator());
}

test "registering multiple settings with the same policy keeps only the first" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerConfiguration("_test_default", &.{
        .{ .key = "policy1", .policy = "policy" },
        .{ .key = "policy2", .policy = "policy" },
    });
    const props = registry.getConfigurationProperties();
    try std.testing.expect(props.get("policy1") != null);
    try std.testing.expect(props.get("policy2") == null);
}

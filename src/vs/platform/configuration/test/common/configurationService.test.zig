// Port of the user-target update cases of
// `src/vs/platform/configuration/test/common/configurationService.test.ts`,
// adapted to the in-memory terminal configuration service (no settings file).
const std = @import("std");
const configurationRegistry = @import("../../common/configurationRegistry.zig");
const configurationService = @import("../../common/configurationService.zig");
const configuration = @import("../../common/configuration.zig");

fn setup(allocator: std.mem.Allocator) !struct { registry: *configurationRegistry.ConfigurationRegistry, service: *configurationService.ConfigurationService } {
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    try registry.registerConfiguration("_test", &.{.{ .key = "configurationService.testSetting", .default = std.json.Value{ .string = "isSet" } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    try service.initialize();
    return .{ .registry = registry, .service = service };
}

fn teardown(registry: *configurationRegistry.ConfigurationRegistry, service: *configurationService.ConfigurationService) void {
    service.deinit();
    registry.deinit();
}

test "update configuration" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);
    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "value" }, .USER);
    try std.testing.expectEqualStrings("value", fixture.service.getValue("configurationService.testSetting").?.string);
}

test "update configuration when it exists" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);
    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "value" }, .USER);
    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "updatedValue" }, .USER);
    try std.testing.expectEqualStrings("updatedValue", fixture.service.getValue("configurationService.testSetting").?.string);
}

test "update configuration to default value removes it" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);
    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "value" }, .USER);
    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "isSet" }, .USER);
    try std.testing.expect(fixture.service.inspect("configurationService.testSetting").user_value == null);
}

test "update configuration removes when undefined is passed" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);
    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "value" }, .USER);
    try fixture.service.updateValue("configurationService.testSetting", null, .USER);
    try std.testing.expect(fixture.service.inspect("configurationService.testSetting").user_value == null);
}

test "update unknown configuration" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);
    try fixture.service.updateValue("configurationService.unknownSetting", .{ .string = "value" }, .USER);
    try std.testing.expectEqualStrings("value", fixture.service.getValue("configurationService.unknownSetting").?.string);
}

test "update configuration in non-user target throws" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);
    try std.testing.expectError(
        error.UnsupportedConfigurationTarget,
        fixture.service.updateValue("configurationService.testSetting", .{ .string = "value" }, .WORKSPACE),
    );
}

test "lookup nested default values" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{
        .{ .key = "a.b", .default = std.json.Value{ .integer = 1 } },
        .{ .key = "a.c", .default = std.json.Value{ .integer = 2 } },
    });
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();

    try std.testing.expectEqual(@as(i64, 1), service.getValue("a.b").?.integer);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("a.c").?.integer);
    const a = service.getValue("a").?;
    try std.testing.expectEqual(@as(i64, 1), a.object.get("b").?.integer);
    try std.testing.expectEqual(@as(i64, 2), a.object.get("c").?.integer);
}

test "lookup missing and configured settings" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);

    var result = fixture.service.inspect("something.missing");
    try std.testing.expect(result.value == null);
    try std.testing.expect(result.default_value == null);
    try std.testing.expect(result.user_value == null);
    try std.testing.expect(!configurationService.isConfigured(result));

    result = fixture.service.inspect("configurationService.testSetting");
    try std.testing.expectEqualStrings("isSet", result.default_value.?.string);
    try std.testing.expectEqualStrings("isSet", result.value.?.string);
    try std.testing.expect(result.user_value == null);
    try std.testing.expect(!configurationService.isConfigured(result));

    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "bar" }, .USER);
    result = fixture.service.inspect("configurationService.testSetting");
    try std.testing.expectEqualStrings("isSet", result.default_value.?.string);
    try std.testing.expectEqualStrings("bar", result.user_value.?.string);
    try std.testing.expectEqualStrings("bar", result.value.?.string);
    try std.testing.expect(configurationService.isConfigured(result));
}

test "lookup with null" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_testNull", &.{.{ .key = "lookup.service.testNullSetting", .value_type = "null" }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();

    var result = service.inspect("lookup.service.testNullSetting");
    try std.testing.expect(result.default_value.?.* == .null);
    try std.testing.expect(result.value.?.* == .null);
    try std.testing.expect(result.user_value == null);

    try service.updateValue("lookup.service.testNullSetting", std.json.Value.null, .USER);
    result = service.inspect("lookup.service.testNullSetting");
    try std.testing.expect(result.user_value == null);
}

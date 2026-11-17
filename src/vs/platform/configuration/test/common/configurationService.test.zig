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

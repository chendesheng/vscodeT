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

test "workspace configuration overrides user and defaults" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);

    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "user" }, .USER);
    try fixture.service.loadWorkspaceJson("{\"configurationService.testSetting\":\"workspace\"}");
    try std.testing.expectEqualStrings("workspace", fixture.service.getValue("configurationService.testSetting").?.string);
    const result = fixture.service.inspect("configurationService.testSetting");
    try std.testing.expectEqualStrings("workspace", result.workspace_value.?.string);
    try std.testing.expectEqualStrings("user", result.user_value.?.string);
    try std.testing.expectEqualStrings("workspace", result.value.?.string);
    try std.testing.expect(configurationService.isConfigured(result));
}

test "reloading workspace configuration reflects the new document" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);

    try fixture.service.loadWorkspaceJson("{\"configurationService.testSetting\":\"first\"}");
    try std.testing.expectEqualStrings("first", fixture.service.getValue("configurationService.testSetting").?.string);
    try fixture.service.loadWorkspaceJson("{\"configurationService.testSetting\":\"second\"}");
    try std.testing.expectEqualStrings("second", fixture.service.getValue("configurationService.testSetting").?.string);
    try fixture.service.loadWorkspaceJson("{}");
    try std.testing.expectEqualStrings("isSet", fixture.service.getValue("configurationService.testSetting").?.string);
}

test "late registered defaults become visible automatically" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();

    try std.testing.expect(service.getValue("late.setting") == null);
    try registry.registerConfiguration("late", &.{.{ .key = "late.setting", .default = std.json.Value{ .string = "default" } }});
    try std.testing.expectEqualStrings("default", service.getValue("late.setting").?.string);
}

test "configuration changes emit the changed source and keys" {
    const allocator = std.testing.allocator;
    var fixture = try setup(allocator);
    defer teardown(fixture.registry, fixture.service);

    // `Change.keys` is borrowed for the duration of the event, so a listener
    // that keeps the change must copy both the key array and its strings.
    const RecordedChange = struct {
        source: configuration.ConfigurationTarget,
        keys: std.array_list.Managed([]u8),

        fn record(allocator_: std.mem.Allocator, change: configuration.Change) !@This() {
            var recorded = @This(){
                .source = change.source,
                .keys = std.array_list.Managed([]u8).init(allocator_),
            };
            errdefer recorded.deinit(allocator_);
            for (change.keys) |key| try recorded.keys.append(try allocator_.dupe(u8, key));
            return recorded;
        }

        fn deinit(self: *@This(), allocator_: std.mem.Allocator) void {
            for (self.keys.items) |key| allocator_.free(key);
            self.keys.deinit();
        }
    };

    var events = std.array_list.Managed(RecordedChange).init(allocator);
    defer {
        for (events.items) |*event| event.deinit(allocator);
        events.deinit();
    }
    const Listener = struct {
        fn onChange(change: configuration.Change, list: *std.array_list.Managed(RecordedChange)) anyerror!void {
            try list.append(try RecordedChange.record(list.allocator, change));
        }
    };
    _ = try fixture.service.onDidChange.listen(&events, Listener.onChange);

    try fixture.service.updateValue("configurationService.testSetting", .{ .string = "value" }, .USER);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(configuration.ConfigurationTarget.USER, events.items[0].source);
    try std.testing.expectEqualStrings("configurationService.testSetting", events.items[0].keys.items[0]);

    try fixture.service.loadWorkspaceJson("{\"configurationService.testSetting\":\"workspace\"}");
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqual(configuration.ConfigurationTarget.WORKSPACE, events.items[1].source);
    try std.testing.expectEqualStrings("configurationService.testSetting", events.items[1].keys.items[0]);

    try fixture.service.updateValue("configurationService.testSetting", null, .USER);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expectEqual(configuration.ConfigurationTarget.USER, events.items[2].source);
    try std.testing.expectEqualStrings("configurationService.testSetting", events.items[2].keys.items[0]);
}

test "language override values resolve through the service" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "editor.tabSize", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();

    try std.testing.expectEqual(@as(i64, 4), (try service.getValueWithOverrides("editor.tabSize", "typescript")).?.integer);

    try service.loadWorkspaceJson("{\"[typescript]\":{\"editor.tabSize\":2}}");
    try std.testing.expectEqual(@as(i64, 2), (try service.getValueWithOverrides("editor.tabSize", "typescript")).?.integer);
    try std.testing.expectEqual(@as(i64, 4), service.getValue("editor.tabSize").?.integer);
}

test "override-aware inspect reports language values per scope" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "editor.tabSize", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.loadWorkspaceJson("{\"[typescript]\":{\"editor.tabSize\":2}}");

    const plain = service.inspect("editor.tabSize");
    try std.testing.expectEqual(@as(i64, 4), plain.value.?.integer);
    try std.testing.expect(plain.workspace_value == null);

    const inspected = try service.inspectWithOverride("editor.tabSize", "typescript");
    try std.testing.expectEqual(@as(i64, 2), inspected.workspace_value.?.integer);
    try std.testing.expectEqual(@as(i64, 2), inspected.value.?.integer);
    try std.testing.expectEqual(@as(i64, 4), inspected.default_value.?.integer);
}

test "language override lookup falls back to user and default values" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "editor.tabSize", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.updateValue("editor.tabSize", .{ .integer = 8 }, .USER);

    try std.testing.expectEqual(@as(i64, 8), (try service.getValueWithOverrides("editor.tabSize", "typescript")).?.integer);
    try std.testing.expectEqual(@as(i64, 8), (try service.getValueWithOverrides("editor.tabSize", null)).?.integer);
    try std.testing.expectEqual(@as(i64, 8), service.getValue("editor.tabSize").?.integer);

    try service.loadWorkspaceJson("{\"[typescript]\":{\"editor.tabSize\":2}}");
    try std.testing.expectEqual(@as(i64, 2), (try service.getValueWithOverrides("editor.tabSize", "typescript")).?.integer);
    try std.testing.expectEqual(@as(i64, 8), (try service.getValueWithOverrides("editor.tabSize", "python")).?.integer);
}

test "inspect reflects workspace reloads" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "inspect.setting", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();

    try std.testing.expect(service.inspect("inspect.setting").workspace_value == null);
    try service.loadWorkspaceJson("{\"inspect.setting\":2}");
    try std.testing.expectEqual(@as(i64, 2), service.inspect("inspect.setting").workspace_value.?.integer);
    try std.testing.expectEqual(@as(i64, 2), service.inspect("inspect.setting").value.?.integer);
    try service.loadWorkspaceJson("{}");
    try std.testing.expect(service.inspect("inspect.setting").workspace_value == null);
    try std.testing.expectEqual(@as(i64, 4), service.inspect("inspect.setting").value.?.integer);
}

test "isConfigured reflects user and workspace values" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "configured.setting", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();

    try std.testing.expect(!configurationService.isConfigured(service.inspect("configured.setting")));
    try service.updateValue("configured.setting", .{ .integer = 8 }, .USER);
    try std.testing.expect(configurationService.isConfigured(service.inspect("configured.setting")));
    try service.loadWorkspaceJson("{\"configured.setting\":2}");
    try std.testing.expect(configurationService.isConfigured(service.inspect("configured.setting")));
}

test "empty override identifier falls back to normal values" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "empty.setting", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.loadWorkspaceJson("{\"empty.setting\":2}");
    try std.testing.expectEqual(@as(i64, 2), (try service.getValueWithOverrides("empty.setting", "")).?.integer);
    try std.testing.expectEqual(@as(i64, 2), (try service.getValueWithOverrides("empty.setting", "missing")).?.integer);
}

test "updating to the default value clears the user setting" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "clear.setting", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.updateValue("clear.setting", .{ .integer = 8 }, .USER);
    try std.testing.expect(configurationService.isConfigured(service.inspect("clear.setting")));
    try service.updateValue("clear.setting", .{ .integer = 4 }, .USER);
    try std.testing.expect(!configurationService.isConfigured(service.inspect("clear.setting")));
    try std.testing.expectEqual(@as(i64, 4), service.getValue("clear.setting").?.integer);
}

test "invalid workspace settings reset to an empty workspace model" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "workspace.setting", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.loadWorkspaceJson("{\"workspace.setting\":2}");
    try std.testing.expectEqual(@as(i64, 2), service.getValue("workspace.setting").?.integer);
    try service.loadWorkspaceJson("{invalid");
    try std.testing.expectEqual(@as(i64, 4), service.getValue("workspace.setting").?.integer);
}

test "only user settings can be updated by the platform service" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try std.testing.expectError(error.UnsupportedConfigurationTarget, service.updateValue("any.setting", .{ .bool = true }, .WORKSPACE));
    try std.testing.expectError(error.UnsupportedConfigurationTarget, service.updateValue("any.setting", .{ .bool = true }, .DEFAULT));
}

test "removing a user setting falls back to the default" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "remove.setting", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.updateValue("remove.setting", .{ .integer = 8 }, .USER);
    try std.testing.expectEqual(@as(i64, 8), service.getValue("remove.setting").?.integer);
    try service.updateValue("remove.setting", null, .USER);
    try std.testing.expectEqual(@as(i64, 4), service.getValue("remove.setting").?.integer);
    try std.testing.expect(!configurationService.isConfigured(service.inspect("remove.setting")));
}

test "non-object workspace settings are ignored" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "shape.setting", .default = std.json.Value{ .integer = 4 } }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.loadWorkspaceJson("null");
    try std.testing.expectEqual(@as(i64, 4), service.getValue("shape.setting").?.integer);
    try service.loadWorkspaceJson("[]");
    try std.testing.expectEqual(@as(i64, 4), service.getValue("shape.setting").?.integer);
}

test "default configurations can contribute language overrides" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "editor.tabSize", .default = std.json.Value{ .integer = 4 } }});
    try registry.registerDefaultsJson("{\"[typescript]\":{\"editor.tabSize\":2}}");
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try std.testing.expectEqual(@as(i64, 4), service.getValue("editor.tabSize").?.integer);
    try std.testing.expectEqual(@as(i64, 2), (try service.getValueWithOverrides("editor.tabSize", "typescript")).?.integer);

    try registry.registerDefaultsJson("{\"[python]\":{\"editor.tabSize\":3}}");
    try std.testing.expectEqual(@as(i64, 3), (try service.getValueWithOverrides("editor.tabSize", "python")).?.integer);
}

test "restoring a snapshot updates an initialized service" {
    const allocator = std.testing.allocator;
    const source_registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer source_registry.deinit();
    try source_registry.registerConfiguration("snapshot", &.{.{ .key = "snapshot.setting", .default = std.json.Value{ .bool = false } }});
    try source_registry.registerDefaultConfigurations(&.{.{ .key = "snapshot.setting", .value = std.json.Value{ .bool = true } }});
    var snapshot = try source_registry.record(allocator);

    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try std.testing.expect(service.getValue("snapshot.setting") == null);

    try registry.restore(&snapshot);
    try std.testing.expectEqual(@as(bool, true), service.getValue("snapshot.setting").?.bool);
}

test "registry default changes emit DEFAULT change events" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();

    var events = std.array_list.Managed(configuration.Change).init(allocator);
    defer events.deinit();
    const Listener = struct {
        fn onChange(change: configuration.Change, list: *std.array_list.Managed(configuration.Change)) anyerror!void {
            try list.append(change);
        }
    };
    _ = try service.onDidChange.listen(&events, Listener.onChange);

    try registry.registerConfiguration("events", &.{.{ .key = "events.setting", .default = std.json.Value{ .bool = true } }});
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(configuration.ConfigurationTarget.DEFAULT, events.items[0].source);
    try std.testing.expectEqualStrings("events.setting", events.items[0].keys[0]);
}

test "untrusted workspaces ignore restricted workspace values" {
    const allocator = std.testing.allocator;
    const registry = try configurationRegistry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test", &.{.{ .key = "restricted.setting", .default = std.json.Value{ .integer = 4 }, .restricted = true }});
    const service = try configurationService.ConfigurationService.init(allocator, registry);
    defer service.deinit();
    try service.initialize();
    try service.loadWorkspaceJson("{\"restricted.setting\":8}");
    try std.testing.expectEqual(@as(i64, 8), service.getValue("restricted.setting").?.integer);

    service.trusted = false;
    try std.testing.expectEqual(@as(i64, 4), service.getValue("restricted.setting").?.integer);
    try std.testing.expect(service.inspect("restricted.setting").workspace_value == null);
    try std.testing.expect((try service.inspectWithOverride("restricted.setting", "typescript")).workspace_value == null);
    try std.testing.expectEqual(@as(i64, 4), (try service.getValueWithOverrides("restricted.setting", "typescript")).?.integer);

    try registry.registerConfiguration("_test", &.{.{ .key = "plain.setting", .default = std.json.Value{ .integer = 1 } }});
    try service.loadWorkspaceJson("{\"restricted.setting\":8,\"plain.setting\":9,\"[typescript]\":{\"plain.setting\":7}}");
    try std.testing.expectEqual(@as(i64, 9), service.getValue("plain.setting").?.integer);
    try std.testing.expectEqual(@as(i64, 7), (try service.getValueWithOverrides("plain.setting", "typescript")).?.integer);

    service.trusted = true;
    try std.testing.expectEqual(@as(i64, 8), service.getValue("restricted.setting").?.integer);
}

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

test "isConfigurationDefaultSourceEquals" {
    const registry_mod = configuration_registry;
    try std.testing.expect(registry_mod.isConfigurationDefaultSourceEquals(null, null));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(.{ .string = "source" }, null));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(null, .{ .string = "source" }));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(.{ .extension = .{ .id = "ext" } }, null));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(null, .{ .extension = .{ .id = "ext" } }));

    try std.testing.expect(registry_mod.isConfigurationDefaultSourceEquals(.{ .string = "source" }, .{ .string = "source" }));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(.{ .string = "source1" }, .{ .string = "source2" }));
    try std.testing.expect(registry_mod.isConfigurationDefaultSourceEquals(.{ .extension = .{ .id = "ext" } }, .{ .extension = .{ .id = "ext" } }));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(.{ .extension = .{ .id = "ext1" } }, .{ .extension = .{ .id = "ext2" } }));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(.{ .string = "ext" }, .{ .extension = .{ .id = "ext" } }));
    try std.testing.expect(!registry_mod.isConfigurationDefaultSourceEquals(.{ .extension = .{ .id = "ext" } }, .{ .string = "ext" }));

    const source = registry_mod.ConfigurationDefaultSource{ .extension = .{ .id = "ext", .display_name = "Extension" } };
    try std.testing.expect(registry_mod.isConfigurationDefaultSourceEquals(source, source));
}

test "policyReference attaches subordinate settings to an owning policy" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerConfiguration("_test_default", &.{
        .{ .key = "policy.owner", .value_type = "boolean", .policy = "sharedPolicy" },
        .{ .key = "policy.subordinate", .value_type = "boolean", .policy_reference = "sharedPolicy" },
    });
    const props = registry.getConfigurationProperties();
    try std.testing.expect(props.get("policy.owner") != null);
    try std.testing.expect(props.get("policy.subordinate") != null);
    try std.testing.expectEqualStrings("policy.owner", registry.getPolicyConfigurations().get("sharedPolicy").?);
    const references = registry.getPolicyReferenceConfigurations().get("sharedPolicy").?;
    try std.testing.expectEqual(@as(usize, 1), references.items.len);
    try std.testing.expectEqualStrings("policy.subordinate", references.items[0]);
}

test "policyReference does not require its owner to be registered" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test_default", &.{
        .{ .key = "policy.orphanReference", .value_type = "boolean", .policy_reference = "externallyOwnedPolicy" },
    });
    try std.testing.expect(registry.getConfigurationProperties().get("policy.orphanReference") != null);
    try std.testing.expect(registry.getPolicyConfigurations().get("externallyOwnedPolicy") == null);
    const references = registry.getPolicyReferenceConfigurations().get("externallyOwnedPolicy").?;
    try std.testing.expectEqualStrings("policy.orphanReference", references.items[0]);
}

test "policy and policyReference on the same setting are rejected" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test_default", &.{
        .{ .key = "policy.both", .value_type = "boolean", .policy = "policyBoth", .policy_reference = "policyBothReference" },
    });
    try std.testing.expect(registry.getConfigurationProperties().get("policy.both") == null);
    try std.testing.expect(registry.getPolicyConfigurations().get("policyBoth") == null);
    try std.testing.expect(registry.getPolicyReferenceConfigurations().get("policyBothReference") == null);
}

fn defaultEntries(allocator: std.mem.Allocator, key: []const u8, text: []const u8) ![]configuration_registry.DefaultOverride {
    const entries = try allocator.alloc(configuration_registry.DefaultOverride, 1);
    entries[0] = .{ .key = key, .value = try value(allocator, text) };
    return entries;
}

test "deregister merged object default overrides" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test_default", &.{.{ .key = "config" }});

    const overrides1 = try defaultEntries(arena.allocator(), "config", "{\"a\":1,\"b\":2}");
    const overrides2 = try defaultEntries(arena.allocator(), "config", "{\"a\":2,\"c\":3}");
    const source1 = configuration_registry.ConfigurationDefaultSource{ .extension = .{ .id = "source1", .display_name = "source1" } };
    const source2 = configuration_registry.ConfigurationDefaultSource{ .extension = .{ .id = "source2", .display_name = "source2" } };
    try registry.registerDefaultConfigurationsWithSource(overrides1, source1);
    try registry.registerDefaultConfigurationsWithSource(overrides2, source2);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":2,\"b\":2,\"c\":3}", arena.allocator());

    try registry.deregisterDefaultConfigurations(overrides2, source2);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":1,\"b\":2}", arena.allocator());
    try registry.deregisterDefaultConfigurations(overrides1, source1);
    try expectDefault(registry.getConfigurationProperties(), "config", "{}", arena.allocator());
}

test "deregister merged object default overrides without source" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test_default", &.{.{ .key = "config" }});

    const overrides1 = try defaultEntries(arena.allocator(), "config", "{\"a\":1,\"b\":2}");
    const overrides2 = try defaultEntries(arena.allocator(), "config", "{\"a\":2,\"c\":3}");
    try registry.registerDefaultConfigurations(overrides1);
    try registry.registerDefaultConfigurations(overrides2);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":2,\"b\":2,\"c\":3}", arena.allocator());

    try registry.deregisterDefaultConfigurations(overrides2, null);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":1,\"b\":2}", arena.allocator());
    try registry.deregisterDefaultConfigurations(overrides1, null);
    try expectDefault(registry.getConfigurationProperties(), "config", "{}", arena.allocator());
}

test "deregister merged object default language overrides" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test_default", &.{.{ .key = "config" }});

    const overrides1 = try defaultEntries(arena.allocator(), "[lang]", "{\"config\":{\"a\":1,\"b\":2}}");
    const overrides2 = try defaultEntries(arena.allocator(), "[lang]", "{\"config\":{\"a\":2,\"c\":3}}");
    const source1 = configuration_registry.ConfigurationDefaultSource{ .string = "source1" };
    const source2 = configuration_registry.ConfigurationDefaultSource{ .string = "source2" };
    try registry.registerDefaultConfigurationsWithSource(overrides1, source1);
    try registry.registerDefaultConfigurationsWithSource(overrides2, source2);
    try expectDefault(registry.getConfigurationProperties(), "[lang]", "{\"config\":{\"a\":2,\"b\":2,\"c\":3}}", arena.allocator());

    try registry.deregisterDefaultConfigurations(overrides2, source2);
    try expectDefault(registry.getConfigurationProperties(), "[lang]", "{\"config\":{\"a\":1,\"b\":2}}", arena.allocator());
    try registry.deregisterDefaultConfigurations(overrides1, source1);
    try std.testing.expect(registry.getConfigurationProperties().get("[lang]") == null);
}

test "deregister with string and extension sources" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test_default", &.{.{ .key = "config" }});

    const overrides1 = try defaultEntries(arena.allocator(), "config", "{\"a\":1,\"b\":2}");
    const overrides2 = try defaultEntries(arena.allocator(), "config", "{\"a\":2,\"c\":3}");
    const string_source = configuration_registry.ConfigurationDefaultSource{ .string = "stringSource" };
    const extension_source = configuration_registry.ConfigurationDefaultSource{ .extension = .{ .id = "extSource", .display_name = "Extension Source" } };
    try registry.registerDefaultConfigurationsWithSource(overrides1, string_source);
    try registry.registerDefaultConfigurationsWithSource(overrides2, extension_source);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":2,\"b\":2,\"c\":3}", arena.allocator());

    try registry.deregisterDefaultConfigurations(overrides1, string_source);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":2,\"c\":3}", arena.allocator());
    try registry.deregisterDefaultConfigurations(overrides2, extension_source);
    try expectDefault(registry.getConfigurationProperties(), "config", "{}", arena.allocator());
}

test "hidden properties and node deregistration" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerConfiguration("_test_restore", &.{
        .{ .key = "restore.overridden", .value_type = "boolean", .default = std.json.Value{ .bool = false } },
        .{ .key = "restore.hiddenMirrored", .value_type = "string", .default = std.json.Value{ .string = "" }, .included = false, .agent_host_key = "restore.hiddenMirrored" },
        .{ .key = "restore.hiddenExperiment", .value_type = "boolean", .default = std.json.Value{ .bool = false }, .included = false, .experiment_mode = "auto" },
    });
    try registry.registerDefaultConfigurations(&.{.{ .key = "restore.overridden", .value = std.json.Value{ .bool = true } }});

    try std.testing.expectEqual(@as(bool, true), registry.getConfigurationProperties().get("restore.overridden").?.default.bool);
    const mirrored = registry.getAgentHostSyncConfigurations().get("restore.hiddenMirrored").?;
    try std.testing.expectEqualStrings("restore.hiddenMirrored", mirrored.key);
    const experiment = registry.getExcludedConfigurationProperties().get("restore.hiddenExperiment").?;
    try std.testing.expectEqualStrings("auto", experiment.experiment_mode.?);

    const registered = try registry.getRegisteredDefaultConfigurations(allocator);
    defer allocator.free(registered);
    try registry.deregisterDefaultConfigurations(registered, null);
    try std.testing.expectEqual(@as(bool, false), registry.getConfigurationProperties().get("restore.overridden").?.default.bool);
    try std.testing.expect(registry.getAgentHostSyncConfigurations().get("restore.hiddenMirrored") != null);

    registry.deregisterConfigurations("_test_restore");
    try std.testing.expect(registry.getConfigurationProperties().get("restore.overridden") == null);
    try std.testing.expect(registry.getAgentHostSyncConfigurations().get("restore.hiddenMirrored") == null);
    try std.testing.expect(registry.getExcludedConfigurationProperties().get("restore.hiddenExperiment") == null);
}

test "configuration defaults track their string source" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("_test_default", &.{.{ .key = "config" }});

    const overrides1 = try defaultEntries(arena.allocator(), "config", "{\"a\":1,\"b\":2}");
    const overrides2 = try defaultEntries(arena.allocator(), "config", "{\"a\":2,\"c\":3}");
    const source1 = configuration_registry.ConfigurationDefaultSource{ .string = "source1" };
    const source2 = configuration_registry.ConfigurationDefaultSource{ .string = "source2" };
    try registry.registerDefaultConfigurationsWithSource(overrides1, source1);
    try registry.registerDefaultConfigurationsWithSource(overrides2, source2);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":2,\"b\":2,\"c\":3}", arena.allocator());
    try std.testing.expect(registry.getConfigurationProperties().get("config").?.default_value_source != null);
    try std.testing.expect(std.mem.eql(u8, registry.getConfigurationProperties().get("config").?.default_value_source.?.string, "source2"));

    try registry.deregisterDefaultConfigurations(overrides2, source2);
    try expectDefault(registry.getConfigurationProperties(), "config", "{\"a\":1,\"b\":2}", arena.allocator());
    try std.testing.expect(std.mem.eql(u8, registry.getConfigurationProperties().get("config").?.default_value_source.?.string, "source1"));
    try registry.deregisterDefaultConfigurations(overrides1, source1);
    try expectDefault(registry.getConfigurationProperties(), "config", "{}", arena.allocator());
    try std.testing.expect(registry.getConfigurationProperties().get("config").?.default_value_source == null);
}

test "record and restore keep declared defaults, hidden settings and contributions" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source_registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer source_registry.deinit();
    try source_registry.registerConfiguration("restore.node", &.{
        .{ .key = "restore.overridden", .value_type = "boolean", .default = std.json.Value{ .bool = false } },
        .{ .key = "restore.hidden", .value_type = "string", .included = false, .agent_host_key = "restore.hidden", .policy = "restorePolicy" },
        .{ .key = "restore.ref", .value_type = "boolean", .default = std.json.Value{ .bool = true }, .policy_reference = "restoreRef" },
    });
    try source_registry.registerDefaultConfigurations(&.{.{ .key = "restore.overridden", .value = std.json.Value{ .bool = true } }});
    try source_registry.registerDefaultsJson("{\"[typescript]\":{\"editor.tabSize\":2}}");

    var snapshot = try source_registry.record(allocator);

    const restored = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer restored.deinit();
    try restored.restore(&snapshot);

    try std.testing.expectEqual(@as(bool, true), restored.getConfigurationProperties().get("restore.overridden").?.default.bool);
    try std.testing.expect(restored.getExcludedConfigurationProperties().get("restore.hidden") != null);
    try std.testing.expect(restored.getAgentHostSyncConfigurations().get("restore.hidden") != null);
    try std.testing.expect(restored.getPolicyConfigurations().get("restorePolicy") != null);
    var base = try restored.buildDefaultModel(allocator);
    defer base.deinit();
    var overridden = try base.override(allocator, "typescript");
    defer overridden.deinit();
    try std.testing.expectEqual(@as(i64, 2), overridden.getValue("editor.tabSize").?.integer);
    const references = restored.getPolicyReferenceConfigurations().get("restoreRef").?;
    try std.testing.expectEqual(@as(usize, 1), references.items.len);
    try std.testing.expectEqualStrings("restore.ref", references.items[0]);

    const entries = try restored.getRegisteredDefaultConfigurations(allocator);
    defer allocator.free(entries);
    try restored.deregisterDefaultConfigurations(entries, null);
    try std.testing.expectEqual(@as(bool, false), restored.getConfigurationProperties().get("restore.overridden").?.default.bool);
    try std.testing.expect(restored.getExcludedConfigurationProperties().get("restore.hidden") != null);

    restored.deregisterConfigurations("restore.node");
    try std.testing.expect(restored.getConfigurationProperties().get("restore.overridden") == null);
    try std.testing.expect(restored.getExcludedConfigurationProperties().get("restore.hidden") == null);
    try std.testing.expect(restored.getAgentHostSyncConfigurations().get("restore.hidden") == null);
}

test "duplicate property registration keeps the first schema" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("dup", &.{.{
        .key = "dup.setting",
        .value_type = "boolean",
        .default = std.json.Value{ .bool = true },
        .policy = "dupPolicy",
    }});
    try registry.registerConfiguration("dup", &.{.{
        .key = "dup.setting",
        .value_type = "string",
        .default = std.json.Value{ .string = "second" },
    }});
    const property = registry.getConfigurationProperties().get("dup.setting").?;
    try std.testing.expectEqualStrings("boolean", property.value_type);
    try std.testing.expectEqual(@as(bool, true), property.default.bool);
    try std.testing.expectEqualStrings("dupPolicy", property.policy.?);
}

test "policy and policy reference registrations are tracked" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("policy", &.{
        .{ .key = "policy.setting", .default = std.json.Value{ .bool = true }, .policy = "policyName" },
        .{ .key = "reference.setting", .default = std.json.Value{ .bool = true }, .policy_reference = "referenceName" },
        .{ .key = "both.setting", .default = std.json.Value{ .bool = true }, .policy = "policyName", .policy_reference = "referenceName" },
    });
    try std.testing.expectEqualStrings("policy.setting", registry.getPolicyConfigurations().get("policyName").?);
    try std.testing.expect(registry.getPolicyReferenceConfigurations().get("referenceName") != null);
    try std.testing.expect(registry.getConfigurationProperties().get("both.setting") == null);
}

test "policy reference lists accumulate keys" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("refs", &.{
        .{ .key = "ref.one", .default = std.json.Value{ .bool = true }, .policy_reference = "shared" },
        .{ .key = "ref.two", .default = std.json.Value{ .bool = true }, .policy_reference = "shared" },
    });
    const list = registry.getPolicyReferenceConfigurations().get("shared").?;
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("ref.one", list.items[0]);
    try std.testing.expectEqualStrings("ref.two", list.items[1]);
}

test "discarding a registry snapshot frees its state" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("discard", &.{.{ .key = "discard.setting", .default = std.json.Value{ .bool = true } }});
    try registry.registerDefaultsJson("{\"discard.setting\":false}");
    var snapshot = try registry.record(allocator);
    snapshot.deinit();
}

test "deregistering a node clears owner policies and reference keys" {
    const allocator = std.testing.allocator;
    const registry = try configuration_registry.ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerConfiguration("owner", &.{.{
        .key = "policy.owner",
        .value_type = "boolean",
        .default = std.json.Value{ .bool = true },
        .policy = "SharedPolicy",
    }});
    try registry.registerConfiguration("reference", &.{.{
        .key = "policy.reference",
        .value_type = "boolean",
        .default = std.json.Value{ .bool = true },
        .policy_reference = "SharedPolicy",
    }});
    try std.testing.expect(registry.getPolicyConfigurations().get("SharedPolicy") != null);
    registry.deregisterConfigurations("owner");
    try std.testing.expect(registry.getPolicyConfigurations().get("SharedPolicy") == null);
    const references = registry.getPolicyReferenceConfigurations().get("SharedPolicy").?;
    try std.testing.expectEqual(@as(usize, 1), references.items.len);
    try std.testing.expectEqualStrings("policy.reference", references.items[0]);
}

// Port of the ConfigurationModel parsing cases of
// `src/vs/platform/configuration/test/common/configurationModels.test.ts`.
// The scope-filter cases need the configuration registry and are not ported.
const std = @import("std");
const configuration_models = @import("../../common/configurationModels.zig");

test "parse configuration model with single override identifier" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"[x]\":{\"a\":1}}");
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 1), model.overrides.len);
    try std.testing.expectEqual(@as(usize, 1), model.overrides[0].identifiers.len);
    try std.testing.expectEqualStrings("x", model.overrides[0].identifiers[0]);
    try std.testing.expectEqual(@as(usize, 1), model.overrides[0].keys.len);
    try std.testing.expectEqualStrings("a", model.overrides[0].keys[0]);
    try std.testing.expectEqual(@as(i64, 1), model.overrides[0].contents.object.get("a").?.integer);
}

test "parse configuration model with multiple override identifiers" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"[x][y]\":{\"a\":1}}");
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 2), model.overrides[0].identifiers.len);
    try std.testing.expectEqualStrings("x", model.overrides[0].identifiers[0]);
    try std.testing.expectEqualStrings("y", model.overrides[0].identifiers[1]);
}

test "parse configuration model with duplicate override identifiers" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"[x][y][x][z]\":{\"a\":1}}");
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 3), model.overrides[0].identifiers.len);
    try std.testing.expectEqualStrings("x", model.overrides[0].identifiers[0]);
    try std.testing.expectEqualStrings("y", model.overrides[0].identifiers[1]);
    try std.testing.expectEqualStrings("z", model.overrides[0].identifiers[2]);
}

test "parse configuration model with exclude option" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a\":1,\"b\":2}", .{ .exclude = &.{"a"} });
    defer model.deinit();
    try std.testing.expect(model.getValue("a") == null);
    try std.testing.expectEqual(@as(i64, 2), model.getValue("b").?.integer);
}

test "parse configuration model with exclude option even included" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a\":1,\"b\":2}", .{ .exclude = &.{"a"}, .include = &.{"a"} });
    defer model.deinit();
    try std.testing.expect(model.getValue("a") == null);
    try std.testing.expectEqual(@as(i64, 2), model.getValue("b").?.integer);
}

test "parse configuration model with invalid setting key" {
    const allocator = std.testing.allocator;
    var model = try configuration_models.ConfigurationModel.fromJson(allocator, "{\"a\":null,\"a.b.c\":{\"c\":1}}");
    defer model.deinit();
    try std.testing.expect(model.getValue("a").?.* == .null);
    try std.testing.expect(model.getValue("a.b") == null);
    try std.testing.expect(model.getValue("a.b.c") == null);
}

fn expectKeys(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_key, actual_key| {
        try std.testing.expectEqualStrings(expected_key, actual_key);
    }
}

fn modelWithOverride(
    allocator: std.mem.Allocator,
    value_text: []const u8,
    keys: []const []const u8,
    identifier: []const u8,
    override_text: []const u8,
    override_keys: []const []const u8,
) !configuration_models.ConfigurationModel {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value_text, .{});
    const override_value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), override_text, .{});
    const identifiers = [_][]const u8{identifier};
    const overrides = [_]configuration_models.OverrideIdentifier{.{ .identifiers = &identifiers, .keys = override_keys, .contents = override_value }};
    return configuration_models.ConfigurationModel.initWithOverrides(allocator, value, keys, &overrides);
}

fn modelFrom(allocator: std.mem.Allocator, text: []const u8, keys: []const []const u8) !configuration_models.ConfigurationModel {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    return configuration_models.ConfigurationModel.init(allocator, value, keys);
}

test "setValue for keys with and without sections" {
    const allocator = std.testing.allocator;
    {
        var model = try modelFrom(allocator, "{\"a\":{\"b\":1}}", &.{"a.b"});
        defer model.deinit();
        try model.setValue("f", .{ .integer = 1 });
        try std.testing.expectEqual(@as(i64, 1), model.getValue("a.b").?.integer);
        try std.testing.expectEqual(@as(i64, 1), model.getValue("f").?.integer);
        try expectKeys(&.{ "a.b", "f" }, model.getKeys());
    }
    {
        var model = try modelFrom(allocator, "{\"a\":{\"b\":1},\"f\":1}", &.{ "a.b", "f" });
        defer model.deinit();
        try model.setValue("f", .{ .integer = 3 });
        try std.testing.expectEqual(@as(i64, 3), model.getValue("f").?.integer);
        try expectKeys(&.{ "a.b", "f" }, model.getKeys());
    }
    {
        var model = try modelFrom(allocator, "{\"a\":{\"b\":1},\"f\":1}", &.{ "a.b", "f" });
        defer model.deinit();
        try model.setValue("b.c", .{ .integer = 1 });
        try std.testing.expectEqual(@as(i64, 1), model.getValue("b.c").?.integer);
        try expectKeys(&.{ "a.b", "f", "b.c" }, model.getKeys());
    }
    {
        var model = try modelFrom(allocator, "{\"a\":{\"b\":1},\"b\":{\"c\":1},\"f\":1}", &.{ "a.b", "b.c", "f" });
        defer model.deinit();
        try model.setValue("b.c", .{ .integer = 3 });
        try std.testing.expectEqual(@as(i64, 3), model.getValue("b.c").?.integer);
        try expectKeys(&.{ "a.b", "b.c", "f" }, model.getKeys());
    }
    {
        var model = try modelFrom(allocator, "{\"a\":{\"b\":1},\"f\":1}", &.{ "a.b", "f" });
        defer model.deinit();
        try model.setValue("a.c", .{ .integer = 1 });
        try std.testing.expectEqual(@as(i64, 1), model.getValue("a.c").?.integer);
        try expectKeys(&.{ "a.b", "f", "a.c" }, model.getKeys());
    }
}

test "removeValue removes segmented keys" {
    const allocator = std.testing.allocator;
    {
        var model = try modelFrom(allocator, "{\"a\":{\"b\":2}}", &.{"a.b"});
        defer model.deinit();
        model.removeValue("a.b.c");
        try std.testing.expectEqual(@as(i64, 2), model.getValue("a.b").?.integer);
        try expectKeys(&.{"a.b"}, model.getKeys());
    }
    {
        var model = try modelFrom(allocator, "{\"a\":1}", &.{"a"});
        defer model.deinit();
        model.removeValue("a");
        try std.testing.expect(model.getValue("a") == null);
        try std.testing.expectEqual(@as(usize, 0), model.getKeys().len);
    }
    {
        var model = try modelFrom(allocator, "{\"a\":{\"b\":1}}", &.{"a.b"});
        defer model.deinit();
        model.removeValue("a.b");
        try std.testing.expect(model.getValue("a.b") == null);
        try std.testing.expectEqual(@as(usize, 0), model.getKeys().len);
    }
}

test "get overriding configuration model" {
    const allocator = std.testing.allocator;
    {
        var model = try modelWithOverride(allocator, "{\"a\":{\"b\":1},\"f\":1}", &.{}, "c", "{\"a\":{\"d\":1}}", &.{"a"});
        defer model.deinit();
        var overridden = try model.override(allocator, "c");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("a.b").?.integer);
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("a.d").?.integer);
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("f").?.integer);

        var missing = try model.override(allocator, "xyz");
        defer missing.deinit();
        try std.testing.expectEqual(@as(i64, 1), missing.getValue("a.b").?.integer);
        try std.testing.expect(missing.getValue("a.d") == null);
    }
    {
        var model = try modelWithOverride(allocator, "{\"a\":{\"b\":1},\"f\":1}", &.{}, "c", "{\"a\":{\"d\":1},\"g\":1}", &.{ "a", "g" });
        defer model.deinit();
        var overridden = try model.override(allocator, "c");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("g").?.integer);
    }
    {
        var model = try modelWithOverride(allocator, "{\"a\":{\"b\":1},\"f\":1}", &.{}, "c", "{\"a\":{\"d\":1},\"f\":{\"g\":1}}", &.{ "a", "f" });
        defer model.deinit();
        var overridden = try model.override(allocator, "c");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("f.g").?.integer);
    }
    {
        var model = try modelWithOverride(allocator, "{\"a\":{\"b\":1},\"f\":{\"g\":1}}", &.{}, "c", "{\"a\":{\"d\":1},\"f\":1}", &.{ "a", "f" });
        defer model.deinit();
        var overridden = try model.override(allocator, "c");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("f").?.integer);
    }
}

test "simple merge" {
    const allocator = std.testing.allocator;
    var base = try modelFrom(allocator, "{\"a\":1,\"b\":2}", &.{ "a", "b" });
    defer base.deinit();
    var add = try modelFrom(allocator, "{\"a\":3,\"c\":4}", &.{ "a", "c" });
    defer add.deinit();
    const models = [_]*const configuration_models.ConfigurationModel{ &base, &add };
    var result = try configuration_models.ConfigurationModel.merge(allocator, &models);
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 3), result.getValue("a").?.integer);
    try std.testing.expectEqual(@as(i64, 2), result.getValue("b").?.integer);
    try std.testing.expectEqual(@as(i64, 4), result.getValue("c").?.integer);
    try expectKeys(&.{ "a", "b", "c" }, result.getKeys());
}

const OverrideSpec = struct {
    identifiers: []const []const u8,
    contents: []const u8,
    keys: []const []const u8,
};

fn modelWithOverrides(allocator: std.mem.Allocator, value_text: []const u8, keys: []const []const u8, specs: []const OverrideSpec) !configuration_models.ConfigurationModel {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), value_text, .{});
    var overrides = std.array_list.Managed(configuration_models.OverrideIdentifier).init(arena.allocator());
    for (specs) |spec| {
        try overrides.append(.{
            .identifiers = spec.identifiers,
            .keys = spec.keys,
            .contents = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), spec.contents, .{}),
        });
    }
    return configuration_models.ConfigurationModel.initWithOverrides(allocator, value, keys, overrides.items);
}

test "merge overrides" {
    const allocator = std.testing.allocator;
    {
        var base = try modelWithOverrides(allocator, "{\"a\":{\"b\":1}}", &.{"a.b"}, &.{.{ .identifiers = &.{"c"}, .contents = "{\"a\":2}", .keys = &.{"a"} }});
        defer base.deinit();
        var add = try modelWithOverrides(allocator, "{\"a\":{\"b\":2}}", &.{"a.b"}, &.{.{ .identifiers = &.{"c"}, .contents = "{\"b\":2}", .keys = &.{"b"} }});
        defer add.deinit();
        const models = [_]*const configuration_models.ConfigurationModel{ &base, &add };
        var result = try configuration_models.ConfigurationModel.merge(allocator, &models);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.overrides.len);
        try std.testing.expectEqual(@as(i64, 2), result.overrides[0].contents.object.get("a").?.integer);
        try std.testing.expectEqual(@as(i64, 2), result.overrides[0].contents.object.get("b").?.integer);
        var overridden = try result.override(allocator, "c");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 2), overridden.getValue("a").?.integer);
        try std.testing.expectEqual(@as(i64, 2), overridden.getValue("b").?.integer);
        try expectKeys(&.{"a.b"}, result.getKeys());
    }
    {
        var base = try modelWithOverrides(allocator, "{\"a\":{\"b\":1},\"f\":1}", &.{ "a.b", "f" }, &.{.{ .identifiers = &.{"c"}, .contents = "{\"a\":{\"d\":1}}", .keys = &.{"a"} }});
        defer base.deinit();
        var add = try modelWithOverrides(allocator, "{\"a\":{\"b\":2}}", &.{"a.b"}, &.{.{ .identifiers = &.{"c"}, .contents = "{\"a\":{\"e\":2}}", .keys = &.{"a"} }});
        defer add.deinit();
        const models = [_]*const configuration_models.ConfigurationModel{ &base, &add };
        var result = try configuration_models.ConfigurationModel.merge(allocator, &models);
        defer result.deinit();
        var overridden = try result.override(allocator, "c");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 2), overridden.getValue("a.b").?.integer);
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("a.d").?.integer);
        try std.testing.expectEqual(@as(i64, 2), overridden.getValue("a.e").?.integer);
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("f").?.integer);
    }
}

test "override identifiers and multiple overrides" {
    const allocator = std.testing.allocator;
    {
        var model = try modelWithOverrides(allocator, "{\"a\":1,\"c\":1}", &.{ "a", "c" }, &.{.{ .identifiers = &.{ "x", "y" }, .contents = "{\"a\":2}", .keys = &.{"a"} }});
        defer model.deinit();
        var overridden = try model.override(allocator, "x");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 2), overridden.getValue("a").?.integer);
        const keys = try model.getKeysForOverrideIdentifier(allocator, "y");
        defer allocator.free(keys);
        try std.testing.expectEqual(@as(usize, 1), keys.len);
        try std.testing.expectEqualStrings("a", keys[0]);
    }
    {
        var model = try modelWithOverrides(allocator, "{\"a\":1,\"c\":1}", &.{ "a", "c" }, &.{
            .{ .identifiers = &.{"x"}, .contents = "{\"a\":3,\"b\":1}", .keys = &.{ "a", "b" } },
            .{ .identifiers = &.{ "x", "y" }, .contents = "{\"a\":2}", .keys = &.{"a"} },
        });
        defer model.deinit();
        var overridden = try model.override(allocator, "x");
        defer overridden.deinit();
        try std.testing.expectEqual(@as(i64, 3), overridden.getValue("a").?.integer);
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("b").?.integer);
        try std.testing.expectEqual(@as(i64, 1), overridden.getValue("c").?.integer);
        const keys = try model.getKeysForOverrideIdentifier(allocator, "x");
        defer allocator.free(keys);
        try std.testing.expectEqual(@as(usize, 2), keys.len);
        try std.testing.expectEqualStrings("a", keys[0]);
        try std.testing.expectEqualStrings("b", keys[1]);
    }
}

test "parse configuration model with scope and registration filters" {
    const allocator = std.testing.allocator;
    const schemas = [_]configuration_models.PropertySchemaEntry{
        .{ .key = "windowSetting", .scope = .WINDOW },
        .{ .key = "appSetting", .scope = .APPLICATION },
        .{ .key = "restrictedSetting", .scope = .WINDOW, .restricted = true },
    };

    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"windowSetting\":\"1\"}", .{ .scopes = &.{.APPLICATION}, .schemas = &schemas });
        defer model.deinit();
        try std.testing.expect(model.getValue("windowSetting") == null);
    }
    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"windowSetting\":\"1\"}", .{ .include = &.{"windowSetting"}, .scopes = &.{.APPLICATION}, .schemas = &schemas });
        defer model.deinit();
        try std.testing.expectEqualStrings("1", model.getValue("windowSetting").?.string);
    }
    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"windowSetting\":\"1\",\"unregistered\":true}", .{ .skip_unregistered = true, .schemas = &schemas });
        defer model.deinit();
        try std.testing.expect(model.getValue("unregistered") == null);
        try std.testing.expect(model.getValue("windowSetting") != null);
    }
    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"restrictedSetting\":true,\"windowSetting\":\"1\"}", .{ .skip_restricted = true, .schemas = &schemas });
        defer model.deinit();
        try std.testing.expect(model.getValue("restrictedSetting") == null);
        try std.testing.expect(model.getValue("windowSetting") != null);
    }
}

test "nested restricted and scoped settings are filtered" {
    const allocator = std.testing.allocator;
    const schemas = [_]configuration_models.PropertySchemaEntry{
        .{ .key = "a.b", .restricted = true },
        .{ .key = "a.machine", .scope = .MACHINE },
    };
    {
        var dotted = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a.b\":1,\"a.c\":2}", .{ .skip_restricted = true, .schemas = &schemas });
        defer dotted.deinit();
        var nested = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a\":{\"b\":1,\"c\":2}}", .{ .skip_restricted = true, .schemas = &schemas });
        defer nested.deinit();
        try std.testing.expect(dotted.getValue("a.b") == null);
        try std.testing.expect(nested.getValue("a.b") == null);
        try std.testing.expectEqual(@as(i64, 2), dotted.getValue("a.c").?.integer);
        try std.testing.expectEqual(@as(i64, 2), nested.getValue("a.c").?.integer);
    }
    {
        const restricted_parent = [_]configuration_models.PropertySchemaEntry{.{ .key = "a", .restricted = true }};
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a\":{\"b\":1},\"c\":2}", .{ .skip_restricted = true, .schemas = &restricted_parent });
        defer model.deinit();
        try std.testing.expect(model.getValue("a") == null);
        try std.testing.expectEqual(@as(i64, 2), model.getValue("c").?.integer);
    }
    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(allocator, "{\"a\":{\"machine\":1,\"allowed\":2}}", .{ .scopes = &.{.WINDOW}, .schemas = &schemas });
        defer model.deinit();
        try std.testing.expect(model.getValue("a.machine") == null);
        try std.testing.expectEqual(@as(i64, 2), model.getValue("a.allowed").?.integer);
    }
}

test "excluded property schemas bypass skipRestricted but respect scope" {
    const allocator = std.testing.allocator;
    const schemas = [_]configuration_models.PropertySchemaEntry{
        .{ .key = "regularProperty" },
        .{ .key = "restrictedProperty", .restricted = true },
    };
    const excluded = [_]configuration_models.PropertySchemaEntry{
        .{ .key = "excludedProperty", .restricted = true },
        .{ .key = "excludedNonRestrictedProperty" },
        .{ .key = "excludedApplicationProperty", .scope = .APPLICATION },
    };
    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(
            allocator,
            "{\"regularProperty\":\"regularValue\",\"restrictedProperty\":\"restrictedValue\",\"excludedProperty\":\"excludedValue\",\"excludedNonRestrictedProperty\":\"excludedNonRestrictedValue\"}",
            .{ .skip_restricted = true, .schemas = &schemas, .excluded_schemas = &excluded },
        );
        defer model.deinit();
        try std.testing.expectEqualStrings("regularValue", model.getValue("regularProperty").?.string);
        try std.testing.expect(model.getValue("restrictedProperty") == null);
        try std.testing.expectEqualStrings("excludedValue", model.getValue("excludedProperty").?.string);
        try std.testing.expectEqualStrings("excludedNonRestrictedValue", model.getValue("excludedNonRestrictedProperty").?.string);
    }
    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(
            allocator,
            "{\"regularProperty\":\"regularValue\",\"excludedApplicationProperty\":\"excludedApplicationValue\"}",
            .{ .scopes = &.{.WINDOW}, .schemas = &schemas, .excluded_schemas = &excluded },
        );
        defer model.deinit();
        try std.testing.expectEqualStrings("regularValue", model.getValue("regularProperty").?.string);
        try std.testing.expect(model.getValue("excludedApplicationProperty") == null);
    }
    {
        var model = try configuration_models.ConfigurationModel.fromJsonWithOptions(
            allocator,
            "{\"regularProperty\":\"regularValue\",\"excludedProperty\":\"excludedValue\"}",
            .{ .include = &.{"excludedProperty"}, .schemas = &schemas, .excluded_schemas = &excluded },
        );
        defer model.deinit();
        try std.testing.expectEqualStrings("regularValue", model.getValue("regularProperty").?.string);
        try std.testing.expectEqualStrings("excludedValue", model.getValue("excludedProperty").?.string);
    }
}

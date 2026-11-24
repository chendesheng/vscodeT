// Port of the default/scope subset of
// `src/vs/workbench/api/common/configurationExtensionPoint.ts`.
//
// Extension contributions are parsed before the extension host starts so the
// host's `workspace.getConfiguration()` sees the same defaults as VS Code.
// Schema validation, NLS translations, policy metadata and the Settings editor
// projection are not ported; a value keeps its literal manifest default.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configuration = @import("../../../platform/configuration/common/configuration.zig");
const configurationRegistry = @import("../../../platform/configuration/common/configurationRegistry.zig");

const ConfigurationRegistry = configurationRegistry.ConfigurationRegistry;
const ConfigurationScope = configuration.ConfigurationScope;
const PropertySchema = configurationRegistry.PropertySchema;
const DefaultOverride = configurationRegistry.DefaultOverride;

/// Registers `contributes.configuration` and `contributes.configurationDefaults`
/// from one extension manifest. Invalid nodes are skipped, like upstream's
/// collector (a bad contribution must not invalidate the extension).
pub fn registerManifest(
    registry: *ConfigurationRegistry,
    manifest: std.json.Value,
    extension_id: []const u8,
) !void {
    if (manifest != .object) return;
    const contributes = manifest.object.get("contributes") orelse return;
    if (contributes != .object) return;
    if (contributes.object.get("configuration")) |value| {
        try registerConfigurationValue(registry, value, extension_id);
    }
    if (contributes.object.get("configurationDefaults")) |value| {
        try registerConfigurationDefaults(registry, value);
    }
}

pub fn registerConfigurationValue(
    registry: *ConfigurationRegistry,
    value: std.json.Value,
    extension_id: []const u8,
) !void {
    switch (value) {
        .object => try registerNode(registry, value.object, extension_id),
        .array => |array| {
            for (array.items) |item| {
                if (item != .object) continue;
                try registerNode(registry, item.object, extension_id);
            }
        },
        else => {},
    }
}

fn registerNode(
    registry: *ConfigurationRegistry,
    node: std.json.ObjectMap,
    extension_id: []const u8,
) !void {
    const properties_value = node.get("properties") orelse return;
    if (properties_value != .object) return;

    var arena = std.heap.ArenaAllocator.init(registry.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var properties = std.array_list.Managed(PropertySchema).init(scratch);

    var iterator = properties_value.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len == 0) continue;
        if (entry.value_ptr.* != .object) continue;
        const property = entry.value_ptr.object;
        const value_type = schemaType(property.get("type"));
        const default_value = property.get("default");
        const scope = if (property.get("scope")) |scope_value|
            if (scope_value == .string) parseScope(scope_value.string) else .WINDOW
        else
            .WINDOW;
        const included = if (property.get("included")) |included_value|
            included_value != .bool or included_value.bool
        else
            true;
        try properties.append(.{
            .key = try scratch.dupe(u8, key),
            .value_type = value_type,
            .default = if (default_value) |item| try configuration.cloneValue(scratch, item) else null,
            .scope = scope,
            .included = included,
            .restricted = boolField(property, "restricted"),
            .disallow_configuration_default = boolField(property, "disallowConfigurationDefault"),
        });
    }

    if (properties.items.len > 0) {
        try registry.registerConfiguration(extension_id, properties.items);
    }
}

pub fn registerConfigurationDefaults(
    registry: *ConfigurationRegistry,
    value: std.json.Value,
) !void {
    if (value != .object) return;
    var arena = std.heap.ArenaAllocator.init(registry.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var overrides = std.array_list.Managed(DefaultOverride).init(scratch);
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        try overrides.append(.{
            .key = try scratch.dupe(u8, entry.key_ptr.*),
            .value = try configuration.cloneValue(scratch, entry.value_ptr.*),
        });
    }
    if (overrides.items.len > 0) {
        try registry.registerDefaultConfigurations(overrides.items);
    }
}

fn schemaType(value: ?std.json.Value) []const u8 {
    const item = value orelse return "object";
    switch (item) {
        .string => |name| return name,
        .array => |array| {
            for (array.items) |candidate| {
                if (candidate == .string) return candidate.string;
            }
        },
        else => {},
    }
    return "object";
}

fn boolField(object: std.json.ObjectMap, name: []const u8) bool {
    const value = object.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn parseScope(value: []const u8) ConfigurationScope {
    if (std.mem.eql(u8, value, "application")) return .APPLICATION;
    if (std.mem.eql(u8, value, "machine")) return .MACHINE;
    if (std.mem.eql(u8, value, "machine-overridable")) return .MACHINE_OVERRIDABLE;
    if (std.mem.eql(u8, value, "resource")) return .RESOURCE;
    if (std.mem.eql(u8, value, "language-overridable")) return .LANGUAGE_OVERRIDABLE;
    return .WINDOW;
}

test "configuration extension point registers defaults and scopes" {
    const allocator = std.testing.allocator;
    const registry = try ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    const manifest =
        \\{
        \\  "contributes": {
        \\    "configuration": [
        \\      { "properties": {
        \\          "js/ts.format.enabled": { "type": "boolean", "default": true, "scope": "language-overridable" },
        \\          "js/ts.validate.enabled": { "type": "boolean", "default": true }
        \\      } }
        \\    ],
        \\    "configurationDefaults": {
        \\      "files.eol": "\n"
        \\    }
        \\  }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest, .{});
    defer parsed.deinit();
    try registerManifest(registry, parsed.value, "vscode.typescript-language-features");

    var model = try registry.buildDefaultModel(allocator);
    defer model.deinit();
    try std.testing.expect(model.getValue("js/ts.format.enabled").?.bool);
    try std.testing.expect(model.getValue("js/ts.validate.enabled").?.bool);
    try std.testing.expectEqualStrings("\n", model.getValue("files.eol").?.string);
    try std.testing.expectEqual(
        ConfigurationScope.LANGUAGE_OVERRIDABLE,
        registry.getConfigurationProperties().get("js/ts.format.enabled").?.scope,
    );
}

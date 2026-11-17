// Port of the default-configuration subset of
// `src/vs/platform/configuration/common/configurationRegistry.ts`.
//
// Upstream keeps a global registry of JSON schemas, default values, policy
// metadata and experiment overrides. This port keeps an owned registry of
// default settings documents and the configuration scope enum; schema
// validation, policy/experiment metadata, excluded properties and the Settings
// editor schema are not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const configurationModels = @import("./configurationModels.zig");
const ConfigurationModel = configurationModels.ConfigurationModel;

pub const ConfigurationScope = enum(u8) {
    APPLICATION = 1,
    MACHINE,
    APPLICATION_MACHINE,
    WINDOW,
    RESOURCE,
    LANGUAGE_OVERRIDABLE,
    MACHINE_OVERRIDABLE,
};

pub const PropertySchema = struct {
    key: []const u8,
    value_type: []const u8 = "object",
    default: ?std.json.Value = null,
    scope: ConfigurationScope = .WINDOW,
    restricted: bool = false,
    disallow_configuration_default: bool = false,
    policy: ?[]const u8 = null,
};

pub const Property = struct {
    value_type: []const u8,
    default: std.json.Value = .null,
    scope: ConfigurationScope = .WINDOW,
    restricted: bool = false,
    disallow_configuration_default: bool = false,
    policy: ?[]const u8 = null,
};

pub const DefaultOverride = struct {
    key: []const u8,
    value: std.json.Value,
};

pub const ConfigurationRegistry = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    defaults: std.array_list.Managed(*ConfigurationModel),
    properties: std.StringHashMap(Property),
    policies: std.StringHashMap(void),

    pub fn init(allocator: Allocator) !*ConfigurationRegistry {
        const self = try allocator.create(ConfigurationRegistry);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .defaults = std.array_list.Managed(*ConfigurationModel).init(allocator),
            .properties = std.StringHashMap(Property).init(allocator),
            .policies = std.StringHashMap(void).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *ConfigurationRegistry) void {
        for (self.defaults.items) |model| {
            model.deinit();
            self.allocator.destroy(model);
        }
        self.defaults.deinit();
        self.properties.deinit();
        self.policies.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Registers configuration properties. A property whose policy name was
    /// already registered is skipped (upstream logs and ignores it).
    pub fn registerConfiguration(self: *ConfigurationRegistry, id: []const u8, properties: []const PropertySchema) !void {
        _ = id;
        const arena = self.arena.allocator();
        for (properties) |schema| {
            if (schema.policy) |policy| {
                if (self.policies.contains(policy)) continue;
                try self.policies.put(try arena.dupe(u8, policy), {});
            }
            const default_value = if (schema.default) |value| try cloneValue(arena, value) else std.json.Value.null;
            try self.properties.put(try arena.dupe(u8, schema.key), .{
                .value_type = try arena.dupe(u8, schema.value_type),
                .default = default_value,
                .scope = schema.scope,
                .restricted = schema.restricted,
                .disallow_configuration_default = schema.disallow_configuration_default,
                .policy = if (schema.policy) |policy| try arena.dupe(u8, policy) else null,
            });
        }
    }

    /// Merges registered default overrides into the property defaults. Later
    /// object defaults merge recursively; a disallowing property is untouched.
    pub fn registerDefaultConfigurations(self: *ConfigurationRegistry, overrides: []const DefaultOverride) !void {
        const arena = self.arena.allocator();
        for (overrides) |override_value| {
            const entry = try self.properties.getOrPut(try arena.dupe(u8, override_value.key));
            if (!entry.found_existing) {
                entry.value_ptr.* = .{ .value_type = "object" };
            }
            const property = entry.value_ptr;
            if (property.disallow_configuration_default) continue;
            switch (property.default) {
                .object => {
                    if (override_value.value == .object) {
                        try mergeObjects(arena, &property.default, override_value.value);
                    } else {
                        property.default = try cloneValue(arena, override_value.value);
                    }
                },
                else => property.default = try cloneValue(arena, override_value.value),
            }
        }
    }

    pub fn getConfigurationProperties(self: *ConfigurationRegistry) *std.StringHashMap(Property) {
        return &self.properties;
    }

    /// Registers a JSON settings document as configuration defaults. Later
    /// registrations override earlier ones, matching upstream's
    /// default-configuration contribution order.
    pub fn registerDefaultsJson(self: *ConfigurationRegistry, text: []const u8) !void {
        const model = try self.allocator.create(ConfigurationModel);
        errdefer self.allocator.destroy(model);
        model.* = try ConfigurationModel.fromJson(self.allocator, text);
        errdefer model.deinit();
        try self.defaults.append(model);
    }

    /// Produces the merged default model. The caller owns the returned model.
    pub fn buildDefaultModel(self: *const ConfigurationRegistry, allocator: Allocator) !ConfigurationModel {
        var models = std.array_list.Managed(*const ConfigurationModel).init(allocator);
        defer models.deinit();
        for (self.defaults.items) |model| try models.append(model);
        return ConfigurationModel.merge(allocator, models.items);
    }
};

fn cloneValue(arena: Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .object => |object| blk: {
            var result = std.json.ObjectMap{};
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try result.put(arena, try arena.dupe(u8, entry.key_ptr.*), try cloneValue(arena, entry.value_ptr.*));
            }
            break :blk .{ .object = result };
        },
        .array => |array| blk: {
            var result = std.json.Array.init(arena);
            for (array.items) |item| try result.append(try cloneValue(arena, item));
            break :blk .{ .array = result };
        },
        else => value,
    };
}

fn mergeObjects(arena: Allocator, target: *std.json.Value, source: std.json.Value) !void {
    var iterator = source.object.iterator();
    while (iterator.next()) |entry| {
        const existing = target.object.getPtr(entry.key_ptr.*);
        if (existing) |value| {
            if (value.* == .object and entry.value_ptr.* == .object) {
                try mergeObjects(arena, value, entry.value_ptr.*);
            } else {
                value.* = try cloneValue(arena, entry.value_ptr.*);
            }
        } else {
            try target.object.put(arena, try arena.dupe(u8, entry.key_ptr.*), try cloneValue(arena, entry.value_ptr.*));
        }
    }
}

/// The defaults registered by the terminal workbench. `explorer.excludeGitIgnore`
/// is on by default here: the Explorer hid `.gitignore` entries before the
/// configuration service existed, and the TUI keeps that behavior unless the
/// user disables it in settings. `files.exclude` matches VS Code's default VCS
/// and OS metadata excludes.
pub const tui_defaults_json =
    \\{
    \\  "files": {
    \\    "exclude": {
    \\      "**/.git": true,
    \\      "**/.svn": true,
    \\      "**/.hg": true,
    \\      "**/.jj": true,
    \\      "**/.DS_Store": true,
    \\      "**/Thumbs.db": true
    \\    }
    \\  },
    \\  "explorer": {
    \\    "excludeGitIgnore": true
    \\  }
    \\}
;

test "ConfigurationRegistry: later defaults win and build a merged model" {
    const allocator = std.testing.allocator;
    const registry = try ConfigurationRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerDefaultsJson("{\"editor.tabSize\": 4}");
    try registry.registerDefaultsJson("{\"editor.tabSize\": 2, \"files.eol\": \"\\n\"}");

    var model = try registry.buildDefaultModel(allocator);
    defer model.deinit();

    try std.testing.expectEqual(@as(i64, 2), model.getValue("editor.tabSize").?.integer);
    try std.testing.expectEqualStrings("\n", model.getValue("files.eol").?.string);
}

test "ConfigurationRegistry: terminal defaults hide VCS metadata and ignore files" {
    const allocator = std.testing.allocator;
    const registry = try ConfigurationRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerDefaultsJson(tui_defaults_json);

    var model = try registry.buildDefaultModel(allocator);
    defer model.deinit();

    try std.testing.expect(model.getValue("explorer.excludeGitIgnore").?.bool);
    const exclude = model.getValue("files.exclude").?;
    try std.testing.expect(exclude.object.get("**/.git").?.bool);
    try std.testing.expect(exclude.object.get("**/.DS_Store").?.bool);
}

pub const ExtensionSource = struct {
    id: []const u8,
    display_name: ?[]const u8 = null,
};

pub const ConfigurationDefaultSource = union(enum) {
    string: []const u8,
    extension: ExtensionSource,
};

/// Port of `isConfigurationDefaultSourceEquals`: same kind and value/id.
pub fn isConfigurationDefaultSourceEquals(a: ?ConfigurationDefaultSource, b: ?ConfigurationDefaultSource) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return switch (a.?) {
        .string => |value| switch (b.?) {
            .string => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .extension => |value| switch (b.?) {
            .extension => |other| std.mem.eql(u8, value.id, other.id),
            else => false,
        },
    };
}

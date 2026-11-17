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
const configuration = @import("./configuration.zig");
const configurationModels = @import("./configurationModels.zig");
const ConfigurationModel = configurationModels.ConfigurationModel;

pub const ConfigurationScope = configuration.ConfigurationScope;

pub const PropertySchema = struct {
    key: []const u8,
    value_type: []const u8 = "object",
    default: ?std.json.Value = null,
    scope: ConfigurationScope = .WINDOW,
    restricted: bool = false,
    disallow_configuration_default: bool = false,
    policy: ?[]const u8 = null,
    policy_reference: ?[]const u8 = null,
    included: bool = true,
    agent_host_key: ?[]const u8 = null,
    experiment_mode: ?[]const u8 = null,
};

pub const Property = struct {
    value_type: []const u8,
    default: std.json.Value = .null,
    scope: ConfigurationScope = .WINDOW,
    restricted: bool = false,
    disallow_configuration_default: bool = false,
    policy: ?[]const u8 = null,
    policy_reference: ?[]const u8 = null,
    included: bool = true,
    agent_host_key: ?[]const u8 = null,
    experiment_mode: ?[]const u8 = null,
};

pub const AgentHostConfig = struct {
    key: []const u8,
};

pub const DefaultOverride = struct {
    key: []const u8,
    value: std.json.Value,
    source: ?ConfigurationDefaultSource = null,
};

pub const ConfigurationRegistry = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    defaults: std.array_list.Managed(*ConfigurationModel),
    properties: std.StringHashMap(Property),
    policies: std.StringHashMap(void),
    policy_configurations: std.StringHashMap([]const u8),
    policy_reference_configurations: std.StringHashMap(std.array_list.Managed([]const u8)),
    base_defaults: std.StringHashMap(std.json.Value),
    contributions: std.array_list.Managed(Contribution),
    excluded_properties: std.StringHashMap(Property),
    agent_host_configurations: std.StringHashMap(AgentHostConfig),
    nodes: std.StringHashMap(std.array_list.Managed([]const u8)),

    const Contribution = struct {
        source: ?ConfigurationDefaultSource,
        entries: []const DefaultOverride,
    };

    pub fn init(allocator: Allocator) !*ConfigurationRegistry {
        const self = try allocator.create(ConfigurationRegistry);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .defaults = std.array_list.Managed(*ConfigurationModel).init(allocator),
            .properties = std.StringHashMap(Property).init(allocator),
            .policies = std.StringHashMap(void).init(allocator),
            .policy_configurations = std.StringHashMap([]const u8).init(allocator),
            .policy_reference_configurations = std.StringHashMap(std.array_list.Managed([]const u8)).init(allocator),
            .base_defaults = std.StringHashMap(std.json.Value).init(allocator),
            .contributions = std.array_list.Managed(Contribution).init(allocator),
            .excluded_properties = std.StringHashMap(Property).init(allocator),
            .agent_host_configurations = std.StringHashMap(AgentHostConfig).init(allocator),
            .nodes = std.StringHashMap(std.array_list.Managed([]const u8)).init(allocator),
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
        self.policy_configurations.deinit();
        var references = self.policy_reference_configurations.valueIterator();
        while (references.next()) |list| list.deinit();
        self.policy_reference_configurations.deinit();
        self.base_defaults.deinit();
        self.contributions.deinit();
        self.excluded_properties.deinit();
        self.agent_host_configurations.deinit();
        var nodes = self.nodes.valueIterator();
        while (nodes.next()) |keys| keys.deinit();
        self.nodes.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Registers configuration properties. A property whose policy name was
    /// already registered is skipped (upstream logs and ignores it).
    pub fn registerConfiguration(self: *ConfigurationRegistry, id: []const u8, properties: []const PropertySchema) !void {
        const arena = self.arena.allocator();
        const node_entry = try self.nodes.getOrPut(try arena.dupe(u8, id));
        if (!node_entry.found_existing) node_entry.value_ptr.* = std.array_list.Managed([]const u8).init(arena);
        for (properties) |schema| {
            try node_entry.value_ptr.append(try arena.dupe(u8, schema.key));
            if (schema.policy != null and schema.policy_reference != null) continue;
            if (schema.policy) |policy| {
                if (self.policies.contains(policy)) continue;
                try self.policies.put(try arena.dupe(u8, policy), {});
                try self.policy_configurations.put(try arena.dupe(u8, policy), try arena.dupe(u8, schema.key));
            }
            if (schema.policy_reference) |reference| {
                const entry = try self.policy_reference_configurations.getOrPut(try arena.dupe(u8, reference));
                if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed([]const u8).init(arena);
                try entry.value_ptr.append(try arena.dupe(u8, schema.key));
            }
            const base_value = if (schema.default) |value| try cloneValue(arena, value) else std.json.Value{ .object = .{} };
            const default_value = try cloneValue(arena, base_value);
            const property = Property{
                .value_type = try arena.dupe(u8, schema.value_type),
                .default = default_value,
                .scope = schema.scope,
                .restricted = schema.restricted,
                .disallow_configuration_default = schema.disallow_configuration_default,
                .policy = if (schema.policy) |policy| try arena.dupe(u8, policy) else null,
                .policy_reference = if (schema.policy_reference) |reference| try arena.dupe(u8, reference) else null,
                .included = schema.included,
                .agent_host_key = if (schema.agent_host_key) |key| try arena.dupe(u8, key) else null,
                .experiment_mode = if (schema.experiment_mode) |mode| try arena.dupe(u8, mode) else null,
            };
            if (schema.included) {
                try self.base_defaults.put(try arena.dupe(u8, schema.key), try cloneValue(arena, base_value));
                try self.properties.put(try arena.dupe(u8, schema.key), property);
            } else {
                try self.excluded_properties.put(try arena.dupe(u8, schema.key), property);
            }
            if (schema.agent_host_key) |agent_key| {
                try self.agent_host_configurations.put(try arena.dupe(u8, agent_key), .{ .key = try arena.dupe(u8, schema.key) });
            }
        }
    }

    /// Merges registered default overrides into the property defaults. Later
    /// object defaults merge recursively; a disallowing property is untouched.
    pub fn registerDefaultConfigurations(self: *ConfigurationRegistry, overrides: []const DefaultOverride) !void {
        return self.registerDefaultConfigurationsWithSource(overrides, null);
    }

    pub fn registerDefaultConfigurationsWithSource(self: *ConfigurationRegistry, overrides: []const DefaultOverride, source: ?ConfigurationDefaultSource) !void {
        const arena = self.arena.allocator();
        var entries = std.array_list.Managed(DefaultOverride).init(arena);
        for (overrides) |override_value| {
            try entries.append(.{
                .key = try arena.dupe(u8, override_value.key),
                .value = try cloneValue(arena, override_value.value),
                .source = source,
            });
        }
        try self.contributions.append(.{ .source = source, .entries = try entries.toOwnedSlice() });
        try self.rebuildDefaults();
    }

    /// Removes the first contribution matching `overrides` (and source when
    /// given), then rebuilds the effective defaults.
    pub fn deregisterDefaultConfigurations(self: *ConfigurationRegistry, overrides: []const DefaultOverride, source: ?ConfigurationDefaultSource) !void {
        var index: usize = 0;
        while (index < self.contributions.items.len) : (index += 1) {
            const contribution = self.contributions.items[index];
            if (!isConfigurationDefaultSourceEquals(contribution.source, source)) continue;
            if (!sameOverrides(contribution.entries, overrides)) continue;
            _ = self.contributions.orderedRemove(index);
            try self.rebuildDefaults();
            return;
        }
    }

    fn rebuildDefaults(self: *ConfigurationRegistry) !void {
        const arena = self.arena.allocator();
        var iterator = self.properties.iterator();
        while (iterator.next()) |entry| {
            if (self.base_defaults.get(entry.key_ptr.*)) |base| {
                entry.value_ptr.default = try cloneValue(arena, base);
            }
        }
        // Drop properties that only existed because of default overrides.
        var removals = std.array_list.Managed([]const u8).init(self.allocator);
        defer removals.deinit();
        iterator = self.properties.iterator();
        while (iterator.next()) |entry| {
            if (self.base_defaults.contains(entry.key_ptr.*)) continue;
            try removals.append(entry.key_ptr.*);
        }
        for (removals.items) |key| _ = self.properties.remove(key);

        for (self.contributions.items) |contribution| {
            for (contribution.entries) |override_value| {
                const entry = try self.properties.getOrPut(try arena.dupe(u8, override_value.key));
                if (!entry.found_existing) entry.value_ptr.* = .{ .value_type = "object", .default = .{ .object = .{} } };
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
    }

    pub fn getConfigurationProperties(self: *ConfigurationRegistry) *std.StringHashMap(Property) {
        return &self.properties;
    }

    pub fn getExcludedConfigurationProperties(self: *ConfigurationRegistry) *std.StringHashMap(Property) {
        return &self.excluded_properties;
    }

    pub fn getAgentHostSyncConfigurations(self: *ConfigurationRegistry) *std.StringHashMap(AgentHostConfig) {
        return &self.agent_host_configurations;
    }

    /// Flattened registered default overrides (borrowed from the registry).
    pub fn getRegisteredDefaultConfigurations(self: *ConfigurationRegistry, allocator: Allocator) ![]DefaultOverride {
        var result = std.array_list.Managed(DefaultOverride).init(allocator);
        errdefer result.deinit();
        for (self.contributions.items) |contribution| try result.appendSlice(contribution.entries);
        return result.toOwnedSlice();
    }

    /// Removes every property contributed by the node id.
    pub fn deregisterConfigurations(self: *ConfigurationRegistry, id: []const u8) void {
        const keys = self.nodes.get(id) orelse return;
        for (keys.items) |key| {
            _ = self.properties.remove(key);
            _ = self.excluded_properties.remove(key);
            _ = self.base_defaults.remove(key);
        }
        var agents = self.agent_host_configurations.iterator();
        var removed_agents = std.array_list.Managed([]const u8).init(self.allocator);
        defer removed_agents.deinit();
        while (agents.next()) |entry| {
            for (keys.items) |key| {
                if (std.mem.eql(u8, entry.value_ptr.key, key)) removed_agents.append(entry.key_ptr.*) catch break;
            }
        }
        for (removed_agents.items) |key| _ = self.agent_host_configurations.remove(key);
        _ = self.nodes.remove(id);
    }

    pub fn getPolicyConfigurations(self: *ConfigurationRegistry) *std.StringHashMap([]const u8) {
        return &self.policy_configurations;
    }

    pub fn getPolicyReferenceConfigurations(self: *ConfigurationRegistry) *std.StringHashMap(std.array_list.Managed([]const u8)) {
        return &self.policy_reference_configurations;
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

fn sameOverrides(a: []const DefaultOverride, b: []const DefaultOverride) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.key, right.key)) return false;
        if (!valueEquals(left.value, right.value)) return false;
    }
    return true;
}

fn valueEquals(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .integer => |value| value == b.integer,
        .float => |value| value == b.float,
        .number_string => |value| std.mem.eql(u8, value, b.number_string),
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |array| blk: {
            if (array.items.len != b.array.items.len) break :blk false;
            for (array.items, b.array.items) |item_a, item_b| {
                if (!valueEquals(item_a, item_b)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != b.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valueEquals(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

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

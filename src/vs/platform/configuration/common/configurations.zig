// Port of the `DefaultConfiguration` subset of
// `src/vs/platform/configuration/common/configurations.ts`.
//
// Terminal adaptation: the registry is passed explicitly and the change event
// is a plain callback (`onDidUpdateConfiguration`) instead of an observable.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configurationModels = @import("./configurationModels.zig");
const configurationRegistry = @import("./configurationRegistry.zig");
const configuration = @import("./configuration.zig");

const ConfigurationModel = configurationModels.ConfigurationModel;
const policy_mod = @import("../../policy/common/policy.zig");
const InMemoryPolicyService = policy_mod.InMemoryPolicyService;
const PolicyDefinition = policy_mod.PolicyDefinition;
const PolicyType = policy_mod.PolicyType;
const PolicyValue = policy_mod.PolicyValue;
const Emitter = @import("../../../base/common/event.zig").Emitter;

pub const DefaultConfiguration = struct {
    allocator: Allocator,
    registry: *configurationRegistry.ConfigurationRegistry,
    model: *ConfigurationModel,
    listener_id: ?usize = null,

    pub fn init(allocator: Allocator, registry: *configurationRegistry.ConfigurationRegistry) !DefaultConfiguration {
        const model = try allocator.create(ConfigurationModel);
        errdefer allocator.destroy(model);
        model.* = try ConfigurationModel.initEmpty(allocator);
        return .{ .allocator = allocator, .registry = registry, .model = model };
    }

    pub fn deinit(self: *DefaultConfiguration) void {
        if (self.listener_id) |id| self.registry.on_did_update_configuration.unlisten(id);
        self.model.deinit();
        self.allocator.destroy(self.model);
    }

    pub fn configurationModel(self: *const DefaultConfiguration) *const ConfigurationModel {
        return self.model;
    }

    /// Rebuilds the model from every registered property (including hidden
    /// experimental settings).
    pub fn initialize(self: *DefaultConfiguration) !void {
        if (self.listener_id) |id| {
            self.registry.on_did_update_configuration.unlisten(id);
            self.listener_id = null;
        }
        self.model.deinit();
        self.model.* = try ConfigurationModel.initEmpty(self.allocator);
        try self.onDidUpdateConfiguration(null);
        self.listener_id = try self.registry.on_did_update_configuration.listen(self, onRegistryUpdate);
    }

    fn onRegistryUpdate(keys: []const []const u8, self: *DefaultConfiguration) anyerror!void {
        try self.onDidUpdateConfiguration(keys);
    }

    pub fn reload(self: *DefaultConfiguration) !void {
        try self.initialize();
    }

    /// Updates the given properties (or all when `properties == null`).
    pub fn onDidUpdateConfiguration(self: *DefaultConfiguration, properties: ?[]const []const u8) !void {
        _ = properties;
        // Rebuild from scratch so JSON default contributions layered over the
        // registered property defaults are included (and later wins).
        var fresh = try ConfigurationModel.initEmpty(self.allocator);
        defer fresh.deinit();
        var iterator = self.registry.getConfigurationProperties().iterator();
        while (iterator.next()) |entry| {
            const value = try configuration.cloneValue(fresh.arena.allocator(), entry.value_ptr.default);
            try fresh.setValue(entry.key_ptr.*, value);
        }
        var excluded = self.registry.getExcludedConfigurationProperties().iterator();
        while (excluded.next()) |entry| {
            if (entry.value_ptr.experiment_mode == null) continue;
            const value = try configuration.cloneValue(fresh.arena.allocator(), entry.value_ptr.default);
            try fresh.setValue(entry.key_ptr.*, value);
        }
        var contributed = try self.registry.buildDefaultModel(self.allocator);
        defer contributed.deinit();
        const merged = try ConfigurationModel.merge(self.allocator, &.{ &fresh, &contributed });
        self.model.deinit();
        self.model.* = merged;
    }

    fn setDefault(self: *DefaultConfiguration, key: []const u8, property: configurationRegistry.Property) !void {
        const value = try configuration.cloneValue(self.model.arena.allocator(), property.default);
        try self.model.setValue(key, value);
    }
};

/// Port of `PolicyConfiguration` for the in-memory policy service: resolves
/// policy definitions from registered settings, applies policy values to a
/// model and notifies listeners.
pub const PolicyConfiguration = struct {
    allocator: Allocator,
    defaults: *DefaultConfiguration,
    policy_service: *InMemoryPolicyService,
    model: ConfigurationModel,
    onDidChangeConfiguration: Emitter(ConfigurationModel),
    submitted: std.StringHashMap(PolicyDefinition),
    name_by_key: std.StringHashMap([]const u8),
    listener_id: ?usize = null,
    registry_listener: ?usize = null,

    pub fn init(allocator: Allocator, defaults: *DefaultConfiguration, policy_service: *InMemoryPolicyService) !PolicyConfiguration {
        return .{
            .allocator = allocator,
            .defaults = defaults,
            .policy_service = policy_service,
            .model = try ConfigurationModel.initEmpty(allocator),
            .onDidChangeConfiguration = Emitter(ConfigurationModel).init(allocator),
            .submitted = std.StringHashMap(PolicyDefinition).init(allocator),
            .name_by_key = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PolicyConfiguration) void {
        if (self.listener_id) |id| self.policy_service.unlisten(id);
        if (self.registry_listener) |id| self.defaults.registry.on_did_update_configuration.unlisten(id);
        self.model.deinit();
        self.onDidChangeConfiguration.deinit();
        self.submitted.deinit();
        self.name_by_key.deinit();
    }

    pub fn configurationModel(self: *const PolicyConfiguration) *const ConfigurationModel {
        return &self.model;
    }

    pub fn initialize(self: *PolicyConfiguration) !void {
        var keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer keys.deinit();
        for (self.defaults.configurationModel().getKeys()) |key| try keys.append(key);
        var excluded = self.defaults.registry.getExcludedConfigurationProperties().keyIterator();
        while (excluded.next()) |key| try keys.append(key.*);
        try self.updateDefinitions(keys.items);
        try self.update(keys.items, false);
        self.listener_id = try self.policy_service.listen(self, onPolicyChanged);
        self.registry_listener = try self.defaults.registry.on_did_update_configuration.listen(self, onRegistryChanged);
    }

    fn onRegistryChanged(_: []const []const u8, self: *PolicyConfiguration) anyerror!void {
        var keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer keys.deinit();
        for (self.defaults.configurationModel().getKeys()) |key| try keys.append(key);
        var excluded = self.defaults.registry.getExcludedConfigurationProperties().keyIterator();
        while (excluded.next()) |key| try keys.append(key.*);
        try self.updateDefinitions(keys.items);
        try self.update(keys.items, true);
    }

    fn onPolicyChanged(names: []const []const u8, self: *PolicyConfiguration) anyerror!void {
        const owners = self.defaults.registry.getPolicyConfigurations();
        const references = self.defaults.registry.getPolicyReferenceConfigurations();
        var keys = std.array_list.Managed([]const u8).init(self.allocator);
        defer keys.deinit();
        for (names) |name| {
            if (owners.get(name)) |key| try keys.append(key);
            if (references.get(name)) |list| for (list.items) |key| try keys.append(key);
        }
        try self.update(keys.items, true);
    }

    fn propertyFor(self: *PolicyConfiguration, key: []const u8) ?configurationRegistry.Property {
        if (self.defaults.registry.getConfigurationProperties().get(key)) |property| return property;
        return self.defaults.registry.getExcludedConfigurationProperties().get(key);
    }

    fn updateDefinitions(self: *PolicyConfiguration, keys: []const []const u8) !void {
        var changed = std.array_list.Managed(PolicyDefinition).init(self.allocator);
        defer changed.deinit();
        for (keys) |key| {
            const property = self.propertyFor(key) orelse continue;
            const policy_name = property.policy orelse property.policy_reference orelse continue;
            const definition = self.resolveDefinition(policy_name) orelse continue;
            if (self.submitted.get(policy_name)) |existing| {
                if (std.meta.eql(existing, definition)) continue;
            }
            try self.submitted.put(policy_name, definition);
            try self.name_by_key.put(key, policy_name);
            try changed.append(definition);
        }
        if (changed.items.len > 0) try self.policy_service.updatePolicyDefinitions(changed.items);
    }

    fn resolveDefinition(self: *PolicyConfiguration, name: []const u8) ?PolicyDefinition {
        const owner = self.defaults.registry.getPolicyConfigurations().get(name);
        if (owner) |key| {
            if (self.propertyFor(key)) |property| {
                return .{
                    .name = name,
                    .value_type = policyType(property.value_type),
                    .managed_settings = property.policy_managed_settings,
                    .restricted_value = tryPolicyValue(property.policy_restricted_value),
                };
            }
        }
        if (self.defaults.registry.getPolicyReferenceConfigurations().get(name)) |list| {
            for (list.items) |key| {
                if (self.propertyFor(key)) |property| {
                    return .{
                        .name = name,
                        .value_type = policyType(property.value_type),
                        .managed_settings = property.policy_managed_settings,
                        .restricted_value = tryPolicyValue(property.policy_restricted_value),
                    };
                }
            }
        }
        return null;
    }

    fn update(self: *PolicyConfiguration, keys: []const []const u8, trigger: bool) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var changes = std.array_list.Managed(struct { key: []const u8, value: ?std.json.Value }).init(self.allocator);
        defer changes.deinit();
        for (keys) |key| {
            const property = self.propertyFor(key) orelse {
                if (self.model.getValue(key) != null) try changes.append(.{ .key = key, .value = null });
                continue;
            };
            const policy_name = property.policy orelse property.policy_reference orelse continue;
            const policy_value = self.policy_service.getPolicyValue(policy_name) orelse {
                if (self.model.getValue(key) != null) try changes.append(.{ .key = key, .value = null });
                continue;
            };
            const value = policyValueAsJson(scratch.allocator(), property, policy_value) catch continue;
            const existing = self.model.getValue(key);
            const differs = if (existing) |current| !configuration.jsonValuesEqual(current.*, value) else true;
            if (differs) try changes.append(.{ .key = key, .value = value });
        }
        var has_stale = false;
        for (self.model.getKeys()) |key| {
            if (self.propertyFor(key) == null) {
                has_stale = true;
                break;
            }
        }
        if (changes.items.len == 0 and !has_stale) return;

        var next = try ConfigurationModel.initEmpty(self.allocator);
        errdefer next.deinit();
        const arena = next.arena.allocator();
        for (self.model.getKeys()) |key| {
            if (self.propertyFor(key) == null) {
                next.removeValue(key);
                continue;
            }
            if (self.model.getValue(key)) |value| try next.setValue(key, try configuration.cloneValue(arena, value.*));
        }
        for (changes.items) |change| {
            if (change.value) |value| {
                try next.setValue(change.key, try configuration.cloneValue(arena, value));
            } else {
                next.removeValue(change.key);
            }
        }
        self.model.deinit();
        self.model = next;
        if (trigger) self.onDidChangeConfiguration.fire(self.model) catch {};
    }

    fn policyValueAsJson(allocator: Allocator, property: configurationRegistry.Property, value: PolicyValue) !std.json.Value {
        const accepts_string = std.mem.eql(u8, property.value_type, "string");
        switch (value) {
            .string => |text| {
                if (accepts_string) return .{ .string = try allocator.dupe(u8, text) };
                return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{ .duplicate_field_behavior = .@"error" }) catch return error.InvalidPolicyValue;
            },
            .number => |number| return .{ .float = number },
            .boolean => |boolean| return .{ .bool = boolean },
        }
    }
};

fn policyType(value_type: []const u8) PolicyType {
    if (std.mem.eql(u8, value_type, "number")) return .number;
    if (std.mem.eql(u8, value_type, "boolean")) return .boolean;
    return .string;
}

fn tryPolicyValue(value: ?std.json.Value) ?PolicyValue {
    const json = value orelse return null;
    return switch (json) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .number = @floatFromInt(number) },
        .float => |number| .{ .number = number },
        .bool => |boolean| .{ .boolean = boolean },
        else => null,
    };
}

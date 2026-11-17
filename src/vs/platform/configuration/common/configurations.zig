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
        if (properties) |keys| {
            for (keys) |key| try self.updateProperty(key);
            return;
        }
        var iterator = self.registry.getConfigurationProperties().iterator();
        while (iterator.next()) |entry| try self.setDefault(entry.key_ptr.*, entry.value_ptr.*);
        var excluded = self.registry.getExcludedConfigurationProperties().iterator();
        while (excluded.next()) |entry| {
            if (entry.value_ptr.experiment_mode == null) continue;
            try self.setDefault(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn updateProperty(self: *DefaultConfiguration, key: []const u8) !void {
        if (self.registry.getConfigurationProperties().getPtr(key)) |property| {
            try self.setDefault(key, property.*);
            return;
        }
        if (self.registry.getExcludedConfigurationProperties().getPtr(key)) |property| {
            if (property.experiment_mode != null) {
                try self.setDefault(key, property.*);
                return;
            }
        }
        self.model.removeValue(key);
    }

    fn setDefault(self: *DefaultConfiguration, key: []const u8, property: configurationRegistry.Property) !void {
        const value = try configuration.cloneValue(self.model.arena.allocator(), property.default);
        try self.model.setValue(key, value);
    }
};

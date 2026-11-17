// Port of the user-target subset of
// `src/vs/platform/configuration/common/configurationService.ts`.
//
// Terminal adaptation: settings are kept as in-memory `ConfigurationModel`s
// (no settings file/URI), the registry is explicit, policy and remote
// configuration are not ported, and only the USER target is writable.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configuration = @import("./configuration.zig");
const configurationModels = @import("./configurationModels.zig");
const configurationRegistry = @import("./configurationRegistry.zig");
const configurations = @import("./configurations.zig");

const ConfigurationModel = configurationModels.ConfigurationModel;
const ConfigurationTarget = configuration.ConfigurationTarget;

pub const InspectValue = struct {
    default_value: ?*const std.json.Value,
    user_value: ?*const std.json.Value,
    workspace_value: ?*const std.json.Value,
    value: ?*const std.json.Value,
};

/// A setting is configured when the user or workspace overrides it.
pub fn isConfigured(value: InspectValue) bool {
    return value.user_value != null or value.workspace_value != null;
}

pub const ConfigurationService = struct {
    allocator: Allocator,
    defaults: configurations.DefaultConfiguration,
    user: ConfigurationModel,
    workspace: ConfigurationModel,

    pub fn init(allocator: Allocator, registry: *configurationRegistry.ConfigurationRegistry) !*ConfigurationService {
        const self = try allocator.create(ConfigurationService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .defaults = try configurations.DefaultConfiguration.init(allocator, registry),
            .user = try ConfigurationModel.initEmpty(allocator),
            .workspace = try ConfigurationModel.initEmpty(allocator),
        };
        return self;
    }

    pub fn deinit(self: *ConfigurationService) void {
        self.defaults.deinit();
        self.user.deinit();
        self.workspace.deinit();
        self.allocator.destroy(self);
    }

    pub fn initialize(self: *ConfigurationService) !void {
        try self.defaults.initialize();
    }

    pub fn getValue(self: *ConfigurationService, key: []const u8) ?*const std.json.Value {
        if (self.workspace.getValue(key)) |value| return value;
        if (self.user.getValue(key)) |value| return value;
        return self.defaults.configurationModel().getValue(key);
    }

    /// Replaces the workspace configuration from a JSON(C) document.
    pub fn loadWorkspaceJson(self: *ConfigurationService, text: []const u8) !void {
        self.workspace.deinit();
        self.workspace = try ConfigurationModel.fromJson(self.allocator, text);
    }

    pub fn inspect(self: *ConfigurationService, key: []const u8) InspectValue {
        const user_value = self.user.getValue(key);
        const workspace_value = self.workspace.getValue(key);
        const default_value = self.defaults.configurationModel().getValue(key);
        return .{
            .default_value = default_value,
            .user_value = user_value,
            .workspace_value = workspace_value,
            .value = workspace_value orelse user_value orelse default_value,
        };
    }

    /// Updates the user configuration. Passing null removes the value; writing
    /// a value equal to the default also removes it (upstream behavior).
    pub fn updateValue(self: *ConfigurationService, key: []const u8, value: ?std.json.Value, target: ConfigurationTarget) !void {
        if (target != .USER) return error.UnsupportedConfigurationTarget;
        if (value == null or std.meta.activeTag(value.?) == .null) {
            self.user.removeValue(key);
            return;
        }
        if (self.defaults.configurationModel().getValue(key)) |default_value| {
            if (configuration.jsonValuesEqual(default_value.*, value.?)) {
                self.user.removeValue(key);
                return;
            }
        }
        try self.user.setValue(key, value.?);
    }
};

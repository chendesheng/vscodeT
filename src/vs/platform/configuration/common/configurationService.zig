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
    onDidChange: @import("../../../base/common/event.zig").Emitter(configuration.Change),
    scratch: std.heap.ArenaAllocator,
    registry_listener: ?usize = null,
    /// When false, workspace values for restricted settings are ignored.
    trusted: bool = true,

    pub fn init(allocator: Allocator, registry: *configurationRegistry.ConfigurationRegistry) !*ConfigurationService {
        const self = try allocator.create(ConfigurationService);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .defaults = try configurations.DefaultConfiguration.init(allocator, registry),
            .user = try ConfigurationModel.initEmpty(allocator),
            .workspace = try ConfigurationModel.initEmpty(allocator),
            .onDidChange = @import("../../../base/common/event.zig").Emitter(configuration.Change).init(allocator),
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer {
            self.defaults.deinit();
            self.user.deinit();
            self.workspace.deinit();
            self.onDidChange.deinit();
            self.scratch.deinit();
            allocator.destroy(self);
        }
        self.registry_listener = try self.defaults.registry.on_did_update_configuration.listen(self, onRegistryDefaultsChanged);
        return self;
    }

    fn onRegistryDefaultsChanged(keys: []const []const u8, self: *ConfigurationService) anyerror!void {
        self.onDidChange.fire(.{ .source = .DEFAULT, .keys = keys }) catch {};
    }

    pub fn deinit(self: *ConfigurationService) void {
        if (self.registry_listener) |id| self.defaults.registry.on_did_update_configuration.unlisten(id);
        self.defaults.deinit();
        self.user.deinit();
        self.workspace.deinit();
        self.onDidChange.deinit();
        self.scratch.deinit();
        self.allocator.destroy(self);
    }

    pub fn initialize(self: *ConfigurationService) !void {
        try self.defaults.initialize();
    }

    /// Resolves a value for a language-override identifier. The returned
    /// pointer is owned by a scratch arena and stays valid until the next
    /// `getValueWithOverrides` call.
    pub fn getValueWithOverrides(self: *ConfigurationService, key: []const u8, override_identifier: ?[]const u8) !?*const std.json.Value {
        const identifier = override_identifier orelse return self.getValue(key);
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();
        if (self.trusted) {
            var workspace = try self.workspace.override(scratch, identifier);
            if (workspace.getValue(key)) |value| return value;
        }
        var user = try self.user.override(scratch, identifier);
        if (user.getValue(key)) |value| return value;
        var defaults = try self.defaults.configurationModel().override(scratch, identifier);
        if (defaults.getValue(key)) |value| return value;
        return self.getValue(key);
    }

    pub fn getValue(self: *ConfigurationService, key: []const u8) ?*const std.json.Value {
        if (self.workspaceValue(key)) |value| return value;
        if (self.user.getValue(key)) |value| return value;
        return self.defaults.configurationModel().getValue(key);
    }

    /// Replaces the workspace configuration from a JSON(C) document.
    pub fn loadWorkspaceJson(self: *ConfigurationService, text: []const u8) !void {
        const parsed = try ConfigurationModel.fromJson(self.allocator, text);
        self.workspace.deinit();
        self.workspace = parsed;
        self.onDidChange.fire(.{ .source = .WORKSPACE, .keys = self.workspace.getKeys() }) catch {};
    }

    /// Override-aware inspect; pointers live in the scratch arena until the
    /// next override lookup.
    pub fn inspectWithOverride(self: *ConfigurationService, key: []const u8, identifier: []const u8) !InspectValue {
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();
        var workspace = try self.workspace.override(scratch, identifier);
        var user = try self.user.override(scratch, identifier);
        var defaults = try self.defaults.configurationModel().override(scratch, identifier);
        const workspace_value = if (self.trusted) workspace.getValue(key) else null;
        const user_value = user.getValue(key);
        const default_value = defaults.getValue(key);
        return .{
            .default_value = default_value,
            .user_value = user_value,
            .workspace_value = workspace_value,
            .value = workspace_value orelse user_value orelse default_value,
        };
    }

    pub fn inspect(self: *ConfigurationService, key: []const u8) InspectValue {
        const user_value = self.user.getValue(key);
        const workspace_value = self.workspaceValue(key);
        const default_value = self.defaults.configurationModel().getValue(key);
        return .{
            .default_value = default_value,
            .user_value = user_value,
            .workspace_value = workspace_value,
            .value = workspace_value orelse user_value orelse default_value,
        };
    }

    fn workspaceValue(self: *ConfigurationService, key: []const u8) ?*const std.json.Value {
        if (!self.trusted) {
            if (self.defaults.registry.getConfigurationProperties().get(key)) |property| {
                if (property.restricted) return null;
            }
        }
        return self.workspace.getValue(key);
    }

    /// Updates the user configuration. Passing null removes the value; writing
    /// a value equal to the default also removes it (upstream behavior).
    pub fn updateValue(self: *ConfigurationService, key: []const u8, value: ?std.json.Value, target: ConfigurationTarget) !void {
        if (target != .USER) return error.UnsupportedConfigurationTarget;
        if (value == null or std.meta.activeTag(value.?) == .null) {
            self.user.removeValue(key);
            self.onDidChange.fire(.{ .source = .USER, .keys = &.{key} }) catch {};
            return;
        }
        if (self.defaults.configurationModel().getValue(key)) |default_value| {
            if (configuration.jsonValuesEqual(default_value.*, value.?)) {
                self.user.removeValue(key);
                self.onDidChange.fire(.{ .source = .USER, .keys = &.{key} }) catch {};
                return;
            }
        }
        try self.user.setValue(key, value.?);
        self.onDidChange.fire(.{ .source = .USER, .keys = &.{key} }) catch {};
    }
};

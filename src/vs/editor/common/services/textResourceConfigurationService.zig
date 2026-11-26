// Port of the resource/language-bound configuration reads and writes in
// `src/vs/editor/common/services/textResourceConfigurationService.ts`.
// The terminal's configuration interface selects the actual local store;
// remote, policy and memory stores remain outside its supported scopes.
const std = @import("std");
const configuration = @import("../../../platform/configuration/common/configuration.zig");
const TextModel = @import("../model/textModel.zig").TextModel;
const std_uri = @import("../../../base/common/stdUri.zig");
const contract = @import("textResourceConfiguration.zig");
const instantiation = @import("../../../platform/instantiation/common/instantiation.zig");

pub const TextResourceConfigurationService = struct {
    allocator: std.mem.Allocator,
    configuration: configuration.IConfigurationService,
    api: contract.ITextResourceConfigurationService = undefined,

    pub fn interface(self: *TextResourceConfigurationService) contract.ITextResourceConfigurationService {
        return .{ .context = self, .get_value = getValue, .update_value = updateValue };
    }

    fn overridesForModel(arena: std.mem.Allocator, model: *TextModel) !configuration.Overrides {
        return .{ .resource = try std_uri.fsPath(model.uri(), arena), .override_identifier = model.getLanguageId() };
    }

    fn getValue(context: *anyopaque, model: *TextModel, key: []const u8) ?*const configuration.Value {
        const self: *TextResourceConfigurationService = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const overrides = overridesForModel(scratch.allocator(), model) catch return null;
        return self.configuration.getValueWithOverrides(key, overrides);
    }

    fn updateValue(context: *anyopaque, model: *TextModel, key: []const u8, value: ?configuration.Value, target: ?configuration.ConfigurationTarget) !void {
        const self: *TextResourceConfigurationService = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try self.configuration.updateResourceValue(key, value, try overridesForModel(scratch.allocator(), model), target);
    }
};

pub fn registerSingleton(collection: *@import("../../../platform/instantiation/common/serviceCollection.zig").ServiceCollection) !void {
    _ = try collection.setFactory(contract.text_resource_configuration_service_id, createService, disposeService);
}
fn createService(allocator: std.mem.Allocator, accessor: instantiation.ServicesAccessor) !*contract.ITextResourceConfigurationService {
    const self = try allocator.create(TextResourceConfigurationService);
    errdefer allocator.destroy(self);
    const config = try accessor.get(configuration.configuration_service_id);
    self.* = .{ .allocator = allocator, .configuration = config.* };
    self.api = self.interface();
    return &self.api;
}
fn disposeService(allocator: std.mem.Allocator, service: *contract.ITextResourceConfigurationService) void {
    const self: *TextResourceConfigurationService = @fieldParentPtr("api", service);
    allocator.destroy(self);
}

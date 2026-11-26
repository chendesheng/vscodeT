// Port of the text-resource configuration contract in
// `src/vs/editor/common/services/textResourceConfiguration.ts`.
// The terminal passes the resolved model at the call boundary instead of
// looking it up again through IModelService; its URI and current language are
// the same two inputs to the upstream configuration override computation.
const configuration = @import("../../../platform/configuration/common/configuration.zig");
const TextModel = @import("../model/textModel.zig").TextModel;
const instantiation = @import("../../../platform/instantiation/common/instantiation.zig");

pub const ITextResourceConfigurationService = struct {
    context: *anyopaque,
    get_value: *const fn (*anyopaque, *TextModel, []const u8) ?*const configuration.Value,
    update_value: *const fn (*anyopaque, *TextModel, []const u8, ?configuration.Value, ?configuration.ConfigurationTarget) anyerror!void,

    pub fn getValue(self: ITextResourceConfigurationService, model: *TextModel, key: []const u8) ?*const configuration.Value {
        return self.get_value(self.context, model, key);
    }

    pub fn updateValue(self: ITextResourceConfigurationService, model: *TextModel, key: []const u8, value: ?configuration.Value, target: ?configuration.ConfigurationTarget) !void {
        try self.update_value(self.context, model, key, value, target);
    }
};
pub const text_resource_configuration_service_id = instantiation.ServiceIdentifier(ITextResourceConfigurationService, "textResourceConfigurationService");

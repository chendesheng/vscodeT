// Port of the model enumeration and lifecycle contracts in
// `src/vs/editor/common/services/modelService.ts`.
// Native models use the resolved-document handle to expose the text model and
// its working-copy metadata without transferring ownership to observers.
const std = @import("std");
const Emitter = @import("../../../base/common/event.zig").Emitter;
const resolver = @import("resolverService.zig");
const ServiceIdentifier = @import("../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier;

pub const IModelService = struct {
    context: *anyopaque,
    get_model: *const fn (*anyopaque, std.Uri) ?resolver.IResolvedTextEditorModel,
    get_models: *const fn (*anyopaque, std.mem.Allocator) anyerror![]resolver.IResolvedTextEditorModel,
    on_model_added: *Emitter(resolver.IResolvedTextEditorModel),
    on_model_removed: *Emitter(resolver.IResolvedTextEditorModel),

    pub fn getModel(self: IModelService, resource: std.Uri) ?resolver.IResolvedTextEditorModel {
        return self.get_model(self.context, resource);
    }

    /// The slice is caller-owned; elements borrow the model-service lifetime.
    pub fn getModels(self: IModelService, allocator: std.mem.Allocator) ![]resolver.IResolvedTextEditorModel {
        return self.get_models(self.context, allocator);
    }
};

pub const model_service_id = ServiceIdentifier(IModelService, "modelService");

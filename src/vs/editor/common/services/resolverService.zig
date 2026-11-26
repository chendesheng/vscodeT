// Port of `src/vs/editor/common/services/resolverService.ts`.
// Native text resolution publishes a shared model on the window dispatcher;
// acquiring an already-published model is synchronous. Provider work runs
// outside this reference contract and may not mutate the model on its worker.
const std = @import("std");
const TextModel = @import("../model/textModel.zig").TextModel;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const IDisposable = @import("../../../base/common/lifecycle.zig").IDisposable;
const instantiation = @import("../../../platform/instantiation/common/instantiation.zig");

pub const text_model_service_id = instantiation.ServiceIdentifier(ITextModelService, "textModelService");

pub const IResolvedTextEditorModel = struct {
    /// The native model owner. The concrete service, not clients of this
    /// interface, unwraps the editor document at the platform boundary.
    context: *anyopaque,
    textEditorModel: *TextModel,
    onWillDispose: *Emitter(void),
    readonly: bool,

    pub fn isReadonly(self: IResolvedTextEditorModel) bool {
        return self.readonly;
    }

    pub fn getLanguageId(self: IResolvedTextEditorModel) []const u8 {
        return self.textEditorModel.getLanguageId();
    }
};

/// An owned upstream IReference<IResolvedTextEditorModel>. The reference is
/// move-only by convention; dispose the reference, not the underlying model.
pub const ModelReference = struct {
    object: IResolvedTextEditorModel,
    release: IDisposable,

    pub fn dispose(self: *ModelReference) void {
        const release = self.release;
        self.release = .none;
        release.dispose();
    }
};

pub const ITextModelService = struct {
    context: *anyopaque,
    create_model_reference: *const fn (*anyopaque, std.Uri) anyerror!ModelReference,
    create_synthetic_document: *const fn (*anyopaque, []const u8, ?[]const u8) anyerror!ModelReference,
    can_handle_resource: *const fn (*anyopaque, std.Uri) bool,

    pub fn createModelReference(self: ITextModelService, resource: std.Uri) !ModelReference {
        return self.create_model_reference(self.context, resource);
    }

    pub fn createSyntheticDocument(self: ITextModelService, value: []const u8, language_id: ?[]const u8) !ModelReference {
        return self.create_synthetic_document(self.context, value, language_id);
    }

    pub fn canHandleResource(self: ITextModelService, resource: std.Uri) bool {
        return self.can_handle_resource(self.context, resource);
    }
};

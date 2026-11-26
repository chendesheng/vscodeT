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

/// Native async adaptation of ITextModelContentProvider.provideTextContent:
/// capture immutable provider data on the window thread, then load contents
/// on the worker. Only the resolver publishes or mutates the text model.
pub const TextContentRequest = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator) anyerror!Result,
    destroy: *const fn (*anyopaque) void,

    pub const Result = struct {
        uri: std.Uri,
        path: []const u8,
        text: ?[]const u8 = null,
        encoding: ?[]const u8 = null,
        is_working_file: bool = false,
        failure: ?anyerror = null,
    };
};

pub const ITextModelContentProvider = struct {
    context: *anyopaque,
    capture: *const fn (*anyopaque, std.Uri) anyerror!?TextContentRequest,
};

pub const ContentProviderRegistration = struct {
    context: *anyopaque,
    id: usize,
    remove: *const fn (*anyopaque, usize) void,

    pub fn dispose(self: ContentProviderRegistration) void {
        self.remove(self.context, self.id);
    }
};

/// One async acquisition owns its resulting reference. Canceling detaches
/// the listener without affecting other acquisitions of the same URI.
pub const ModelReferenceResult = union(enum) { resolved: ModelReference, failure: anyerror };
pub const ModelReferenceListener = struct {
    context: *anyopaque,
    complete: *const fn (*anyopaque, ModelReferenceResult) void,
};
pub const ModelReferenceRequest = struct {
    context: *anyopaque,
    id: u64,
    cancel_fn: *const fn (*anyopaque, u64) void,

    pub fn cancel(self: ModelReferenceRequest) void {
        self.cancel_fn(self.context, self.id);
    }
};

pub const ITextModelService = struct {
    context: *anyopaque,
    create_model_reference: *const fn (*anyopaque, std.Uri, ModelReferenceListener) anyerror!ModelReferenceRequest,
    acquire_model_reference: *const fn (*anyopaque, std.Uri) anyerror!ModelReference,
    refresh_model_reference: *const fn (*anyopaque, std.Uri, ModelReferenceListener) anyerror!ModelReferenceRequest,
    create_synthetic_document: *const fn (*anyopaque, []const u8, ?[]const u8) anyerror!ModelReference,
    can_handle_resource: *const fn (*anyopaque, std.Uri) bool,
    register_provider: *const fn (*anyopaque, []const u8, ITextModelContentProvider) anyerror!ContentProviderRegistration,

    pub fn createModelReference(self: ITextModelService, resource: std.Uri, listener: ModelReferenceListener) !ModelReferenceRequest {
        return self.create_model_reference(self.context, resource, listener);
    }

    /// Native provider-change delivery refreshes an already-published
    /// virtual document, then acquires its existing shared model.
    pub fn refreshModelReference(self: ITextModelService, resource: std.Uri, listener: ModelReferenceListener) !ModelReferenceRequest {
        return self.refresh_model_reference(self.context, resource, listener);
    }

    /// Window-thread native boundary for a document already resolved and
    /// published by a provider or editor input.
    pub fn acquireModelReference(self: ITextModelService, resource: std.Uri) !ModelReference {
        return self.acquire_model_reference(self.context, resource);
    }

    pub fn createSyntheticDocument(self: ITextModelService, value: []const u8, language_id: ?[]const u8) !ModelReference {
        return self.create_synthetic_document(self.context, value, language_id);
    }

    pub fn registerTextModelContentProvider(self: ITextModelService, scheme: []const u8, provider: ITextModelContentProvider) !ContentProviderRegistration {
        return self.register_provider(self.context, scheme, provider);
    }

    pub fn canHandleResource(self: ITextModelService, resource: std.Uri) bool {
        return self.can_handle_resource(self.context, resource);
    }
};

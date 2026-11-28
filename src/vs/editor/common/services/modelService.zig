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

const Allocator = std.mem.Allocator;
const TextModel = @import("../model/textModel.zig").TextModel;
const edit_stack = @import("../model/editStack.zig");
const UndoRedoService = @import("../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const UndoSnapshot = @import("../../../platform/undoRedo/common/undoRedo.zig").ResourceEditStackSnapshot;
const uri_util = @import("../../../base/common/stdUri.zig");
const configuration = @import("../../../platform/configuration/common/configuration.zig");
const time = @import("../../../base/common/timeCompat.zig");

/// The window's model service supplies one undo/redo service to all its text
/// models. The retained closed-model records mirror ModelService's undo stack
/// restoration: detached elements keep their URI, and are reattached only when
/// the resolved text still matches the saved SHA-1. Native model references may
/// outlive the resolver, so each document also owns a store reference.
pub const ModelUndoRedoStore = struct {
    pub const MAX_MEMORY_FOR_CLOSED_FILES_UNDO_STACK = 20 * 1024 * 1024;
    const MAX_MODEL_SIZE = 10 * 1024 * 1024;
    const Sha1 = std.crypto.hash.Sha1;
    allocator: Allocator,
    service: UndoRedoService,
    configuration_service: ?configuration.IConfigurationService = null,
    refs: usize = 1,
    disposed_models: std.StringHashMapUnmanaged(*DisposedModelInfo) = .empty,
    disposed_models_heap_size: usize = 0,

    const DisposedModelInfo = struct {
        arena: std.heap.ArenaAllocator,
        key: []const u8,
        uri: std.Uri,
        initial_snapshot: ?UndoSnapshot,
        time: i64,
        heap_size: usize,
        sha1: [Sha1.digest_length]u8,
        version_id: u32,
        alternative_version_id: u32,

        fn deinit(self: *DisposedModelInfo, a: Allocator) void {
            if (self.initial_snapshot) |*snapshot| snapshot.deinit();
            self.arena.deinit();
            a.destroy(self);
        }
    };

    pub fn create(a: Allocator) !*ModelUndoRedoStore {
        const self = try a.create(ModelUndoRedoStore);
        self.* = .{ .allocator = a, .service = UndoRedoService.init(a) };
        return self;
    }
    pub fn retain(self: *ModelUndoRedoStore) void {
        self.refs += 1;
    }
    pub fn release(self: *ModelUndoRedoStore) void {
        std.debug.assert(self.refs > 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        self.service.deinit();
        var iterator = self.disposed_models.valueIterator();
        while (iterator.next()) |record| record.*.deinit(self.allocator);
        self.disposed_models.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn releaseOwner(self: *ModelUndoRedoStore) void {
        self.configuration_service = null;
        self.release();
    }

    fn maintainsUndoStack(self: *const ModelUndoRedoStore, resource: std.Uri) bool {
        if (self.configuration_service) |service| if (!service.getBool("files.restoreUndoStack", true)) return false;
        for ([_][]const u8{ "file", "vscode-remote", "vscode-userdata", "vscode-notebook-cell", "fake-fs" }) |scheme| {
            if (std.mem.eql(u8, scheme, resource.scheme)) return true;
        }
        return false;
    }

    fn hashModel(model: *TextModel) ![Sha1.digest_length]u8 {
        if (model.getValueLength(null, false) > MAX_MODEL_SIZE) return error.ModelTooLarge;
        var value = try model.getValue(null, false);
        defer value.deinit();
        var digest: [Sha1.digest_length]u8 = undefined;
        Sha1.hash(value.items, &digest, .{});
        return digest;
    }

    fn removeDisposedModel(self: *ModelUndoRedoStore, key: []const u8) ?*DisposedModelInfo {
        const record = self.disposed_models.fetchRemove(key) orelse return null;
        self.disposed_models_heap_size -= record.value.heap_size;
        return record.value;
    }

    fn ensureDisposedModelsHeapSize(self: *ModelUndoRedoStore, maximum: usize) void {
        while (self.disposed_models_heap_size > maximum) {
            var oldest: ?*DisposedModelInfo = null;
            var iterator = self.disposed_models.valueIterator();
            while (iterator.next()) |record| {
                if (oldest == null or record.*.time < oldest.?.time) oldest = record.*;
            }
            const record = self.removeDisposedModel((oldest orelse break).key).?;
            defer record.deinit(self.allocator);
            if (record.initial_snapshot) |snapshot| self.service.restoreSnapshot(snapshot) catch {};
        }
    }

    fn isModelElement(element: *const edit_stack.EditStackElement) bool {
        return element.* != .workspace;
    }

    /// Called while the model and its URI still exist. On a failed retention
    /// allocation, restore its initial snapshot so no history retains a stale
    /// native model pointer.
    pub fn onWillDisposeModel(self: *ModelUndoRedoStore, model: *TextModel) void {
        self.retainClosedModel(model) catch {
            if (model.getInitialUndoRedoSnapshot()) |snapshot| {
                self.service.restoreSnapshot(snapshot) catch self.service.removeElements(model.uri()) catch {};
            } else self.service.removeElements(model.uri()) catch {};
        };
    }
    fn retainClosedModel(self: *ModelUndoRedoStore, model: *TextModel) !void {
        const uri = model.uri();
        if (!self.maintainsUndoStack(uri)) {
            if (model.getInitialUndoRedoSnapshot()) |snapshot| try self.service.restoreSnapshot(snapshot);
            return;
        }
        var elements = try self.service.getElements(uri);
        defer elements.deinit(self.allocator);
        var maintain = false;
        var heap_size: usize = 0;
        for ([_][]const *const edit_stack.EditStackElement{ elements.past, elements.future }) |list| {
            for (list) |element| if (element.matchesResource(uri)) {
                maintain = true;
                heap_size +|= try element.heapSize(uri);
            };
        }
        if (!maintain) return;
        if (heap_size > MAX_MEMORY_FOR_CLOSED_FILES_UNDO_STACK) return error.UndoStackTooLarge;
        const digest = try hashModel(model);
        self.ensureDisposedModelsHeapSize(MAX_MEMORY_FOR_CLOSED_FILES_UNDO_STACK - heap_size);
        const record = try self.allocator.create(DisposedModelInfo);
        errdefer self.allocator.destroy(record);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned_uri = try uri_util.clone(arena.allocator(), uri);
        const key = try uri_util.resourceKey(arena.allocator(), uri);
        try self.disposed_models.ensureUnusedCapacity(self.allocator, 1);
        if (self.removeDisposedModel(key)) |old| old.deinit(self.allocator);
        record.* = .{ .arena = arena, .key = key, .uri = owned_uri, .initial_snapshot = model.getInitialUndoRedoSnapshot(), .time = time.milliTimestamp(model.clockIo()), .heap_size = heap_size, .sha1 = digest, .version_id = model.getVersionId(), .alternative_version_id = model.getAlternativeVersionId() };
        if (record.initial_snapshot) |*snapshot| snapshot.resource = owned_uri;
        model._initialUndoRedoSnapshot = null; // transfer ownership to the retained record
        for ([_][]const *const edit_stack.EditStackElement{ elements.past, elements.future }) |list| {
            for (list) |element| if (element.matchesResource(uri)) @constCast(element).setModel(.{ .uri = owned_uri });
        }
        // `setElementsValidFlag` is scoped to this resource stack; workspace
        // file operations remain valid even while their text model is closed.
        self.service.setElementsValidFlag(uri, false, isModelElement) catch {};
        self.disposed_models.putAssumeCapacity(key, record);
        self.disposed_models_heap_size += heap_size;
    }

    pub fn onModelCreated(self: *ModelUndoRedoStore, model: *TextModel) !void {
        const key = try uri_util.resourceKey(self.allocator, model.uri());
        defer self.allocator.free(key);
        const record = self.removeDisposedModel(key) orelse return;
        defer record.deinit(self.allocator);
        errdefer if (record.initial_snapshot) |snapshot| self.service.restoreSnapshot(snapshot) catch {};
        const hash = hashModel(model) catch null;
        if (hash != null and std.mem.eql(u8, &hash.?, &record.sha1)) {
            var elements = try self.service.getElements(model.uri());
            defer elements.deinit(self.allocator);
            for ([_][]const *const edit_stack.EditStackElement{ elements.past, elements.future }) |list| {
                for (list) |element| if (element.matchesResource(model.uri())) @constCast(element).setModel(.{ .model = model });
            }
            self.service.setElementsValidFlag(model.uri(), true, isModelElement) catch {};
            model._overwriteVersionId(record.version_id);
            model._overwriteAlternativeVersionId(record.alternative_version_id);
            if (record.initial_snapshot) |snapshot| {
                var transferred = snapshot;
                transferred.resource = model.uri();
                model._overwriteInitialUndoRedoSnapshot(transferred);
                record.initial_snapshot = null;
            }
        } else if (record.initial_snapshot) |snapshot| try self.service.restoreSnapshot(snapshot);
    }
};

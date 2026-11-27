// Port of `src/vs/editor/common/services/modelUndoRedoParticipant.ts`.
// Model acquisition is asynchronous on the window dispatcher; the completion
// owns model references until UndoRedoService has revalidated and executed
// the operation. Canceling detaches every pending model acquisition.
const std = @import("std");
const model = @import("modelService.zig");
const resolver = @import("resolverService.zig");
const undo = @import("../../../platform/undoRedo/common/undoRedo.zig");
const UndoRedoService = @import("../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService;
const edit_stack = @import("../model/editStack.zig");
const uri = @import("../../../base/common/stdUri.zig");
const Disposable = undo.IDisposable;

pub const ModelUndoRedoParticipant = struct {
    allocator: std.mem.Allocator,
    models: model.IModelService,
    resolver_service: resolver.ITextModelService,
    undo_service: *UndoRedoService,
    model_removed_listener: usize,

    pub fn create(a: std.mem.Allocator, models: model.IModelService, resolver_service: resolver.ITextModelService, undo_service: *UndoRedoService) !*ModelUndoRedoParticipant {
        const self = try a.create(ModelUndoRedoParticipant);
        errdefer a.destroy(self);
        self.* = .{
            .allocator = a,
            .models = models,
            .resolver_service = resolver_service,
            .undo_service = undo_service,
            .model_removed_listener = try models.on_model_removed.listen(self, onModelRemoved),
        };
        return self;
    }

    pub fn dispose(self: *ModelUndoRedoParticipant) void {
        self.models.on_model_removed.unlisten(self.model_removed_listener);
        self.undo_service.cancelPendingPreparations();
        self.undo_service.clearPrepareDelegate(self);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *ModelUndoRedoParticipant) edit_stack.UndoRedoDelegate {
        return .{ .context = self, .prepare_fn = prepareUndoRedo };
    }

    fn onModelRemoved(removed: resolver.IResolvedTextEditorModel, self: *ModelUndoRedoParticipant) !void {
        var elements = try self.undo_service.getElements(removed.textEditorModel.uri());
        defer elements.deinit(self.allocator);
        for ([_][]const *const edit_stack.EditStackElement{ elements.past, elements.future }) |stack| {
            for (stack) |element| {
                const mutable = @constCast(element);
                if (mutable.* == .multiModel) mutable.multiModel.setDelegate(self.interface());
            }
        }
    }

    fn prepareUndoRedo(context: *anyopaque, element: *edit_stack.MultiModelEditStackElement, listener: undo.PrepareUndoRedoListener) !?Disposable {
        const self: *ModelUndoRedoParticipant = @ptrCast(@alignCast(context));
        var missing = try element.getMissingModels();
        defer missing.deinit();
        if (missing.items.len == 0) {
            listener.complete(listener.context, .none);
            return null;
        }
        return Preparation.start(self.allocator, self.resolver_service, missing.items, listener);
    }
};

const Preparation = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    listener: undo.PrepareUndoRedoListener,
    tasks: []Task,
    remaining: usize,
    starting: bool = true,

    const Task = struct {
        owner: *Preparation,
        resource: std.Uri,
        pending: ?resolver.ModelReferenceRequest = null,
        reference: ?resolver.ModelReference = null,
        completed: bool = false,

        fn resolved(context: *anyopaque, result: resolver.ModelReferenceResult) void {
            const self: *Task = @ptrCast(@alignCast(context));
            self.pending = null;
            self.completed = true;
            // A missing/deleted model stays invalid; UndoRedoService handles
            // the failed verification exactly as for other invalid resources.
            if (result == .resolved) self.reference = result.resolved;
            const owner = self.owner;
            owner.remaining -= 1;
            if (!owner.starting and owner.remaining == 0) owner.finish();
        }
    };

    fn start(a: std.mem.Allocator, service: resolver.ITextModelService, missing: []const std.Uri, listener: undo.PrepareUndoRedoListener) !?Disposable {
        const self = try a.create(Preparation);
        errdefer a.destroy(self);
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const tasks = try arena.allocator().alloc(Task, missing.len);
        for (missing, tasks) |resource, *task| {
            task.* = .{ .owner = self, .resource = try uri.clone(arena.allocator(), resource) };
        }
        self.* = .{
            .allocator = a,
            .arena = arena,
            .listener = listener,
            .tasks = tasks,
            .remaining = tasks.len,
        };
        for (self.tasks) |*task| {
            const pending = service.createModelReference(task.resource, .{
                .context = task,
                .complete = Task.resolved,
            }) catch |err| {
                Task.resolved(task, .{ .failure = err });
                continue;
            };
            if (!task.completed) task.pending = pending;
        }
        self.starting = false;
        if (self.remaining == 0) {
            self.finish();
            return null;
        }
        return Disposable.from(Preparation, self, destroy);
    }

    fn finish(self: *Preparation) void {
        const listener = self.listener;
        // The receiver may synchronously dispose the transferred references.
        listener.complete(listener.context, Disposable.from(Preparation, self, destroy));
    }

    fn destroy(self: *Preparation) void {
        for (self.tasks) |*task| {
            if (task.pending) |pending| pending.cancel();
            if (task.reference) |*reference| reference.dispose();
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

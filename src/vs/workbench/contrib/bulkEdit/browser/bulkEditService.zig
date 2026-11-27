// Port of `src/vs/workbench/contrib/bulkEdit/browser/bulkEditService.ts`.
// The model-reference service supplies all text-edit targets, including
// unmounted working documents. A registered preview handler selects the edits
// before any operation touches the underlying resources.
const std = @import("std");
const bulk = @import("../../../../editor/browser/services/bulkEditService.zig");
const languages = @import("../../../../editor/common/languages.zig");
const resolver = @import("../../../../editor/common/services/resolverService.zig");
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const BulkTextEdits = @import("bulkTextEdits.zig").BulkTextEdits;

pub const BulkEditService = struct {
    allocator: std.mem.Allocator,
    resolver_service: resolver.ITextModelService,
    preview_handler: ?*PreviewRegistration = null,

    const PreviewRegistration = struct {
        owner: *BulkEditService,
        handler: bulk.IBulkEditPreviewHandler,
        fn dispose(self: *PreviewRegistration) void {
            if (self.owner.preview_handler == self) self.owner.preview_handler = null;
            self.owner.allocator.destroy(self);
        }
    };

    pub fn interface(self: *BulkEditService) bulk.IBulkEditService {
        return .{ .context = self, .apply_fn = apply, .has_preview_handler_fn = hasPreviewHandler, .set_preview_handler_fn = setPreviewHandler };
    }

    fn apply(context: *anyopaque, edit: languages.WorkspaceEdit, options: bulk.IBulkEditOptions, listener: bulk.EditListener) !?Disposable {
        const self: *BulkEditService = @ptrCast(@alignCast(context));
        try options.token.throwIfCancellationRequested();
        if (edit.edits.len == 0) {
            listener.complete(listener.context, .{ .is_applied = false });
            return null;
        }
        if (self.preview_handler) |registration| {
            var needs_preview = options.show_preview;
            for (edit.edits) |resource_edit| {
                const metadata = switch (resource_edit) {
                    .text => |text| text.metadata,
                    .file => |file| file.metadata,
                };
                if (metadata) |value| needs_preview = needs_preview or value.needs_confirmation;
            }
            if (needs_preview) return PreviewApplyRequest.start(self, registration.handler, edit.edits, options, listener);
        }
        return self.applyEdits(edit.edits, options, listener);
    }

    fn applyEdits(self: *BulkEditService, edits: []const bulk.ResourceEdit, options: bulk.IBulkEditOptions, listener: bulk.EditListener) !?Disposable {
        return BulkTextEdits.start(self.allocator, self.resolver_service, edits, options, listener);
    }

    fn setPreviewHandler(context: *anyopaque, handler: bulk.IBulkEditPreviewHandler) !Disposable {
        const self: *BulkEditService = @ptrCast(@alignCast(context));
        const registration = try self.allocator.create(PreviewRegistration);
        registration.* = .{ .owner = self, .handler = handler };
        self.preview_handler = registration;
        return Disposable.from(PreviewRegistration, registration, PreviewRegistration.dispose);
    }

    fn hasPreviewHandler(context: *anyopaque) bool {
        const self: *BulkEditService = @ptrCast(@alignCast(context));
        return self.preview_handler != null;
    }
};

const PreviewApplyRequest = struct {
    service: *BulkEditService,
    options: bulk.IBulkEditOptions,
    listener: bulk.EditListener,
    phase: enum { preview, applying, finished } = .preview,
    pending: ?Disposable = null,
    cancellation_listener: ?Disposable = null,
    depth: usize = 0,
    result: ?anyerror!bulk.IBulkEditResult = null,
    detached: bool = false,

    fn start(service: *BulkEditService, handler: bulk.IBulkEditPreviewHandler, edits: []const bulk.ResourceEdit, options: bulk.IBulkEditOptions, listener: bulk.EditListener) !?Disposable {
        const self = try service.allocator.create(PreviewApplyRequest);
        self.* = .{ .service = service, .options = options, .listener = listener, .depth = 1 };
        self.cancellation_listener = options.token.onCancellationRequested(.{ .context = self, .callbackFn = onCanceled }) catch |err| {
            service.allocator.destroy(self);
            return err;
        };
        if (self.phase == .preview) {
            const pending = handler.preview(handler.context, edits, options, .{ .context = self, .complete = previewCompleted }) catch |err| blk: {
                self.finish(err);
                break :blk null;
            };
            if (self.phase == .preview) self.pending = pending else if (pending) |handle| handle.dispose();
        }
        const finished = self.phase == .finished;
        self.leave();
        return if (finished) null else Disposable.from(PreviewApplyRequest, self, dispose);
    }

    fn previewCompleted(context: *anyopaque, reply: anyerror![]const bulk.ResourceEdit) void {
        const self: *PreviewApplyRequest = @ptrCast(@alignCast(context));
        if (self.phase != .preview) return;
        self.depth += 1;
        defer self.leave();
        self.pending = null;
        const edits = reply catch |err| {
            self.finish(err);
            return;
        };
        if (edits.len == 0) {
            self.finish(.{ .is_applied = false });
            return;
        }
        self.phase = .applying;
        self.options.show_preview = false;
        const pending = self.service.applyEdits(edits, self.options, .{ .context = self, .complete = editsApplied }) catch |err| {
            self.finish(err);
            return;
        };
        if (self.phase == .applying) self.pending = pending else if (pending) |handle| handle.dispose();
    }

    fn editsApplied(context: *anyopaque, value: anyerror!bulk.IBulkEditResult) void {
        const self: *PreviewApplyRequest = @ptrCast(@alignCast(context));
        if (self.phase != .applying) return;
        self.pending = null;
        self.finish(value);
    }

    fn onCanceled(context: *anyopaque) void {
        const self: *PreviewApplyRequest = @ptrCast(@alignCast(context));
        self.cancel(false);
    }
    fn dispose(self: *PreviewApplyRequest) void {
        self.cancel(true);
    }
    fn cancel(self: *PreviewApplyRequest, detached: bool) void {
        if (self.phase == .finished) return;
        self.depth += 1;
        defer self.leave();
        self.detached = detached;
        // Detach the child before it can answer; callbacks cannot publish a
        // selected preview after the originating action or window closes.
        self.phase = .finished;
        if (self.pending) |pending| pending.dispose();
        self.pending = null;
        self.result = error.CancellationError;
    }

    fn finish(self: *PreviewApplyRequest, result: anyerror!bulk.IBulkEditResult) void {
        if (self.phase == .finished) return;
        self.phase = .finished;
        self.pending = null;
        self.result = result;
        if (self.depth == 0) self.complete();
    }
    fn leave(self: *PreviewApplyRequest) void {
        self.depth -= 1;
        if (self.depth == 0 and self.phase == .finished) self.complete();
    }
    fn complete(self: *PreviewApplyRequest) void {
        if (self.cancellation_listener) |listener| listener.dispose();
        const listener = self.listener;
        const result = self.result.?;
        const notify = !self.detached;
        self.service.allocator.destroy(self);
        if (notify) listener.complete(listener.context, result);
    }
};

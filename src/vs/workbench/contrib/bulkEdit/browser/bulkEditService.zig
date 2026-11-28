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
const EditorEditTarget = @import("bulkTextEdits.zig").EditorEditTarget;
const file_edits = @import("bulkFileEdits.zig");
const group_mod = @import("../../../../platform/undoRedo/common/undoRedo.zig");
const window_dispatch = @import("../../../../base/common/windowDispatch.zig");
const cancellation = @import("../../../../base/common/cancellation.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");

pub const auto_save_setting = "files.refactoring.autoSave";
pub const properties = [_]@import("../../../../platform/configuration/common/configurationRegistry.zig").PropertySchema{
    .{ .key = auto_save_setting, .value_type = "boolean", .default = .{ .bool = true } },
};

pub const BulkEditService = struct {
    allocator: std.mem.Allocator,
    resolver_service: resolver.ITextModelService,
    undo_redo_service: *@import("../../../../platform/undoRedo/common/undoRedoService.zig").UndoRedoService,
    file_services: ?file_edits.Services = null,
    working_copy_service: ?*@import("../../../services/workingCopy/common/workingCopyService.zig").WorkingCopyService = null,
    active_groups: std.ArrayList(*ActiveGroup) = .empty,
    window: ?*window_dispatch.Queue = null,
    file_jobs: std.Io.Group = .init,
    stopping: bool = false,
    preview_handler: ?*PreviewRegistration = null,

    /// Join outstanding file groups before disposing providers, listeners
    /// and the undo store. An already-started operation publishes its result
    /// before the request's owned data is released.
    pub fn cancelFileJobs(self: *BulkEditService) void {
        self.stopping = true;
        if (self.window) |window| self.file_jobs.cancel(window.io);
    }

    const ActiveGroup = struct { value: group_mod.UndoRedoGroup, references: usize = 1 };

    fn acquireGroup(self: *BulkEditService, id: ?u64) !*ActiveGroup {
        if (id) |requested| for (self.active_groups.items) |group| {
            if (group.value.id == requested) {
                group.references += 1;
                return group;
            }
        };
        const group = try self.allocator.create(ActiveGroup);
        errdefer self.allocator.destroy(group);
        group.* = .{ .value = group_mod.UndoRedoGroup.init() };
        try self.active_groups.append(self.allocator, group);
        return group;
    }

    fn releaseGroup(self: *BulkEditService, group: *ActiveGroup) void {
        group.references -= 1;
        if (group.references != 0) return;
        for (self.active_groups.items, 0..) |entry, index| if (entry == group) {
            _ = self.active_groups.swapRemove(index);
            break;
        };
        self.allocator.destroy(group);
        if (self.active_groups.items.len == 0) self.active_groups.clearAndFree(self.allocator);
    }

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
        return BulkApplyRequest.start(self, edits, options, listener);
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

/// Contiguous resource groups execute in original workspace-edit order,
/// with one active undo group shared by text and file operations. The request
/// owns every DTO and a detachable originating editor reference so preview
/// dismissal or a later file/model-reference completion cannot retain a
/// disposed view. Selection is read from the actual editor edit task.
const BulkApplyRequest = struct {
    service: *BulkEditService,
    arena: std.heap.ArenaAllocator,
    edits: []const bulk.ResourceEdit,
    options: bulk.IBulkEditOptions,
    listener: bulk.EditListener,
    group: *BulkEditService.ActiveGroup,
    editor_target: EditorEditTarget = .{},
    next: usize = 0,
    result: bulk.IBulkEditResult = .{ .is_applied = false },
    resources: std.StringHashMapUnmanaged(void) = .empty,
    resources_complete: bool = true,
    completion: ?anyerror!bulk.IBulkEditResult = null,
    pending: ?Disposable = null,
    cancellation_listener: ?Disposable = null,
    waiting: bool = false,
    advancing: bool = false,
    depth: usize = 1,
    detached: bool = false,
    file_cancellation: cancellation.MutableToken,

    fn cloneMetadata(a: std.mem.Allocator, metadata: ?languages.WorkspaceEditMetadata) !?languages.WorkspaceEditMetadata {
        var value = metadata orelse return null;
        value.label = try a.dupe(u8, value.label);
        if (value.description) |description| value.description = try a.dupe(u8, description);
        return value;
    }
    fn cloneEdit(a: std.mem.Allocator, edit: bulk.ResourceEdit) !bulk.ResourceEdit {
        switch (edit) {
            .text => |value| {
                var owned = value;
                owned.resource = try uri_util.clone(a, value.resource);
                owned.text = try a.dupe(u8, value.text);
                owned.metadata = try cloneMetadata(a, value.metadata);
                return .{ .text = owned };
            },
            .file => |value| {
                var owned = value;
                if (value.old_resource) |uri| owned.old_resource = try uri_util.clone(a, uri);
                if (value.new_resource) |uri| owned.new_resource = try uri_util.clone(a, uri);
                if (value.options.contents) |contents| owned.options.contents = try a.dupe(u8, contents);
                owned.metadata = try cloneMetadata(a, value.metadata);
                return .{ .file = owned };
            },
        }
    }

    fn start(service: *BulkEditService, edits: []const bulk.ResourceEdit, options: bulk.IBulkEditOptions, listener: bulk.EditListener) !?Disposable {
        try options.token.throwIfCancellationRequested();
        const self = try service.allocator.create(BulkApplyRequest);
        errdefer service.allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(service.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.alloc(bulk.ResourceEdit, edits.len);
        for (edits, owned) |edit, *target| target.* = try cloneEdit(a, edit);
        var saved_options = options;
        if (options.label) |label| saved_options.label = try a.dupe(u8, label);
        if (options.code) |code| saved_options.code = try a.dupe(u8, code);
        if (options.quotable_label) |label| saved_options.quotable_label = try a.dupe(u8, label);
        saved_options.editor = null;
        const group = try service.acquireGroup(options.undo_redo_group_id);
        errdefer service.releaseGroup(group);
        self.* = .{ .service = service, .arena = arena, .edits = owned, .options = saved_options, .listener = listener, .group = group, .file_cancellation = cancellation.MutableToken.init(service.allocator) };
        errdefer self.file_cancellation.deinit();
        try self.editor_target.attach(options.editor);
        errdefer self.editor_target.deinit();
        self.cancellation_listener = try options.token.onCancellationRequested(.{ .context = self, .callbackFn = onCanceled });
        self.advance();
        const finished = self.completion != null;
        self.leave();
        return if (finished) null else Disposable.from(BulkApplyRequest, self, dispose);
    }

    fn accumulate(self: *BulkApplyRequest, result: bulk.IBulkEditResult) void {
        self.result.is_applied = self.result.is_applied or result.is_applied;
        self.result.edited_resources += result.edited_resources;
        self.result.edit_count += result.edit_count;
    }
    fn reportResources(context: *anyopaque, resources: []const std.Uri) void {
        const self: *BulkApplyRequest = @ptrCast(@alignCast(context));
        const a = self.arena.allocator();
        for (resources) |resource| {
            const key = uri_util.resourceKey(a, resource) catch {
                self.resources_complete = false;
                continue;
            };
            self.resources.put(a, key, {}) catch {
                self.resources_complete = false;
            };
        }
    }
    const SaveGroup = struct {
        allocator: std.mem.Allocator,
        owner: ?*BulkApplyRequest,
        remaining: usize = 1, // sentinel while issuing the working-copy saves

        fn completed(context: *anyopaque, result: anyerror!bool) void {
            const self: *SaveGroup = @ptrCast(@alignCast(context));
            if (result) |_| {} else |err| std.log.warn("Bulk edit save failed: {s}", .{@errorName(err)});
            self.release();
        }

        fn release(self: *SaveGroup) void {
            self.remaining -= 1;
            if (self.remaining != 0) return;
            const owner = self.owner;
            self.allocator.destroy(self);
            if (owner) |request| request.completedAutoSave();
        }

        fn detach(context: *anyopaque) void {
            const self: *SaveGroup = @ptrCast(@alignCast(context));
            self.owner = null;
        }
    };

    fn maybeAutoSave(self: *BulkApplyRequest) bool {
        if (!self.options.respect_auto_save_config or self.result.edited_resources <= 1 or !self.resources_complete) return false;
        const copies = self.service.working_copy_service orelse return false;
        const config = if (self.service.file_services) |services| services.configuration_service else null;
        if (config) |settings| if (!settings.getBool(auto_save_setting, true)) return false;
        const a = self.arena.allocator();
        const dirty = copies.dirtyWorkingCopies(a) catch return false;
        const saves = self.service.allocator.create(SaveGroup) catch return false;
        saves.* = .{ .allocator = self.service.allocator, .owner = self };
        self.waiting = true;
        self.pending = .{ .context = saves, .disposeFn = SaveGroup.detach };
        for (dirty) |copy| {
            if (self.completion != null) break;
            const key = uri_util.resourceKey(a, copy.getResourceUri()) catch continue;
            if (!self.resources.contains(key)) continue;
            saves.remaining += 1;
            copy.requestSave(.{ .context = saves, .complete = SaveGroup.completed }) catch |err| SaveGroup.completed(saves, err);
        }
        // All immediate results have already been delivered. The sentinel
        // keeps the group alive until every save has been issued.
        saves.release();
        return true;
    }

    fn completedAutoSave(self: *BulkApplyRequest) void {
        if (self.completion != null) return;
        self.depth += 1;
        defer self.leave();
        self.waiting = false;
        self.pending = null;
        self.finish(self.result);
    }

    fn advance(self: *BulkApplyRequest) void {
        if (self.completion != null or self.advancing) return;
        self.advancing = true;
        defer self.advancing = false;
        while (self.completion == null and !self.waiting) {
            if (self.service.stopping or self.options.token.isCancellationRequested()) {
                self.finish(error.CancellationError);
                return;
            }
            if (self.next == self.edits.len) {
                self.result.is_applied = self.edits.len != 0;
                if (!self.maybeAutoSave()) self.finish(self.result);
                return;
            }
            const start_index = self.next;
            const kind = std.meta.activeTag(self.edits[start_index]);
            while (self.next < self.edits.len and std.meta.activeTag(self.edits[self.next]) == kind) self.next += 1;
            const edits = self.edits[start_index..self.next];
            switch (kind) {
                .file => {
                    const services = self.service.file_services orelse {
                        self.finish(error.UnsupportedResourceEdit);
                        return;
                    };
                    if (self.service.window) |window| if (window.scheduler != null) {
                        // One in-flight reference protects the request's DTOs
                        // and undo group across native awaits, even if the
                        // originating editor/rpc disposes its callback.
                        self.waiting = true;
                        self.depth += 1;
                        self.service.file_jobs.concurrent(window.io, runFileGroup, .{ self, services, edits }) catch |err| {
                            self.depth -= 1;
                            self.waiting = false;
                            self.finish(err);
                        };
                        return;
                    };
                    const result = file_edits.BulkFileEdits.applyWithReporting(self.service.allocator, services, edits, self.options, &self.group.value, .{ .context = self, .report = reportResources }) catch |err| {
                        self.finish(err);
                        return;
                    };
                    self.accumulate(result);
                },
                .text => {
                    self.waiting = true;
                    const request = BulkTextEdits.start(self.service.allocator, self.service.resolver_service, self.service.undo_redo_service, edits, self.options, &self.group.value, &self.editor_target, .{ .context = self, .report = reportResources }, .{ .context = self, .complete = completedTextGroup }) catch |err| {
                        self.waiting = false;
                        self.finish(err);
                        return;
                    };
                    if (self.waiting and self.completion == null) self.pending = request else if (request) |handle| handle.dispose();
                },
            }
        }
    }
    fn runFileGroup(self: *BulkApplyRequest, services: file_edits.Services, edits: []const bulk.ResourceEdit) void {
        defer self.leave();
        if (self.completion != null) return;
        if (self.service.stopping) {
            self.finish(error.CancellationError);
            return;
        }
        // VS Code only forwards the token to file-operation participants;
        // once the operation starts, finish its events and undo bookkeeping.
        // The request observes cancellation at the next group boundary.
        const io = self.service.window.?.io;
        const previous = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous);
        var options = self.options;
        options.token = self.file_cancellation.token();
        const result = file_edits.BulkFileEdits.applyWithReporting(self.service.allocator, services, edits, options, &self.group.value, .{ .context = self, .report = reportResources });
        self.waiting = false;
        if (self.completion != null) return;
        self.accumulate(result catch |err| {
            self.finish(err);
            return;
        });
        self.advance();
    }

    fn completedTextGroup(context: *anyopaque, reply: anyerror!bulk.IBulkEditResult) void {
        const self: *BulkApplyRequest = @ptrCast(@alignCast(context));
        if (self.completion != null or !self.waiting) return;
        self.depth += 1;
        defer self.leave();
        self.waiting = false;
        self.pending = null;
        const result = reply catch |err| {
            self.finish(err);
            return;
        };
        self.accumulate(result);
        self.advance();
    }
    fn onCanceled(context: *anyopaque) void {
        const self: *BulkApplyRequest = @ptrCast(@alignCast(context));
        self.cancel(false);
    }
    fn dispose(self: *BulkApplyRequest) void {
        self.cancel(true);
    }
    fn cancel(self: *BulkApplyRequest, detached: bool) void {
        if (self.completion != null) return;
        self.depth += 1;
        defer self.leave();
        self.detached = detached;
        self.completion = error.CancellationError;
        self.file_cancellation.cancel();
        // The caller may dispose its token before the detached file group
        // finishes; release that subscription now.
        if (self.cancellation_listener) |listener| listener.dispose();
        self.cancellation_listener = null;
        if (self.pending) |handle| handle.dispose();
        self.pending = null;
    }
    fn finish(self: *BulkApplyRequest, reply: anyerror!bulk.IBulkEditResult) void {
        if (self.completion != null) return;
        self.completion = reply;
    }
    fn leave(self: *BulkApplyRequest) void {
        self.depth -= 1;
        if (self.depth != 0 or self.completion == null) return;
        if (self.cancellation_listener) |listener| listener.dispose();
        const listener = self.listener;
        const reply = self.completion.?;
        const notify = !self.detached;
        self.service.releaseGroup(self.group);
        self.editor_target.deinit();
        self.file_cancellation.deinit();
        self.arena.deinit();
        self.service.allocator.destroy(self);
        if (notify) listener.complete(listener.context, reply);
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
    editor_target: EditorEditTarget = .{},

    fn start(service: *BulkEditService, handler: bulk.IBulkEditPreviewHandler, edits: []const bulk.ResourceEdit, options: bulk.IBulkEditOptions, listener: bulk.EditListener) !?Disposable {
        const self = try service.allocator.create(PreviewApplyRequest);
        self.* = .{ .service = service, .options = options, .listener = listener, .depth = 1 };
        self.editor_target.attach(options.editor) catch |err| {
            service.allocator.destroy(self);
            return err;
        };
        self.options.editor = null;
        self.cancellation_listener = options.token.onCancellationRequested(.{ .context = self, .callbackFn = onCanceled }) catch |err| {
            self.editor_target.deinit();
            service.allocator.destroy(self);
            return err;
        };
        if (self.phase == .preview) {
            const pending = handler.preview(handler.context, edits, self.options, .{ .context = self, .complete = previewCompleted }) catch |err| blk: {
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
        var options = self.options;
        options.editor = self.editor_target.editor;
        const pending = self.service.applyEdits(edits, options, .{ .context = self, .complete = editsApplied }) catch |err| {
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
        self.editor_target.deinit();
        self.service.allocator.destroy(self);
        if (notify) listener.complete(listener.context, result);
    }
};

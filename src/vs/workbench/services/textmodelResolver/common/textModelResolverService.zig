// Port of `src/vs/workbench/services/textmodelResolver/common/textModelResolverService.ts`.
// Native reads are immutable worker requests; ResourceModelCollection owns
// published URI model identity and deferred last-reference disposal.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text_file = @import("../../textfile/common/textFileService.zig");
const encoding = @import("../../textfile/common/encoding.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");
const DiskFileService = @import("../../../../platform/files/common/fileService.zig").DiskFileService;
const files = @import("../../../../platform/files/common/files.zig");
const event_mod = @import("../../../../base/common/event.zig");

const resolver = @import("../../../../editor/common/services/resolverService.zig");
const EditorDocument = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const worker_mod = @import("../../../../editor/browser/services/editorWorkerService.zig");
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const web_worker = @import("../../../../editor/common/services/editorWebWorker.zig");
const WorkingCopyListener = @import("../../workingCopy/common/workingCopy.zig").WorkingCopyListener;

/// The resource collection retains one native document while any resolver
/// reference exists, or while last-reference disposal is pending. Existing
/// editor inputs may also own the document: the URI registration itself is
/// weak and is removed by the document's actual disposal event.
pub const TextModelResolverService = struct {
    allocator: Allocator,
    io: std.Io,
    window: *dispatch.Queue,
    collection: ResourceModelCollection,
    file_service: ?files.IFileService = null,
    file_listener: ?event_mod.SignalSubscription = null,
    providers: std.ArrayList(*ProviderEntry) = .empty,
    next_provider_id: usize = 0,
    worker: ?*worker_mod.EditorWorkerService = null,
    pending: std.StringHashMapUnmanaged(*PendingReference) = .empty,
    pending_listeners: std.AutoHashMapUnmanaged(u64, *PendingReference) = .empty,
    next_request_id: u64 = 0,
    delivering: ?*PendingReference = null,
    virtual_updates: std.AutoHashMapUnmanaged(*EditorDocument, *VirtualUpdate) = .empty,

    const ProviderEntry = struct {
        service: *TextModelResolverService,
        id: usize,
        scheme: []u8,
        provider: resolver.ITextModelContentProvider,
        listener: ?@import("../../../../base/common/event.zig").SignalSubscription = null,

        fn changed(change: resolver.ContentChange, self: *ProviderEntry) !void {
            try self.service.onProviderContentChanged(self.scheme, change);
        }
        fn destroy(self: *ProviderEntry) void {
            if (self.listener) |listener| listener.dispose();
            const a = self.service.allocator;
            a.free(self.scheme);
            a.destroy(self);
        }
    };

    pub fn init(allocator: Allocator, io: std.Io, window: *dispatch.Queue) TextModelResolverService {
        return .{ .allocator = allocator, .io = io, .window = window, .collection = ResourceModelCollection.init(allocator, window) };
    }

    /// The workbench supplies the window's registered file service. Virtual
    /// filesystem resources resolve through the same raw-byte text-file
    /// decoding path; content providers retain their distinct upstream role.
    pub fn bindFileService(self: *TextModelResolverService, service: files.IFileService) !void {
        if (self.file_listener) |listener| listener.dispose();
        self.file_listener = null;
        self.file_service = service;
        self.file_listener = try service.on_did_files_change.listenDisposable(self, onFilesChanged);
    }

    fn onFilesChanged(change: files.FileChangesEvent, self: *TextModelResolverService) !void {
        const service = self.file_service orelse return;
        for ([_][]const []const u8{ change.raw_updated, change.raw_added, change.raw_deleted }) |resources| {
            for (resources) |encoded| {
                const uri = std.Uri.parse(encoded) catch continue;
                // Working files are handled by the text-file working copy
                // service; never overwrite their unsaved contents here.
                if (std.mem.eql(u8, uri.scheme, "file") or !service.hasProvider(uri)) continue;
                try self.queueProviderRefresh(uri);
            }
        }
    }

    pub fn hasResolvedModel(self: *TextModelResolverService, uri: std.Uri) bool {
        const key = uri_util.resourceKey(self.allocator, uri) catch return false;
        defer self.allocator.free(key);
        return self.collection.entries.contains(key);
    }

    pub fn deinit(self: *TextModelResolverService) void {
        if (self.file_listener) |listener| listener.dispose();
        self.file_listener = null;
        self.file_service = null;
        for (self.providers.items) |entry| entry.destroy();
        self.providers.deinit(self.allocator);
        var delivery = self.delivering;
        while (delivery) |pending| {
            pending.service = null;
            delivery = pending.previous_delivery;
        }
        self.delivering = null;
        var iterator = self.pending.valueIterator();
        while (iterator.next()) |value| {
            const pending = value.*;
            pending.service = null;
            pending.canceled.store(true, .release);
            pending.delivery.schedule(null);
            if (!pending.worker_submitted) pending.destroy();
        }
        self.pending.deinit(self.allocator);
        self.pending_listeners.deinit(self.allocator);
        while (self.virtual_updates.count() != 0) {
            var updates = self.virtual_updates.valueIterator();
            updates.next().?.*.detach(true);
        }
        self.virtual_updates.deinit(self.allocator);
        if (self.worker) |worker| {
            worker.deinit();
            self.allocator.destroy(worker);
            self.worker = null;
        }
        self.collection.deinit();
    }

    pub fn registerTextModelContentProvider(self: *TextModelResolverService, scheme: []const u8, provider: resolver.ITextModelContentProvider) !resolver.ContentProviderRegistration {
        const entry = try self.allocator.create(ProviderEntry);
        errdefer self.allocator.destroy(entry);
        const owned = try self.allocator.dupe(u8, scheme);
        errdefer self.allocator.free(owned);
        const id = self.next_provider_id;
        self.next_provider_id += 1;
        entry.* = .{ .service = self, .id = id, .scheme = owned, .provider = provider };
        if (provider.on_did_change_content) |event| entry.listener = try event.listenDisposable(entry, ProviderEntry.changed);
        errdefer if (entry.listener) |listener| listener.dispose();
        try self.providers.append(self.allocator, entry);
        return .{ .context = self, .id = id, .remove = unregisterProvider };
    }

    fn unregisterProvider(context: *anyopaque, id: usize) void {
        const self: *TextModelResolverService = @ptrCast(@alignCast(context));
        for (self.providers.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.providers.orderedRemove(index);
            entry.destroy();
            return;
        }
    }

    fn onProviderContentChanged(self: *TextModelResolverService, scheme: []const u8, change: resolver.ContentChange) !void {
        switch (change) {
            .resources => |uris| for (uris) |uri| {
                if (std.mem.eql(u8, uri.scheme, scheme)) try self.queueProviderRefresh(uri);
            },
            .all => {
                // Only live resources, copied before provider callbacks can
                // reenter registration. This is an event, not a model scan
                // from rendering or the native host loop.
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                const a = scratch.allocator();
                var resources: std.ArrayList(std.Uri) = .empty;
                var iterator = self.collection.entries.valueIterator();
                while (iterator.next()) |value| {
                    const uri = value.*.document.model.uri();
                    if (std.mem.eql(u8, uri.scheme, scheme)) try resources.append(a, try std.Uri.parse(try uri_util.encodedResource(a, uri)));
                }
                for (resources.items) |uri| try self.queueProviderRefresh(uri);
            },
        }
    }

    fn queueProviderRefresh(self: *TextModelResolverService, uri: std.Uri) !void {
        const key = try uri_util.resourceKey(self.allocator, uri);
        defer self.allocator.free(key);
        if (!self.collection.entries.contains(key)) return;
        if (self.pending.get(key)) |pending| {
            // This event arrived after the immutable provider capture; make
            // one more read after its completion so the new content is not lost.
            if (pending.source != null or pending.async_content != null or pending.result != null) pending.provider_refresh_after = true;
        }
        _ = try self.refreshModelReference(uri, .{ .context = self, .complete = providerRefreshCompleted });
    }

    fn providerRefreshCompleted(_: *anyopaque, result: resolver.ModelReferenceResult) void {
        if (result == .resolved) {
            var reference = result.resolved;
            reference.dispose();
        }
    }

    fn captureBuiltinContent(self: *TextModelResolverService, resource: std.Uri) !?resolver.TextContentRequest {
        // The file service wins, and an already-open file supplies its actual
        // unsaved contents rather than a second read of the disk file.
        if (std.mem.eql(u8, resource.scheme, "file")) {
            if (try self.acquireExisting(resource)) |value| {
                var reference = value;
                defer reference.dispose();
                return try CachedContentRequest.create(documentOf(reference), true);
            }
            return try FileContentRequest.create(self.io, resource);
        }
        if (self.file_service) |service| {
            if (try service.captureRead(resource)) |request| return try ProviderContentRequest.create(resource, request);
        }
        return null;
    }

    /// Immediate capture used by native provider tests. Model acquisition uses
    /// the same builtin precedence and provider ordering, including promises.
    pub fn captureContent(self: *TextModelResolverService, resource: std.Uri) !resolver.TextContentRequest {
        if (try self.captureBuiltinContent(resource)) |request| return request;
        // Upstream registers most recent content provider first, falling
        // through only when it declines the resource.
        var index = self.providers.items.len;
        while (index != 0) {
            index -= 1;
            const entry = self.providers.items[index];
            if (!std.mem.eql(u8, entry.scheme, resource.scheme)) continue;
            if (entry.provider.request_content != null) return error.AsynchronousTextContentProvider;
            if (entry.provider.capture) |capture| if (try capture(entry.provider.context, resource)) |request| return request;
        }
        if (try self.acquireExisting(resource)) |value| {
            var reference = value;
            defer reference.dispose();
            return CachedContentRequest.create(documentOf(reference), false);
        }
        return error.UnableToResolveResource;
    }

    /// The editor worker computes minimal whole-model edits, raced against
    /// the upstream one-second fallback. One outstanding update per live
    /// model; disposal and replacement detach the older completion.
    pub fn updateVirtualContent(self: *TextModelResolverService, resource: std.Uri, text: []const u8, listener: resolver.VirtualContentListener) !?IDisposable {
        if (std.mem.eql(u8, resource.scheme, "file")) return null;
        const key = try uri_util.resourceKey(self.allocator, resource);
        defer self.allocator.free(key);
        const entry = self.collection.entries.get(key) orelse return null;
        const document = entry.document;
        if (self.virtual_updates.get(document)) |previous| previous.detach(true);
        const worker = try self.ensureWorker();
        const update = try self.allocator.create(VirtualUpdate);
        errdefer self.allocator.destroy(update);
        update.* = .{ .allocator = self.allocator, .service = self, .document = document, .listener = listener, .version = document.model.getVersionId(), .eol = document.model.getEOL(), .skip_minimal = document.model.isTooLargeForSyncing() };
        errdefer update.arena.deinit();
        const a = update.arena.allocator();
        var original = try document.model.getValue(.TextDefined, false);
        defer original.deinit();
        update.original = try a.dupe(u8, original.items);
        update.text = try a.dupe(u8, text);
        update.deadline = .{ .queue = self.window, .context = update, .run = VirtualUpdate.timeout };
        update.dispose_listener = try document.on_will_dispose.listen(update, VirtualUpdate.onDocumentDisposed);
        errdefer document.on_will_dispose.unlisten(update.dispose_listener.?);
        try self.virtual_updates.put(self.allocator, document, update);
        const now = @import("../../../../base/common/timeCompat.zig").milliTimestamp();
        update.deadline.schedule(now + 1000);
        worker.computeDiff(&update.message, now);
        return IDisposable.from(VirtualUpdate, update, VirtualUpdate.cancel);
    }

    const VirtualUpdate = struct {
        allocator: Allocator,
        service: ?*TextModelResolverService,
        document: *EditorDocument,
        listener: resolver.VirtualContentListener,
        version: u32,
        skip_minimal: bool,
        eol: @import("../../../../editor/common/core/misc/eolCounter.zig").EOL,
        arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
        original: []const u8 = "",
        text: []const u8 = "",
        result: ?web_worker.MinimalEdits = null,
        dispose_listener: ?usize = null,
        deadline: dispatch.Task = .{},
        message: worker_mod.Request = .{ .compute = compute, .reply = reply },

        fn compute(message: *worker_mod.Request) void {
            const self: *VirtualUpdate = @fieldParentPtr("message", message);
            if (self.skip_minimal) return;
            self.result = web_worker.computeMoreMinimalEdits(self.arena.allocator(), self.original, self.text, self.eol, false) catch null;
        }

        fn reply(message: *worker_mod.Request) bool {
            const self: *VirtualUpdate = @fieldParentPtr("message", message);
            defer {
                self.arena.deinit();
                self.allocator.destroy(self);
            }
            return self.apply(self.result);
        }

        fn timeout(context: *anyopaque, _: i64, _: bool) bool {
            const self: *VirtualUpdate = @ptrCast(@alignCast(context));
            return self.apply(null);
        }

        fn apply(self: *VirtualUpdate, result: ?web_worker.MinimalEdits) bool {
            if (self.service == null) return false;
            const document = self.document;
            document.retain();
            defer document.release();
            self.detach(false);
            const changed = if (result != null and document.model.getVersionId() == self.version)
                document.applyGeneratedEdits(result.?)
            else
                document.replaceGeneratedContents(self.text);
            const value = changed catch |err| {
                self.listener.complete(self.listener.context, err);
                return false;
            };
            self.listener.complete(self.listener.context, {});
            return value;
        }

        fn onDocumentDisposed(_: void, self: *VirtualUpdate) !void {
            self.detach(true);
        }

        fn detach(self: *VirtualUpdate, notify: bool) void {
            const service = self.service orelse return;
            _ = service.virtual_updates.remove(self.document);
            self.service = null;
            self.deadline.schedule(null);
            if (self.dispose_listener) |id| self.document.on_will_dispose.unlisten(id);
            self.dispose_listener = null;
            if (notify) self.listener.complete(self.listener.context, {});
        }

        fn cancel(self: *VirtualUpdate) void {
            self.detach(false);
        }
    };

    pub fn registerDocument(self: *TextModelResolverService, document: *EditorDocument, readonly: bool) !void {
        _ = try self.collection.register(document, readonly);
    }

    pub fn acquireExisting(self: *TextModelResolverService, uri: std.Uri) !?resolver.ModelReference {
        return self.collection.acquire(uri);
    }

    pub fn acquireModelReference(self: *TextModelResolverService, resource: std.Uri) !resolver.ModelReference {
        return (try self.acquireExisting(resource)) orelse error.UnableToResolveResource;
    }

    fn ensureWorker(self: *TextModelResolverService) !*worker_mod.EditorWorkerService {
        if (self.worker) |worker| return worker;
        const worker = try self.allocator.create(worker_mod.EditorWorkerService);
        worker.* = .init();
        worker.attachWindow(self.window);
        self.worker = worker;
        return worker;
    }

    /// Acquisitions of the same URI, even while its provider is loading,
    /// share one request and one published model. Delivery is always a window
    /// event, including an already-resolved resource.
    pub fn createModelReference(self: *TextModelResolverService, resource: std.Uri, listener: resolver.ModelReferenceListener) !resolver.ModelReferenceRequest {
        return self.requestReference(resource, listener, false);
    }

    pub fn refreshModelReference(self: *TextModelResolverService, resource: std.Uri, listener: resolver.ModelReferenceListener) !resolver.ModelReferenceRequest {
        return self.requestReference(resource, listener, true);
    }

    fn shouldRefresh(self: *TextModelResolverService, resource: std.Uri) bool {
        if (std.mem.eql(u8, resource.scheme, "file")) return false;
        if (self.file_service) |service| if (service.hasProvider(resource)) return true;
        for (self.providers.items) |entry| if (std.mem.eql(u8, entry.scheme, resource.scheme)) return true;
        return false;
    }

    fn requestReference(self: *TextModelResolverService, resource: std.Uri, listener: resolver.ModelReferenceListener, refresh: bool) !resolver.ModelReferenceRequest {
        const reload = refresh and self.shouldRefresh(resource);
        const key = try uri_util.resourceKey(self.allocator, resource);
        defer self.allocator.free(key);
        const id = self.next_request_id;
        self.next_request_id += 1;
        if (self.pending.get(key)) |pending| {
            try pending.addListener(id, listener);
            if (reload) pending.reloadIfNecessary();
        } else {
            const pending = try PendingReference.create(self, key, resource, reload);
            errdefer pending.destroy();
            try pending.addListener(id, listener);
            errdefer _ = self.pending_listeners.remove(id);
            try self.pending.put(self.allocator, pending.key, pending);
            pending.start();
        }
        return .{ .context = self, .id = id, .cancel_fn = cancelReference };
    }

    fn cancelReference(context: *anyopaque, id: u64) void {
        const self: *TextModelResolverService = @ptrCast(@alignCast(context));
        const entry = self.pending_listeners.fetchRemove(id) orelse return;
        const pending = entry.value;
        for (pending.listeners.items) |*listener| {
            if (listener.id == id) {
                listener.active = false;
                break;
            }
        }
        for (pending.listeners.items) |listener| if (listener.active) return;
        // The request may be in the middle of delivering another result.
        // Only an as-yet-undelivered acquisition is detached here.
        if (self.pending.get(pending.key) != pending) return;
        _ = self.pending.remove(pending.key);
        pending.canceled.store(true, .release);
        pending.service = null;
        pending.delivery.schedule(null);
        if (!pending.worker_submitted) pending.destroy();
    }

    const PendingReference = struct {
        allocator: Allocator,
        service: ?*TextModelResolverService,
        key: []u8,
        uri: std.Uri,
        arena: std.heap.ArenaAllocator,
        listeners: std.ArrayList(Listener) = .empty,
        existing: ?resolver.ModelReference = null,
        source: ?resolver.TextContentRequest = null,
        async_content: ?@import("../../../../base/common/lifecycle.zig").IDisposable = null,
        provider_cursor: ?usize = null,
        result: ?resolver.TextContentRequest.Result = null,
        failure: ?anyerror = null,
        worker_submitted: bool = false,
        canceled: std.atomic.Value(bool) = .init(false),
        reload: bool = false,
        provider_refresh_after: bool = false,
        previous_delivery: ?*PendingReference = null,
        delivery: dispatch.Task = .{},
        message: worker_mod.Request = .{ .compute = compute, .reply = reply },

        const Listener = struct { id: u64, callback: resolver.ModelReferenceListener, active: bool = true };

        fn create(service: *TextModelResolverService, key: []const u8, resource: std.Uri, reload: bool) !*PendingReference {
            const allocator = service.allocator;
            const self = try allocator.create(PendingReference);
            errdefer allocator.destroy(self);
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            errdefer arena.deinit();
            const uri = try std.Uri.parse(try uri_util.encodedResource(arena.allocator(), resource));
            self.* = .{ .allocator = allocator, .service = service, .key = owned_key, .uri = uri, .arena = arena, .reload = reload };
            self.delivery = .{ .queue = service.window, .context = self, .run = deliver, .progress = true };
            self.existing = try service.acquireExisting(resource);
            return self;
        }

        fn reloadIfNecessary(self: *PendingReference) void {
            if (self.existing == null or self.source != null or self.async_content != null or self.reload) return;
            self.reload = true;
            self.delivery.schedule(null);
            self.start();
        }

        fn addListener(self: *PendingReference, id: u64, listener: resolver.ModelReferenceListener) !void {
            try self.listeners.append(self.allocator, .{ .id = id, .callback = listener });
            errdefer _ = self.listeners.pop();
            const service = self.service orelse return error.ResolverDisposed;
            try service.pending_listeners.put(self.allocator, id, self);
        }

        fn start(self: *PendingReference) void {
            if (self.existing != null and !self.reload) {
                self.delivery.post();
                return;
            }
            self.beginContent() catch |err| {
                self.failure = err;
                self.delivery.post();
            };
        }

        fn beginContent(self: *PendingReference) !void {
            const service = self.service.?;
            if (try service.captureBuiltinContent(self.uri)) |source| {
                self.source = source;
                self.startWorker();
                return;
            }
            try self.advanceProvider();
        }

        fn advanceProvider(self: *PendingReference) !void {
            const service = self.service.?;
            // The monotonically assigned registration ID is the stable
            // continuation cursor even if a provider is removed while waiting.
            var index = service.providers.items.len;
            while (index > 0) {
                index -= 1;
                const entry = service.providers.items[index];
                if (self.provider_cursor) |cursor| if (entry.id >= cursor) continue;
                if (!std.mem.eql(u8, entry.scheme, self.uri.scheme)) continue;
                self.provider_cursor = entry.id;
                if (entry.provider.request_content) |request| {
                    self.async_content = try request(entry.provider.context, self.uri, .{ .context = self, .complete = onAsyncContent });
                    return;
                }
                if (entry.provider.capture) |capture| if (try capture(entry.provider.context, self.uri)) |source| {
                    self.source = source;
                    self.startWorker();
                    return;
                };
            }
            if (try service.acquireExisting(self.uri)) |value| {
                var reference = value;
                defer reference.dispose();
                self.source = try CachedContentRequest.create(documentOf(reference), false);
                self.startWorker();
                return;
            }
            return error.UnableToResolveResource;
        }

        fn onAsyncContent(context: *anyopaque, result: anyerror!?[]const u8) void {
            const self: *PendingReference = @ptrCast(@alignCast(context));
            self.async_content = null;
            self.acceptAsyncContent(result) catch |err| {
                self.failure = err;
                self.delivery.post();
            };
        }

        fn acceptAsyncContent(self: *PendingReference, result: anyerror!?[]const u8) !void {
            const text = (try result) orelse return self.advanceProvider();
            const a = self.arena.allocator();
            self.result = .{
                .uri = self.uri,
                .path = try uri_util.fsPath(self.uri, a),
                .text = try a.dupe(u8, text),
            };
            self.delivery.post();
        }

        fn startWorker(self: *PendingReference) void {
            if (self.source != null) {
                const service = self.service.?;
                const worker = service.ensureWorker() catch |err| {
                    self.failure = err;
                    self.delivery.post();
                    return;
                };
                self.worker_submitted = true;
                worker.computeDiff(&self.message, @import("../../../../base/common/timeCompat.zig").milliTimestamp());
            } else self.delivery.post();
        }

        fn compute(message: *worker_mod.Request) void {
            const self: *PendingReference = @fieldParentPtr("message", message);
            if (self.canceled.load(.acquire)) return;
            const source = self.source.?;
            self.result = source.read(source.context, self.arena.allocator()) catch |err| {
                self.failure = err;
                return;
            };
        }

        fn reply(message: *worker_mod.Request) bool {
            const self: *PendingReference = @fieldParentPtr("message", message);
            self.worker_submitted = false;
            if (self.service == null) {
                self.destroy();
                return false;
            }
            self.complete();
            return true;
        }

        fn deliver(context: *anyopaque, _: i64, _: bool) bool {
            const self: *PendingReference = @ptrCast(@alignCast(context));
            self.complete();
            return true;
        }

        fn complete(self: *PendingReference) void {
            const service = self.service orelse return self.destroy();
            _ = service.pending.remove(self.key);
            defer self.destroy();
            if (for (self.listeners.items) |listener| {
                if (listener.active) break false;
            } else true) return;
            self.previous_delivery = service.delivering;
            service.delivering = self;
            defer if (self.service) |current| {
                current.delivering = self.previous_delivery;
            };
            // A provider may have discovered native state during its read.
            // Publish on this dispatcher, never on its worker or for a
            // canceled acquisition. The model creation below observes it.
            if (self.source) |source| if (source.complete) |publish| {
                publish(source.context) catch |err| {
                    if (self.failure == null) self.failure = err;
                };
            };
            // Keep the creator's reference during all deliveries; reentrant
            // acquisitions cannot observe an orphaned model.
            var owner = self.existing;
            self.existing = null;
            defer if (owner) |*reference| reference.dispose();
            defer if (self.provider_refresh_after) {
                if (self.service) |current| current.queueProviderRefresh(self.uri) catch {};
            };
            if ((owner == null or self.reload) and self.failure == null) {
                if (self.result) |value| {
                    if (value.failure) |err| {
                        self.failure = err;
                    } else if (value.text) |text| {
                        const result_key = uri_util.resourceKey(self.allocator, value.uri) catch null;
                        defer if (result_key) |key| self.allocator.free(key);
                        if (result_key == null or !std.mem.eql(u8, result_key.?, self.key)) {
                            self.failure = error.ProviderResourceMismatch;
                        } else {
                            if (owner == null) {
                                owner = service.createResolvedModelReference(value.uri, value.path, text, !value.is_working_file) catch |err| blk: {
                                    self.failure = err;
                                    break :blk null;
                                };
                            } else if (self.reload) {
                                _ = documentOf(owner.?).replaceGeneratedContents(text) catch |err| blk: {
                                    self.failure = err;
                                    break :blk false;
                                };
                            }
                            if (owner) |reference| if (value.encoding) |name| if (std.meta.stringToEnum(encoding.Encoding, name)) |kind| {
                                documentOf(reference).setEncoding(kind);
                            };
                        }
                    } else self.failure = error.BinaryFile;
                } else self.failure = error.UnableToResolveResource;
            }
            if (self.failure != null) {
                if (owner) |*reference| reference.dispose();
                owner = null;
            }
            for (self.listeners.items) |*listener| {
                if (self.service == null) break;
                if (!listener.active) continue;
                listener.active = false;
                _ = service.pending_listeners.remove(listener.id);
                const outcome: resolver.ModelReferenceResult = if (owner) |reference| blk: {
                    const acquired = service.acquireModelReference(reference.object.textEditorModel.uri()) catch |err| break :blk .{ .failure = err };
                    break :blk .{ .resolved = acquired };
                } else .{ .failure = self.failure orelse error.UnableToResolveResource };
                listener.callback.complete(listener.callback.context, outcome);
            }
        }

        fn destroy(self: *PendingReference) void {
            if (self.existing) |*reference| reference.dispose();
            if (self.async_content) |request| request.dispose();
            if (self.source) |source| source.destroy(source.context);
            self.listeners.deinit(self.allocator);
            self.arena.deinit();
            self.allocator.free(self.key);
            self.allocator.destroy(self);
        }
    };

    /// Publish a worker-resolved resource through the same collection used
    /// by existing documents. If another request completed first, acquire
    /// its model rather than constructing a second model at the same URI.
    pub fn createResolvedModelReference(self: *TextModelResolverService, resource: std.Uri, path: []const u8, text: []const u8, readonly: bool) !resolver.ModelReference {
        if (try self.acquireExisting(resource)) |reference| return reference;
        const document = try EditorDocument.createFromText(self.allocator, self.io, path, text, resource);
        defer document.release();
        const entry = try self.collection.register(document, readonly);
        return entry.acquire();
    }

    pub fn createSyntheticDocument(self: *TextModelResolverService, value: []const u8, language_id: ?[]const u8) !resolver.ModelReference {
        var bytes: [16]u8 = undefined;
        self.io.random(&bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const path = try std.fmt.allocPrint(self.allocator, "/synthetic/{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..] });
        defer self.allocator.free(path);
        var reference = try self.createResolvedModelReference(.{ .scheme = "inmemory", .path = .{ .raw = path } }, path, value, false);
        errdefer reference.dispose();
        if (language_id) |id| try documentOf(reference).setLanguage(id);
        return reference;
    }

    pub fn canHandleResource(self: *TextModelResolverService, resource: std.Uri) bool {
        if (std.mem.eql(u8, resource.scheme, "file") or std.mem.eql(u8, resource.scheme, "untitled") or std.mem.eql(u8, resource.scheme, "inmemory")) return true;
        if (self.shouldRefresh(resource)) return true;
        const key = uri_util.resourceKey(self.allocator, resource) catch return false;
        defer self.allocator.free(key);
        return self.collection.entries.contains(key);
    }

    pub fn interface(self: *TextModelResolverService) resolver.ITextModelService {
        const Adapter = struct {
            fn reference(context: *anyopaque, uri: std.Uri, listener: resolver.ModelReferenceListener) !resolver.ModelReferenceRequest {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.createModelReference(uri, listener);
            }
            fn refresh(context: *anyopaque, uri: std.Uri, listener: resolver.ModelReferenceListener) !resolver.ModelReferenceRequest {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.refreshModelReference(uri, listener);
            }
            fn acquireReference(context: *anyopaque, uri: std.Uri) !resolver.ModelReference {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.acquireModelReference(uri);
            }
            fn synthetic(context: *anyopaque, value: []const u8, language: ?[]const u8) !resolver.ModelReference {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.createSyntheticDocument(value, language);
            }
            fn updateVirtualContent(context: *anyopaque, uri: std.Uri, text: []const u8, listener: resolver.VirtualContentListener) !?IDisposable {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.updateVirtualContent(uri, text, listener);
            }
            fn register(context: *anyopaque, scheme: []const u8, provider: resolver.ITextModelContentProvider) !resolver.ContentProviderRegistration {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.registerTextModelContentProvider(scheme, provider);
            }
            fn canHandle(context: *anyopaque, uri: std.Uri) bool {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.canHandleResource(uri);
            }
        };
        return .{ .context = self, .create_model_reference = Adapter.reference, .acquire_model_reference = Adapter.acquireReference, .refresh_model_reference = Adapter.refresh, .create_synthetic_document = Adapter.synthetic, .can_handle_resource = Adapter.canHandle, .register_provider = Adapter.register, .update_virtual_content = Adapter.updateVirtualContent };
    }

    pub fn modelService(self: *TextModelResolverService) @import("../../../../editor/common/services/modelService.zig").IModelService {
        return self.collection.interface();
    }

    pub fn documentOf(reference: resolver.ModelReference) *EditorDocument {
        return @ptrCast(@alignCast(reference.object.context));
    }
};

const ResourceModelCollection = struct {
    allocator: Allocator,
    window: *dispatch.Queue,
    entries: std.StringHashMap(*Entry),
    on_model_added: @import("../../../../base/common/event.zig").Emitter(resolver.IResolvedTextEditorModel),
    on_model_removed: @import("../../../../base/common/event.zig").Emitter(resolver.IResolvedTextEditorModel),

    fn init(allocator: Allocator, window: *dispatch.Queue) ResourceModelCollection {
        return .{ .allocator = allocator, .window = window, .entries = .init(allocator), .on_model_added = .init(allocator), .on_model_removed = .init(allocator) };
    }

    fn interface(self: *ResourceModelCollection) @import("../../../../editor/common/services/modelService.zig").IModelService {
        return .{
            .context = self,
            .get_models = struct {
                fn get(context: *anyopaque, allocator: Allocator) ![]resolver.IResolvedTextEditorModel {
                    const collection: *ResourceModelCollection = @ptrCast(@alignCast(context));
                    const models = try allocator.alloc(resolver.IResolvedTextEditorModel, collection.entries.count());
                    var iterator = collection.entries.valueIterator();
                    var i: usize = 0;
                    while (iterator.next()) |entry| : (i += 1) models[i] = entry.*.modelInterface();
                    return models;
                }
            }.get,
            .on_model_added = &self.on_model_added,
            .on_model_removed = &self.on_model_removed,
        };
    }

    fn register(self: *ResourceModelCollection, document: *EditorDocument, readonly: bool) !*Entry {
        const key = try uri_util.resourceKey(self.allocator, document.model.uri());
        errdefer self.allocator.free(key);
        if (self.entries.get(key)) |entry| {
            if (entry.document != document) return error.ModelAlreadyRegistered;
            self.allocator.free(key);
            return entry;
        }
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .allocator = self.allocator, .collection = self, .key = key, .document = document, .readonly = readonly };
        entry.disposal_task = .{ .queue = self.window, .context = entry, .run = Entry.disposePending, .progress = true };
        entry.dispose_listener = try document.on_will_dispose.listen(entry, Entry.onDocumentDisposed);
        errdefer document.on_will_dispose.unlisten(entry.dispose_listener.?);
        try self.entries.put(key, entry);
        self.on_model_added.fire(entry.modelInterface()) catch {};
        return entry;
    }

    fn acquire(self: *ResourceModelCollection, resource: std.Uri) !?resolver.ModelReference {
        const key = try uri_util.resourceKey(self.allocator, resource);
        defer self.allocator.free(key);
        const entry = self.entries.get(key) orelse return null;
        return entry.acquire();
    }

    fn deinit(self: *ResourceModelCollection) void {
        // References may outlive the owning service during orderly shutdown.
        // Detach all callbacks while the document is alive; a detached entry
        // with active references destroys itself on the last release.
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |value| {
            self.on_model_removed.fire(value.*.modelInterface()) catch {};
            value.*.detach();
        }
        self.entries.deinit();
        self.on_model_added.deinit();
        self.on_model_removed.deinit();
    }

    const Entry = struct {
        allocator: Allocator,
        collection: ?*ResourceModelCollection,
        key: []u8,
        document: *EditorDocument,
        readonly: bool,
        refs: usize = 0,
        held: bool = false,
        dispose_listener: ?usize = null,
        dirty_listener: bool = false,
        disposal_task: dispatch.Task = .{},

        fn modelInterface(self: *Entry) resolver.IResolvedTextEditorModel {
            return .{ .context = self.document, .textEditorModel = self.document.model, .onWillDispose = &self.document.on_will_dispose, .readonly = self.readonly };
        }

        fn acquire(self: *Entry) resolver.ModelReference {
            self.disposal_task.schedule(null);
            self.stopWaitingForClean();
            if (!self.held) {
                self.document.retain();
                self.held = true;
            }
            self.refs += 1;
            return .{ .object = self.modelInterface(), .release = @import("../../../../base/common/lifecycle.zig").IDisposable.from(Entry, self, release) };
        }

        fn release(self: *Entry) void {
            std.debug.assert(self.refs > 0);
            self.refs -= 1;
            if (self.refs != 0) return;
            if (self.collection != null) {
                self.disposal_task.post();
            } else {
                const document = self.document;
                self.destroy();
                document.release();
            }
        }

        fn disposePending(context: *anyopaque, _: i64, _: bool) bool {
            const self: *Entry = @ptrCast(@alignCast(context));
            if (self.refs != 0 or !self.held) return false;
            const uri = self.document.model.uri();
            const wait_for_clean = std.mem.eql(u8, uri.scheme, "file") or std.mem.eql(u8, uri.scheme, "untitled");
            if (wait_for_clean and self.document.isDirty()) {
                if (!self.dirty_listener) {
                    const working_copy = self.document.interface();
                    working_copy.add_dirty_listener(working_copy.context, self.dirtyListener());
                    self.dirty_listener = true;
                }
                return false;
            }
            self.stopWaitingForClean();
            self.held = false;
            self.document.release(); // may synchronously destroy this entry
            return false;
        }

        fn dirtyListener(self: *Entry) WorkingCopyListener {
            return .{ .context = self, .callback = onDirtyChanged };
        }

        fn onDirtyChanged(context: *anyopaque) void {
            const self: *Entry = @ptrCast(@alignCast(context));
            if (!self.document.isDirty() and self.refs == 0) self.disposal_task.post();
        }

        fn stopWaitingForClean(self: *Entry) void {
            if (!self.dirty_listener) return;
            const working_copy = self.document.interface();
            working_copy.remove_dirty_listener(working_copy.context, self.dirtyListener());
            self.dirty_listener = false;
        }

        fn onDocumentDisposed(_: void, self: *Entry) !void {
            std.debug.assert(!self.held and self.refs == 0);
            self.disposal_task.schedule(null);
            if (self.collection) |collection| {
                _ = collection.entries.remove(self.key);
                collection.on_model_removed.fire(self.modelInterface()) catch {};
            }
            self.destroy();
        }

        fn detach(self: *Entry) void {
            self.disposal_task.schedule(null);
            self.stopWaitingForClean();
            if (self.dispose_listener) |listener| self.document.on_will_dispose.unlisten(listener);
            self.dispose_listener = null;
            self.collection = null;
            if (self.refs != 0) return;
            const document = self.document;
            const held = self.held;
            self.destroy();
            if (held) document.release();
        }

        fn destroy(self: *Entry) void {
            self.allocator.free(self.key);
            self.allocator.destroy(self);
        }
    };
};

const CachedContentRequest = struct {
    arena: std.heap.ArenaAllocator,
    uri: []const u8,
    path: []const u8,
    text: []const u8,
    encoding_name: []const u8,
    is_working_file: bool,

    fn create(document: *EditorDocument, working_file: bool) !resolver.TextContentRequest {
        const self = try std.heap.page_allocator.create(CachedContentRequest);
        errdefer std.heap.page_allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        var text = try document.model.getValue(.TextDefined, true);
        defer text.deinit();
        const a = arena.allocator();
        const uri = try uri_util.encodedResource(a, document.model.uri());
        const path = try a.dupe(u8, document.path);
        const content = try a.dupe(u8, text.items);
        self.* = .{ .arena = arena, .uri = uri, .path = path, .text = content, .encoding_name = @tagName(document.encoding), .is_working_file = working_file };
        return .{ .context = self, .read = read, .destroy = destroy };
    }
    fn read(context: *anyopaque, a: Allocator) !resolver.TextContentRequest.Result {
        const self: *CachedContentRequest = @ptrCast(@alignCast(context));
        return .{ .uri = try std.Uri.parse(try a.dupe(u8, self.uri)), .path = try a.dupe(u8, self.path), .text = try a.dupe(u8, self.text), .encoding = self.encoding_name, .is_working_file = self.is_working_file };
    }
    fn destroy(context: *anyopaque) void {
        const self: *CachedContentRequest = @ptrCast(@alignCast(context));
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

/// The file service captures a resource, not a comparison. Decoding and
/// binary detection happen on the native worker before model publication.
const FileContentRequest = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    path: []const u8,
    uri: []const u8,

    fn create(io: std.Io, uri: std.Uri) !resolver.TextContentRequest {
        const self = try std.heap.page_allocator.create(FileContentRequest);
        errdefer std.heap.page_allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const path = try text_file.absolutePath(a, io, try uri_util.fsPath(uri, a));
        const encoded = try uri_util.encodedResource(a, uri);
        self.* = .{ .arena = arena, .io = io, .path = path, .uri = encoded };
        return .{ .context = self, .read = read, .destroy = destroy };
    }
    fn read(context: *anyopaque, a: Allocator) !resolver.TextContentRequest.Result {
        const self: *FileContentRequest = @ptrCast(@alignCast(context));
        var resource: resolver.TextContentRequest.Result = .{ .uri = try std.Uri.parse(try a.dupe(u8, self.uri)), .path = try a.dupe(u8, self.path) };
        var disk = DiskFileService.init(a, self.io);
        defer disk.deinit();
        var data = disk.readFile(self.path) catch |err| {
            if (err == error.OutOfMemory) return err;
            resource.failure = err;
            return resource;
        };
        defer data.deinit(a);
        try decodeFileContents(a, &resource, data.bytes, true);
        return resource;
    }
    fn destroy(context: *anyopaque) void {
        const self: *FileContentRequest = @ptrCast(@alignCast(context));
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

fn decodeFileContents(a: Allocator, result: *resolver.TextContentRequest.Result, bytes: []const u8, working_file: bool) !void {
    const decoded = (try encoding.decodeText(a, bytes)) orelse return;
    result.is_working_file = working_file;
    result.encoding = @tagName(decoded.encoding);
    result.text = decoded.text;
}

/// Owns a captured filesystem read independently of provider registration.
/// Decode and binary classification share the native text-file path.
const ProviderContentRequest = struct {
    arena: std.heap.ArenaAllocator,
    source: files.FileReadRequest,
    uri: []const u8,
    path: []const u8,

    fn create(uri: std.Uri, source: files.FileReadRequest) !resolver.TextContentRequest {
        errdefer source.destroy(source.context);
        const self = try std.heap.page_allocator.create(ProviderContentRequest);
        errdefer std.heap.page_allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        self.* = .{
            .arena = undefined,
            .source = source,
            .uri = try uri_util.encodedResource(a, uri),
            .path = try a.dupe(u8, source.display_path orelse try uri_util.fsPath(uri, a)),
        };
        self.arena = arena;
        return .{ .context = self, .read = read, .destroy = destroy, .complete = complete };
    }

    fn read(context: *anyopaque, a: Allocator) !resolver.TextContentRequest.Result {
        const self: *ProviderContentRequest = @ptrCast(@alignCast(context));
        var result: resolver.TextContentRequest.Result = .{
            .uri = try std.Uri.parse(try a.dupe(u8, self.uri)),
            .path = try a.dupe(u8, self.path),
        };
        const bytes = self.source.read(self.source.context, a) catch |err| {
            if (err == error.OutOfMemory) return err;
            result.failure = err;
            return result;
        };
        defer a.free(bytes);
        try decodeFileContents(a, &result, bytes, false);
        return result;
    }

    fn complete(context: *anyopaque) !void {
        const self: *ProviderContentRequest = @ptrCast(@alignCast(context));
        if (self.source.complete) |publish| try publish(self.source.context);
    }

    fn destroy(context: *anyopaque) void {
        const self: *ProviderContentRequest = @ptrCast(@alignCast(context));
        self.source.destroy(self.source.context);
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

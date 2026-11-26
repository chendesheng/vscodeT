// Port of `src/vs/workbench/services/textmodelResolver/common/textModelResolverService.ts`.
// Native reads are immutable worker requests; ResourceModelCollection owns
// published URI model identity and deferred last-reference disposal.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SnapshotSource = @import("../../../../editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;
const text_file = @import("../../textfile/common/textFileService.zig");
const encoding = @import("../../textfile/common/encoding.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");
const DiskFileService = @import("../../../../platform/files/common/fileService.zig").DiskFileService;

const resolver = @import("../../../../editor/common/services/resolverService.zig");
const EditorDocument = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const worker_mod = @import("../../../../editor/browser/services/editorWorkerService.zig");
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
    providers: std.ArrayList(ProviderEntry) = .empty,
    next_provider_id: usize = 0,
    worker: ?*worker_mod.EditorWorkerService = null,
    pending: std.StringHashMapUnmanaged(*PendingReference) = .empty,
    pending_listeners: std.AutoHashMapUnmanaged(u64, *PendingReference) = .empty,
    next_request_id: u64 = 0,
    delivering: ?*PendingReference = null,

    const ProviderEntry = struct { id: usize, scheme: []u8, provider: resolver.ITextModelContentProvider };

    pub fn init(allocator: Allocator, io: std.Io, window: *dispatch.Queue) TextModelResolverService {
        return .{ .allocator = allocator, .io = io, .window = window, .collection = ResourceModelCollection.init(allocator, window) };
    }

    pub fn deinit(self: *TextModelResolverService) void {
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
            pending.delivery.schedule(null);
            if (!pending.worker_submitted) pending.destroy();
        }
        self.pending.deinit(self.allocator);
        self.pending_listeners.deinit(self.allocator);
        if (self.worker) |worker| {
            worker.deinit();
            self.allocator.destroy(worker);
            self.worker = null;
        }
        self.collection.deinit();
        for (self.providers.items) |entry| self.allocator.free(entry.scheme);
        self.providers.deinit(self.allocator);
    }

    pub fn registerTextModelContentProvider(self: *TextModelResolverService, scheme: []const u8, provider: resolver.ITextModelContentProvider) !resolver.ContentProviderRegistration {
        const owned = try self.allocator.dupe(u8, scheme);
        errdefer self.allocator.free(owned);
        const id = self.next_provider_id;
        self.next_provider_id += 1;
        try self.providers.append(self.allocator, .{ .id = id, .scheme = owned, .provider = provider });
        return .{ .context = self, .id = id, .remove = unregisterProvider };
    }

    fn unregisterProvider(context: *anyopaque, id: usize) void {
        const self: *TextModelResolverService = @ptrCast(@alignCast(context));
        for (self.providers.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.providers.orderedRemove(index);
            self.allocator.free(entry.scheme);
            return;
        }
    }

    /// Resolve each URI independently. A mixed Git/filesystem/custom pair
    /// must never be sent to a single repository-specific pair provider.
    pub fn capturePair(self: *TextModelResolverService, original: ?std.Uri, modified: ?std.Uri) !SnapshotSource {
        const left = if (original) |uri| try self.captureContent(uri) else null;
        errdefer if (left) |request| request.destroy(request.context);
        const right = if (modified) |uri| try self.captureContent(uri) else null;
        errdefer if (right) |request| request.destroy(request.context);
        return PairContentRequest.create(left, right);
    }

    pub fn captureContent(self: *TextModelResolverService, resource: std.Uri) !resolver.TextContentRequest {
        // The file service wins, and an already-open file supplies its actual
        // unsaved contents rather than a second read of the disk file.
        if (std.mem.eql(u8, resource.scheme, "file")) {
            if (try self.acquireExisting(resource)) |value| {
                var reference = value;
                defer reference.dispose();
                return CachedContentRequest.create(documentOf(reference), true);
            }
            return FileContentRequest.create(self.io, resource);
        }
        // Upstream registers most recent provider first, falling through only
        // when it declines the resource. A provider can refresh a live URI.
        var index = self.providers.items.len;
        while (index != 0) {
            index -= 1;
            const entry = self.providers.items[index];
            if (!std.mem.eql(u8, entry.scheme, resource.scheme)) continue;
            if (try entry.provider.capture(entry.provider.context, resource)) |request| return request;
        }
        if (try self.acquireExisting(resource)) |value| {
            var reference = value;
            defer reference.dispose();
            return CachedContentRequest.create(documentOf(reference), false);
        }
        return error.UnableToResolveResource;
    }

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
        const key = try uri_util.resourceKey(self.allocator, resource);
        defer self.allocator.free(key);
        const id = self.next_request_id;
        self.next_request_id += 1;
        if (self.pending.get(key)) |pending| {
            try pending.addListener(id, listener);
        } else {
            const pending = try PendingReference.create(self, key, resource);
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
        for (entry.value.listeners.items) |*listener| {
            if (listener.id == id) {
                listener.active = false;
                break;
            }
        }
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
        result: ?resolver.TextContentRequest.Result = null,
        failure: ?anyerror = null,
        worker_submitted: bool = false,
        previous_delivery: ?*PendingReference = null,
        delivery: dispatch.Task = .{},
        message: worker_mod.Request = .{ .compute = compute, .reply = reply },

        const Listener = struct { id: u64, callback: resolver.ModelReferenceListener, active: bool = true };

        fn create(service: *TextModelResolverService, key: []const u8, resource: std.Uri) !*PendingReference {
            const allocator = service.allocator;
            const self = try allocator.create(PendingReference);
            errdefer allocator.destroy(self);
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            errdefer arena.deinit();
            const uri = try std.Uri.parse(try uri_util.encodedResource(arena.allocator(), resource));
            self.* = .{ .allocator = allocator, .service = service, .key = owned_key, .uri = uri, .arena = arena };
            self.delivery = .{ .queue = service.window, .context = self, .run = deliver, .progress = true };
            self.existing = try service.acquireExisting(resource);
            if (self.existing == null) self.source = service.captureContent(resource) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            return self;
        }

        fn addListener(self: *PendingReference, id: u64, listener: resolver.ModelReferenceListener) !void {
            try self.listeners.append(self.allocator, .{ .id = id, .callback = listener });
            errdefer _ = self.listeners.pop();
            const service = self.service orelse return error.ResolverDisposed;
            try service.pending_listeners.put(self.allocator, id, self);
        }

        fn start(self: *PendingReference) void {
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
            // Keep the creator's reference during all deliveries; reentrant
            // acquisitions cannot observe an orphaned model.
            var owner = self.existing;
            self.existing = null;
            defer if (owner) |*reference| reference.dispose();
            if (owner == null and self.failure == null) {
                if (self.result) |value| {
                    if (value.failure) |err| self.failure = err else if (value.text) |text| {
                        owner = service.createResolvedModelReference(value.uri, value.path, text, !value.is_working_file) catch |err| blk: {
                            self.failure = err;
                            break :blk null;
                        };
                        if (owner) |reference| if (value.encoding) |name| if (std.meta.stringToEnum(encoding.Encoding, name)) |kind| {
                            documentOf(reference).encoding = kind;
                        };
                    } else self.failure = error.BinaryFile;
                } else self.failure = error.UnableToResolveResource;
            }
            for (self.listeners.items) |listener| {
                if (self.service == null) break;
                if (!listener.active) continue;
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
        for (self.providers.items) |entry| if (std.mem.eql(u8, entry.scheme, resource.scheme)) return true;
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
            fn acquireReference(context: *anyopaque, uri: std.Uri) !resolver.ModelReference {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.acquireModelReference(uri);
            }
            fn synthetic(context: *anyopaque, value: []const u8, language: ?[]const u8) !resolver.ModelReference {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.createSyntheticDocument(value, language);
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
        return .{ .context = self, .create_model_reference = Adapter.reference, .acquire_model_reference = Adapter.acquireReference, .create_synthetic_document = Adapter.synthetic, .can_handle_resource = Adapter.canHandle, .register_provider = Adapter.register };
    }

    pub fn documentOf(reference: resolver.ModelReference) *EditorDocument {
        return @ptrCast(@alignCast(reference.object.context));
    }
};

const ResourceModelCollection = struct {
    allocator: Allocator,
    window: *dispatch.Queue,
    entries: std.StringHashMap(*Entry),

    fn init(allocator: Allocator, window: *dispatch.Queue) ResourceModelCollection {
        return .{ .allocator = allocator, .window = window, .entries = .init(allocator) };
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
        while (iterator.next()) |value| value.*.detach();
        self.entries.deinit();
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

        fn acquire(self: *Entry) resolver.ModelReference {
            self.disposal_task.schedule(null);
            self.stopWaitingForClean();
            if (!self.held) {
                self.document.retain();
                self.held = true;
            }
            self.refs += 1;
            return .{ .object = .{ .context = self.document, .textEditorModel = self.document.model, .onWillDispose = &self.document.on_will_dispose, .readonly = self.readonly }, .release = @import("../../../../base/common/lifecycle.zig").IDisposable.from(Entry, self, release) };
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
            if (self.collection) |collection| _ = collection.entries.remove(self.key);
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

const PairContentRequest = struct {
    original: ?resolver.TextContentRequest,
    modified: ?resolver.TextContentRequest,

    fn create(original: ?resolver.TextContentRequest, modified: ?resolver.TextContentRequest) !SnapshotSource {
        const self = try std.heap.page_allocator.create(PairContentRequest);
        self.* = .{ .original = original, .modified = modified };
        return .{ .context = self, .read = read, .destroy = destroy };
    }
    fn read(context: *anyopaque, a: Allocator) !SnapshotSource.Texts {
        const self: *PairContentRequest = @ptrCast(@alignCast(context));
        const left = if (self.original) |request| try request.read(request.context, a) else null;
        const right = if (self.modified) |request| try request.read(request.context, a) else null;
        return .{
            .original = if (left) |value| value.text orelse "" else "",
            .modified = if (right) |value| value.text orelse "" else "",
            .original_resource = if (left) |value| resource(value) else null,
            .modified_resource = if (right) |value| resource(value) else null,
            .original_available = if (left) |value| value.text != null else false,
            .modified_available = if (right) |value| value.text != null else false,
        };
    }
    fn resource(value: resolver.TextContentRequest.Result) SnapshotSource.Resource {
        return .{ .path = value.path, .uri = value.uri, .is_working_file = value.is_working_file, .encoding = if (value.encoding) |name| std.meta.stringToEnum(encoding.Encoding, name) else null, .failure = value.failure };
    }
    fn destroy(context: *anyopaque) void {
        const self: *PairContentRequest = @ptrCast(@alignCast(context));
        if (self.original) |request| request.destroy(request.context);
        if (self.modified) |request| request.destroy(request.context);
        std.heap.page_allocator.destroy(self);
    }
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

const FileContentRequest = struct {
    source: SnapshotSource,

    fn create(io: std.Io, uri: std.Uri) !resolver.TextContentRequest {
        const self = try std.heap.page_allocator.create(FileContentRequest);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{ .source = try FileSnapshotRequest.capture(io, uri, null, null, null) };
        return .{ .context = self, .read = read, .destroy = destroy };
    }
    fn read(context: *anyopaque, a: Allocator) !resolver.TextContentRequest.Result {
        const self: *FileContentRequest = @ptrCast(@alignCast(context));
        const result = try self.source.read(self.source.context, a);
        const resource = result.original_resource orelse return error.UnableToResolveResource;
        return .{ .uri = resource.uri, .path = resource.path, .text = if (result.original_available) result.original else null, .encoding = if (resource.encoding) |value| @tagName(value) else null, .is_working_file = resource.is_working_file, .failure = resource.failure };
    }
    fn destroy(context: *anyopaque) void {
        const self: *FileContentRequest = @ptrCast(@alignCast(context));
        self.source.destroy(self.source.context);
        std.heap.page_allocator.destroy(self);
    }
};

pub const FileSnapshotRequest = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    original: ?Entry,
    modified: ?Entry,

    pub const WorkingText = struct { text: []const u8, encoding: encoding.Encoding };
    const Entry = struct {
        path: []const u8,
        uri: []const u8,
        working: ?WorkingText = null,
    };
    pub fn supports(uri: ?std.Uri) bool {
        return if (uri) |value| std.mem.eql(u8, value.scheme, "file") else true;
    }
    fn captureEntry(a: Allocator, io: std.Io, uri: ?std.Uri, working: ?WorkingText) !?Entry {
        const value = uri orelse return null;
        if (!supports(value)) return error.UnsupportedResourceScheme;
        const path = try text_file.absolutePath(a, io, try uri_util.fsPath(value, a));
        return .{
            .path = path,
            .uri = try uri_util.encodedResource(a, value),
            .working = if (working) |text| .{ .text = try a.dupe(u8, text.text), .encoding = text.encoding } else null,
        };
    }
    pub fn capture(io: std.Io, original: ?std.Uri, modified: ?std.Uri, original_working: ?WorkingText, modified_working: ?WorkingText) !SnapshotSource {
        const self = try std.heap.page_allocator.create(FileSnapshotRequest);
        errdefer std.heap.page_allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const original_entry = try captureEntry(a, io, original, original_working);
        const modified_entry = try captureEntry(a, io, modified, modified_working);
        self.* = .{ .arena = arena, .io = io, .original = original_entry, .modified = modified_entry };
        return self.interface();
    }
    const Result = struct { resource: ?SnapshotSource.Resource = null, text: ?[]const u8 = null };
    fn readEntry(self: *FileSnapshotRequest, allocator: Allocator, entry: ?Entry) !Result {
        const value = entry orelse return .{};
        var resource: SnapshotSource.Resource = .{
            .path = try allocator.dupe(u8, value.path),
            .uri = try std.Uri.parse(try allocator.dupe(u8, value.uri)),
        };
        if (value.working) |working| {
            resource.encoding = working.encoding;
            resource.is_working_file = true;
            return .{ .resource = resource, .text = try allocator.dupe(u8, working.text) };
        }
        var files = DiskFileService.init(allocator, self.io);
        defer files.deinit();
        var data = files.readFile(value.path) catch |err| {
            if (err == error.OutOfMemory) return err;
            resource.failure = err;
            return .{ .resource = resource };
        };
        defer data.deinit(allocator);
        const detected = if (encoding.detectBOM(data.bytes)) |bom| bom.encoding else encoding.Encoding.utf8;
        if (!encoding.isUTF16(detected) and std.mem.indexOfScalar(u8, data.bytes, 0) != null) return .{ .resource = resource };
        resource.is_working_file = true;
        resource.encoding = detected;
        return .{ .resource = resource, .text = try encoding.decode(allocator, data.bytes, detected) };
    }
    fn read(context: *anyopaque, allocator: Allocator) !SnapshotSource.Texts {
        const self: *FileSnapshotRequest = @ptrCast(@alignCast(context));
        const original = try self.readEntry(allocator, self.original);
        const modified = try self.readEntry(allocator, self.modified);
        return .{
            .original = original.text orelse "",
            .modified = modified.text orelse "",
            .original_resource = original.resource,
            .modified_resource = modified.resource,
            .original_available = original.text != null,
            .modified_available = modified.text != null,
        };
    }
    fn destroy(context: *anyopaque) void {
        const self: *FileSnapshotRequest = @ptrCast(@alignCast(context));
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
    pub fn interface(self: *FileSnapshotRequest) SnapshotSource {
        return .{ .context = self, .read = read, .destroy = destroy };
    }
};

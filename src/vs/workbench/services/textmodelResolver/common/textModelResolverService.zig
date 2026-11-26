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

    pub fn init(allocator: Allocator, io: std.Io, window: *dispatch.Queue) TextModelResolverService {
        return .{ .allocator = allocator, .io = io, .window = window, .collection = ResourceModelCollection.init(allocator, window) };
    }

    pub fn deinit(self: *TextModelResolverService) void {
        self.collection.deinit();
    }

    pub fn registerDocument(self: *TextModelResolverService, document: *EditorDocument, readonly: bool) !void {
        _ = try self.collection.register(document, readonly);
    }

    pub fn acquireExisting(self: *TextModelResolverService, uri: std.Uri) !?resolver.ModelReference {
        return self.collection.acquire(uri);
    }

    pub fn createModelReference(self: *TextModelResolverService, resource: std.Uri) !resolver.ModelReference {
        return (try self.acquireExisting(resource)) orelse error.UnableToResolveResource;
    }

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
        const key = uri_util.resourceKey(self.allocator, resource) catch return false;
        defer self.allocator.free(key);
        return self.collection.entries.contains(key);
    }

    pub fn interface(self: *TextModelResolverService) resolver.ITextModelService {
        const Adapter = struct {
            fn reference(context: *anyopaque, uri: std.Uri) !resolver.ModelReference {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.createModelReference(uri);
            }
            fn synthetic(context: *anyopaque, value: []const u8, language: ?[]const u8) !resolver.ModelReference {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.createSyntheticDocument(value, language);
            }
            fn canHandle(context: *anyopaque, uri: std.Uri) bool {
                const service: *TextModelResolverService = @ptrCast(@alignCast(context));
                return service.canHandleResource(uri);
            }
        };
        return .{ .context = self, .create_model_reference = Adapter.reference, .create_synthetic_document = Adapter.synthetic, .can_handle_resource = Adapter.canHandle };
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

// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffSourceResolverService.ts`.
// Resolvers expose ordered resource changes through the same event contract;
// native text resolution is a separate input/model operation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const std_uri = @import("../../../../base/common/stdUri.zig");
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const multi_diff_source_resolver_service_id = instantiation.ServiceIdentifier(IMultiDiffSourceResolverService, "multiDiffSourceResolverService");

pub const MultiDiffEditorItem = struct {
    originalUri: ?std.Uri = null,
    modifiedUri: ?std.Uri = null,
    goToFileUri: ?std.Uri = null,
    goToFileEditorTitle: ?[]const u8 = null,

    pub fn validate(self: MultiDiffEditorItem) !void {
        if (self.originalUri == null and self.modifiedUri == null) return error.MissingDiffResources;
    }
    pub fn getKey(self: MultiDiffEditorItem, allocator: Allocator) ![]u8 {
        try self.validate();
        const modified = if (self.modifiedUri) |uri| try std_uri.resourceKey(allocator, uri) else null;
        defer if (modified) |key| allocator.free(key);
        const original = if (self.originalUri) |uri| try std_uri.resourceKey(allocator, uri) else null;
        defer if (original) |key| allocator.free(key);
        return std.json.Stringify.valueAlloc(allocator, [2]?[]const u8{ modified, original }, .{});
    }
};

pub const IResolvedMultiDiffSource = struct {
    context: *anyopaque,
    resources: *const fn (*anyopaque) []const MultiDiffEditorItem,
    on_did_change_resources: *Emitter(void),
    label: ?*const fn (*anyopaque) []const u8 = null,
    on_did_change_label: ?*Emitter(void) = null,
    /// A pending source is returned immediately; completion is delivered by
    /// on_did_change_resources even for an empty initial resource set.
    is_ready: ?*const fn (*anyopaque) bool = null,
    get_failure: ?*const fn (*anyopaque) ?anyerror = null,
    get_context_keys: ?*const fn (*anyopaque) ContextKeys = null,
    dispose: *const fn (*anyopaque) void,

    pub const ContextKeys = struct {
        scmResourceGroup: ?[]const u8 = null,
        scmProvider: ?[]const u8 = null,
    };
    pub fn isReady(self: IResolvedMultiDiffSource) bool {
        return if (self.is_ready) |ready| ready(self.context) else true;
    }
    pub fn failure(self: IResolvedMultiDiffSource) ?anyerror {
        return if (self.get_failure) |get| get(self.context) else null;
    }
};

pub const IMultiDiffSourceResolver = struct {
    context: *anyopaque,
    can_handle_uri: *const fn (*anyopaque, std.Uri) bool,
    resolve_diff_source: *const fn (*anyopaque, std.Uri) anyerror!IResolvedMultiDiffSource,
};

pub const IMultiDiffSourceResolverService = struct {
    context: *anyopaque,
    register_resolver: *const fn (*anyopaque, IMultiDiffSourceResolver) anyerror!Registration,
    resolve_fn: *const fn (*anyopaque, std.Uri) anyerror!?IResolvedMultiDiffSource,

    pub fn registerResolver(self: IMultiDiffSourceResolverService, resolver: IMultiDiffSourceResolver) !Registration {
        return self.register_resolver(self.context, resolver);
    }
    pub fn resolve(self: IMultiDiffSourceResolverService, uri: std.Uri) !?IResolvedMultiDiffSource {
        return self.resolve_fn(self.context, uri);
    }
};

pub const Registration = struct {
    service: *MultiDiffSourceResolverService,
    id: usize,
    pub fn dispose(self: Registration) void {
        for (self.service.resolvers.items, 0..) |entry, i| {
            if (entry.id == self.id) {
                _ = self.service.resolvers.orderedRemove(i);
                return;
            }
        }
    }
};

pub const MultiDiffSourceResolverService = struct {
    allocator: Allocator,
    resolvers: std.ArrayList(Entry) = .empty,
    next_id: usize = 0,
    const Entry = struct { id: usize, resolver: IMultiDiffSourceResolver };

    pub fn init(allocator: Allocator) MultiDiffSourceResolverService {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *MultiDiffSourceResolverService) void {
        self.resolvers.deinit(self.allocator);
    }
    pub fn registerResolver(self: *MultiDiffSourceResolverService, resolver: IMultiDiffSourceResolver) !Registration {
        for (self.resolvers.items) |entry| {
            if (entry.resolver.context == resolver.context and entry.resolver.resolve_diff_source == resolver.resolve_diff_source) return error.DuplicateResolver;
        }
        const id = self.next_id;
        self.next_id += 1;
        try self.resolvers.append(self.allocator, .{ .id = id, .resolver = resolver });
        return .{ .service = self, .id = id };
    }
    pub fn resolve(self: *MultiDiffSourceResolverService, uri: std.Uri) !?IResolvedMultiDiffSource {
        for (self.resolvers.items) |entry| {
            const resolver = entry.resolver;
            if (resolver.can_handle_uri(resolver.context, uri)) return try resolver.resolve_diff_source(resolver.context, uri);
        }
        return null;
    }
    pub fn interface(self: *MultiDiffSourceResolverService) IMultiDiffSourceResolverService {
        const Adapter = struct {
            fn register(context: *anyopaque, resolver: IMultiDiffSourceResolver) !Registration {
                const actual: *MultiDiffSourceResolverService = @ptrCast(@alignCast(context));
                return actual.registerResolver(resolver);
            }
            fn resolveUri(context: *anyopaque, uri: std.Uri) !?IResolvedMultiDiffSource {
                const actual: *MultiDiffSourceResolverService = @ptrCast(@alignCast(context));
                return actual.resolve(uri);
            }
        };
        return .{ .context = self, .register_resolver = Adapter.register, .resolve_fn = Adapter.resolveUri };
    }
};

/// Native resource reads are queued independently of the diff computation.
/// The provider captures immutable references before submitting the work.
const SnapshotSource = @import("../../../../editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;
const worker_mod = @import("../../../../editor/browser/services/editorWorkerService.zig");
pub const SnapshotItem = struct {
    source: SnapshotSource,
    original_exists: bool = true,
    modified_exists: bool = true,
    go_to_file_uri: ?[]const u8 = null,
    go_to_file_title: ?[]const u8 = null,
};
pub const SnapshotBatch = struct {
    allocator: Allocator,
    items: []SnapshotItem,
    pub fn deinit(self: SnapshotBatch) void {
        for (self.items) |item| {
            item.source.destroy(item.source.context);
            if (item.go_to_file_uri) |value| self.allocator.free(value);
            if (item.go_to_file_title) |value| self.allocator.free(value);
        }
        self.allocator.free(self.items);
    }
};
/// Native adapter for the text resource resolver. It captures provider-owned
/// read requests on the dispatch thread, independent of the source metadata
/// service and the diff computation.
pub const ResourceSnapshotProvider = struct {
    context: *anyopaque,
    capture: *const fn (*anyopaque, MultiDiffEditorItem) anyerror!SnapshotSource,

    pub fn captureBatch(self: ResourceSnapshotProvider, allocator: Allocator, resources: []const MultiDiffEditorItem) !SnapshotBatch {
        const items = try allocator.alloc(SnapshotItem, resources.len);
        var count: usize = 0;
        errdefer {
            for (items[0..count]) |item| {
                item.source.destroy(item.source.context);
                if (item.go_to_file_uri) |value| allocator.free(value);
                if (item.go_to_file_title) |value| allocator.free(value);
            }
            allocator.free(items);
        }
        for (resources, items) |resource, *item| {
            const snapshot = try self.capture(self.context, resource);
            errdefer snapshot.destroy(snapshot.context);
            const uri = if (resource.goToFileUri) |value| try std.fmt.allocPrint(allocator, "{f}", .{value}) else null;
            errdefer if (uri) |value| allocator.free(value);
            const title = if (resource.goToFileEditorTitle) |value| try allocator.dupe(u8, value) else null;
            item.* = .{ .source = snapshot, .original_exists = resource.originalUri != null, .modified_exists = resource.modifiedUri != null, .go_to_file_uri = uri, .go_to_file_title = title };
            count += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }
};

pub const ResolvedSnapshot = struct {
    original_exists: bool,
    modified_exists: bool,
    go_to_file_uri: ?[]const u8 = null,
    go_to_file_title: ?[]const u8 = null,
    texts: ?SnapshotSource.Texts = null,
    failure: ?anyerror = null,
};
pub const SnapshotBatchRequest = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    batch: SnapshotBatch,
    message: worker_mod.Request = .{ .compute = compute, .reply = reply },
    result: []ResolvedSnapshot = &.{},
    failure: ?anyerror = null,
    listener: ?Listener,
    pub const Listener = struct {
        context: *anyopaque,
        run: *const fn (*anyopaque, *SnapshotBatchRequest) bool,
    };
    /// Consumes the batch on every outcome; replies own the bytes until the
    /// input has retained the resolved native documents.
    pub fn submit(allocator: Allocator, worker: *worker_mod.EditorWorkerService, batch: SnapshotBatch, listener: Listener, now: i64) !*SnapshotBatchRequest {
        errdefer batch.deinit();
        const self = try allocator.create(SnapshotBatchRequest);
        self.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .batch = batch, .listener = listener };
        worker.computeDiff(&self.message, now);
        return self;
    }
    pub fn cancel(self: *SnapshotBatchRequest) void {
        self.listener = null;
    }
    fn compute(message: *worker_mod.Request) void {
        const self: *SnapshotBatchRequest = @fieldParentPtr("message", message);
        const result = self.arena.allocator().alloc(ResolvedSnapshot, self.batch.items.len) catch |err| {
            self.failure = err;
            return;
        };
        self.result = result;
        for (self.batch.items, result) |item, *entry| {
            entry.* = .{ .original_exists = item.original_exists, .modified_exists = item.modified_exists, .go_to_file_uri = item.go_to_file_uri, .go_to_file_title = item.go_to_file_title };
            entry.texts = item.source.read(item.source.context, self.arena.allocator()) catch |err| blk: {
                entry.failure = err;
                break :blk null;
            };
        }
    }
    fn reply(message: *worker_mod.Request) bool {
        const self: *SnapshotBatchRequest = @fieldParentPtr("message", message);
        defer {
            self.batch.deinit();
            self.arena.deinit();
            self.allocator.destroy(self);
        }
        return if (self.listener) |listener| listener.run(listener.context, self) else false;
    }
};

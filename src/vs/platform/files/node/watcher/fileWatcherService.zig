// Terminal watch subset of `src/vs/platform/files/common/fileService.ts`
// (`watch`/`doWatch`/`activeWatchers`) backed by the upstream-shaped
// `UniversalWatcherClient`.
//
// Upstream the workbench file service deduplicates watch requests and forwards
// them to the provider/watcher process. The terminal workbench does not have a
// provider-backed file service yet, so this service owns that deduplication and
// refcounting directly; the request/watch contract is the upstream one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("../../common/watcher.zig");
const files = @import("../../common/files.zig");
const event = @import("../../../../base/common/event.zig");
const client_mod = @import("./watcherClient.zig");
const Emitter = event.Emitter;
const FileChange = files.FileChange;
const WatchRequest = common.WatchRequest;
const UniversalWatcherClient = client_mod.UniversalWatcherClient;
const WatcherError = client_mod.WatcherError;

pub const WatchOptions = struct {
    recursive: bool = true,
    excludes: []const []const u8 = &.{},
    includes: []const common.PatternSource = &.{},
    correlation_id: ?u32 = null,
    filter: ?u8 = null,
};

const Entry = struct {
    owned: *common.OwnedRequests,
    count: usize,
};

pub const WatchHandle = struct {
    allocator: Allocator,
    service: *FileWatcherService,
    path: []u8,
    key: []u8,

    pub fn dispose(self: *WatchHandle) void {
        self.service.unwatch(self.key);
        self.allocator.free(self.key);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

pub const FileWatcherService = struct {
    allocator: Allocator,
    io: Io,
    client: *UniversalWatcherClient,
    active: std.StringHashMap(Entry),
    on_did_change: Emitter([]const FileChange),
    on_did_error: Emitter(WatcherError),

    pub fn init(allocator: Allocator, io: Io) !*FileWatcherService {
        const self = try allocator.create(FileWatcherService);
        errdefer allocator.destroy(self);

        const client = try UniversalWatcherClient.init(allocator);
        errdefer client.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .active = std.StringHashMap(Entry).init(allocator),
            .on_did_change = Emitter([]const FileChange).init(allocator),
            .on_did_error = Emitter(WatcherError).init(allocator),
        };
        errdefer {
            self.on_did_change.deinit();
            self.on_did_error.deinit();
            self.active.deinit();
        }
        _ = try client.on_change.listen(self, onClientChanges);
        _ = try client.on_error.listen(self, onClientError);
        _ = try client.on_log.listen(self, onClientLog);
        return self;
    }

    pub fn deinit(self: *FileWatcherService) void {
        self.client.stop();
        var iterator = self.active.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.owned.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.active.deinit();
        self.client.deinit();
        self.on_did_change.deinit();
        self.on_did_error.deinit();
        self.allocator.destroy(self);
    }

    /// Upstream `FileService.watch` subset. The returned handle must be
    /// disposed by its owner; disposing a handle decrements the request count.
    pub fn watch(self: *FileWatcherService, path: []const u8, options: WatchOptions) !*WatchHandle {
        const request: WatchRequest = .{
            .path = path,
            .recursive = options.recursive,
            .excludes = options.excludes,
            .includes = options.includes,
            .correlationId = options.correlation_id,
            .filter = options.filter,
        };
        // Like FileService.doWatch, deduplicate the complete request, not just
        // its resource. Flat and recursive requests can have distinct filters.
        const key = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        errdefer self.allocator.free(key);
        const handle = try self.allocator.create(WatchHandle);
        errdefer self.allocator.destroy(handle);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        if (self.active.getPtr(key)) |entry| {
            entry.count += 1;
        } else {
            const entry_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(entry_key);
            const owned = try common.copyRequests(self.allocator, &.{request});
            errdefer owned.deinit();
            try self.active.put(entry_key, .{ .owned = owned, .count = 1 });
            errdefer _ = self.active.remove(entry_key);
            try self.rebuildRequests();
        }
        handle.* = .{ .allocator = self.allocator, .service = self, .path = owned_path, .key = key };
        return handle;
    }

    fn unwatch(self: *FileWatcherService, key: []const u8) void {
        const entry = self.active.getPtr(key) orelse return;
        if (entry.count > 1) {
            entry.count -= 1;
            return;
        }
        const removed = self.active.fetchRemove(key) orelse return;
        removed.value.owned.deinit();
        self.allocator.free(removed.key);
        self.rebuildRequests() catch |err| {
            std.log.scoped(.file_watcher).err("failed to update watch requests: {s}", .{@errorName(err)});
        };
    }

    fn rebuildRequests(self: *FileWatcherService) !void {
        var requests = std.array_list.Managed(WatchRequest).init(self.allocator);
        defer requests.deinit();
        var iterator = self.active.valueIterator();
        while (iterator.next()) |entry| try requests.append(entry.owned.requests[0]);
        try self.client.watch(requests.items);
    }

    /// Drains watcher events from the worker. Returns true when a change was
    /// delivered.
    pub fn poll(self: *FileWatcherService) bool {
        return self.client.poll();
    }

    pub fn hasQueuedEvents(self: *FileWatcherService) bool {
        return self.client.hasQueuedEvents();
    }

    pub fn isReady(self: *FileWatcherService) bool {
        return self.client.isReady();
    }

    pub fn nextTimeout(self: *FileWatcherService) ?u32 {
        return if (self.client.hasQueuedEvents()) 0 else null;
    }

    pub fn watchedCount(self: *const FileWatcherService) usize {
        return self.active.count();
    }

    /// Test/diagnostic accessor; the returned slice stays valid until the next
    /// watch/unwatch call.
    pub fn watchedPathAt(self: *const FileWatcherService, index: usize) ?[]const u8 {
        var iterator = self.active.valueIterator();
        var current: usize = 0;
        while (iterator.next()) |entry| {
            if (current == index) return entry.owned.requests[0].path;
            current += 1;
        }
        return null;
    }

    pub fn watchedExcludesAt(self: *const FileWatcherService, index: usize) ?[]const []const u8 {
        var iterator = self.active.valueIterator();
        var current: usize = 0;
        while (iterator.next()) |entry| {
            if (current == index) return entry.owned.requests[0].excludes;
            current += 1;
        }
        return null;
    }

    fn onClientChanges(changes: []const FileChange, self: *FileWatcherService) !void {
        try self.on_did_change.fire(changes);
    }

    fn onClientError(watcher_error: WatcherError, self: *FileWatcherService) !void {
        try self.on_did_error.fire(watcher_error);
    }

    fn onClientLog(message: common.ILogMessage, _: *FileWatcherService) !void {
        switch (message.type) {
            .trace, .debug => std.log.scoped(.file_watcher).debug("{s}", .{message.message}),
            .info => std.log.scoped(.file_watcher).info("{s}", .{message.message}),
            .warn => std.log.scoped(.file_watcher).warn("{s}", .{message.message}),
            .@"error" => std.log.scoped(.file_watcher).err("{s}", .{message.message}),
        }
    }
};

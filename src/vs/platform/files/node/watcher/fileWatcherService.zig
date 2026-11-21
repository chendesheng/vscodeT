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
};

const Entry = struct {
    key: []u8,
    recursive: bool,
    excludes: []const []const u8,
    count: usize,
};

pub const WatchHandle = struct {
    allocator: Allocator,
    service: *FileWatcherService,
    path: []u8,

    pub fn dispose(self: *WatchHandle) void {
        self.service.unwatch(self.path);
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
            freeExcludes(self.allocator, entry.value_ptr.excludes);
            self.allocator.free(entry.value_ptr.key);
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
        if (self.active.getPtr(path)) |entry| {
            entry.count += 1;
        } else {
            const key = try self.allocator.dupe(u8, path);
            var key_owned = true;
            errdefer if (key_owned) self.allocator.free(key);
            const excludes = try copyExcludes(self.allocator, options.excludes);
            var excludes_owned = true;
            errdefer if (excludes_owned) freeExcludes(self.allocator, excludes);
            try self.active.put(key, .{
                .key = key,
                .recursive = options.recursive,
                .excludes = excludes,
                .count = 1,
            });
            key_owned = false;
            excludes_owned = false;
            self.rebuildRequests() catch |err| {
                if (self.active.fetchRemove(path)) |removed| {
                    freeExcludes(self.allocator, removed.value.excludes);
                    self.allocator.free(removed.value.key);
                }
                return err;
            };
        }

        const handle = self.allocator.create(WatchHandle) catch |err| {
            if (self.active.getPtr(path)) |entry| {
                if (entry.count == 1) {
                    const removed = self.active.fetchRemove(path) orelse return err;
                    freeExcludes(self.allocator, removed.value.excludes);
                    self.allocator.free(removed.value.key);
                    self.rebuildRequests() catch {};
                } else {
                    entry.count -= 1;
                }
            }
            return err;
        };
        errdefer self.allocator.destroy(handle);
        errdefer self.unwatch(path);
        handle.* = .{
            .allocator = self.allocator,
            .service = self,
            .path = try self.allocator.dupe(u8, path),
        };
        return handle;
    }

    fn unwatch(self: *FileWatcherService, path: []const u8) void {
        const entry = self.active.getPtr(path) orelse return;
        if (entry.count > 1) {
            entry.count -= 1;
            return;
        }
        const removed = self.active.fetchRemove(path) orelse return;
        freeExcludes(self.allocator, removed.value.excludes);
        self.allocator.free(removed.value.key);
        self.rebuildRequests() catch |err| {
            std.log.scoped(.file_watcher).err("failed to update watch requests: {s}", .{@errorName(err)});
        };
    }

    fn rebuildRequests(self: *FileWatcherService) !void {
        var requests = std.array_list.Managed(WatchRequest).init(self.allocator);
        defer requests.deinit();
        var iterator = self.active.valueIterator();
        while (iterator.next()) |entry| {
            try requests.append(.{
                .path = entry.key,
                .recursive = entry.recursive,
                .excludes = entry.excludes,
            });
        }
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
        var iterator = self.active.keyIterator();
        var current: usize = 0;
        while (iterator.next()) |key| {
            if (current == index) return key.*;
            current += 1;
        }
        return null;
    }

    pub fn watchedExcludesAt(self: *const FileWatcherService, index: usize) ?[]const []const u8 {
        var iterator = self.active.valueIterator();
        var current: usize = 0;
        while (iterator.next()) |entry| {
            if (current == index) return entry.excludes;
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

fn copyExcludes(allocator: Allocator, excludes: []const []const u8) ![]const []const u8 {
    if (excludes.len == 0) return &.{};
    const copy = try allocator.alloc([]const u8, excludes.len);
    var copied: usize = 0;
    while (copied < excludes.len) : (copied += 1) {
        copy[copied] = allocator.dupe(u8, excludes[copied]) catch |err| {
            for (copy[0..copied]) |value| allocator.free(value);
            allocator.free(copy);
            return err;
        };
    }
    return copy;
}

fn freeExcludes(allocator: Allocator, excludes: []const []const u8) void {
    if (excludes.len == 0) return;
    for (excludes) |value| allocator.free(value);
    allocator.free(excludes);
}

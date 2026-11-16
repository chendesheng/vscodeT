// Port of `src/vs/platform/files/node/watcher/parcel/parcelWatcher.ts`.
//
// Terminal adaptation: the `@parcel/watcher` native addon is replaced by the
// in-tree Zig port in `parcel/watcherLib`. The request deduplication, include /
// exclude filtering, correlation ids, coalescing, root-deletion handling and
// suspend/resume behavior follow upstream.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("../../../common/watcher.zig");
const files = @import("../../../common/files.zig");
const WatchRequest = common.WatchRequest;
const FileChange = files.FileChange;
const FileChangeType = files.FileChangeType;
const glob = @import("../../../../../base/common/glob.zig");
const event = @import("../../../../../base/common/event.zig");
const base_mod = @import("../baseWatcher.zig");
const BaseWatcher = base_mod.BaseWatcher;
const plib = @import("watcherLib/root.zig");
const Emitter = event.Emitter;

pub const Options = struct {
    ignored_case: bool = builtin.os.tag != .linux,
};

pub const Instance = struct {
    allocator: Allocator,
    watcher: *ParcelWatcher,
    request: *const WatchRequest,
    subscription: *plib.Subscription,
    arena: std.heap.ArenaAllocator,
    excludes: []const glob.Pattern,
    includes: []const glob.Pattern,
    has_includes: bool,
    failed: bool = false,
    stopped: bool = false,

    pub fn deinit(self: *Instance) void {
        self.subscription.unsubscribe();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn include(self: *const Instance, path: []const u8) bool {
        if (!self.has_includes) return true;
        for (self.includes) |pattern| {
            if (pattern.matches(path)) return true;
        }
        return false;
    }

    fn exclude(self: *const Instance, path: []const u8) bool {
        for (self.excludes) |pattern| {
            if (pattern.matches(path)) return true;
        }
        return false;
    }

    fn handleEvents(self: *Instance, raw_events: []const plib.Event) void {
        if (self.stopped or self.failed) return;
        var changes = std.array_list.Managed(FileChange).init(self.allocator);
        defer changes.deinit();

        for (raw_events) |raw| {
            if (self.exclude(raw.path) or !self.include(raw.path)) continue;
            const change_type: FileChangeType = switch (raw.type) {
                .create => .ADDED,
                .update => .UPDATED,
                .delete => .DELETED,
            };
            changes.append(.{
                .type = change_type,
                .resource = raw.path,
                .cId = self.request.correlationId,
            }) catch return;
        }
        if (changes.items.len == 0) return;

        const coalesced = common.coalesceEventsWithCase(self.allocator, changes.items, self.watcher.ignore_case) catch return;
        defer self.allocator.free(coalesced);

        var filtered = std.array_list.Managed(FileChange).init(self.allocator);
        defer filtered.deinit();
        const filter: ?u8 = if (self.request.correlationId != null) self.request.filter else null;
        for (coalesced) |change| {
            if (common.isFiltered(change, filter)) continue;
            filtered.append(change) catch return;
        }
        if (filtered.items.len == 0) return;
        self.watcher.on_change.fire(filtered.items) catch {};
    }

    fn handleError(self: *Instance, message: []const u8) void {
        if (self.stopped or self.failed) return;
        self.failed = true;
        self.watcher.on_error.fire(.{ .@"error" = message, .request = self.request }) catch {};
        self.watcher.base.requestFailed(self.request, nowMs());
    }
};

pub const ParcelWatcher = struct {
    allocator: Allocator,
    io: Io,
    lib: *plib.Lib,
    owns_lib: bool = true,
    base: BaseWatcher,
    instances: std.array_list.Managed(*Instance),
    ignore_case: bool,
    verbose_logging: bool = false,

    on_change: Emitter([]const FileChange),
    on_log: Emitter(common.ILogMessage),
    on_error: Emitter(common.IWatcherErrorEvent),

    pub fn init(allocator: Allocator, io: Io, options: Options) !*ParcelWatcher {
        const lib = try plib.Lib.init(allocator, io);
        errdefer lib.deinit();
        return initWithLib(allocator, io, lib, options, true);
    }

    pub fn initWithLib(allocator: Allocator, io: Io, lib: *plib.Lib, options: Options, owns_lib: bool) !*ParcelWatcher {
        const self = try allocator.create(ParcelWatcher);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .lib = lib,
            .owns_lib = owns_lib,
            .base = undefined,
            .instances = std.array_list.Managed(*Instance).init(allocator),
            .ignore_case = options.ignored_case,
            .on_change = Emitter([]const FileChange).init(allocator),
            .on_log = Emitter(common.ILogMessage).init(allocator),
            .on_error = Emitter(common.IWatcherErrorEvent).init(allocator),
        };
        self.base = BaseWatcher.init(
            allocator,
            io,
            self,
            startRequestCallback,
            stopRequestCallback,
            emitChangesCallback,
        );
        return self;
    }

    pub fn deinit(self: *ParcelWatcher) void {
        self.base.deinit();
        for (self.instances.items) |instance| instance.deinit();
        self.instances.deinit();
        self.on_change.deinit();
        self.on_log.deinit();
        self.on_error.deinit();
        if (self.owns_lib) self.lib.deinit();
        self.allocator.destroy(self);
    }

    /// Port of upstream `removeDuplicateRequests`.
    pub fn deduplicateRequests(self: *ParcelWatcher, allocator: Allocator, requests: []const WatchRequest) !*DedupedRequests {
        return deduplicateRequestList(allocator, requests, self.ignore_case);
    }

    pub fn watch(self: *ParcelWatcher, requests: []const WatchRequest) !void {
        var deduped = try self.deduplicateRequests(self.allocator, requests);
        defer deduped.deinit();
        try self.base.watch(deduped.requests, nowMs());
    }

    pub fn stop(self: *ParcelWatcher) void {
        self.base.stop();
        for (self.instances.items) |instance| instance.deinit();
        self.instances.clearRetainingCapacity();
    }

    pub fn setVerboseLogging(self: *ParcelWatcher, enabled: bool) void {
        self.verbose_logging = enabled;
        self.base.verbose_logging = enabled;
    }

    pub fn isSuspended(self: *const ParcelWatcher, request: *const WatchRequest) base_mod.SuspensionState {
        return self.base.isSuspended(request);
    }

    pub fn poll(self: *ParcelWatcher, now_ms: i64) !bool {
        _ = try self.lib.poll(now_ms);
        return self.base.poll(now_ms);
    }

    fn startRequest(self: *ParcelWatcher, request: *const WatchRequest) !void {
        for (self.instances.items) |instance| {
            if (sameRequest(instance.request, request)) return;
        }

        const instance = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(instance);
        instance.* = .{
            .allocator = self.allocator,
            .watcher = self,
            .request = request,
            .subscription = undefined,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .excludes = &.{},
            .includes = &.{},
            .has_includes = request.includes.len > 0,
        };
        errdefer instance.arena.deinit();

        const arena = instance.arena.allocator();
        if (request.excludes.len > 0) {
            const sources = try arena.alloc(glob.Source, request.excludes.len);
            for (request.excludes, 0..) |exclude, index| {
                sources[index] = .{ .string = exclude };
            }
            instance.excludes = try common.parseWatcherPatterns(arena, request.path, sources, self.ignore_case);
        }
        if (request.includes.len > 0) {
            instance.includes = try common.parseWatcherPatterns(arena, request.path, request.includes, self.ignore_case);
        }

        instance.subscription = try self.lib.subscribe(request.path, .{
            .context = instance,
            .call = subscriptionCallback,
        }, .{
            .ignore = request.excludes,
            .recursive = request.recursive,
        });
        try self.instances.append(instance);
    }

    fn stopRequest(self: *ParcelWatcher, request: *const WatchRequest) void {
        var index: usize = 0;
        while (index < self.instances.items.len) : (index += 1) {
            const instance = self.instances.items[index];
            if (!sameRequest(instance.request, request)) continue;
            instance.stopped = true;
            _ = self.instances.orderedRemove(index);
            instance.deinit();
            return;
        }
    }
};

fn subscriptionCallback(context: *anyopaque, error_message: ?[]const u8, events: []const plib.Event) anyerror!void {
    const instance: *Instance = @ptrCast(@alignCast(context));
    if (error_message) |message| {
        instance.handleEvents(events);
        instance.handleError(message);
        return;
    }
    instance.handleEvents(events);
}

fn startRequestCallback(context: *anyopaque, request: *const WatchRequest) anyerror!void {
    const self: *ParcelWatcher = @ptrCast(@alignCast(context));
    return self.startRequest(request);
}

fn stopRequestCallback(context: *anyopaque, request: *const WatchRequest) void {
    const self: *ParcelWatcher = @ptrCast(@alignCast(context));
    self.stopRequest(request);
}

fn emitChangesCallback(context: *anyopaque, changes: []const FileChange) void {
    const self: *ParcelWatcher = @ptrCast(@alignCast(context));
    self.on_change.fire(changes) catch {};
}

pub const DedupedRequests = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    requests: []WatchRequest,

    pub fn deinit(self: *DedupedRequests) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
pub fn deduplicateRequestList(allocator: Allocator, requests: []const WatchRequest, ignore_case: bool) !*DedupedRequests {
    const result = try allocator.create(DedupedRequests);
    errdefer allocator.destroy(result);
    result.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .requests = &.{},
    };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();

    const sorted = try arena.dupe(WatchRequest, requests);
    std.mem.sort(WatchRequest, sorted, {}, struct {
        fn lessThan(_: void, a: WatchRequest, b: WatchRequest) bool {
            return a.path.len < b.path.len;
        }
    }.lessThan);

    var selected = std.array_list.Managed(WatchRequest).init(arena);
    for (sorted) |request| {
        if (hasGlobstarExclude(request)) continue;

        var merged = false;
        for (selected.items) |*existing| {
            if (existing.correlationId != request.correlationId) continue;
            if (!std.mem.eql(u8, existing.path, request.path)) continue;
            if (existing.correlationId != null) continue;

            const broad = if (request.includes.len == 0) request else existing.*;
            var includes = std.array_list.Managed(glob.Source).init(arena);
            if (existing.includes.len > 0 and request.includes.len > 0) {
                for (existing.includes) |source| try includes.append(source);
                for (request.includes) |source| try includes.append(source);
            }
            var excludes = std.array_list.Managed([]const u8).init(arena);
            for (existing.excludes) |exclude| {
                if (containsString(request.excludes, exclude)) try excludes.append(exclude);
            }
            existing.* = broad;
            existing.includes = if (includes.items.len > 0) try includes.toOwnedSlice() else &.{};
            existing.excludes = try excludes.toOwnedSlice();
            merged = true;
            break;
        }
        if (merged) continue;

        var child_of_parent = false;
        for (selected.items) |existing| {
            if (existing.correlationId != request.correlationId) continue;
            if (!files.isParent(request.path, existing.path, ignore_case)) continue;
            if (!isSymlink(request.path)) {
                child_of_parent = true;
                break;
            }
        }
        if (child_of_parent) continue;
        try selected.append(request);
    }

    result.requests = try selected.toOwnedSlice();
    return result;
}

fn hasGlobstarExclude(request: WatchRequest) bool {
    for (request.excludes) |exclude| {
        if (std.mem.eql(u8, exclude, "**")) return true;
    }
    return false;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn isSymlink(path: []const u8) bool {
    const io = Io.Threaded.global_single_threaded.io();
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .sym_link;
}

pub fn sameRequest(a: *const WatchRequest, b: *const WatchRequest) bool {
    if (a.correlationId != b.correlationId) return false;
    if (a.recursive != b.recursive) return false;
    if (!std.mem.eql(u8, a.path, b.path)) return false;
    if (a.filter != b.filter) return false;
    return true;
}

pub fn nowMs() i64 {
    return std.Io.Timestamp.now(Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}

// Port of the non-recursive `NodeJSFileWatcherLibrary` behavior from
// `src/vs/platform/files/node/watcher/nodejs/nodejsWatcherLib.ts`.
//
// Terminal adaptation: Node's `fs.watch()` is replaced by the parcel watcher
// port running in non-recursive mode. A file request watches its parent
// directory and filters by basename; a folder request watches the folder.
// Atomic-save sequences are handled by the shared event coalescer.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("../../../common/watcher.zig");
const files = @import("../../../common/files.zig");
const WatchRequest = common.WatchRequest;
const FileChange = files.FileChange;
const FileChangeType = files.FileChangeType;
const glob = @import("../../../../../base/common/glob.zig");
const event = @import("../../../../../base/common/event.zig");
const plib = @import("../parcel/watcherLib/root.zig");
const Emitter = event.Emitter;

pub const Options = struct {
    ignore_case: bool = builtin.os.tag != .linux,
};

pub const Instance = struct {
    allocator: Allocator,
    watcher: *NodeJSWatcher,
    request: *const WatchRequest,
    subscription: *plib.Subscription,
    arena: std.heap.ArenaAllocator,
    excludes: []const glob.Pattern,
    includes: []const glob.Pattern,
    has_includes: bool,
    watch_path: []u8,
    basename: []u8,
    watched_file: bool,
    failed: bool = false,
    stopped: bool = false,

    pub fn deinit(self: *Instance) void {
        self.subscription.unsubscribe();
        self.arena.deinit();
        self.allocator.free(self.watch_path);
        self.allocator.free(self.basename);
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
            if (self.watched_file) {
                if (!std.mem.eql(u8, std.fs.path.basename(raw.path), self.basename)) continue;
            }
            if (!self.watched_file and (self.exclude(raw.path) or !self.include(raw.path))) continue;
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
        self.watcher.on_log.fire(.{ .type = .warn, .message = message }) catch {};
        self.watcher.base.requestFailed(self.request, nowMs());
    }
};

pub const NodeJSWatcher = struct {
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

    const BaseWatcher = @import("../baseWatcher.zig").BaseWatcher;

    pub fn init(allocator: Allocator, io: Io, options: Options) !*NodeJSWatcher {
        // FSEvents watches directories only; non-recursive file requests keep
        // the kqueue backend on macOS.
        const force_kqueue = builtin.os.tag == .macos and build_options.fsevents;
        const lib = try plib.Lib.initWithBackend(allocator, io, force_kqueue);
        errdefer lib.deinit();
        return initWithLib(allocator, io, lib, options, true);
    }

    pub fn initWithLib(allocator: Allocator, io: Io, lib: *plib.Lib, options: Options, owns_lib: bool) !*NodeJSWatcher {
        const self = try allocator.create(NodeJSWatcher);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .lib = lib,
            .owns_lib = owns_lib,
            .base = undefined,
            .instances = std.array_list.Managed(*Instance).init(allocator),
            .ignore_case = options.ignore_case,
            .on_change = Emitter([]const FileChange).init(allocator),
            .on_log = Emitter(common.ILogMessage).init(allocator),
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

    pub fn deinit(self: *NodeJSWatcher) void {
        self.base.deinit();
        for (self.instances.items) |instance| instance.deinit();
        self.instances.deinit();
        self.on_change.deinit();
        self.on_log.deinit();
        if (self.owns_lib) self.lib.deinit();
        self.allocator.destroy(self);
    }

    pub fn watch(self: *NodeJSWatcher, requests: []const WatchRequest) !void {
        try self.base.watch(requests, nowMs());
    }

    pub fn stop(self: *NodeJSWatcher) void {
        self.base.stop();
        for (self.instances.items) |instance| instance.deinit();
        self.instances.clearRetainingCapacity();
    }

    pub fn setVerboseLogging(self: *NodeJSWatcher, enabled: bool) void {
        self.verbose_logging = enabled;
        self.base.verbose_logging = enabled;
    }

    pub fn isSuspended(self: *const NodeJSWatcher, request: *const WatchRequest) @import("../baseWatcher.zig").SuspensionState {
        return self.base.isSuspended(request);
    }

    pub fn poll(self: *NodeJSWatcher, now_ms: i64) !bool {
        _ = try self.lib.poll(now_ms);
        return self.base.poll(now_ms);
    }

    fn startRequest(self: *NodeJSWatcher, request: *const WatchRequest) !void {
        for (self.instances.items) |instance| {
            if (sameRequest(instance.request, request)) return;
        }

        const stat = Io.Dir.cwd().statFile(self.io, request.path, .{ .follow_symlinks = false }) catch return error.FileNotFound;
        const is_dir = stat.kind == .directory;
        const watch_path = if (is_dir)
            try self.allocator.dupe(u8, request.path)
        else
            try self.allocator.dupe(u8, std.fs.path.dirname(request.path) orelse request.path);
        errdefer self.allocator.free(watch_path);
        const basename = try self.allocator.dupe(u8, std.fs.path.basename(request.path));
        errdefer self.allocator.free(basename);

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
            .watch_path = watch_path,
            .basename = basename,
            .watched_file = !is_dir,
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

        instance.subscription = try self.lib.subscribe(watch_path, .{
            .context = instance,
            .call = subscriptionCallback,
        }, .{
            .ignore = &.{},
            .recursive = false,
        });
        try self.instances.append(instance);
    }

    fn stopRequest(self: *NodeJSWatcher, request: *const WatchRequest) void {
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
    const self: *NodeJSWatcher = @ptrCast(@alignCast(context));
    return self.startRequest(request);
}

fn stopRequestCallback(context: *anyopaque, request: *const WatchRequest) void {
    const self: *NodeJSWatcher = @ptrCast(@alignCast(context));
    self.stopRequest(request);
}

fn emitChangesCallback(context: *anyopaque, changes: []const FileChange) void {
    const self: *NodeJSWatcher = @ptrCast(@alignCast(context));
    self.on_change.fire(changes) catch {};
}

pub fn sameRequest(a: *const WatchRequest, b: *const WatchRequest) bool {
    return a.correlationId == b.correlationId and
        a.recursive == b.recursive and
        a.filter == b.filter and
        std.mem.eql(u8, a.path, b.path);
}

pub fn nowMs() i64 {
    return std.Io.Timestamp.now(Io.Threaded.global_single_threaded.io(), .real).toMilliseconds();
}

pub const FileContentsHandle = struct {
    allocator: Allocator,
    io: Io,
    watcher: *NodeJSWatcher,
    file: Io.File,
    buffer: []u8,
    position: u64 = 0,
    on_data_context: *anyopaque,
    on_data: *const fn (context: *anyopaque, chunk: []const u8) void,

    pub fn poll(self: *FileContentsHandle, now_ms: i64) !bool {
        const changed = try self.watcher.poll(now_ms);
        if (!changed) return false;
        while (true) {
            const read = try self.file.readPositionalAll(self.io, self.buffer, self.position);
            if (read == 0) break;
            self.position += read;
            self.on_data(self.on_data_context, self.buffer[0..read]);
        }
        return true;
    }

    pub fn deinit(self: *FileContentsHandle) void {
        self.watcher.deinit();
        self.file.close(self.io);
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }
};

/// Port of upstream `watchFileContents`: call `on_ready` once the watcher is
/// attached, then deliver appended file contents through `on_data`.
pub fn watchFileContents(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    on_data_context: *anyopaque,
    on_data: *const fn (context: *anyopaque, chunk: []const u8) void,
    on_ready_context: *anyopaque,
    on_ready: *const fn (context: *anyopaque) void,
    buffer_size: usize,
) !*FileContentsHandle {
    const handle = try allocator.create(FileContentsHandle);
    errdefer allocator.destroy(handle);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const buffer = try allocator.alloc(u8, @max(buffer_size, 1));
    errdefer allocator.free(buffer);

    const watcher = try NodeJSWatcher.init(allocator, io, .{});
    errdefer watcher.deinit();

    handle.* = .{
        .allocator = allocator,
        .io = io,
        .watcher = watcher,
        .file = file,
        .buffer = buffer,
        .on_data_context = on_data_context,
        .on_data = on_data,
    };
    _ = try watcher.on_change.listen(handle, fileContentsOnChange);
    try watcher.watch(&.{.{ .path = path, .recursive = false }});
    on_ready(on_ready_context);
    return handle;
}

fn fileContentsOnChange(changes: []const FileChange, handle: *FileContentsHandle) !void {
    for (changes) |change| {
        if (change.type != .UPDATED) continue;
        while (true) {
            const read = try handle.file.readPositionalAll(handle.io, handle.buffer, handle.position);
            if (read == 0) break;
            handle.position += read;
            handle.on_data(handle.on_data_context, handle.buffer[0..read]);
        }
        return;
    }
}

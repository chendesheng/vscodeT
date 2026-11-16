// Public surface of the Zig port of `@parcel/watcher` v2.5.6 (external
// package).
//
// Mirrors `index.d.ts`: `subscribe`, `unsubscribe`, `getEventsSince`,
// `writeSnapshot` and an async-style subscription object. Terminal adaptation:
// events are delivered when the host calls `poll(now_ms)`, and snapshot APIs
// use a `DirTree` diff on every platform (which is what upstream uses for the
// polling/WSL path).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const event_mod = @import("event.zig");
pub const EventType = event_mod.EventType;
pub const Event = event_mod.Event;
const EventList = event_mod.EventList;
const dir_tree = @import("dirTree.zig");
const DirTree = dir_tree.DirTree;
const watcher_mod = @import("watcher.zig");
const Watcher = watcher_mod.Watcher;
const brute_force = @import("bruteForce.zig");

pub const MinWaitMs: i64 = 50;
pub const MaxWaitMs: i64 = 500;

pub const Options = struct {
    ignore: []const []const u8 = &.{},
    recursive: bool = true,
};

pub const Callback = watcher_mod.Callback;

pub const WaitHandle = union(enum) {
    none,
    fd: std.posix.fd_t,
    handle: *anyopaque,
};

const BackendVTable = struct {
    deinit: *const fn (context: *anyopaque) void,
    subscribe: *const fn (context: *anyopaque, watcher: *Watcher) anyerror!void,
    unsubscribe: *const fn (context: *anyopaque, watcher: *Watcher) void,
    poll: *const fn (context: *anyopaque, now_ms: i64) anyerror!bool,
    wait_handle: *const fn (context: *anyopaque) WaitHandle,
};

const Backend = struct {
    context: *anyopaque,
    vtable: *const BackendVTable,

    fn deinit(self: *Backend) void {
        self.vtable.deinit(self.context);
        self.* = undefined;
    }
    fn subscribe(self: *Backend, watcher: *Watcher) !void {
        return self.vtable.subscribe(self.context, watcher);
    }
    fn unsubscribe(self: *Backend, watcher: *Watcher) void {
        self.vtable.unsubscribe(self.context, watcher);
    }
    fn poll(self: *Backend, now_ms: i64) !bool {
        return self.vtable.poll(self.context, now_ms);
    }
    fn waitHandle(self: *const Backend) WaitHandle {
        return self.vtable.wait_handle(self.context);
    }
};

fn makeBackend(allocator: Allocator, io: Io) !Backend {
    if (builtin.os.tag == .macos) {
        const Kqueue = @import("kqueue.zig").Backend;
        const context = try allocator.create(Kqueue);
        errdefer allocator.destroy(context);
        context.* = try Kqueue.init(allocator, io);
        return .{ .context = @ptrCast(context), .vtable = &kqueue_vtable };
    }
    if (builtin.os.tag == .windows) {
        const Windows = @import("windows.zig").Backend;
        const context = try allocator.create(Windows);
        errdefer allocator.destroy(context);
        context.* = try Windows.init(allocator, io);
        return .{ .context = @ptrCast(context), .vtable = &windows_vtable };
    }
    if (builtin.os.tag == .linux) {
        const Inotify = @import("inotify.zig").Backend;
        const context = try allocator.create(Inotify);
        errdefer allocator.destroy(context);
        context.* = try Inotify.init(allocator, io);
        return .{ .context = @ptrCast(context), .vtable = &inotify_vtable };
    }
    const context = try allocator.create(brute_force.Backend);
    errdefer allocator.destroy(context);
    context.* = try brute_force.Backend.init(allocator, io);
    return .{ .context = @ptrCast(context), .vtable = &brute_force_vtable };
}

const inotify_vtable: BackendVTable = if (builtin.os.tag == .linux) blk: {
    const Inotify = @import("inotify.zig").Backend;
    break :blk .{
        .deinit = struct {
            fn call(context: *anyopaque) void {
                const self: *Inotify = @ptrCast(@alignCast(context));
                self.deinit();
                self.allocator.destroy(self);
            }
        }.call,
        .subscribe = struct {
            fn call(context: *anyopaque, watcher: *Watcher) anyerror!void {
                const self: *Inotify = @ptrCast(@alignCast(context));
                return self.subscribe(watcher);
            }
        }.call,
        .unsubscribe = struct {
            fn call(context: *anyopaque, watcher: *Watcher) void {
                const self: *Inotify = @ptrCast(@alignCast(context));
                self.unsubscribe(watcher);
            }
        }.call,
        .poll = struct {
            fn call(context: *anyopaque, now_ms: i64) anyerror!bool {
                const self: *Inotify = @ptrCast(@alignCast(context));
                return self.poll(now_ms);
            }
        }.call,
        .wait_handle = struct {
            fn call(context: *anyopaque) WaitHandle {
                const self: *Inotify = @ptrCast(@alignCast(context));
                return self.waitHandle();
            }
        }.call,
    };
} else .{
    .deinit = undefined,
    .subscribe = undefined,
    .unsubscribe = undefined,
    .poll = undefined,
    .wait_handle = undefined,
};

const kqueue_vtable: BackendVTable = if (builtin.os.tag == .macos) blk: {
    const Kqueue = @import("kqueue.zig").Backend;
    break :blk .{
        .deinit = struct {
            fn call(context: *anyopaque) void {
                const self: *Kqueue = @ptrCast(@alignCast(context));
                self.deinit();
                self.allocator.destroy(self);
            }
        }.call,
        .subscribe = struct {
            fn call(context: *anyopaque, watcher: *Watcher) anyerror!void {
                const self: *Kqueue = @ptrCast(@alignCast(context));
                return self.subscribe(watcher);
            }
        }.call,
        .unsubscribe = struct {
            fn call(context: *anyopaque, watcher: *Watcher) void {
                const self: *Kqueue = @ptrCast(@alignCast(context));
                self.unsubscribe(watcher);
            }
        }.call,
        .poll = struct {
            fn call(context: *anyopaque, now_ms: i64) anyerror!bool {
                const self: *Kqueue = @ptrCast(@alignCast(context));
                return self.poll(now_ms);
            }
        }.call,
        .wait_handle = struct {
            fn call(context: *anyopaque) WaitHandle {
                const self: *Kqueue = @ptrCast(@alignCast(context));
                return self.waitHandle();
            }
        }.call,
    };
} else .{
    .deinit = undefined,
    .subscribe = undefined,
    .unsubscribe = undefined,
    .poll = undefined,
    .wait_handle = undefined,
};

const windows_vtable: BackendVTable = if (builtin.os.tag == .windows) blk: {
    const Windows = @import("windows.zig").Backend;
    break :blk .{
        .deinit = struct {
            fn call(context: *anyopaque) void {
                const self: *Windows = @ptrCast(@alignCast(context));
                self.deinit();
                self.allocator.destroy(self);
            }
        }.call,
        .subscribe = struct {
            fn call(context: *anyopaque, watcher: *Watcher) anyerror!void {
                const self: *Windows = @ptrCast(@alignCast(context));
                return self.subscribe(watcher);
            }
        }.call,
        .unsubscribe = struct {
            fn call(context: *anyopaque, watcher: *Watcher) void {
                const self: *Windows = @ptrCast(@alignCast(context));
                self.unsubscribe(watcher);
            }
        }.call,
        .poll = struct {
            fn call(context: *anyopaque, now_ms: i64) anyerror!bool {
                const self: *Windows = @ptrCast(@alignCast(context));
                return self.poll(now_ms);
            }
        }.call,
        .wait_handle = struct {
            fn call(context: *anyopaque) WaitHandle {
                const self: *Windows = @ptrCast(@alignCast(context));
                return self.waitHandle();
            }
        }.call,
    };
} else .{
    .deinit = undefined,
    .subscribe = undefined,
    .unsubscribe = undefined,
    .poll = undefined,
    .wait_handle = undefined,
};

const brute_force_vtable: BackendVTable = .{
    .deinit = struct {
        fn call(context: *anyopaque) void {
            const self: *brute_force.Backend = @ptrCast(@alignCast(context));
            self.deinit();
            self.allocator.destroy(self);
        }
    }.call,
    .subscribe = struct {
        fn call(context: *anyopaque, watcher: *Watcher) anyerror!void {
            const self: *brute_force.Backend = @ptrCast(@alignCast(context));
            return self.subscribe(watcher);
        }
    }.call,
    .unsubscribe = struct {
        fn call(context: *anyopaque, watcher: *Watcher) void {
            const self: *brute_force.Backend = @ptrCast(@alignCast(context));
            self.unsubscribe(watcher);
        }
    }.call,
    .poll = struct {
        fn call(context: *anyopaque, now_ms: i64) anyerror!bool {
            const self: *brute_force.Backend = @ptrCast(@alignCast(context));
            return self.poll(now_ms);
        }
    }.call,
    .wait_handle = struct {
        fn call(context: *anyopaque) WaitHandle {
            const self: *brute_force.Backend = @ptrCast(@alignCast(context));
            return self.waitHandle();
        }
    }.call,
};

pub const Subscription = struct {
    lib: *Lib,
    watcher: *Watcher,

    pub fn unsubscribe(self: *Subscription) void {
        self.lib.unsubscribe(self);
    }
};

pub const OwnedEvents = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    events: []Event,

    pub fn deinit(self: *OwnedEvents) void {
        self.arena.deinit();
    }
};

pub const Lib = struct {
    allocator: Allocator,
    io: Io,
    backend: Backend,
    watchers: std.array_list.Managed(*Watcher),
    disposed: bool = false,

    pub fn init(allocator: Allocator, io: Io) !*Lib {
        const self = try allocator.create(Lib);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .backend = try makeBackend(allocator, io),
            .watchers = std.array_list.Managed(*Watcher).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Lib) void {
        for (self.watchers.items) |watcher| {
            if (!watcher.removed) self.backend.unsubscribe(watcher);
            watcher.deinit();
        }
        self.watchers.deinit();
        self.backend.deinit();
        self.disposed = true;
        self.allocator.destroy(self);
    }

    pub fn subscribe(self: *Lib, dir: []const u8, callback: Callback, options: Options) !*Subscription {
        const watcher = try Watcher.init(self.allocator, self.io, dir, options.ignore, options.recursive);
        errdefer watcher.deinit();
        _ = try watcher.addSubscriber(callback);
        try self.backend.subscribe(watcher);
        errdefer self.backend.unsubscribe(watcher);
        try self.watchers.append(watcher);

        const subscription = try self.allocator.create(Subscription);
        subscription.* = .{ .lib = self, .watcher = watcher };
        return subscription;
    }

    pub fn unsubscribe(self: *Lib, subscription: *Subscription) void {
        self.removeWatcher(subscription.watcher);
        self.allocator.destroy(subscription);
    }

    fn removeWatcher(self: *Lib, watcher: *Watcher) void {
        if (watcher.removed) return;
        watcher.removed = true;
        self.backend.unsubscribe(watcher);
    }

    /// Removes watchers that were unsubscribed from inside a listener. Leaving
    /// them allocated during the callback avoids invalidating the flush loop.
    fn cleanupRemoved(self: *Lib) void {
        var index: usize = 0;
        while (index < self.watchers.items.len) {
            if (self.watchers.items[index].removed) {
                const watcher = self.watchers.orderedRemove(index);
                watcher.deinit();
                continue;
            }
            index += 1;
        }
    }

    pub fn poll(self: *Lib, now_ms: i64) !bool {
        _ = try self.backend.poll(now_ms);

        var snapshot = std.array_list.Managed(*Watcher).init(self.allocator);
        defer snapshot.deinit();
        snapshot.appendSlice(self.watchers.items) catch {};

        var emitted = false;
        for (snapshot.items) |watcher| {
            if (watcher.removed or !watcher.hasEvents()) continue;
            if (watcher.dirty_since_ms == null) watcher.markDirty(now_ms);
            const dirty_since = watcher.dirty_since_ms.?;
            const last_event = watcher.last_event_ms orelse now_ms;
            const due = now_ms - last_event >= MinWaitMs or now_ms - dirty_since >= MaxWaitMs;
            if (due) {
                if (try watcher.flush()) emitted = true;
            }
        }
        self.cleanupRemoved();
        return emitted;
    }

    pub fn nextTimeout(self: *const Lib, now_ms: i64) ?u32 {
        var result: ?u32 = null;
        for (self.watchers.items) |watcher| {
            if (!watcher.hasEvents()) continue;
            const dirty_since = watcher.dirty_since_ms orelse return 0;
            const last_event = watcher.last_event_ms orelse now_ms;
            const deadline = @min(last_event + MinWaitMs, dirty_since + MaxWaitMs);
            const timeout: u32 = if (deadline <= now_ms) 0 else @intCast(deadline - now_ms);
            result = if (result) |current| @min(current, timeout) else timeout;
        }
        return result;
    }

    pub fn waitHandle(self: *const Lib) WaitHandle {
        return self.backend.waitHandle();
    }

    pub fn writeSnapshot(self: *Lib, dir: []const u8, snapshot: []const u8, options: Options) !void {
        var tree = try buildTree(self.allocator, self.io, dir, options.ignore);
        defer tree.deinit();
        try tree.writeSnapshot(self.io, snapshot);
    }

    pub fn getEventsSince(self: *Lib, dir: []const u8, snapshot: []const u8, options: Options) !OwnedEvents {
        var old = DirTree.readSnapshot(self.allocator, self.io, snapshot) catch |err| switch (err) {
            error.FileNotFound => DirTree.init(self.allocator),
            else => return err,
        };
        defer old.deinit();

        var current = try buildTree(self.allocator, self.io, dir, options.ignore);
        defer current.deinit();

        var list = EventList.init(self.allocator);
        defer list.deinit();
        try current.getChanges(&old, &list);

        const events = try list.getEvents(self.allocator);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const arena_events = try arena.allocator().alloc(Event, events.len);
        for (events, 0..) |event, index| {
            arena_events[index] = .{
                .path = try arena.allocator().dupe(u8, event.path),
                .type = event.type,
            };
        }
        self.allocator.free(events);
        return .{ .allocator = self.allocator, .arena = arena, .events = arena_events };
    }
};

fn buildTree(allocator: Allocator, io: Io, root: []const u8, ignore_patterns: []const []const u8) !DirTree {
    const ignore_mod = @import("ignore.zig");
    var ignore = try ignore_mod.Ignore.init(allocator, root, ignore_patterns);
    defer ignore.deinit();

    var tree = DirTree.init(allocator);
    errdefer tree.deinit();

    const stat = std.Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false }) catch return error.FileNotFound;
    if (stat.kind != .directory) return error.NotDir;
    try tree.add(root, mtimeNs(stat.mtime), true);

    var stack = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (stack.items) |path| allocator.free(path);
        stack.deinit();
    }
    try stack.append(try allocator.dupe(u8, root));

    while (stack.pop()) |path| {
        defer allocator.free(path);
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (true) {
            const entry = (iterator.next(io) catch break) orelse break;
            if (entry.kind == .sym_link) continue;
            const child = try std.fs.path.join(allocator, &.{ path, entry.name });
            if (ignore.isIgnored(child)) {
                allocator.free(child);
                continue;
            }
            const child_stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch {
                allocator.free(child);
                continue;
            };
            try tree.add(child, mtimeNs(child_stat.mtime), child_stat.kind == .directory);
            if (child_stat.kind == .directory) {
                try stack.append(child);
            } else {
                allocator.free(child);
            }
        }
    }
    return tree;
}

fn mtimeNs(timestamp: Io.Timestamp) i64 {
    return @intCast(timestamp.toNanoseconds());
}

test "Lib: brute force snapshots" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    var file = try tmp.dir.createFile(io, "sub/a.txt", .{});
    file.close(io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];
    const snapshot = try std.fs.path.join(allocator, &.{ root, "snapshot" });
    defer allocator.free(snapshot);

    var lib = try Lib.init(allocator, io);
    defer lib.deinit();
    const opts: Options = .{ .ignore = &.{snapshot} };
    try lib.writeSnapshot(root, snapshot, opts);

    var file2 = try tmp.dir.createFile(io, "sub/b.txt", .{});
    file2.close(io);

    var events = try lib.getEventsSince(root, snapshot, opts);
    defer events.deinit();
    try std.testing.expectEqual(@as(usize, 1), events.events.len);
    try std.testing.expectEqual(EventType.create, events.events[0].type);
}

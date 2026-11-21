// Port of the `Watcher` state in `src/Watcher.cc` from `@parcel/watcher`
// v2.5.6 (external package).
//
// The terminal watcher owns its directory tree and event list directly. A
// backend records raw changes here; the library flushes the list to
// subscribers after its debounce window, matching upstream's thread-safe
// callback handoff.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const event_mod = @import("event.zig");
const Event = event_mod.Event;
const EventList = event_mod.EventList;
const dir_tree = @import("dirTree.zig");
const DirTree = dir_tree.DirTree;
const ignore_mod = @import("ignore.zig");
const Ignore = ignore_mod.Ignore;

pub const Callback = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque, error_message: ?[]const u8, events: []const Event) anyerror!void,
};

pub const Watcher = struct {
    allocator: Allocator,
    io: Io,
    dir: []u8,
    ignore: Ignore,
    recursive: bool,
    subscribers: std.array_list.Managed(Callback),
    events: EventList,
    tree: DirTree,
    /// Cooperative cancellation for a recursive scan. The watcher process
    /// equivalent is stopped by the client; the worker-thread adaptation sets
    /// this atomic so a large initial walk can abort on shutdown.
    cancel_flag: ?*std.atomic.Value(bool) = null,
    failed: bool = false,
    removed: bool = false,
    dirty_since_ms: ?i64 = null,
    last_event_ms: ?i64 = null,

    pub fn init(
        allocator: Allocator,
        io: Io,
        dir: []const u8,
        ignore_patterns: []const []const u8,
        recursive: bool,
    ) !*Watcher {
        const self = try allocator.create(Watcher);
        errdefer allocator.destroy(self);
        const owned_dir = try allocator.dupe(u8, dir);
        errdefer allocator.free(owned_dir);
        var ignore = try Ignore.init(allocator, dir, ignore_patterns);
        errdefer ignore.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .dir = owned_dir,
            .ignore = ignore,
            .recursive = recursive,
            .subscribers = std.array_list.Managed(Callback).init(allocator),
            .events = EventList.init(allocator),
            .tree = DirTree.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        self.subscribers.deinit();
        self.events.deinit();
        self.tree.deinit();
        self.ignore.deinit();
        const allocator = self.allocator;
        allocator.free(self.dir);
        allocator.destroy(self);
    }

    pub fn addSubscriber(self: *Watcher, callback: Callback) !usize {
        try self.subscribers.append(callback);
        return self.subscribers.items.len - 1;
    }

    pub fn removeSubscriber(self: *Watcher, id: usize) void {
        if (id >= self.subscribers.items.len) return;
        self.subscribers.items[id] = .{
            .context = undefined,
            .call = noopCallback,
        };
    }

    pub fn isIgnored(self: *const Watcher, path: []const u8) bool {
        return self.ignore.isIgnored(path);
    }

    pub fn isCancelled(self: *const Watcher) bool {
        const flag = self.cancel_flag orelse return false;
        return flag.load(.acquire);
    }

    pub fn recordCreate(self: *Watcher, path: []const u8, mtime_ns: i64, is_dir: bool) !void {
        if (self.isIgnored(path)) return;
        try self.tree.add(path, mtime_ns, is_dir);
        try self.events.create(path);
    }

    pub fn recordUpdate(self: *Watcher, path: []const u8, mtime_ns: i64) !void {
        if (self.isIgnored(path)) return;
        if (self.tree.find(path)) |entry| {
            entry.mtime_ns = mtime_ns;
        } else {
            try self.tree.add(path, mtime_ns, false);
        }
        try self.events.update(path);
    }

    pub fn recordDelete(self: *Watcher, path: []const u8) !void {
        if (self.isIgnored(path)) return;
        self.tree.remove(path);
        try self.events.remove(path);
    }

    pub fn recordError(self: *Watcher, message: []const u8) !void {
        self.failed = true;
        try self.events.recordError(message);
    }

    pub fn hasEvents(self: *const Watcher) bool {
        return self.events.hasEvents();
    }

    pub fn markDirty(self: *Watcher, now_ms: i64) void {
        if (self.dirty_since_ms == null) self.dirty_since_ms = now_ms;
        self.last_event_ms = now_ms;
    }

    /// Calls every subscriber with the current batch, then clears the list.
    pub fn flush(self: *Watcher) !bool {
        if (!self.events.hasEvents()) return false;

        const error_message = self.events.error_message;
        const list = try self.events.getEvents(self.allocator);
        defer self.allocator.free(list);
        defer self.events.clear();
        defer {
            self.dirty_since_ms = null;
            self.last_event_ms = null;
        }

        var index: usize = 0;
        while (index < self.subscribers.items.len) : (index += 1) {
            const subscriber = self.subscribers.items[index];
            if (subscriber.call == noopCallback) continue;
            subscriber.call(subscriber.context, error_message, list) catch {};
        }
        return true;
    }
};

fn noopCallback(_: *anyopaque, _: ?[]const u8, _: []const Event) anyerror!void {}

// Port of `src/macos/FSEventsBackend.cc` from `@parcel/watcher` v2.5.6
// (external package), the backend VS Code's file watcher uses on macOS.
//
// Terminal adaptation: parcel runs the backend on a dedicated CFRunLoop
// thread and the JS binding hands events across a lockscreen; this port runs
// the same run loop on a worker-owned thread, queues the raw FSEvents
// callbacks under `events_mutex`, and interprets them in `poll` on the
// watcher worker. The stream setup, exclusion paths, ambiguity handling,
// mtime/birthtime checks and deleted-root behavior follow the upstream
// backend.
//
// Snapshot APIs stay generic `DirTree` snapshots in `root.zig`; this backend
// only serves the live recursive watch.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const watcher_mod = @import("watcher.zig");
const Watcher = watcher_mod.Watcher;
const root_mod = @import("root.zig");
const WaitHandle = root_mod.WaitHandle;

comptime {
    if (builtin.os.tag != .macos) @compileError("FSEvents backend is only for macOS");
}

// ---------------------------------------------------------------------------
// CoreFoundation / CoreServices bindings
// ---------------------------------------------------------------------------

const CFIndex = isize;
const CFStringRef = ?*const anyopaque;
const CFArrayRef = ?*const anyopaque;
const CFMutableArrayRef = ?*anyopaque;
const CFAllocatorRef = ?*const anyopaque;
const CFRunLoopRef = ?*anyopaque;
const FSEventStreamRef = ?*anyopaque;
const FSEventStreamEventId = u64;
const FSEventStreamCreateFlags = u32;
const FSEventStreamCallback = *const fn (
    stream_ref: ?*anyopaque,
    client_callback_info: ?*anyopaque,
    num_events: usize,
    event_paths: ?*anyopaque,
    event_flags: [*c]const u32,
    event_ids: [*c]const u64,
) callconv(.c) void;

const FSEventStreamContext = extern struct {
    version: CFIndex,
    info: ?*anyopaque,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
};

const CFArrayCallBacks = extern struct {
    version: CFIndex,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
    equal: ?*const anyopaque,
};

extern "c" fn CFStringCreateWithCString(allocator: CFAllocatorRef, c_str: [*:0]const u8, encoding: u32) ?*const anyopaque;
extern "c" fn CFArrayCreate(allocator: CFAllocatorRef, values: [*c]const ?*const anyopaque, num_values: CFIndex, callbacks: ?*const anyopaque) ?*const anyopaque;
extern "c" fn CFArrayCreateMutable(allocator: CFAllocatorRef, capacity: CFIndex, callbacks: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFArrayAppendValue(array: CFMutableArrayRef, value: ?*const anyopaque) void;
extern "c" fn CFRelease(value: ?*const anyopaque) void;
extern "c" fn CFRetain(value: ?*const anyopaque) ?*const anyopaque;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRunLoopStop(run_loop: CFRunLoopRef) void;
extern "c" fn CFRunLoopWakeUp(run_loop: CFRunLoopRef) void;
extern "c" fn FSEventStreamCreate(
    allocator: CFAllocatorRef,
    callback: FSEventStreamCallback,
    context: *const FSEventStreamContext,
    paths_to_watch: CFArrayRef,
    since_when: FSEventStreamEventId,
    latency: f64,
    flags: FSEventStreamCreateFlags,
) FSEventStreamRef;
extern "c" fn FSEventStreamSetExclusionPaths(stream: FSEventStreamRef, exclusion_paths: CFArrayRef) void;
extern "c" fn FSEventStreamScheduleWithRunLoop(stream: FSEventStreamRef, run_loop: CFRunLoopRef, mode: ?*const anyopaque) void;
extern "c" fn FSEventStreamStart(stream: FSEventStreamRef) u8;
extern "c" fn FSEventStreamStop(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamUnscheduleFromRunLoop(stream: FSEventStreamRef, run_loop: CFRunLoopRef, mode: ?*const anyopaque) void;
extern "c" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
extern "c" fn FSEventStreamRelease(stream: FSEventStreamRef) void;

extern "c" var kCFRunLoopDefaultMode: ?*const anyopaque;
extern "c" var kCFTypeArrayCallBacks: CFArrayCallBacks;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kFSEventStreamEventIdSinceNow: FSEventStreamEventId = 0xFFFFFFFFFFFFFFFF;
const kFSEventStreamCreateFlagFileEvents: FSEventStreamCreateFlags = 0x00000010;

// FSEventStreamEventFlags
const MUST_SCAN_SUBDIRS: u32 = 0x00000001;
const USER_DROPPED: u32 = 0x00000002;
const KERNEL_DROPPED: u32 = 0x00000004;
const EVENT_IDS_WRAPPED: u32 = 0x00000008;
const HISTORY_DONE: u32 = 0x00000010;
const ROOT_CHANGED: u32 = 0x00000020;
const MOUNT: u32 = 0x00000040;
const UNMOUNT: u32 = 0x00000080;
const ITEM_CREATED: u32 = 0x00000100;
const ITEM_REMOVED: u32 = 0x00000200;
const ITEM_INODE_META_MOD: u32 = 0x00000400;
const ITEM_RENAMED: u32 = 0x00000800;
const ITEM_MODIFIED: u32 = 0x00001000;
const ITEM_FINDER_INFO_MOD: u32 = 0x00002000;
const ITEM_CHANGE_OWNER: u32 = 0x00004000;
const ITEM_XATTR_MOD: u32 = 0x00008000;
const ITEM_IS_FILE: u32 = 0x00010000;
const ITEM_IS_DIR: u32 = 0x00020000;
const ITEM_IS_SYMLINK: u32 = 0x00040000;
const ITEM_OWN_EVENT: u32 = 0x00080000;
const ITEM_IS_HARDLINK: u32 = 0x00100000;
const ITEM_IS_LAST_HARDLINK: u32 = 0x00200000;
const ITEM_CLONED: u32 = 0x00400000;

const IGNORED_FLAGS = ITEM_IS_HARDLINK | ITEM_IS_LAST_HARDLINK | ITEM_IS_SYMLINK |
    ITEM_IS_DIR | ITEM_IS_FILE | ITEM_CLONED;

// ---------------------------------------------------------------------------
// Backend state
// ---------------------------------------------------------------------------

const StreamState = struct {
    watcher: *Watcher,
    stream: FSEventStreamRef,
    context: *CallbackContext,
    exclusions: ?CFMutableArrayRef = null,
    since: u64 = 0,
    deleted_root: bool = false,
};

const CallbackContext = struct {
    backend: *Backend,
    watcher: *Watcher,
};

const RawEvent = struct {
    watcher: *Watcher,
    path: [:0]u8,
    flags: u32,
};

pub const Backend = struct {
    allocator: Allocator,
    io: Io,

    run_loop: CFRunLoopRef = null,
    thread: ?std.Thread = null,
    start_mutex: Io.Mutex = .init,
    start_condition: Io.Condition = .init,
    started: bool = false,
    start_failed: bool = false,
    stop_requested: bool = false,

    streams: std.AutoHashMap(*Watcher, *StreamState),
    events_mutex: Io.Mutex = .init,
    pending: std.array_list.Managed(RawEvent),

    pub fn create(allocator: Allocator, io: Io) !*Backend {
        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .streams = std.AutoHashMap(*Watcher, *StreamState).init(allocator),
            .pending = std.array_list.Managed(RawEvent).init(allocator),
        };
        errdefer {
            self.streams.deinit();
            self.pending.deinit();
        }

        self.thread = try std.Thread.spawn(.{}, runLoopMain, .{self});
        errdefer self.stopRunLoop();

        self.start_mutex.lockUncancelable(self.io);
        while (!self.started) self.start_condition.waitUncancelable(self.io, &self.start_mutex);
        const failed = self.start_failed;
        self.start_mutex.unlock(self.io);
        if (failed) return error.RunLoopUnavailable;
        return self;
    }

    pub fn deinit(self: *Backend) void {
        var keys = std.array_list.Managed(*Watcher).init(self.allocator);
        defer keys.deinit();
        var iterator = self.streams.keyIterator();
        while (iterator.next()) |watcher| keys.append(watcher.*) catch {};
        for (keys.items) |watcher| self.unsubscribe(watcher);

        self.stopRunLoop();
        self.discardAllEvents();
        self.streams.deinit();
        self.pending.deinit();
    }

    fn stopRunLoop(self: *Backend) void {
        self.start_mutex.lockUncancelable(self.io);
        self.stop_requested = true;
        self.start_condition.broadcast(self.io);
        self.start_mutex.unlock(self.io);

        if (self.run_loop) |run_loop| {
            CFRunLoopStop(run_loop);
            CFRunLoopWakeUp(run_loop);
        }
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn waitHandle(_: *const Backend) WaitHandle {
        // FSEvents has no pollable descriptor; the watcher worker polls the
        // backend on its own short timer.
        return .none;
    }

    pub fn subscribe(self: *Backend, watcher: *Watcher) !void {
        if (self.streams.contains(watcher)) return;
        const state = try self.startStream(watcher);
        errdefer self.destroyState(state);
        try self.streams.put(watcher, state);
    }

    pub fn unsubscribe(self: *Backend, watcher: *Watcher) void {
        const state = self.streams.fetchRemove(watcher) orelse {
            self.discardEventsFor(watcher);
            return;
        };
        self.stopStream(state.value);
        self.destroyState(state.value);
        self.discardEventsFor(watcher);
    }

    fn startStream(self: *Backend, watcher: *Watcher) !*StreamState {
        try checkWatcher(watcher.dir);

        const state = try self.allocator.create(StreamState);
        errdefer self.allocator.destroy(state);
        const context = try self.allocator.create(CallbackContext);
        errdefer self.allocator.destroy(context);
        context.* = .{ .backend = self, .watcher = watcher };
        state.* = .{
            .watcher = watcher,
            .stream = null,
            .context = context,
            .since = 0,
        };

        const path_z = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{watcher.dir}, 0);
        defer self.allocator.free(path_z);
        const file_watch_path = CFStringCreateWithCString(null, path_z.ptr, kCFStringEncodingUTF8) orelse
            return error.StreamCreateFailed;
        defer CFRelease(file_watch_path);

        var values = [_]?*const anyopaque{file_watch_path};
        const paths_to_watch = CFArrayCreate(null, @ptrCast(&values), 1, null) orelse
            return error.StreamCreateFailed;
        defer CFRelease(paths_to_watch);

        var stream_context = FSEventStreamContext{
            .version = 0,
            .info = @ptrCast(context),
            .retain = null,
            .release = null,
            .copy_description = null,
        };
        const stream = FSEventStreamCreate(
            null,
            fseventsCallback,
            &stream_context,
            paths_to_watch,
            kFSEventStreamEventIdSinceNow,
            0.001,
            kFSEventStreamCreateFlagFileEvents,
        ) orelse return error.StreamCreateFailed;
        errdefer FSEventStreamRelease(stream);
        state.stream = stream;

        state.exclusions = setExclusionPaths(stream, watcher);

        if (self.run_loop) |run_loop| {
            FSEventStreamScheduleWithRunLoop(stream, run_loop, kCFRunLoopDefaultMode);
        } else {
            return error.RunLoopUnavailable;
        }
        if (FSEventStreamStart(stream) == 0) return error.StreamStartFailed;
        return state;
    }

    fn stopStream(self: *Backend, state: *StreamState) void {
        const stream = state.stream;
        if (stream == null) return;
        FSEventStreamStop(stream);
        if (self.run_loop) |run_loop| {
            FSEventStreamUnscheduleFromRunLoop(stream, run_loop, kCFRunLoopDefaultMode);
        }
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        state.stream = null;
    }

    fn destroyState(self: *Backend, state: *StreamState) void {
        if (state.exclusions) |exclusions| CFRelease(exclusions);
        self.allocator.destroy(state.context);
        self.allocator.destroy(state);
    }

    /// `FSEventsBackend::subscribe`/callback deliver raw events; the port
    /// queues them and interprets them here on the watcher worker.
    pub fn poll(self: *Backend, now_ms: i64) !bool {
        var batch = std.array_list.Managed(RawEvent).init(self.allocator);
        defer batch.deinit();
        self.events_mutex.lockUncancelable(self.io);
        std.mem.swap(std.array_list.Managed(RawEvent), &batch, &self.pending);
        self.events_mutex.unlock(self.io);

        var changed = false;
        for (batch.items) |*raw_event| {
            defer self.allocator.free(raw_event.path);
            const state = self.streams.get(raw_event.watcher) orelse continue;
            if (self.applyEvent(state, raw_event.path, raw_event.flags)) {
                changed = true;
                raw_event.watcher.markDirty(now_ms);
            }
            if (state.deleted_root) {
                raw_event.watcher.recordError("Watcher shutdown because watched path got deleted") catch {};
                self.unsubscribe(raw_event.watcher);
                changed = true;
            }
        }
        return changed;
    }

    fn applyEvent(_: *Backend, state: *StreamState, path: [:0]const u8, flags: u32) bool {
        const watcher = state.watcher;
        var changed = false;

        if ((flags & MUST_SCAN_SUBDIRS) != 0) {
            if ((flags & USER_DROPPED) != 0) {
                watcher.recordError("Events were dropped by the FSEvents client. File system must be re-scanned.") catch {};
            } else if ((flags & KERNEL_DROPPED) != 0) {
                watcher.recordError("Events were dropped by the kernel. File system must be re-scanned.") catch {};
            } else {
                watcher.recordError("Too many events. File system must be re-scanned.") catch {};
            }
            changed = true;
        }
        if ((flags & HISTORY_DONE) != 0) return changed;
        if ((flags & ~IGNORED_FLAGS) == 0) return changed;
        if (watcher.isIgnored(path)) return changed;

        const is_created = (flags & ITEM_CREATED) != 0;
        const is_removed = (flags & ITEM_REMOVED) != 0;
        const is_renamed = (flags & ITEM_RENAMED) != 0;
        const is_modified = (flags & ITEM_MODIFIED) != 0 or
            (flags & ITEM_INODE_META_MOD) != 0 or
            (flags & ITEM_FINDER_INFO_MOD) != 0 or
            (flags & ITEM_CHANGE_OWNER) != 0 or
            (flags & ITEM_XATTR_MOD) != 0;
        const is_dir = (flags & ITEM_IS_DIR) != 0;

        if (is_created and !(is_removed or is_modified or is_renamed)) {
            watcher.tree.add(path, 0, is_dir) catch return changed;
            watcher.events.create(path) catch return changed;
            return true;
        }
        if (is_removed and !(is_created or is_modified or is_renamed)) {
            watcher.tree.remove(path);
            watcher.events.remove(path) catch {};
            if (std.mem.eql(u8, path, watcher.dir)) state.deleted_root = true;
            return true;
        }
        if (is_modified and !(is_created or is_removed or is_renamed)) {
            var file: std.c.Stat = undefined;
            if (statPath(path, &file) != 0) return changed;
            const mtime = mtimeNs(file.mtimespec);
            if (watcher.tree.find(path)) |entry| {
                if (mtime == entry.mtime_ns and file.mtimespec.nsec != 0) return changed;
                entry.mtime_ns = mtime;
            } else {
                watcher.tree.add(path, mtime, isDirFromMode(file.mode)) catch return changed;
            }
            watcher.events.update(path) catch {};
            return true;
        }

        // Ambiguous flags: stat and canonical existence disambiguate.
        var file: std.c.Stat = undefined;
        if (statPath(path, &file) != 0 or !pathExists(path)) {
            watcher.tree.remove(path);
            watcher.events.remove(path) catch {};
            if (std.mem.eql(u8, path, watcher.dir)) state.deleted_root = true;
            return true;
        }

        const birth = mtimeNs(file.birthtimespec);
        const mtime = mtimeNs(file.mtimespec);
        const entry = if (state.since == 0) watcher.tree.find(path) else null;
        if (entry != null and entry.?.mtime_ns == mtime and file.mtimespec.nsec != 0) return changed;

        if (is_modified and (entry != null or (birth <= state.since and birth != 0))) {
            if (entry) |value| value.mtime_ns = mtime else watcher.tree.add(path, mtime, isDirFromMode(file.mode)) catch return changed;
            watcher.events.update(path) catch {};
        } else {
            watcher.tree.add(path, mtime, isDirFromMode(file.mode)) catch return changed;
            watcher.events.create(path) catch {};
        }
        return true;
    }

    fn discardEventsFor(self: *Backend, watcher: *Watcher) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        var index: usize = 0;
        while (index < self.pending.items.len) {
            if (self.pending.items[index].watcher != watcher) {
                index += 1;
                continue;
            }
            const event = self.pending.orderedRemove(index);
            self.allocator.free(event.path);
        }
    }

    fn discardAllEvents(self: *Backend) void {
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        for (self.pending.items) |event| self.allocator.free(event.path);
        self.pending.clearRetainingCapacity();
    }

    fn pushEvent(self: *Backend, watcher: *Watcher, path_z: [:0]const u8, flags: u32) void {
        const copy = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{path_z}, 0) catch return;
        self.events_mutex.lockUncancelable(self.io);
        defer self.events_mutex.unlock(self.io);
        self.pending.append(.{
            .watcher = watcher,
            .path = copy,
            .flags = flags,
        }) catch self.allocator.free(copy);
    }
};

fn runLoopMain(self: *Backend) void {
    const run_loop = CFRunLoopGetCurrent() orelse {
        self.start_mutex.lockUncancelable(self.io);
        self.started = true;
        self.start_failed = true;
        self.start_condition.signal(self.io);
        self.start_mutex.unlock(self.io);
        return;
    };
    _ = CFRetain(run_loop);

    self.start_mutex.lockUncancelable(self.io);
    self.run_loop = run_loop;
    self.started = true;
    self.start_condition.signal(self.io);
    self.start_mutex.unlock(self.io);

    // A CFRunLoop with no sources returns immediately. Keep the thread alive
    // between subscriptions; once a stream is scheduled the run blocks on it.
    while (true) {
        self.start_mutex.lockUncancelable(self.io);
        if (self.stop_requested) {
            self.start_mutex.unlock(self.io);
            break;
        }
        self.start_mutex.unlock(self.io);

        CFRunLoopRun();
        self.start_mutex.lockUncancelable(self.io);
        const stop = self.stop_requested;
        self.start_mutex.unlock(self.io);
        if (stop) break;
        self.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    CFRelease(run_loop);
    self.run_loop = null;
}

fn fseventsCallback(
    _: ?*anyopaque,
    info: ?*anyopaque,
    num_events: usize,
    event_paths: ?*anyopaque,
    event_flags: [*c]const u32,
    _: [*c]const u64,
) callconv(.c) void {
    if (info == null or event_paths == null or event_flags == null) return;
    const context: *CallbackContext = @ptrCast(@alignCast(info.?));
    const paths: [*c]const [*c]const u8 = @ptrCast(@alignCast(event_paths.?));
    var index: usize = 0;
    while (index < num_events) : (index += 1) {
        const path_ptr = paths[index];
        if (path_ptr == null) continue;
        const path = std.mem.span(path_ptr);
        context.backend.pushEvent(context.watcher, path, event_flags[index]);
    }
}

fn checkWatcher(dir: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{dir}, 0) catch return error.NameTooLong;
    var file: std.c.Stat = undefined;
    if (std.c.stat(path.ptr, &file) != 0) return error.WatchFailed;
    if (!isDirFromMode(file.mode)) return error.NotDir;
}

fn setExclusionPaths(stream: FSEventStreamRef, watcher: *const Watcher) ?CFMutableArrayRef {
    const paths = watcher.ignore.paths;
    if (paths.len == 0) return null;
    const exclusions = CFArrayCreateMutable(null, @intCast(paths.len), &kCFTypeArrayCallBacks) orelse return null;
    for (paths) |excluded| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&buffer, "{s}", .{excluded}, 0) catch continue;
        const string = CFStringCreateWithCString(null, path_z.ptr, kCFStringEncodingUTF8) orelse continue;
        CFArrayAppendValue(exclusions, string);
        CFRelease(string);
    }
    FSEventStreamSetExclusionPaths(stream, exclusions);
    return exclusions;
}

fn statPath(path: [:0]const u8, file: *std.c.Stat) c_int {
    return std.c.stat(path.ptr, file);
}

/// Upstream `pathExists` disambiguates case-only renames by comparing the
/// canonical path (`F_GETPATH`) with the event path.
fn pathExists(path: [:0]const u8) bool {
    const fd = std.c.open(path.ptr, .{
        .ACCMODE = .RDONLY,
        .SYMLINK = true,
        .CLOEXEC = true,
    });
    if (fd < 0) return false;
    const fd_t: std.posix.fd_t = @intCast(fd);
    defer std.Io.Threaded.closeFd(fd_t);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.fcntl(fd, std.c.F.GETPATH, &buffer) == -1) return false;
    const canonical = std.mem.sliceTo(&buffer, 0);
    return std.mem.eql(u8, path, canonical);
}

fn mtimeNs(ts: std.c.timespec) i64 {
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

fn isDirFromMode(mode: std.c.mode_t) bool {
    return (mode & std.c.S.IFMT) == std.c.S.IFDIR;
}

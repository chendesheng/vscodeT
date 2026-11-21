// Port of `src/linux/InotifyBackend.cc` from `@parcel/watcher` v2.5.6
// (external package).
//
// The backend owns one non-blocking inotify descriptor. Every watched
// directory gets an inotify watch; newly created directories are added
// recursively. The terminal event loop drains the descriptor via `poll`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const linux = std.os.linux;
const watcher_mod = @import("watcher.zig");
const Watcher = watcher_mod.Watcher;
const root_mod = @import("root.zig");
const WaitHandle = root_mod.WaitHandle;

comptime {
    if (builtin.os.tag != .linux) @compileError("inotify backend is Linux-only");
}

const IN_MODIFY: u32 = 0x2;
const IN_ATTRIB: u32 = 0x4;
const IN_MOVED_FROM: u32 = 0x40;
const IN_MOVED_TO: u32 = 0x80;
const IN_CREATE: u32 = 0x100;
const IN_DELETE: u32 = 0x200;
const IN_DELETE_SELF: u32 = 0x400;
const IN_MOVE_SELF: u32 = 0x800;
const IN_Q_OVERFLOW: u32 = 0x4000;
const IN_IGNORED: u32 = 0x8000;
const IN_ONLYDIR: u32 = 0x01000000;
const IN_DONT_FOLLOW: u32 = 0x02000000;
const IN_EXCL_UNLINK: u32 = 0x04000000;
const IN_ISDIR: u32 = 0x40000000;
const IN_NONBLOCK: u32 = 0x800;
const IN_CLOEXEC: u32 = 0x80000;

const WATCH_MASK = IN_MODIFY | IN_ATTRIB | IN_CREATE | IN_DELETE | IN_DELETE_SELF |
    IN_MOVE_SELF | IN_MOVED_FROM | IN_MOVED_TO | IN_ONLYDIR | IN_DONT_FOLLOW | IN_EXCL_UNLINK;

const Binding = struct {
    wd: i32,
    path: []u8,
    watcher: *Watcher,
};

pub const Backend = struct {
    allocator: Allocator,
    io: Io,
    fd: posix.fd_t,
    bindings: std.array_list.Managed(Binding),
    buffer: [64 * 1024]u8 align(8) = undefined,

    pub fn init(allocator: Allocator, io: Io) !Backend {
        const rc = linux.inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.InotifyInitFailed;
        return .{
            .allocator = allocator,
            .io = io,
            .fd = @intCast(rc),
            .bindings = std.array_list.Managed(Binding).init(allocator),
        };
    }

    pub fn deinit(self: *Backend) void {
        self.removeAllBindings();
        self.bindings.deinit();
        std.Io.Threaded.closeFd(self.fd);
    }

    pub fn waitHandle(self: *const Backend) WaitHandle {
        return .{ .fd = self.fd };
    }

    pub fn subscribe(self: *Backend, watcher: *Watcher) !void {
        try self.watchTree(watcher, watcher.dir, true);
    }

    pub fn unsubscribe(self: *Backend, watcher: *Watcher) void {
        var index: usize = 0;
        while (index < self.bindings.items.len) {
            if (self.bindings.items[index].watcher == watcher) {
                const binding = self.bindings.orderedRemove(index);
                self.allocator.free(binding.path);
                continue;
            }
            index += 1;
        }
    }

    fn watchTree(self: *Backend, watcher: *Watcher, path: []const u8, root: bool) !void {
        if (watcher.isCancelled()) return;
        try self.addWatch(watcher, path, root);

        var dir = Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (watcher.isCancelled()) return;
            const child = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            defer self.allocator.free(child);

            const stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch continue;
            const is_dir = stat.kind == .directory;
            try watcher.tree.add(child, mtimeNs(stat.mtime), is_dir);
            if (is_dir and watcher.recursive and entry.kind != .sym_link) {
                try self.watchTree(watcher, child, false);
            }
        }
    }

    fn addWatch(self: *Backend, watcher: *Watcher, path: []const u8, root: bool) !void {
        const path_z = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{path}, 0);
        defer self.allocator.free(path_z);

        const rc = linux.inotify_add_watch(self.fd, path_z, WATCH_MASK);
        if (linux.errno(rc) != .SUCCESS) {
            if (root) return error.WatchFailed;
            return;
        }
        const wd: i32 = @intCast(rc);

        // Replace an existing binding for this watcher/path.
        for (self.bindings.items) |*binding| {
            if (binding.watcher == watcher and std.mem.eql(u8, binding.path, path)) {
                binding.wd = wd;
                return;
            }
        }

        try self.bindings.append(.{
            .wd = wd,
            .path = try self.allocator.dupe(u8, path),
            .watcher = watcher,
        });
    }

    pub fn poll(self: *Backend, now_ms: i64) !bool {
        var touched = std.array_list.Managed(*Watcher).init(self.allocator);
        defer touched.deinit();

        while (true) {
            const bytes = posix.read(self.fd, &self.buffer) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (bytes == 0) break;

            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= bytes) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&self.buffer[offset]));
                offset += @sizeOf(linux.inotify_event) + event.len;

                if ((event.mask & IN_Q_OVERFLOW) != 0) {
                    for (self.bindings.items) |binding| {
                        try binding.watcher.recordError("Event queue overflowed");
                        markTouched(&touched, binding.watcher, now_ms);
                    }
                    continue;
                }
                if ((event.mask & IN_IGNORED) != 0) {
                    continue;
                }

                const name = if (event.len > 0) event.getName() else null;
                var binding_index: usize = 0;
                while (binding_index < self.bindings.items.len) : (binding_index += 1) {
                    const binding = self.bindings.items[binding_index];
                    if (binding.wd != event.wd) continue;

                    const path = if (name) |value|
                        try std.fs.path.join(self.allocator, &.{ binding.path, value })
                    else
                        try self.allocator.dupe(u8, binding.path);
                    defer self.allocator.free(path);

                    try self.handleEvent(binding.watcher, binding.path, path, event.mask, now_ms);
                    markTouched(&touched, binding.watcher, now_ms);
                }
            }
        }

        return touched.items.len > 0;
    }

    fn handleEvent(
        self: *Backend,
        watcher: *Watcher,
        watched_root: []const u8,
        path: []const u8,
        mask: u32,
        now_ms: i64,
    ) !void {
        _ = now_ms;
        const is_self = (mask & (IN_DELETE_SELF | IN_MOVE_SELF)) != 0;

        if ((mask & (IN_CREATE | IN_MOVED_TO)) != 0) {
            const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return;
            const is_dir = stat.kind == .directory;
            try watcher.recordCreate(path, mtimeNs(stat.mtime), is_dir);
            if (is_dir and watcher.recursive) {
                self.watchTree(watcher, path, false) catch {};
            }
            return;
        }

        if ((mask & (IN_MODIFY | IN_ATTRIB)) != 0) {
            const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return;
            try watcher.recordUpdate(path, mtimeNs(stat.mtime));
            return;
        }

        if ((mask & (IN_DELETE | IN_DELETE_SELF | IN_MOVED_FROM | IN_MOVE_SELF)) != 0) {
            if (is_self and !std.mem.eql(u8, path, watched_root)) return;
            try watcher.recordDelete(path);
            self.removeBindingsUnder(path);
            if (is_self) {
                try watcher.recordError("Watcher shutdown because watched path got deleted");
            }
        }
    }

    fn removeBindingsUnder(self: *Backend, path: []const u8) void {
        var index: usize = 0;
        while (index < self.bindings.items.len) {
            const binding_path = self.bindings.items[index].path;
            const matches = std.mem.eql(u8, binding_path, path) or
                (std.mem.startsWith(u8, binding_path, path) and
                    binding_path.len > path.len and binding_path[path.len] == std.fs.path.sep);
            if (matches) {
                const binding = self.bindings.orderedRemove(index);
                self.allocator.free(binding.path);
                continue;
            }
            index += 1;
        }
    }

    fn removeAllBindings(self: *Backend) void {
        for (self.bindings.items) |binding| self.allocator.free(binding.path);
        self.bindings.clearRetainingCapacity();
    }
};

fn mtimeNs(timestamp: Io.Timestamp) i64 {
    return @intCast(timestamp.toNanoseconds());
}

fn markTouched(list: *std.array_list.Managed(*Watcher), watcher: *Watcher, now_ms: i64) void {
    for (list.items) |existing| {
        if (existing == watcher) return;
    }
    watcher.markDirty(now_ms);
    list.append(watcher) catch {};
}

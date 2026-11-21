// Port of `src/kqueue/KqueueBackend.cc` from `@parcel/watcher` v2.5.6
// (external package).
//
// macOS uses kqueue as the terminal's native backend. The upstream parcel
// package defaults to FSEvents, which needs the CoreServices SDK and a
// CFRunLoop thread; kqueue is part of libSystem and integrates directly with
// the terminal poll loop. Directory write events trigger a small directory
// diff, and file descriptors are watched for content/metadata updates.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const watcher_mod = @import("watcher.zig");
const Watcher = watcher_mod.Watcher;
const root_mod = @import("root.zig");
const WaitHandle = root_mod.WaitHandle;

comptime {
    if (builtin.os.tag != .macos and builtin.os.tag != .freebsd and
        builtin.os.tag != .netbsd and builtin.os.tag != .openbsd and
        builtin.os.tag != .dragonfly)
    {
        @compileError("kqueue backend is only for kqueue platforms");
    }
}

const EVFILT_VNODE: i16 = -4;
const EV_ADD: u16 = 0x0001;
const EV_ENABLE: u16 = 0x0004;
const EV_CLEAR: u16 = 0x0020;
const EV_DELETE: u16 = 0x0002;
const NOTE_DELETE: u32 = 0x0001;
const NOTE_WRITE: u32 = 0x0002;
const NOTE_EXTEND: u32 = 0x0004;
const NOTE_ATTRIB: u32 = 0x0008;
const NOTE_RENAME: u32 = 0x0010;
const NOTE_REVOKE: u32 = 0x0020;
const VNODE_FLAGS = NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME | NOTE_REVOKE;

const Binding = struct {
    fd: posix.fd_t,
    watcher: *Watcher,
    path: []u8,
    is_dir: bool,
};

pub const Backend = struct {
    allocator: Allocator,
    io: Io,
    kq: posix.fd_t,
    bindings: std.array_list.Managed(Binding),
    /// kqueue needs one descriptor per watched file and directory, so a
    /// recursive watch of a large tree can exhaust `RLIMIT_NOFILE` before the
    /// app has a chance to spawn anything else. Stop adding watches at 75% of
    /// the soft limit; the rest of the tree stays unwatched instead of failing
    /// the whole watch or starving `spawn` of descriptors.
    fd_budget: usize,

    pub fn init(allocator: Allocator, io: Io) !Backend {
        const kq = std.c.kqueue();
        if (kq < 0) return error.KqueueInitFailed;
        const limits = std.posix.getrlimit(.NOFILE) catch std.posix.rlimit{ .cur = 0, .max = 0 };
        const fd_budget: usize = if (limits.cur >= 64)
            @intCast(@min(limits.cur - limits.cur / 4, @as(u64, std.math.maxInt(usize))))
        else
            64;
        return .{
            .allocator = allocator,
            .io = io,
            .kq = kq,
            .bindings = std.array_list.Managed(Binding).init(allocator),
            .fd_budget = fd_budget,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.removeAll();
        self.bindings.deinit();
        std.Io.Threaded.closeFd(self.kq);
    }

    pub fn waitHandle(self: *const Backend) WaitHandle {
        return .{ .fd = self.kq };
    }

    pub fn subscribe(self: *Backend, watcher: *Watcher) !void {
        try self.watchTree(watcher, watcher.dir, true);
    }

    fn watchTree(self: *Backend, watcher: *Watcher, path: []const u8, root: bool) !void {
        if (watcher.isCancelled()) return;
        if (self.bindings.items.len >= self.fd_budget) return;
        try self.addWatch(watcher, path, root);

        const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return;
        try watcher.tree.add(path, mtimeNs(stat.mtime), stat.kind == .directory);
        if (stat.kind != .directory) return;

        var dir = Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (true) {
            if (watcher.isCancelled()) return;
            const entry = (iterator.next(self.io) catch break) orelse break;
            if (entry.kind == .sym_link) continue;
            const child = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            if (watcher.isIgnored(child)) {
                self.allocator.free(child);
                continue;
            }
            if (watcher.recursive) {
                if (self.bindings.items.len >= self.fd_budget) {
                    self.allocator.free(child);
                    return;
                }
                try self.watchTree(watcher, child, false);
                self.allocator.free(child);
            } else {
                const child_stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch {
                    self.allocator.free(child);
                    continue;
                };
                try watcher.tree.add(child, mtimeNs(child_stat.mtime), child_stat.kind == .directory);
                if (child_stat.kind != .directory) {
                    self.addWatch(watcher, child, false) catch {};
                }
                self.allocator.free(child);
            }
        }
    }

    fn addWatch(self: *Backend, watcher: *Watcher, path: []const u8, root: bool) !void {
        if (self.bindings.items.len >= self.fd_budget) return error.WatchLimitReached;
        const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch {
            if (root) return error.WatchFailed;
            return;
        };
        const is_dir = stat.kind == .directory;
        if (watcher.isIgnored(path)) return;

        const path_z = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{path}, 0);
        defer self.allocator.free(path_z);
        const raw_fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .EVTONLY = true, .NONBLOCK = true, .CLOEXEC = true });
        if (raw_fd < 0) {
            if (root) return error.WatchFailed;
            return;
        }
        const fd: posix.fd_t = raw_fd;
        errdefer std.Io.Threaded.closeFd(fd);

        var change = std.posix.Kevent{
            .ident = @intCast(fd),
            .filter = EVFILT_VNODE,
            .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
            .fflags = VNODE_FLAGS,
            .data = 0,
            .udata = 0,
        };
        var event_buffer: [1]std.c.Kevent = undefined;
        if (std.c.kevent(self.kq, @ptrCast(&change), 1, &event_buffer, 0, null) < 0) {
            if (root) return error.WatchFailed;
            return;
        }

        try self.bindings.append(.{
            .fd = fd,
            .watcher = watcher,
            .path = try self.allocator.dupe(u8, path),
            .is_dir = is_dir,
        });
    }

    pub fn unsubscribe(self: *Backend, watcher: *Watcher) void {
        var index: usize = 0;
        while (index < self.bindings.items.len) {
            if (self.bindings.items[index].watcher != watcher) {
                index += 1;
                continue;
            }
            const binding = self.bindings.orderedRemove(index);
            self.closeBinding(binding);
        }
    }

    pub fn poll(self: *Backend, now_ms: i64) !bool {
        var events: [128]std.posix.Kevent = undefined;
        var timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
        var no_changes: [1]std.c.Kevent = undefined;
        const count = std.c.kevent(self.kq, &no_changes, 0, &events, events.len, &timeout);
        if (count < 0) return error.KqueuePollFailed;

        var changed = false;
        var index: usize = 0;
        while (index < @as(usize, @intCast(count))) : (index += 1) {
            const event = events[index];
            const binding_index = self.findBinding(@intCast(event.ident)) orelse continue;
            const binding = self.bindings.items[binding_index];

            if ((event.fflags & (NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE)) != 0) {
                try binding.watcher.recordDelete(binding.path);
                if (std.mem.eql(u8, binding.path, binding.watcher.dir)) {
                    try binding.watcher.recordError("Watcher shutdown because watched path got deleted");
                }
                binding.watcher.markDirty(now_ms);
                self.closeBinding(self.bindings.orderedRemove(binding_index));
                changed = true;
                continue;
            }

            if (binding.is_dir) {
                try self.diffDirectory(binding, now_ms);
            } else {
                const stat = Io.Dir.cwd().statFile(self.io, binding.path, .{ .follow_symlinks = false }) catch continue;
                try binding.watcher.recordUpdate(binding.path, mtimeNs(stat.mtime));
            }
            binding.watcher.markDirty(now_ms);
            changed = true;
        }
        return changed;
    }

    fn diffDirectory(self: *Backend, binding: Binding, now_ms: i64) !void {
        var present = std.StringHashMap(void).init(self.allocator);
        defer present.deinit();
        var present_keys = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (present_keys.items) |key| self.allocator.free(key);
            present_keys.deinit();
        }

        var dir = Io.Dir.cwd().openDir(self.io, binding.path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (true) {
            if (binding.watcher.isCancelled()) return;
            const entry = (iterator.next(self.io) catch break) orelse break;
            if (entry.kind == .sym_link) continue;
            const child = try std.fs.path.join(self.allocator, &.{ binding.path, entry.name });
            if (binding.watcher.isIgnored(child)) {
                self.allocator.free(child);
                continue;
            }
            try present.put(child, {});
            try present_keys.append(child);

            const stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch continue;
            if (binding.watcher.tree.find(child)) |old| {
                if (old.mtime_ns != mtimeNs(stat.mtime) and !old.is_dir and stat.kind != .directory) {
                    try binding.watcher.recordUpdate(child, mtimeNs(stat.mtime));
                }
            } else {
                try binding.watcher.recordCreate(child, mtimeNs(stat.mtime), stat.kind == .directory);
                if (stat.kind == .directory) {
                    if (binding.watcher.recursive) {
                        self.watchTree(binding.watcher, child, false) catch {};
                    }
                } else {
                    self.addWatch(binding.watcher, child, false) catch {};
                }
            }
        }

        // Entries that disappeared from this directory.
        var to_remove = std.array_list.Managed([]const u8).init(self.allocator);
        defer to_remove.deinit();
        var it = binding.watcher.tree.index.iterator();
        const prefix = binding.path;
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, path, prefix)) continue;
            if (path.len == prefix.len) continue;
            if (path[prefix.len] != std.fs.path.sep) continue;
            if (std.mem.indexOfScalar(u8, path[prefix.len + 1 ..], std.fs.path.sep) != null) continue;
            if (present.contains(path)) continue;
            try to_remove.append(path);
        }
        for (to_remove.items) |path| {
            try binding.watcher.recordDelete(path);
            self.removeBindingsUnder(path);
        }
        _ = now_ms;
    }

    fn findBinding(self: *Backend, fd: posix.fd_t) ?usize {
        for (self.bindings.items, 0..) |binding, index| {
            if (binding.fd == fd) return index;
        }
        return null;
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
                self.closeBinding(binding);
                continue;
            }
            index += 1;
        }
    }

    fn removeAll(self: *Backend) void {
        for (self.bindings.items) |binding| self.closeBinding(binding);
        self.bindings.clearRetainingCapacity();
    }

    fn closeBinding(self: *Backend, binding: Binding) void {
        var change = std.posix.Kevent{
            .ident = @intCast(binding.fd),
            .filter = EVFILT_VNODE,
            .flags = EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        var event_buffer: [1]std.c.Kevent = undefined;
        _ = std.c.kevent(self.kq, @ptrCast(&change), 1, &event_buffer, 0, null);
        std.Io.Threaded.closeFd(binding.fd);
        self.allocator.free(binding.path);
    }
};

fn mtimeNs(timestamp: Io.Timestamp) i64 {
    return @intCast(timestamp.toNanoseconds());
}

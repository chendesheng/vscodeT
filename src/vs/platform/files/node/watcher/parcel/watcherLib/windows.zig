// Port of `src/windows/WindowsBackend.cc` from `@parcel/watcher` v2.5.6
// (external package).
//
// Windows uses overlapped `ReadDirectoryChangesW` on one directory handle per
// watch root. The terminal library exposes `poll(now_ms)`; the overlapped
// completion event is checked without blocking, so no helper thread is needed.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const windows = std.os.windows;
const watcher_mod = @import("watcher.zig");
const Watcher = watcher_mod.Watcher;
const root_mod = @import("root.zig");
const WaitHandle = root_mod.WaitHandle;

comptime {
    if (builtin.os.tag != .windows) @compileError("Windows backend is Windows-only");
}

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const WCHAR = u16;

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const FILE_LIST_DIRECTORY: DWORD = 0x1;
const FILE_SHARE_READ: DWORD = 0x1;
const FILE_SHARE_WRITE: DWORD = 0x2;
const FILE_SHARE_DELETE: DWORD = 0x4;
const OPEN_EXISTING: DWORD = 3;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x1;
const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x2;
const FILE_NOTIFY_CHANGE_ATTRIBUTES: DWORD = 0x4;
const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x8;
const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x10;
const ERROR_OPERATION_ABORTED: DWORD = 995;
const ERROR_NOTIFY_ENUM_DIR: DWORD = 1022;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_INVALID_PARAMETER: DWORD = 87;
const ERROR_IO_PENDING: DWORD = 997;
const ERROR_SUCCESS: DWORD = 0;
const FILE_ACTION_ADDED: DWORD = 1;
const FILE_ACTION_REMOVED: DWORD = 2;
const FILE_ACTION_MODIFIED: DWORD = 3;
const FILE_ACTION_RENAMED_OLD_NAME: DWORD = 4;
const FILE_ACTION_RENAMED_NEW_NAME: DWORD = 5;

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    h_event: ?HANDLE = null,
};

const FileNotifyInformation = extern struct {
    next_entry_offset: u32,
    action: DWORD,
    file_name_length: DWORD,
    file_name: [1]WCHAR,
};

extern "kernel32" fn CreateFileW(
    file_name: [*:0]const u16,
    desired_access: DWORD,
    share_mode: DWORD,
    security_attributes: ?*anyopaque,
    creation_disposition: DWORD,
    flags_and_attributes: DWORD,
    template_file: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadDirectoryChangesW(
    directory: HANDLE,
    buffer: ?*anyopaque,
    buffer_length: DWORD,
    watch_subtree: BOOL,
    notify_filter: DWORD,
    bytes_returned: ?*DWORD,
    overlapped: ?*Overlapped,
    completion_routine: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(
    file: HANDLE,
    overlapped: *Overlapped,
    transferred: *DWORD,
    wait: BOOL,
) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(file: HANDLE, overlapped: ?*Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreateEventW(
    event_attributes: ?*anyopaque,
    manual_reset: BOOL,
    initial_state: BOOL,
    name: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;

const Subscription = struct {
    backend: *Backend,
    watcher: *Watcher,
    handle: HANDLE,
    event_handle: ?HANDLE,
    overlapped: Overlapped = .{},
    buffer: []u8,
    recursive: bool,
    running: bool = true,
};

pub const Backend = struct {
    allocator: Allocator,
    io: Io,
    subscriptions: std.array_list.Managed(*Subscription),

    pub fn init(allocator: Allocator, io: Io) !Backend {
        return .{
            .allocator = allocator,
            .io = io,
            .subscriptions = std.array_list.Managed(*Subscription).init(allocator),
        };
    }

    pub fn deinit(self: *Backend) void {
        for (self.subscriptions.items) |subscription| self.destroySubscription(subscription);
        self.subscriptions.deinit();
    }

    pub fn waitHandle(_: *const Backend) WaitHandle {
        return .none;
    }

    pub fn subscribe(self: *Backend, watcher: *Watcher) !void {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, watcher.dir);
        defer self.allocator.free(path_w);

        const handle = CreateFileW(
            path_w,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (handle == INVALID_HANDLE_VALUE) return error.WatchFailed;

        const event_handle = CreateEventW(null, .FALSE, .FALSE, null);
        if (event_handle == null) {
            _ = windows.CloseHandle(handle);
            return error.WatchFailed;
        }

        const buffer = try self.allocator.alloc(u8, 1024 * 1024);
        errdefer self.allocator.free(buffer);

        const subscription = try self.allocator.create(Subscription);
        errdefer self.allocator.destroy(subscription);
        subscription.* = .{
            .backend = self,
            .watcher = watcher,
            .handle = handle,
            .event_handle = event_handle,
            .buffer = buffer,
            .recursive = watcher.recursive,
        };
        subscription.overlapped.h_event = event_handle;

        try self.subscriptions.append(subscription);
        self.issue(subscription) catch {
            _ = self.subscriptions.pop();
            self.destroySubscription(subscription);
            return error.WatchFailed;
        };

        // Build the initial tree without emitting events.
        try self.buildTree(watcher, watcher.dir);
    }

    fn issue(self: *Backend, subscription: *Subscription) !void {
        _ = self;
        const result = ReadDirectoryChangesW(
            subscription.handle,
            subscription.buffer.ptr,
            @intCast(subscription.buffer.len),
            if (subscription.recursive) windows.BOOL.TRUE else windows.BOOL.FALSE,
            FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
                FILE_NOTIFY_CHANGE_LAST_WRITE,
            null,
            &subscription.overlapped,
            null,
        );
        if (result == .FALSE) {
            const err = windows.GetLastError();
            if (err != .IO_PENDING) return error.WatchFailed;
        }
    }

    pub fn unsubscribe(self: *Backend, watcher: *Watcher) void {
        var index: usize = 0;
        while (index < self.subscriptions.items.len) : (index += 1) {
            if (self.subscriptions.items[index].watcher != watcher) continue;
            const subscription = self.subscriptions.orderedRemove(index);
            self.destroySubscription(subscription);
            return;
        }
    }

    pub fn poll(self: *Backend, now_ms: i64) !bool {
        _ = now_ms;
        var changed = false;
        for (self.subscriptions.items) |subscription| {
            if (!subscription.running) continue;
            if (WaitForSingleObject(subscription.event_handle.?, 0) != 0) continue;

            var transferred: DWORD = 0;
            const ok = GetOverlappedResult(subscription.handle, &subscription.overlapped, &transferred, .FALSE);
            if (ok == .FALSE) {
                const err = windows.GetLastError();
                if (err == .OPERATION_ABORTED) continue;
                if (err == .ACCESS_DENIED) {
                    if (!self.pathIsDirectory(subscription.watcher.dir)) {
                        try subscription.watcher.recordDelete(subscription.watcher.dir);
                        try subscription.watcher.recordError("Watcher shutdown because watched path got deleted");
                        subscription.running = false;
                        changed = true;
                        continue;
                    }
                }
                if (err == .NOTIFY_ENUM_DIR) {
                    try subscription.watcher.recordError("Buffer overflow. Some events may have been lost.");
                }
                self.restart(subscription) catch {};
                continue;
            }

            try self.processBuffer(subscription, subscription.buffer[0..transferred]);
            changed = true;
            self.issue(subscription) catch |err| {
                if (err == error.WatchFailed) {
                    try subscription.watcher.recordError("Failed to read changes");
                }
            };
        }
        return changed;
    }

    fn processBuffer(self: *Backend, subscription: *Subscription, data: []const u8) !void {
        var offset: usize = 0;
        const header_size = @offsetOf(FileNotifyInformation, "file_name");
        while (offset + header_size <= data.len) {
            const info: *align(1) const FileNotifyInformation = @ptrCast(&data[offset]);
            const name_bytes = info.file_name_length;
            if (offset + header_size + name_bytes > data.len) break;
            const name_start = offset + header_size;
            const name_units = try self.allocator.alloc(u16, name_bytes / 2);
            defer self.allocator.free(name_units);
            @memcpy(std.mem.sliceAsBytes(name_units), data[name_start .. name_start + name_bytes]);
            const name = std.unicode.utf16LeToUtf8Alloc(self.allocator, name_units) catch {
                offset += if (info.next_entry_offset == 0) data.len else info.next_entry_offset;
                continue;
            };
            defer self.allocator.free(name);
            const full = try std.fs.path.join(self.allocator, &.{ subscription.watcher.dir, name });
            defer self.allocator.free(full);

            try self.processAction(subscription.watcher, full, info.action);
            if (info.next_entry_offset == 0) break;
            offset += info.next_entry_offset;
        }
    }

    fn processAction(self: *Backend, watcher: *Watcher, path: []const u8, action: DWORD) !void {
        switch (action) {
            FILE_ACTION_ADDED, FILE_ACTION_RENAMED_NEW_NAME => {
                const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return;
                try watcher.recordCreate(path, mtimeNs(stat.mtime), stat.kind == .directory);
            },
            FILE_ACTION_MODIFIED => {
                const stat = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return;
                try watcher.tree.add(path, mtimeNs(stat.mtime), stat.kind == .directory);
                if (stat.kind != .directory) try watcher.recordUpdate(path, mtimeNs(stat.mtime));
            },
            FILE_ACTION_REMOVED, FILE_ACTION_RENAMED_OLD_NAME => {
                try watcher.recordDelete(path);
            },
            else => {},
        }
    }

    fn buildTree(self: *Backend, watcher: *Watcher, root: []const u8) !void {
        const stat = std.Io.Dir.cwd().statFile(self.io, root, .{ .follow_symlinks = false }) catch return;
        try watcher.tree.add(root, mtimeNs(stat.mtime), stat.kind == .directory);
        if (!watcher.recursive) return;

        var stack = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (stack.items) |item| self.allocator.free(item);
            stack.deinit();
        }
        try stack.append(try self.allocator.dupe(u8, root));
        while (stack.pop()) |path| {
            defer self.allocator.free(path);
            var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            var iterator = dir.iterate();
            while (true) {
                const entry = (iterator.next(self.io) catch break) orelse break;
                if (entry.kind == .sym_link) continue;
                const child = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                if (watcher.isIgnored(child)) {
                    self.allocator.free(child);
                    continue;
                }
                const child_stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch {
                    self.allocator.free(child);
                    continue;
                };
                try watcher.tree.add(child, mtimeNs(child_stat.mtime), child_stat.kind == .directory);
                if (child_stat.kind == .directory) {
                    try stack.append(child);
                } else {
                    self.allocator.free(child);
                }
            }
        }
    }

    fn pathIsDirectory(self: *Backend, path: []const u8) bool {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return false;
        return stat.kind == .directory;
    }

    fn restart(self: *Backend, subscription: *Subscription) !void {
        _ = self;
        _ = subscription;
    }

    fn destroySubscription(self: *Backend, subscription: *Subscription) void {
        subscription.running = false;
        _ = CancelIoEx(subscription.handle, &subscription.overlapped);
        if (subscription.event_handle) |handle| _ = windows.CloseHandle(handle);
        _ = windows.CloseHandle(subscription.handle);
        self.allocator.free(subscription.buffer);
        self.allocator.destroy(subscription);
    }
};

fn mtimeNs(timestamp: Io.Timestamp) i64 {
    return @intCast(timestamp.toNanoseconds());
}

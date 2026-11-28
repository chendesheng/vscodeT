// Port of `src/vs/platform/files/common/inMemoryFilesystemProvider.ts`.
//
// Terminal adaptation: resources are canonical path strings instead of `URI`s
// and operations are synchronous (no promises). Change notifications are
// delivered synchronously to registered listeners instead of the upstream
// 5ms-debounced `Emitter`. The tree, capability flags, fd bookkeeping,
// create/overwrite/append rules and error codes follow the upstream provider.
const std = @import("std");
const Allocator = std.mem.Allocator;

const files = @import("./files.zig");
const time_compat = @import("../../../base/common/timeCompat.zig");
const FileType = files.FileType;
const IStat = files.IStat;
const DirectoryEntry = files.DirectoryEntry;
const FileSystemProviderCapabilities = files.FileSystemProviderCapabilities;
const FileSystemProviderError = files.FileSystemProviderError;
const IFileChange = files.IFileChange;
const IFileChangeListener = files.IFileChangeListener;
const IFileDeleteOptions = files.IFileDeleteOptions;
const IFileOverwriteOptions = files.IFileOverwriteOptions;
const IFileWriteOptions = files.IFileWriteOptions;
const IFileOpenOptions = files.IFileOpenOptions;
const IWatchOptions = files.IWatchOptions;
const IFileSystemProvider = files.IFileSystemProvider;
const FileChangeType = files.FileChangeType;

const File = struct {
    name: []u8,
    ctime: i64,
    mtime: i64,
    size: u64,
    data: ?[]u8 = null,
};

const Directory = struct {
    name: []u8,
    ctime: i64,
    mtime: i64,
    size: u64 = 0,
    entries: std.StringHashMap(Entry),
};

const Entry = union(enum) {
    file: *File,
    directory: *Directory,
};

const Fd = struct {
    file: *File,
    resource: []u8,
    write: bool,
    append: bool,
};

pub const InMemoryFileSystemProvider = struct {
    io: std.Io,
    allocator: Allocator,
    root: *Directory,
    capabilities: u32 = FileSystemProviderCapabilities.FileReadWrite |
        FileSystemProviderCapabilities.FileOpenReadWriteClose |
        FileSystemProviderCapabilities.FileAppend |
        FileSystemProviderCapabilities.PathCaseSensitive,
    fds: std.AutoHashMap(u32, Fd),
    next_fd: u32 = 0,
    listeners: std.array_list.Managed(IFileChangeListener),

    pub fn init(allocator: Allocator, io: std.Io) !InMemoryFileSystemProvider {
        const root = try allocator.create(Directory);
        errdefer allocator.destroy(root);
        const now = time_compat.milliTimestamp(io);
        root.* = .{
            .name = try allocator.dupe(u8, ""),
            .ctime = now,
            .mtime = now,
            .entries = std.StringHashMap(Entry).init(allocator),
        };
        return .{
            .allocator = allocator,
            .root = root,
            .io = io,
            .fds = std.AutoHashMap(u32, Fd).init(allocator),
            .listeners = std.array_list.Managed(IFileChangeListener).init(allocator),
        };
    }

    pub fn deinit(self: *InMemoryFileSystemProvider) void {
        self.freeDirectory(self.root);
        var fd_iterator = self.fds.valueIterator();
        while (fd_iterator.next()) |fd| self.allocator.free(fd.resource);
        self.fds.deinit();
        self.listeners.deinit();
    }

    fn freeDirectory(self: *InMemoryFileSystemProvider, directory: *Directory) void {
        var iterator = directory.entries.valueIterator();
        while (iterator.next()) |entry| {
            switch (entry.*) {
                .file => |file| {
                    self.allocator.free(file.name);
                    if (file.data) |data| self.allocator.free(data);
                    self.allocator.destroy(file);
                },
                .directory => |child| self.freeDirectory(child),
            }
        }
        directory.entries.deinit();
        self.allocator.free(directory.name);
        self.allocator.destroy(directory);
    }

    pub fn interface(self: *InMemoryFileSystemProvider) IFileSystemProvider {
        return .{
            .context = self,
            .capabilities = capabilitiesFn,
            .stat = statFn,
            .mkdir = mkdirFn,
            .readdir = readdirFn,
            .delete = deleteFn,
            .rename = renameFn,
            .read_file = readFileFn,
            .write_file = writeFileFn,
            .open = openFn,
            .close = closeFn,
            .read = readFn,
            .write = writeFn,
            .watch = watchFn,
            .add_change_listener = addChangeListenerFn,
            .remove_change_listener = removeChangeListenerFn,
        };
    }

    pub fn setReadOnly(self: *InMemoryFileSystemProvider, read_only: bool) void {
        const is_readonly = (self.capabilities & FileSystemProviderCapabilities.Readonly) != 0;
        if (read_only == is_readonly) return;
        self.capabilities = FileSystemProviderCapabilities.FileReadWrite |
            FileSystemProviderCapabilities.FileAppend |
            FileSystemProviderCapabilities.PathCaseSensitive |
            (if (read_only) FileSystemProviderCapabilities.Readonly else 0);
    }

    // --- manage file metadata

    pub fn stat(self: *InMemoryFileSystemProvider, resource: []const u8) FileSystemProviderError!IStat {
        const entry = (try self.lookup(resource, false)) orelse return error.FileNotFound;
        return switch (entry) {
            .file => |file| .{ .type = FileType.File, .mtime = file.mtime, .ctime = file.ctime, .size = file.size },
            .directory => |directory| .{ .type = FileType.Directory, .mtime = directory.mtime, .ctime = directory.ctime, .size = directory.size },
        };
    }

    pub fn readdir(self: *InMemoryFileSystemProvider, resource: []const u8) FileSystemProviderError![]DirectoryEntry {
        const directory = try self.lookupAsDirectory(resource, false);
        const result = try self.allocator.alloc(DirectoryEntry, directory.entries.count());
        var iterator = directory.entries.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            result[index] = .{
                .name = entry.key_ptr.*,
                .type = switch (entry.value_ptr.*) {
                    .file => FileType.File,
                    .directory => FileType.Directory,
                },
            };
        }
        return result;
    }

    // --- manage file contents

    pub fn readFile(self: *InMemoryFileSystemProvider, resource: []const u8) FileSystemProviderError![]u8 {
        const file = try self.lookupAsFile(resource, false);
        const data = file.data orelse return error.FileNotFound;
        return try self.allocator.dupe(u8, data);
    }

    pub fn writeFile(
        self: *InMemoryFileSystemProvider,
        resource: []const u8,
        content: []const u8,
        options: IFileWriteOptions,
    ) FileSystemProviderError!void {
        const basename = pathBasename(resource);
        const parent = try self.lookupParentDirectory(resource);
        const existing = parent.entries.get(basename);
        if (existing) |entry| {
            switch (entry) {
                .directory => return error.FileIsADirectory,
                .file => {},
            }
        }
        if (existing == null and !options.create) return error.FileNotFound;
        if (existing != null and options.create and !options.overwrite) return error.FileExists;

        var file: *File = undefined;
        if (existing) |entry| {
            file = entry.file;
        } else {
            file = try self.createFile(basename);
            try parent.entries.put(file.name, .{ .file = file });
            parent.mtime = time_compat.milliTimestamp(self.io);
            parent.size += 1;
            self.fire(&.{.{ .type = .ADDED, .resource = resource }});
        }

        file.mtime = time_compat.milliTimestamp(self.io);
        if (options.append) {
            const old_len = if (file.data) |data| data.len else 0;
            const combined = try self.allocator.alloc(u8, old_len + content.len);
            if (file.data) |data| {
                @memcpy(combined[0..data.len], data);
                self.allocator.free(data);
            }
            @memcpy(combined[old_len..], content);
            file.data = combined;
            file.size = combined.len;
        } else {
            if (file.data) |data| self.allocator.free(data);
            file.data = try self.allocator.dupe(u8, content);
            file.size = file.data.?.len;
        }

        self.fire(&.{.{ .type = .UPDATED, .resource = resource }});
    }

    // --- open/read/write/close

    pub fn open(self: *InMemoryFileSystemProvider, resource: []const u8, options: IFileOpenOptions) FileSystemProviderError!u32 {
        const for_write = options.create or options.overwrite or options.append;
        const append = for_write and options.append;
        const found = try self.lookup(resource, true);
        var file: *File = undefined;

        if (found) |entry| {
            switch (entry) {
                .directory => return error.FileIsADirectory,
                .file => |value| file = value,
            }
        } else {
            if (!for_write) return error.FileNotFound;
            const basename = pathBasename(resource);
            const parent = try self.lookupParentDirectory(resource);
            file = try self.createFile(basename);
            parent.entries.put(file.name, .{ .file = file }) catch return error.Unknown;
            parent.mtime = time_compat.milliTimestamp(self.io);
            parent.size += 1;
            self.fire(&.{.{ .type = .ADDED, .resource = resource }});
        }

        const fd = self.next_fd;
        self.next_fd += 1;
        try self.fds.put(fd, .{
            .file = file,
            .resource = try self.allocator.dupe(u8, resource),
            .write = for_write,
            .append = append,
        });
        return fd;
    }

    pub fn close(self: *InMemoryFileSystemProvider, fd: u32) FileSystemProviderError!void {
        const fd_data = self.fds.get(fd) orelse return error.Unavailable;
        if (fd_data.write) {
            fd_data.file.mtime = time_compat.milliTimestamp(self.io);
            fd_data.file.size = if (fd_data.file.data) |data| data.len else 0;
            self.fire(&.{.{ .type = .UPDATED, .resource = fd_data.resource }});
        }
        self.allocator.free(fd_data.resource);
        _ = self.fds.remove(fd);
    }

    pub fn read(self: *InMemoryFileSystemProvider, fd: u32, position: usize, data: []u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const fd_data = self.fds.get(fd) orelse return error.Unavailable;
        const file_data = fd_data.file.data orelse return 0;
        if (position >= file_data.len) return 0;
        const count = @min(length, file_data.len - position);
        if (offset + count > data.len) return error.Unknown;
        @memcpy(data[offset .. offset + count], file_data[position .. position + count]);
        return count;
    }

    pub fn write(self: *InMemoryFileSystemProvider, fd: u32, position: usize, data: []const u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const fd_data = self.fds.get(fd) orelse return error.Unavailable;
        if (offset + length > data.len) return error.Unknown;
        const to_write = data[offset .. offset + length];
        const current = fd_data.file.data orelse &.{};
        const write_position = if (fd_data.append) current.len else position;
        const end_position = write_position + to_write.len;
        if (end_position > current.len) {
            const grown = try self.allocator.alloc(u8, end_position);
            @memcpy(grown[0..current.len], current);
            if (fd_data.file.data) |old| self.allocator.free(old);
            fd_data.file.data = grown;
        }
        @memcpy(fd_data.file.data.?[write_position..end_position], to_write);
        return to_write.len;
    }

    // --- manage files/folders

    pub fn mkdir(self: *InMemoryFileSystemProvider, resource: []const u8) FileSystemProviderError!void {
        if (try self.lookup(resource, true) != null) return error.FileExists;
        const basename = pathBasename(resource);
        const parent = try self.lookupParentDirectory(resource);
        const directory = try self.createDirectory(basename);
        parent.entries.put(directory.name, .{ .directory = directory }) catch return error.Unknown;
        parent.mtime = time_compat.milliTimestamp(self.io);
        parent.size += 1;
        self.fire(&.{
            .{ .type = .UPDATED, .resource = pathDirname(resource) },
            .{ .type = .ADDED, .resource = resource },
        });
    }

    pub fn delete(self: *InMemoryFileSystemProvider, resource: []const u8, _: IFileDeleteOptions) FileSystemProviderError!void {
        const basename = pathBasename(resource);
        const parent = try self.lookupAsDirectory(pathDirname(resource), false);
        if (parent.entries.fetchRemove(basename)) |removed| {
            self.freeEntry(removed.value);
            parent.mtime = time_compat.milliTimestamp(self.io);
            parent.size -|= 1;
            self.fire(&.{
                .{ .type = .UPDATED, .resource = pathDirname(resource) },
                .{ .type = .DELETED, .resource = resource },
            });
        }
    }

    pub fn rename(self: *InMemoryFileSystemProvider, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        if (!options.overwrite and try self.lookup(to, true) != null) return error.FileExists;
        const entry = (try self.lookup(from, false)) orelse return error.FileNotFound;
        const old_parent = try self.lookupParentDirectory(from);
        _ = old_parent.entries.remove(pathBasename(from));
        old_parent.size -|= 1;

        const new_name = pathBasename(to);
        const new_parent = try self.lookupParentDirectory(to);
        new_parent.size += 1;
        const name_copy = try self.allocator.dupe(u8, new_name);
        switch (entry) {
            .file => |file| {
                self.allocator.free(file.name);
                file.name = name_copy;
                new_parent.entries.put(file.name, .{ .file = file }) catch return error.Unknown;
            },
            .directory => |directory| {
                self.allocator.free(directory.name);
                directory.name = name_copy;
                new_parent.entries.put(directory.name, .{ .directory = directory }) catch return error.Unknown;
            },
        }
        self.fire(&.{
            .{ .type = .DELETED, .resource = from },
            .{ .type = .ADDED, .resource = to },
        });
    }

    // --- lookup helpers

    fn lookup(self: *InMemoryFileSystemProvider, resource: []const u8, silent: bool) FileSystemProviderError!?Entry {
        var entry: Entry = .{ .directory = self.root };
        var iterator = std.mem.splitScalar(u8, resource, '/');
        while (iterator.next()) |part| {
            if (part.len == 0) continue;
            const directory = switch (entry) {
                .directory => |value| value,
                .file => {
                    if (silent) return null;
                    return error.FileNotADirectory;
                },
            };
            entry = directory.entries.get(part) orelse {
                if (silent) return null;
                return error.FileNotFound;
            };
        }
        return entry;
    }

    fn lookupAsDirectory(self: *InMemoryFileSystemProvider, resource: []const u8, silent: bool) FileSystemProviderError!*Directory {
        const entry = (try self.lookup(resource, silent)) orelse return error.FileNotFound;
        return switch (entry) {
            .directory => |directory| directory,
            .file => error.FileNotADirectory,
        };
    }

    fn lookupAsFile(self: *InMemoryFileSystemProvider, resource: []const u8, silent: bool) FileSystemProviderError!*File {
        const entry = (try self.lookup(resource, silent)) orelse return error.FileNotFound;
        return switch (entry) {
            .file => |file| file,
            .directory => error.FileIsADirectory,
        };
    }

    fn lookupParentDirectory(self: *InMemoryFileSystemProvider, resource: []const u8) FileSystemProviderError!*Directory {
        return self.lookupAsDirectory(pathDirname(resource), false);
    }

    fn createFile(self: *InMemoryFileSystemProvider, name: []const u8) FileSystemProviderError!*File {
        const file = self.allocator.create(File) catch return error.Unknown;
        const now = time_compat.milliTimestamp(self.io);
        file.* = .{
            .name = self.allocator.dupe(u8, name) catch return error.Unknown,
            .ctime = now,
            .mtime = now,
            .size = 0,
        };
        return file;
    }

    fn createDirectory(self: *InMemoryFileSystemProvider, name: []const u8) FileSystemProviderError!*Directory {
        const directory = self.allocator.create(Directory) catch return error.Unknown;
        const now = time_compat.milliTimestamp(self.io);
        directory.* = .{
            .name = self.allocator.dupe(u8, name) catch return error.Unknown,
            .ctime = now,
            .mtime = now,
            .entries = std.StringHashMap(Entry).init(self.allocator),
        };
        return directory;
    }

    fn freeEntry(self: *InMemoryFileSystemProvider, entry: Entry) void {
        switch (entry) {
            .file => |file| {
                self.allocator.free(file.name);
                if (file.data) |data| self.allocator.free(data);
                self.allocator.destroy(file);
            },
            .directory => |directory| self.freeDirectory(directory),
        }
    }

    // --- events

    pub fn addChangeListener(self: *InMemoryFileSystemProvider, listener: IFileChangeListener) void {
        self.listeners.append(listener) catch {};
    }

    pub fn removeChangeListener(self: *InMemoryFileSystemProvider, listener: IFileChangeListener) void {
        var index: usize = 0;
        while (index < self.listeners.items.len) : (index += 1) {
            const current = self.listeners.items[index];
            if (current.context == listener.context and current.callback == listener.callback) {
                _ = self.listeners.orderedRemove(index);
                return;
            }
        }
    }

    fn fire(self: *InMemoryFileSystemProvider, changes: []const IFileChange) void {
        for (self.listeners.items) |listener| listener.callback(listener.context, changes);
    }

    pub fn watch(_: *InMemoryFileSystemProvider, _: []const u8, _: IWatchOptions) FileSystemProviderError!void {}

    // --- interface adapters

    fn capabilitiesFn(context: *anyopaque) u32 {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.capabilities;
    }

    fn statFn(context: *anyopaque, resource: []const u8) FileSystemProviderError!IStat {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.stat(resource);
    }

    fn mkdirFn(context: *anyopaque, resource: []const u8) FileSystemProviderError!void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.mkdir(resource);
    }

    fn readdirFn(context: *anyopaque, resource: []const u8) FileSystemProviderError![]DirectoryEntry {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.readdir(resource);
    }

    fn deleteFn(context: *anyopaque, resource: []const u8, options: IFileDeleteOptions) FileSystemProviderError!void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.delete(resource, options);
    }

    fn renameFn(context: *anyopaque, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.rename(from, to, options);
    }

    fn readFileFn(context: *anyopaque, resource: []const u8) FileSystemProviderError![]u8 {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.readFile(resource);
    }

    fn writeFileFn(context: *anyopaque, resource: []const u8, content: []const u8, options: IFileWriteOptions) FileSystemProviderError!void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.writeFile(resource, content, options);
    }

    fn openFn(context: *anyopaque, resource: []const u8, options: IFileOpenOptions) FileSystemProviderError!u32 {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.open(resource, options);
    }

    fn closeFn(context: *anyopaque, fd: u32) FileSystemProviderError!void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.close(fd);
    }

    fn readFn(context: *anyopaque, fd: u32, position: usize, data: []u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.read(fd, position, data, offset, length);
    }

    fn writeFn(context: *anyopaque, fd: u32, position: usize, data: []const u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.write(fd, position, data, offset, length);
    }

    fn watchFn(context: *anyopaque, resource: []const u8, options: IWatchOptions) FileSystemProviderError!void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        return self.watch(resource, options);
    }

    fn addChangeListenerFn(context: *anyopaque, listener: IFileChangeListener) void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        self.addChangeListener(listener);
    }

    fn removeChangeListenerFn(context: *anyopaque, listener: IFileChangeListener) void {
        const self: *InMemoryFileSystemProvider = @ptrCast(@alignCast(context));
        self.removeChangeListener(listener);
    }
};

fn pathBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| return path[index + 1 ..];
    return path;
}

fn pathDirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| {
        if (index == 0) return "/";
        return path[0..index];
    }
    return "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "in-memory provider: creates folders and lists entries" {
    const allocator = testing.allocator;
    var provider = try InMemoryFileSystemProvider.init(allocator, std.testing.io);
    defer provider.deinit();

    try provider.mkdir("/folder");
    const stat = try provider.stat("/folder");
    try testing.expect(FileType.isDirectory(stat.type));

    try provider.writeFile("/folder/file.txt", "hello", .{ .create = true, .overwrite = true });
    const entries = try provider.readdir("/folder");
    defer allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("file.txt", entries[0].name);
    try testing.expect(FileType.isFile(entries[0].type));

    try provider.delete("/folder/file.txt", .{});
    const empty = try provider.readdir("/folder");
    defer allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "in-memory provider: writes, appends and reads file contents" {
    const allocator = testing.allocator;
    var provider = try InMemoryFileSystemProvider.init(allocator, std.testing.io);
    defer provider.deinit();

    try provider.writeFile("/file.txt", "hello", .{ .create = true, .overwrite = false });
    const first = try provider.readFile("/file.txt");
    defer allocator.free(first);
    try testing.expectEqualStrings("hello", first);

    try provider.writeFile("/file.txt", " world", .{ .create = true, .overwrite = true, .append = true });
    const appended = try provider.readFile("/file.txt");
    defer allocator.free(appended);
    try testing.expectEqualStrings("hello world", appended);

    try provider.writeFile("/file.txt", "hi", .{ .create = true, .overwrite = true });
    const replaced = try provider.readFile("/file.txt");
    defer allocator.free(replaced);
    try testing.expectEqualStrings("hi", replaced);

    try testing.expectError(error.FileNotFound, provider.readFile("/missing.txt"));
    try testing.expectError(error.FileExists, provider.writeFile("/file.txt", "x", .{ .create = true, .overwrite = false }));
}

test "in-memory provider: renames and moves entries" {
    const allocator = testing.allocator;
    var provider = try InMemoryFileSystemProvider.init(allocator, std.testing.io);
    defer provider.deinit();

    try provider.mkdir("/from");
    try provider.writeFile("/from/file.txt", "data", .{ .create = true, .overwrite = true });
    try provider.rename("/from/file.txt", "/file.txt", .{ .overwrite = false });

    try testing.expectError(error.FileNotFound, provider.stat("/from/file.txt"));
    const stat = try provider.stat("/file.txt");
    try testing.expect(FileType.isFile(stat.type));
    const data = try provider.readFile("/file.txt");
    defer allocator.free(data);
    try testing.expectEqualStrings("data", data);
}

test "in-memory provider: open/read/write/close" {
    const allocator = testing.allocator;
    var provider = try InMemoryFileSystemProvider.init(allocator, std.testing.io);
    defer provider.deinit();

    const fd = try provider.open("/fd.txt", .{ .create = true, .overwrite = false });
    const written = try provider.write(fd, 0, "abc", 0, 3);
    try testing.expectEqual(@as(usize, 3), written);
    try provider.close(fd);

    const read_fd = try provider.open("/fd.txt", .{ .create = false, .overwrite = false });
    var buffer: [8]u8 = undefined;
    const read_count = try provider.read(read_fd, 1, &buffer, 0, 8);
    try testing.expectEqual(@as(usize, 2), read_count);
    try testing.expectEqualStrings("bc", buffer[0..read_count]);
    try provider.close(read_fd);

    const stat = try provider.stat("/fd.txt");
    try testing.expectEqual(@as(u64, 3), stat.size);
}

test "in-memory provider: notifies listeners synchronously" {
    const allocator = testing.allocator;
    var provider = try InMemoryFileSystemProvider.init(allocator, std.testing.io);
    defer provider.deinit();

    const Listener = struct {
        types: std.array_list.Managed(files.FileChangeType) = undefined,
        resources: std.array_list.Managed([]const u8) = undefined,

        fn callback(context: *anyopaque, changes: []const IFileChange) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (changes) |change| {
                self.types.append(change.type) catch {};
                self.resources.append(change.resource) catch {};
            }
        }
    };
    var listener = Listener{
        .types = std.array_list.Managed(files.FileChangeType).init(allocator),
        .resources = std.array_list.Managed([]const u8).init(allocator),
    };
    defer listener.types.deinit();
    defer listener.resources.deinit();
    provider.addChangeListener(.{ .context = &listener, .callback = Listener.callback });

    try provider.writeFile("/event.txt", "x", .{ .create = true, .overwrite = true });
    try testing.expectEqual(@as(usize, 2), listener.types.items.len);
    try testing.expectEqual(files.FileChangeType.ADDED, listener.types.items[0]);
    try testing.expectEqual(files.FileChangeType.UPDATED, listener.types.items[1]);

    provider.removeChangeListener(.{ .context = &listener, .callback = Listener.callback });
    try provider.writeFile("/event.txt", "y", .{ .create = true, .overwrite = true });
    try testing.expectEqual(@as(usize, 2), listener.types.items.len);
}

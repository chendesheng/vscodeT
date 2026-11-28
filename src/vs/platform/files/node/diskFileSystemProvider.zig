// Terminal port of the disk provider in
// `src/vs/platform/files/node/diskFileSystemProvider.ts`.
//
// Terminal adaptation: resources are absolute path strings. Path operations
// invoked from a window fiber await detached DiskFileService work; provider
// state and events stay on the window. Standalone and legacy fd callers retain
// their synchronous contract.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const files = @import("../common/files.zig");
const dispatch = @import("../../../base/common/windowDispatch.zig");
const disk_service_mod = @import("../common/fileService.zig");
const DiskFileService = disk_service_mod.DiskFileService;
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

pub const DiskFileSystemProvider = struct {
    allocator: Allocator,
    io: Io,
    window: ?*dispatch.Queue = null,
    files: DiskFileService,
    fds: std.AutoHashMap(u32, Fd),
    next_fd: u32 = 0,
    listeners: std.array_list.Managed(IFileChangeListener),
    /// Watch requests registered through `watch`, filtered by
    /// `deliverChanges` when the host forwards watcher events.
    watches: std.array_list.Managed(WatchEntry),
    /// Names returned by the most recent `readdir`; valid until the next call.
    names_arena: std.heap.ArenaAllocator,

    const WatchEntry = struct {
        resource: []u8,
        recursive: bool,
    };

    const Fd = struct {
        file: Io.File,
        resource: []u8,
        append: bool,
        write: bool,
    };

    pub fn init(allocator: Allocator, io: Io) DiskFileSystemProvider {
        return .{
            .allocator = allocator,
            .io = io,
            .files = DiskFileService.init(allocator, io),
            .fds = std.AutoHashMap(u32, Fd).init(allocator),
            .listeners = std.array_list.Managed(IFileChangeListener).init(allocator),
            .watches = std.array_list.Managed(WatchEntry).init(allocator),
            .names_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DiskFileSystemProvider) void {
        var iterator = self.fds.valueIterator();
        while (iterator.next()) |fd| {
            fd.file.close(self.io);
            self.allocator.free(fd.resource);
        }
        self.fds.deinit();
        self.listeners.deinit();
        for (self.watches.items) |entry| self.allocator.free(entry.resource);
        self.watches.deinit();
        self.names_arena.deinit();
        self.files.deinit();
    }

    pub fn attachWindow(self: *DiskFileSystemProvider, window: *dispatch.Queue) void {
        self.window = window;
    }

    /// Only the copied allocator, backing Io and operation arguments enter the
    /// worker. In particular its temporary service has no window listeners.
    fn diskCall(self: *DiskFileSystemProvider, comptime operation: anytype, args: anytype) @typeInfo(@TypeOf(operation)).@"fn".return_type.? {
        const Result = @typeInfo(@TypeOf(operation)).@"fn".return_type.?;
        const Runner = struct {
            fn run(a: Allocator, io: Io, captured: @TypeOf(args)) Result {
                var disk = DiskFileService.init(a, io);
                defer disk.deinit();
                return @call(.auto, operation, .{&disk} ++ captured);
            }
        };
        if (self.window) |window| {
            if (@import("ui").WindowIo.inFiber(window.io))
                return dispatch.workerCall(window.io, Runner.run, .{ self.allocator, self.io, args });
        }
        return Runner.run(self.allocator, self.io, args);
    }

    pub fn interface(self: *DiskFileSystemProvider) IFileSystemProvider {
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

    pub fn capabilities(_: *const DiskFileSystemProvider) u32 {
        return FileSystemProviderCapabilities.FileReadWrite |
            FileSystemProviderCapabilities.FileOpenReadWriteClose |
            FileSystemProviderCapabilities.FileFolderCopy |
            FileSystemProviderCapabilities.FileAppend |
            (if (@import("builtin").os.tag == .linux) FileSystemProviderCapabilities.PathCaseSensitive else 0);
    }

    pub fn stat(self: *DiskFileSystemProvider, resource: []const u8) FileSystemProviderError!IStat {
        const info = self.diskCall(DiskFileService.stat, .{resource}) catch |err| return mapError(err);
        return .{
            .type = info.type,
            .size = info.size,
            .mtime = @intCast(info.mtime),
            .ctime = @intCast(info.ctime),
        };
    }

    pub fn mkdir(self: *DiskFileSystemProvider, resource: []const u8) FileSystemProviderError!void {
        self.diskCall(DiskFileService.createDirectory, .{resource}) catch |err| return mapError(err);
        self.fire(&.{.{ .type = .ADDED, .resource = resource }});
    }

    pub fn readdir(self: *DiskFileSystemProvider, resource: []const u8) FileSystemProviderError![]DirectoryEntry {
        const service_entries = self.diskCall(DiskFileService.readDirectory, .{ resource, self.allocator }) catch |err| return mapError(err);
        defer DiskFileService.freeDirectory(self.allocator, service_entries);
        // Only replace the borrowed-name arena after the detached read has
        // returned. Its immediate consumer copies the names before yielding.
        _ = self.names_arena.reset(.retain_capacity);
        const names_allocator = self.names_arena.allocator();

        const result = try self.allocator.alloc(DirectoryEntry, service_entries.len);
        errdefer self.allocator.free(result);
        for (service_entries, 0..) |entry, index| {
            result[index] = .{
                .name = try names_allocator.dupe(u8, entry.name),
                .type = entry.type,
            };
        }
        return result;
    }

    pub fn readFile(self: *DiskFileSystemProvider, resource: []const u8) FileSystemProviderError![]u8 {
        const data = self.diskCall(DiskFileService.readFile, .{resource}) catch |err| return mapError(err);
        return data.bytes;
    }

    pub fn writeFile(self: *DiskFileSystemProvider, resource: []const u8, content: []const u8, options: IFileWriteOptions) FileSystemProviderError!void {
        const existed = self.diskCall(writeFileDetached, .{ resource, content, options }) catch |err| return mapError(err);
        self.fire(&.{.{ .type = if (existed) .UPDATED else .ADDED, .resource = resource }});
    }

    fn writeFileDetached(disk: *DiskFileService, resource: []const u8, content: []const u8, options: IFileWriteOptions) !bool {
        const exists = disk.exists(resource);
        if (!exists and !options.create) return error.FileNotFound;
        if (exists and options.create and !options.overwrite) return error.FileExists;
        if (options.append) {
            // std.Io does not yet expose append-open; write at the end.
            const file = if (options.create)
                try Io.Dir.cwd().createFile(disk.io, resource, .{ .truncate = false, .exclusive = !options.overwrite })
            else
                try Io.Dir.cwd().openFile(disk.io, resource, .{ .mode = .write_only });
            defer file.close(disk.io);
            const file_stat = try file.stat(disk.io);
            try file.writePositionalAll(disk.io, content, file_stat.size);
        } else {
            try disk.writeFile(resource, .{ .bytes = @constCast(content) });
        }
        return exists;
    }

    pub fn delete(self: *DiskFileSystemProvider, resource: []const u8, options: IFileDeleteOptions) FileSystemProviderError!void {
        self.diskCall(DiskFileService.delete, .{ resource, options.recursive }) catch |err| return mapError(err);
        self.fire(&.{.{ .type = .DELETED, .resource = resource }});
    }

    pub fn rename(self: *DiskFileSystemProvider, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        self.diskCall(renameDetached, .{ from, to, options }) catch |err| return mapError(err);
        self.fire(&.{
            .{ .type = .DELETED, .resource = from },
            .{ .type = .ADDED, .resource = to },
        });
    }

    pub fn copy(self: *DiskFileSystemProvider, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        self.diskCall(copyDetached, .{ from, to, options }) catch |err| return mapError(err);
        self.fire(&.{.{ .type = .ADDED, .resource = to }});
    }

    fn renameDetached(disk: *DiskFileService, from: []const u8, to: []const u8, options: IFileOverwriteOptions) !void {
        if (!options.overwrite and disk.exists(to)) return error.FileExists;
        try disk.rename(from, to);
    }

    fn copyDetached(disk: *DiskFileService, from: []const u8, to: []const u8, options: IFileOverwriteOptions) !void {
        if (!options.overwrite and disk.exists(to)) return error.FileExists;
        try disk.copy(from, to);
    }

    pub fn open(self: *DiskFileSystemProvider, resource: []const u8, options: IFileOpenOptions) FileSystemProviderError!u32 {
        const exists = self.files.exists(resource);
        if (!exists and !options.create) return error.FileNotFound;
        if (exists and options.create and !options.overwrite) return error.FileExists;
        if (!exists) {
            self.files.writeFile(resource, .{ .bytes = @constCast(&.{}) }) catch |err| return mapError(err);
            self.fire(&.{.{ .type = .ADDED, .resource = resource }});
        }
        const file = Io.Dir.cwd().openFile(self.io, resource, .{ .mode = .read_write }) catch |err| return mapError(err);
        const fd = self.next_fd;
        self.next_fd += 1;
        self.fds.put(fd, .{
            .file = file,
            .resource = try self.allocator.dupe(u8, resource),
            .append = options.append,
            .write = options.create or options.append,
        }) catch return error.OutOfMemory;
        return fd;
    }

    pub fn close(self: *DiskFileSystemProvider, fd: u32) FileSystemProviderError!void {
        const info = self.fds.fetchRemove(fd) orelse return error.Unavailable;
        info.value.file.close(self.io);
        if (info.value.write) self.fire(&.{.{ .type = .UPDATED, .resource = info.value.resource }});
        self.allocator.free(info.value.resource);
    }

    pub fn read(self: *DiskFileSystemProvider, fd: u32, position: usize, data: []u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const info = self.fds.get(fd) orelse return error.Unavailable;
        if (offset + length > data.len) return error.Unknown;
        const count = Io.File.readPositional(info.file, self.io, &.{data[offset .. offset + length]}, position) catch |err| return mapError(err);
        return count;
    }

    pub fn write(self: *DiskFileSystemProvider, fd: u32, position: usize, data: []const u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const info = self.fds.get(fd) orelse return error.Unavailable;
        if (offset + length > data.len) return error.Unknown;
        const write_position = if (info.append) blk: {
            const file_stat = info.file.stat(self.io) catch |err| return mapError(err);
            break :blk file_stat.size;
        } else position;
        Io.File.writePositionalAll(info.file, self.io, data[offset .. offset + length], write_position) catch |err| return mapError(err);
        return length;
    }

    pub fn watch(self: *DiskFileSystemProvider, resource: []const u8, options: IWatchOptions) FileSystemProviderError!void {
        for (self.watches.items) |entry| {
            if (std.mem.eql(u8, entry.resource, resource) and entry.recursive == options.recursive) return;
        }
        self.watches.append(.{
            .resource = self.allocator.dupe(u8, resource) catch return error.OutOfMemory,
            .recursive = options.recursive,
        }) catch return error.OutOfMemory;
    }

    pub fn unwatch(self: *DiskFileSystemProvider, resource: []const u8) void {
        var index: usize = 0;
        while (index < self.watches.items.len) : (index += 1) {
            if (std.mem.eql(u8, self.watches.items[index].resource, resource)) {
                self.allocator.free(self.watches.items[index].resource);
                _ = self.watches.orderedRemove(index);
                return;
            }
        }
    }

    /// Delivers externally observed changes (for example from
    /// `UniversalWatcher.on_change`) to this provider's listeners, filtered by
    /// the registered watch requests.
    pub fn deliverChanges(self: *DiskFileSystemProvider, changes: []const files.FileChange) void {
        if (self.watches.items.len == 0) return;
        var converted = std.array_list.Managed(IFileChange).init(self.allocator);
        defer converted.deinit();
        for (changes) |change| {
            const watched = blk: {
                for (self.watches.items) |entry| {
                    if (std.mem.eql(u8, entry.resource, change.resource) or
                        (entry.recursive and files.isParent(change.resource, entry.resource, false)))
                    {
                        break :blk true;
                    }
                }
                break :blk false;
            };
            if (watched) converted.append(.{ .type = change.type, .resource = change.resource }) catch continue;
        }
        if (converted.items.len > 0) self.fire(converted.items);
    }

    pub fn addChangeListener(self: *DiskFileSystemProvider, listener: IFileChangeListener) void {
        self.listeners.append(listener) catch {};
    }

    pub fn removeChangeListener(self: *DiskFileSystemProvider, listener: IFileChangeListener) void {
        var index: usize = 0;
        while (index < self.listeners.items.len) : (index += 1) {
            const current = self.listeners.items[index];
            if (current.context == listener.context and current.callback == listener.callback) {
                _ = self.listeners.orderedRemove(index);
                return;
            }
        }
    }

    fn fire(self: *DiskFileSystemProvider, changes: []const IFileChange) void {
        for (self.listeners.items) |listener| listener.callback(listener.context, changes);
    }

    fn mapError(err: anyerror) FileSystemProviderError {
        return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.PathAlreadyExists, error.FileExists => error.FileExists,
            error.IsDir => error.FileIsADirectory,
            error.NotDir => error.FileNotADirectory,
            error.AccessDenied => error.NoPermissions,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unknown,
        };
    }

    // --- interface adapters

    fn capabilitiesFn(context: *anyopaque) u32 {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.capabilities();
    }
    fn statFn(context: *anyopaque, resource: []const u8) FileSystemProviderError!IStat {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.stat(resource);
    }
    fn mkdirFn(context: *anyopaque, resource: []const u8) FileSystemProviderError!void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.mkdir(resource);
    }
    fn readdirFn(context: *anyopaque, resource: []const u8) FileSystemProviderError![]DirectoryEntry {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.readdir(resource);
    }
    fn deleteFn(context: *anyopaque, resource: []const u8, options: IFileDeleteOptions) FileSystemProviderError!void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.delete(resource, options);
    }
    fn renameFn(context: *anyopaque, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.rename(from, to, options);
    }
    fn readFileFn(context: *anyopaque, resource: []const u8) FileSystemProviderError![]u8 {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.readFile(resource);
    }
    fn writeFileFn(context: *anyopaque, resource: []const u8, content: []const u8, options: IFileWriteOptions) FileSystemProviderError!void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.writeFile(resource, content, options);
    }
    fn openFn(context: *anyopaque, resource: []const u8, options: IFileOpenOptions) FileSystemProviderError!u32 {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.open(resource, options);
    }
    fn closeFn(context: *anyopaque, fd: u32) FileSystemProviderError!void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.close(fd);
    }
    fn readFn(context: *anyopaque, fd: u32, position: usize, data: []u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.read(fd, position, data, offset, length);
    }
    fn writeFn(context: *anyopaque, fd: u32, position: usize, data: []const u8, offset: usize, length: usize) FileSystemProviderError!usize {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.write(fd, position, data, offset, length);
    }
    fn watchFn(context: *anyopaque, resource: []const u8, options: IWatchOptions) FileSystemProviderError!void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        return self.watch(resource, options);
    }
    fn addChangeListenerFn(context: *anyopaque, listener: IFileChangeListener) void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        self.addChangeListener(listener);
    }
    fn removeChangeListenerFn(context: *anyopaque, listener: IFileChangeListener) void {
        const self: *DiskFileSystemProvider = @ptrCast(@alignCast(context));
        self.removeChangeListener(listener);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "disk provider: reads, writes, lists, renames, copies and deletes" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var provider = DiskFileSystemProvider.init(allocator, io);
    defer provider.deinit();

    const folder = try std.fs.path.join(allocator, &.{ root, "folder" });
    defer allocator.free(folder);
    try provider.mkdir(folder);

    const file = try std.fs.path.join(allocator, &.{ folder, "file.txt" });
    defer allocator.free(file);
    try provider.writeFile(file, "hello", .{ .create = true, .overwrite = true });

    const data = try provider.readFile(file);
    defer allocator.free(data);
    try testing.expectEqualStrings("hello", data);

    try provider.writeFile(file, " world", .{ .create = true, .overwrite = true, .append = true });
    const appended = try provider.readFile(file);
    defer allocator.free(appended);
    try testing.expectEqualStrings("hello world", appended);

    const stat = try provider.stat(file);
    try testing.expect(FileType.isFile(stat.type));
    try testing.expectEqual(@as(u64, 11), stat.size);

    const entries = try provider.readdir(folder);
    defer allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("file.txt", entries[0].name);

    const renamed = try std.fs.path.join(allocator, &.{ folder, "renamed.txt" });
    defer allocator.free(renamed);
    try provider.rename(file, renamed, .{ .overwrite = false });

    const copied = try std.fs.path.join(allocator, &.{ folder, "copy.txt" });
    defer allocator.free(copied);
    try provider.copy(renamed, copied, .{ .overwrite = false });
    const copied_data = try provider.readFile(copied);
    defer allocator.free(copied_data);
    try testing.expectEqualStrings("hello world", copied_data);

    try provider.delete(folder, .{ .recursive = true });
    try testing.expectError(error.FileNotFound, provider.stat(folder));
}

test "disk provider: fd read/write" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const path = try std.fs.path.join(allocator, &.{ root_buffer[0..root_len], "fd.txt" });
    defer allocator.free(path);

    var provider = DiskFileSystemProvider.init(allocator, io);
    defer provider.deinit();

    const fd = try provider.open(path, .{ .create = true, .overwrite = false });
    _ = try provider.write(fd, 0, "abc", 0, 3);
    try provider.close(fd);

    const read_fd = try provider.open(path, .{ .create = false, .overwrite = false });
    var buffer: [8]u8 = undefined;
    const count = try provider.read(read_fd, 1, &buffer, 0, 8);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("bc", buffer[0..count]);
    try provider.close(read_fd);
}

test "disk provider: backs the provider file service" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var provider = DiskFileSystemProvider.init(allocator, io);
    defer provider.deinit();
    var service = @import("../common/fileService.zig").ProviderFileService.init(allocator);
    defer service.deinit();
    _ = try service.registerProvider("file", provider.interface());

    const folder_resource = try std.fmt.allocPrint(allocator, "file:{s}/nested/deep", .{root});
    defer allocator.free(folder_resource);
    _ = try service.createFolder(folder_resource);
    try testing.expect(service.exists(folder_resource));

    const file_resource = try std.fmt.allocPrint(allocator, "{s}/file.txt", .{folder_resource});
    defer allocator.free(file_resource);
    try service.writeFile(file_resource, "disk", .{ .create = true, .overwrite = true });
    var buffer = try service.readFile(allocator, file_resource, 0);
    defer buffer.deinit(allocator);
    try testing.expectEqualStrings("disk", buffer.bytes);
}

test "disk provider: filters delivered watcher changes by watch requests" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var provider = DiskFileSystemProvider.init(allocator, io);
    defer provider.deinit();

    const Sink = struct {
        count: usize = 0,
        resource: [256]u8 = undefined,
        resource_len: usize = 0,

        fn callback(context: *anyopaque, changes: []const IFileChange) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.resource_len = @min(changes[0].resource.len, self.resource.len);
            @memcpy(self.resource[0..self.resource_len], changes[0].resource[0..self.resource_len]);
        }
    };
    var sink = Sink{};
    provider.addChangeListener(.{ .context = &sink, .callback = Sink.callback });

    try provider.watch(root, .{ .recursive = true });
    const inside = try std.fs.path.join(allocator, &.{ root, "inside.txt" });
    defer allocator.free(inside);
    const outside = try std.fmt.allocPrint(allocator, "{s}-sibling/outside.txt", .{root});
    defer allocator.free(outside);

    provider.deliverChanges(&.{.{ .type = .UPDATED, .resource = inside }});
    try testing.expectEqual(@as(usize, 1), sink.count);
    try testing.expectEqualStrings(inside, sink.resource[0..sink.resource_len]);

    provider.deliverChanges(&.{.{ .type = .UPDATED, .resource = outside }});
    try testing.expectEqual(@as(usize, 1), sink.count);

    provider.unwatch(root);
    provider.deliverChanges(&.{.{ .type = .ADDED, .resource = inside }});
    try testing.expectEqual(@as(usize, 1), sink.count);
}

test "DiskFileSystemProvider append does not allocate or rewrite the existing contents" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "channel.log" });
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "channel.log", .data = "existing\n" });

    // The append must be independent of the size of the existing file and
    // must work without allocating a copy of it.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var provider = DiskFileSystemProvider.init(failing.allocator(), io);
    defer provider.deinit();
    try provider.writeFile(path, "new\n", .{ .create = true, .overwrite = true, .append = true });
    const actual = try tmp.dir.readFileAlloc(io, "channel.log", a, .limited(1024));
    defer a.free(actual);
    try std.testing.expectEqualStrings("existing\nnew\n", actual);
}

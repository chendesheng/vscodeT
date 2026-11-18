// Terminal port of the disk provider in
// `src/vs/platform/files/node/diskFileSystemProvider.ts`.
//
// Terminal adaptation: resources are absolute path strings, operations are
// synchronous, and the node channel/atomic-rename plumbing is not applicable.
// The provider delegates the portable disk behavior to `DiskFileService` and
// implements the `IFileSystemProvider` contract (including fd read/write and
// append) on top of `std.Io`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const files = @import("../common/files.zig");
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
    files: DiskFileService,
    fds: std.AutoHashMap(u32, Fd),
    next_fd: u32 = 0,
    listeners: std.array_list.Managed(IFileChangeListener),
    /// Names returned by the most recent `readdir`; valid until the next call.
    names_arena: std.heap.ArenaAllocator,

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
        self.names_arena.deinit();
        self.files.deinit();
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
            FileSystemProviderCapabilities.PathCaseSensitive;
    }

    pub fn stat(self: *DiskFileSystemProvider, resource: []const u8) FileSystemProviderError!IStat {
        const info = self.files.stat(resource) catch |err| return mapError(err);
        return .{
            .type = info.type,
            .size = info.size,
            .mtime = @intCast(info.mtime),
            .ctime = @intCast(info.ctime),
        };
    }

    pub fn mkdir(self: *DiskFileSystemProvider, resource: []const u8) FileSystemProviderError!void {
        self.files.createDirectory(resource) catch |err| return mapError(err);
        self.fire(&.{.{ .type = .ADDED, .resource = resource }});
    }

    pub fn readdir(self: *DiskFileSystemProvider, resource: []const u8) FileSystemProviderError![]DirectoryEntry {
        _ = self.names_arena.reset(.retain_capacity);
        const names_allocator = self.names_arena.allocator();
        const service_entries = self.files.readDirectory(resource, self.allocator) catch |err| return mapError(err);
        defer DiskFileService.freeDirectory(self.allocator, service_entries);

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
        const data = self.files.readFile(resource) catch |err| return mapError(err);
        return data.bytes;
    }

    pub fn writeFile(self: *DiskFileSystemProvider, resource: []const u8, content: []const u8, options: IFileWriteOptions) FileSystemProviderError!void {
        const exists = self.files.exists(resource);
        if (!exists and !options.create) return error.FileNotFound;
        if (exists and options.create and !options.overwrite) return error.FileExists;
        defer self.fire(&.{.{ .type = if (exists) .UPDATED else .ADDED, .resource = resource }});
        if (options.append) {
            const existing = self.files.readFile(resource) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return mapError(err),
            };
            defer if (existing) |value| {
                var buffer = value;
                buffer.deinit(self.allocator);
            };
            const old_len = if (existing) |buffer| buffer.bytes.len else 0;
            const combined = try self.allocator.alloc(u8, old_len + content.len);
            defer self.allocator.free(combined);
            if (existing) |buffer| @memcpy(combined[0..old_len], buffer.bytes);
            @memcpy(combined[old_len..], content);
            const data = @import("../../../base/common/buffer.zig").VSBuffer{ .bytes = combined };
            self.files.writeFile(resource, data) catch |err| return mapError(err);
        } else {
            const data = @import("../../../base/common/buffer.zig").VSBuffer{ .bytes = @constCast(content) };
            self.files.writeFile(resource, data) catch |err| return mapError(err);
        }
    }

    pub fn delete(self: *DiskFileSystemProvider, resource: []const u8, options: IFileDeleteOptions) FileSystemProviderError!void {
        self.files.delete(resource, options.recursive) catch |err| return mapError(err);
        self.fire(&.{.{ .type = .DELETED, .resource = resource }});
    }

    pub fn rename(self: *DiskFileSystemProvider, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        if (!options.overwrite and self.files.exists(to)) return error.FileExists;
        self.files.rename(from, to) catch |err| return mapError(err);
        self.fire(&.{
            .{ .type = .DELETED, .resource = from },
            .{ .type = .ADDED, .resource = to },
        });
    }

    pub fn copy(self: *DiskFileSystemProvider, from: []const u8, to: []const u8, options: IFileOverwriteOptions) FileSystemProviderError!void {
        if (!options.overwrite and self.files.exists(to)) return error.FileExists;
        self.files.copy(from, to) catch |err| return mapError(err);
        self.fire(&.{.{ .type = .ADDED, .resource = to }});
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

    pub fn watch(_: *DiskFileSystemProvider, _: []const u8, _: IWatchOptions) FileSystemProviderError!void {}

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
            error.PathAlreadyExists => error.FileExists,
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
    const io = std.Io.Threaded.global_single_threaded.io();
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
    const io = std.Io.Threaded.global_single_threaded.io();
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];

    var provider = DiskFileSystemProvider.init(allocator, io);
    defer provider.deinit();
    var service = @import("../common/fileService.zig").ProviderFileService.init(allocator);
    defer service.deinit();
    try service.registerProvider("file", provider.interface());

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

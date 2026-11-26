// Terminal disk-backed subset of `src/vs/platform/files/common/fileService.ts`.
// The full provider/event/etag machinery is not ported; this service exposes
// synchronous path operations used by the terminal editor/file plumbing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = @import("./files.zig");
const buffer_mod = @import("../../../base/common/buffer.zig");
const VSBuffer = buffer_mod.VSBuffer;

pub const DiskFileService = struct {
    allocator: Allocator,
    io: Io,
    onDidChange: @import("../../../base/common/event.zig").Emitter(files.FileChange),

    pub fn init(allocator: Allocator, io: Io) DiskFileService {
        return .{
            .allocator = allocator,
            .io = io,
            .onDidChange = @import("../../../base/common/event.zig").Emitter(files.FileChange).init(allocator),
        };
    }

    pub fn deinit(self: *DiskFileService) void {
        self.onDidChange.deinit();
    }

    pub fn listen(self: *DiskFileService, context: anytype, callback: fn (files.FileChange, @TypeOf(context)) anyerror!void) !usize {
        return self.onDidChange.listen(context, callback);
    }

    fn notify(self: *DiskFileService, resource: []const u8, change_type: files.FileChangeType) void {
        self.onDidChange.fire(.{ .resource = resource, .type = change_type }) catch {};
    }

    pub fn exists(self: *DiskFileService, path: []const u8) bool {
        _ = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch return false;
        return true;
    }

    pub fn existsFile(self: *DiskFileService, path: []const u8) bool {
        const info = self.stat(path) catch return false;
        return info.isFile();
    }

    pub fn existsDirectory(self: *DiskFileService, path: []const u8) bool {
        const info = self.stat(path) catch return false;
        return info.isDirectory();
    }

    pub fn stat(self: *DiskFileService, path: []const u8) !files.FileStat {
        const info = try Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });
        const type_flags: u8 = switch (info.kind) {
            .file => files.FileType.File,
            .directory => files.FileType.Directory,
            .sym_link => files.FileType.SymbolicLink,
            else => files.FileType.Unknown,
        };
        return .{
            .resource = path,
            .name = std.fs.path.basename(path),
            .type = type_flags,
            .size = info.size,
            .mtime = if (info.mtime.nanoseconds > 0) @intCast(info.mtime.nanoseconds) else 0,
            .ctime = if (info.ctime.nanoseconds > 0) @intCast(info.ctime.nanoseconds) else 0,
        };
    }

    pub fn readFile(self: *DiskFileService, path: []const u8) !VSBuffer {
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited);
        return .{ .bytes = bytes };
    }

    /// Writes a file, creating missing parent directories.
    pub fn writeFileEnsuringParents(self: *DiskFileService, path: []const u8, data: VSBuffer) !void {
        const parent = std.fs.path.dirname(path) orelse return self.writeFile(path, data);
        try self.ensureDirectory(parent);
        try self.writeFile(path, data);
    }

    fn ensureDirectory(self: *DiskFileService, path: []const u8) !void {
        if (path.len == 0 or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, ".")) return;
        if (self.exists(path)) return;
        if (std.fs.path.dirname(path)) |parent| try self.ensureDirectory(parent);
        try self.createDirectory(path);
    }

    pub fn writeFile(self: *DiskFileService, path: []const u8, data: VSBuffer) !void {
        const existed = self.exists(path);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data.bytes });
        self.notify(path, if (existed) .UPDATED else .ADDED);
    }

    pub fn deleteFile(self: *DiskFileService, path: []const u8) !void {
        try Io.Dir.cwd().deleteFile(self.io, path);
        self.notify(path, .DELETED);
    }

    pub fn rename(self: *DiskFileService, from: []const u8, to: []const u8) !void {
        try Io.Dir.renameAbsolute(from, to, self.io);
        self.notify(from, .DELETED);
        self.notify(to, .ADDED);
    }

    pub fn createDirectory(self: *DiskFileService, path: []const u8) !void {
        try Io.Dir.createDirAbsolute(self.io, path, .default_dir);
    }

    pub fn deleteDirectory(self: *DiskFileService, path: []const u8) !void {
        try Io.Dir.deleteDirAbsolute(self.io, path);
    }

    pub const DirEntry = struct {
        name: []u8,
        type: u8,
    };

    /// Lists a directory; the caller frees names and the slice with
    /// `allocator.free`/`freeDirectory`.
    pub fn readDirectory(self: *DiskFileService, path: []const u8, allocator: Allocator) ![]DirEntry {
        var dir = try Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        var entries = std.array_list.Managed(DirEntry).init(allocator);
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit();
        }
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            const type_flags: u8 = switch (entry.kind) {
                .file => files.FileType.File,
                .directory => files.FileType.Directory,
                .sym_link => files.FileType.SymbolicLink,
                else => files.FileType.Unknown,
            };
            try entries.append(.{ .name = try allocator.dupe(u8, entry.name), .type = type_flags });
        }
        return entries.toOwnedSlice();
    }

    pub fn freeDirectory(allocator: Allocator, entries: []DirEntry) void {
        for (entries) |entry| allocator.free(entry.name);
        allocator.free(entries);
    }

    /// Deletes a file, or a directory tree when `recursive` is true.
    pub fn delete(self: *DiskFileService, path: []const u8, recursive: bool) !void {
        const info = try self.stat(path);
        if (!info.isDirectory()) return self.deleteFile(path);
        if (!recursive) return self.deleteDirectory(path);
        const entries = try self.readDirectory(path, self.allocator);
        defer DiskFileService.freeDirectory(self.allocator, entries);
        for (entries) |entry| {
            const child = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            defer self.allocator.free(child);
            try self.delete(child, true);
        }
        try self.deleteDirectory(path);
    }

    pub fn copy(self: *DiskFileService, from: []const u8, to: []const u8) !void {
        const info = try self.stat(from);
        if (info.isDirectory()) {
            try self.createDirectory(to);
            const entries = try self.readDirectory(from, self.allocator);
            defer DiskFileService.freeDirectory(self.allocator, entries);
            for (entries) |entry| {
                const source_child = try std.fs.path.join(self.allocator, &.{ from, entry.name });
                defer self.allocator.free(source_child);
                const target_child = try std.fs.path.join(self.allocator, &.{ to, entry.name });
                defer self.allocator.free(target_child);
                try self.copy(source_child, target_child);
            }
            return;
        }
        var data = try self.readFile(from);
        defer data.deinit(self.allocator);
        try self.writeFile(to, data);
    }
};

test "DiskFileService reads, writes, stats and removes files" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "hello.txt" });
    defer allocator.free(path);
    const copy_path = try std.fs.path.join(allocator, &.{ root, "copy.txt" });
    defer allocator.free(copy_path);

    var service = DiskFileService.init(allocator, io);
    defer service.deinit();
    const Listener = struct {
        fn onChange(change: files.FileChange, changes: *std.array_list.Managed(files.FileChangeType)) anyerror!void {
            try changes.append(change.type);
        }
    };
    var changes = std.array_list.Managed(files.FileChangeType).init(allocator);
    defer changes.deinit();
    _ = try service.listen(&changes, Listener.onChange);
    try std.testing.expect(!service.exists(path));
    var data = try VSBuffer.fromString(allocator, "hello");
    defer data.deinit(allocator);
    try service.writeFile(path, data);
    try std.testing.expect(service.exists(path));
    try std.testing.expect(service.existsFile(path));
    try std.testing.expect(!service.existsDirectory(path));
    const stat = try service.stat(path);
    try std.testing.expect(stat.isFile());
    try std.testing.expectEqual(@as(u64, 5), stat.size);
    try std.testing.expect(stat.mtime > 0);

    var read = try service.readFile(path);
    defer read.deinit(allocator);
    const text = try read.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);

    try service.copy(path, copy_path);
    try std.testing.expect(service.exists(copy_path));
    try service.rename(copy_path, path);
    try service.deleteFile(path);
    try std.testing.expect(!service.exists(path));
    try std.testing.expect(changes.items.len >= 4);
}

test "DiskFileService lists directories" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..root_len];
    const dir = try std.fs.path.join(allocator, &.{ root, "sub" });
    defer allocator.free(dir);
    const file = try std.fs.path.join(allocator, &.{ dir, "a.txt" });
    defer allocator.free(file);

    var service = DiskFileService.init(allocator, io);
    try service.createDirectory(dir);
    var data = try VSBuffer.fromString(allocator, "a");
    defer data.deinit(allocator);
    try service.writeFile(file, data);

    const entries = try service.readDirectory(dir, allocator);
    defer DiskFileService.freeDirectory(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("a.txt", entries[0].name);
    try std.testing.expect(files.FileType.isFile(entries[0].type));

    try service.delete(dir, true);
    try std.testing.expect(!service.exists(dir));
}

test "DiskFileService reports missing files" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var service = DiskFileService.init(allocator, io);
    try std.testing.expectError(error.FileNotFound, service.stat("/definitely/not/here"));
}

test "DiskFileService copies directory trees" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source);
    const target = try std.fs.path.join(allocator, &.{ root, "target" });
    defer allocator.free(target);
    const source_file = try std.fs.path.join(allocator, &.{ source, "a.txt" });
    defer allocator.free(source_file);
    const target_file = try std.fs.path.join(allocator, &.{ target, "a.txt" });
    defer allocator.free(target_file);

    var service = DiskFileService.init(allocator, io);
    defer service.deinit();
    try service.createDirectory(source);
    var data = try VSBuffer.fromString(allocator, "tree");
    defer data.deinit(allocator);
    try service.writeFile(source_file, data);
    try service.copy(source, target);
    try std.testing.expect(service.exists(target_file));
    var copied = try service.readFile(target_file);
    defer copied.deinit(allocator);
    const text = try copied.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("tree", text);
}

test "DiskFileService creates parent directories when writing" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    const path = try std.fs.path.join(allocator, &.{ root, "a", "b", "c.txt" });
    defer allocator.free(path);
    var service = DiskFileService.init(allocator, io);
    defer service.deinit();
    var data = try VSBuffer.fromString(allocator, "nested");
    defer data.deinit(allocator);
    try service.writeFileEnsuringParents(path, data);
    try std.testing.expect(service.exists(path));
}

// ---------------------------------------------------------------------------
// Provider-backed FileService
// (port of the provider-registry subset of upstream `fileService.ts`)
// ---------------------------------------------------------------------------

pub const FileOperationEvent = struct {
    operation: files.FileOperation,
    resource: []const u8,
    target: ?files.FileStat = null,
};

/// A `FileService` that dispatches operations to registered
/// `IFileSystemProvider`s. Resources are `scheme:/path` strings (the terminal
/// substitution for `URI`); providers see the `/path` part. Operations are
/// synchronous and the service enforces the provider's `Readonly` capability.
pub const ProviderFileService = struct {
    allocator: Allocator,
    providers: std.StringHashMap(files.IFileSystemProvider),
    registrations: std.array_list.Managed(*ProviderRegistration),
    on_did_files_change: @import("../../../base/common/event.zig").Emitter(files.FileChangesEvent),
    on_did_run_operation: @import("../../../base/common/event.zig").Emitter(FileOperationEvent),

    const ProviderRegistration = struct {
        service: *ProviderFileService,
        scheme: []u8,
        provider: files.IFileSystemProvider,

        fn dispose(self: *ProviderRegistration) void {
            const service = self.service;
            _ = service.providers.remove(self.scheme);
            for (service.registrations.items, 0..) |registration, index| {
                if (registration == self) {
                    _ = service.registrations.orderedRemove(index);
                    break;
                }
            }
            self.destroy();
        }

        fn destroy(self: *ProviderRegistration) void {
            const a = self.service.allocator;
            self.provider.removeChangeListener(.{ .context = self, .callback = providerChanged });
            a.free(self.scheme);
            a.destroy(self);
        }
    };

    pub fn init(allocator: Allocator) ProviderFileService {
        return .{
            .allocator = allocator,
            .providers = std.StringHashMap(files.IFileSystemProvider).init(allocator),
            .registrations = std.array_list.Managed(*ProviderRegistration).init(allocator),
            .on_did_files_change = @import("../../../base/common/event.zig").Emitter(files.FileChangesEvent).init(allocator),
            .on_did_run_operation = @import("../../../base/common/event.zig").Emitter(FileOperationEvent).init(allocator),
        };
    }

    pub fn deinit(self: *ProviderFileService) void {
        for (self.registrations.items) |registration| registration.destroy();
        self.registrations.deinit();
        self.providers.deinit();
        self.on_did_files_change.deinit();
        self.on_did_run_operation.deinit();
    }

    pub fn registerProvider(self: *ProviderFileService, scheme: []const u8, provider: files.IFileSystemProvider) !@import("../../../base/common/lifecycle.zig").IDisposable {
        if (self.providers.contains(scheme)) return error.ProviderAlreadyRegistered;
        const registration = try self.allocator.create(ProviderRegistration);
        errdefer self.allocator.destroy(registration);
        registration.* = .{
            .service = self,
            .scheme = try self.allocator.dupe(u8, scheme),
            .provider = provider,
        };
        errdefer self.allocator.free(registration.scheme);
        try self.providers.put(registration.scheme, provider);
        errdefer _ = self.providers.remove(registration.scheme);
        try self.registrations.append(registration);
        provider.addChangeListener(.{ .context = registration, .callback = providerChanged });
        return @import("../../../base/common/lifecycle.zig").IDisposable.from(ProviderRegistration, registration, ProviderRegistration.dispose);
    }

    pub fn interface(self: *ProviderFileService) files.IFileService {
        const Adapter = struct {
            fn register(context: *anyopaque, scheme: []const u8, provider: files.IFileSystemProvider) !@import("../../../base/common/lifecycle.zig").IDisposable {
                const service: *ProviderFileService = @ptrCast(@alignCast(context));
                return service.registerProvider(scheme, provider);
            }
            fn has(context: *anyopaque, resource: std.Uri) bool {
                const service: *ProviderFileService = @ptrCast(@alignCast(context));
                return service.providers.contains(resource.scheme);
            }
            fn capture(context: *anyopaque, resource: std.Uri) !?files.FileReadRequest {
                const service: *ProviderFileService = @ptrCast(@alignCast(context));
                return service.captureRead(resource);
            }
            fn stat(context: *anyopaque, resource: std.Uri) !files.IStat {
                const service: *ProviderFileService = @ptrCast(@alignCast(context));
                return service.statUri(resource);
            }
        };
        return .{
            .context = self,
            .register_provider = Adapter.register,
            .has_provider = Adapter.has,
            .capture_read = Adapter.capture,
            .stat_uri = Adapter.stat,
            .on_did_files_change = &self.on_did_files_change,
        };
    }

    pub fn captureRead(self: *ProviderFileService, resource: std.Uri) !?files.FileReadRequest {
        const provider = self.providers.get(resource.scheme) orelse return null;
        const capture = provider.capture_read_uri orelse return null;
        return try capture(provider.context, resource);
    }

    pub fn statUri(self: *ProviderFileService, resource: std.Uri) !files.IStat {
        const provider = self.providers.get(resource.scheme) orelse return error.ProviderUnavailable;
        if (provider.stat_uri) |statFn| return statFn(provider.context, resource);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const path = try @import("../../../base/common/stdUri.zig").fsPath(resource, arena.allocator());
        return provider.getStat(path);
    }

    pub fn listenFilesChange(self: *ProviderFileService, context: anytype, callback: fn (files.FileChangesEvent, @TypeOf(context)) anyerror!void) !usize {
        return self.on_did_files_change.listen(context, callback);
    }

    pub fn listenOperation(self: *ProviderFileService, context: anytype, callback: fn (FileOperationEvent, @TypeOf(context)) anyerror!void) !usize {
        return self.on_did_run_operation.listen(context, callback);
    }

    const ParsedResource = struct { scheme: []const u8, path: []const u8 };

    /// URI-style resource paths use `/`, but Windows disk resources are
    /// native paths with `\\`. `std.fs.path.basename` reads a leading `//`
    /// as a UNC server and returns an empty name, so split on both
    /// separators and ignore empty trailing components instead.
    fn resourceBasename(path: []const u8) []const u8 {
        var end = path.len;
        while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
        var start = end;
        while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
        return path[start..end];
    }

    fn parseResource(resource: []const u8) ?ParsedResource {
        // A resource is `scheme:path`. Do not require `/` after the colon:
        // on Windows a native path is `file:C:\...`, and the disk provider
        // consumes that path unchanged.
        const separator = std.mem.indexOfScalar(u8, resource, ':') orelse return null;
        if (separator == 0) return null;
        var path = resource[separator + 1 ..];
        // URI-style resources may repeat the leading slash (`inmemory://x`).
        // Keep exactly one: Windows path helpers read `//x` as a UNC server
        // with no share and report an empty basename.
        var leading: usize = 0;
        while (leading < path.len and path[leading] == '/') leading += 1;
        if (leading > 1) path = path[leading - 1 ..];
        return .{ .scheme = resource[0..separator], .path = path };
    }

    fn providerFor(self: *ProviderFileService, resource: []const u8) ?struct { parsed: ParsedResource, provider: files.IFileSystemProvider } {
        const parsed = parseResource(resource) orelse return null;
        const provider = self.providers.get(parsed.scheme) orelse return null;
        return .{ .parsed = parsed, .provider = provider };
    }

    fn ensureWritable(provider: files.IFileSystemProvider) files.FileSystemProviderError!void {
        if (provider.getCapabilities() & files.FileSystemProviderCapabilities.Readonly != 0) return error.FileReadonly;
    }

    pub fn exists(self: *ProviderFileService, resource: []const u8) bool {
        const found = self.providerFor(resource) orelse return false;
        if (found.provider.stat_uri != null) {
            _ = self.statUri(std.Uri.parse(resource) catch return false) catch return false;
        } else {
            _ = found.provider.getStat(found.parsed.path) catch return false;
        }
        return true;
    }

    pub fn stat(self: *ProviderFileService, resource: []const u8) !files.FileStat {
        const found = self.providerFor(resource) orelse return error.ProviderUnavailable;
        const typed = if (found.provider.stat_uri != null) try std.Uri.parse(resource) else null;
        const stat_info = if (typed) |uri| try self.statUri(uri) else try found.provider.getStat(found.parsed.path);
        const path = if (typed) |uri| switch (uri.path) {
            .raw => |value| value,
            .percent_encoded => |value| value,
        } else found.parsed.path;
        return .{
            .resource = resource,
            .name = resourceBasename(path),
            .type = stat_info.type,
            .size = stat_info.size,
            .mtime = @intCast(@max(stat_info.mtime, 0)),
            .ctime = @intCast(@max(stat_info.ctime, 0)),
        };
    }

    /// Resolves a resource. Directory stats include their direct children;
    /// `resolve_to` narrows the children to the named descendant directories
    /// (which are resolved with their own children, matching upstream
    /// `resolveTo`).
    pub fn resolve(self: *ProviderFileService, allocator: Allocator, resource: []const u8, resolve_to: ?[]const []const u8) !files.FileStat {
        const found = self.providerFor(resource) orelse return error.ProviderUnavailable;
        return resolveResource(self, allocator, resource, found.provider, found.parsed.path, resolve_to);
    }

    fn resolveResource(
        self: *ProviderFileService,
        allocator: Allocator,
        resource: []const u8,
        provider: files.IFileSystemProvider,
        path: []const u8,
        resolve_to: ?[]const []const u8,
    ) !files.FileStat {
        const stat_info = try provider.getStat(path);
        var result = files.FileStat{
            .resource = try allocator.dupe(u8, resource),
            .name = try allocator.dupe(u8, resourceBasename(path)),
            .type = stat_info.type,
            .size = stat_info.size,
            .mtime = @intCast(@max(stat_info.mtime, 0)),
            .ctime = @intCast(@max(stat_info.ctime, 0)),
        };
        if (!files.FileType.isDirectory(stat_info.type)) return result;

        if (resolve_to) |targets| {
            var children = std.array_list.Managed(files.FileStat).init(allocator);
            for (targets) |target| {
                const name = resourceBasename(target);
                const child_resource = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resource, name });
                const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
                const child = try resolveResource(self, allocator, child_resource, provider, child_path, null);
                try children.append(child);
            }
            result.children = try children.toOwnedSlice();
            return result;
        }

        const entries = try provider.getDirectoryEntries(path);
        defer self.allocator.free(entries);
        var children = std.array_list.Managed(files.FileStat).init(allocator);
        for (entries) |entry| {
            const child_resource = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ resource, entry.name });
            const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
            const child = try resolveResource(self, allocator, child_resource, provider, child_path, null);
            try children.append(child);
        }
        result.children = try children.toOwnedSlice();
        return result;
    }

    pub fn freeResolved(self: *ProviderFileService, allocator: Allocator, resolved: *files.FileStat) void {
        allocator.free(resolved.resource);
        allocator.free(resolved.name);
        if (resolved.children) |children| {
            const mutable = @constCast(children);
            for (mutable) |*child| self.freeResolved(allocator, child);
            allocator.free(children);
        }
        resolved.children = null;
    }

    pub fn readFile(self: *ProviderFileService, allocator: Allocator, resource: []const u8, position: usize) !VSBuffer {
        const found = self.providerFor(resource) orelse return error.ProviderUnavailable;
        if (found.provider.capture_read_uri != null) {
            const request = (try self.captureRead(try std.Uri.parse(resource))) orelse return error.ProviderUnavailable;
            defer request.destroy(request.context);
            const result = request.read(request.context, allocator);
            if (request.complete) |publish| publish(request.context) catch |err| {
                if (result) |bytes| {
                    allocator.free(bytes);
                    return err;
                } else |_| {}
            };
            const bytes = try result;
            if (position == 0) return .{ .bytes = bytes };
            defer allocator.free(bytes);
            return .{ .bytes = try allocator.dupe(u8, bytes[@min(position, bytes.len)..]) };
        }
        const data = try found.provider.readFile(found.parsed.path);
        defer self.allocator.free(data);
        const value = if (position < data.len) data[position..] else data[data.len..];
        return .{ .bytes = try allocator.dupe(u8, value) };
    }

    pub fn writeFile(self: *ProviderFileService, resource: []const u8, content: []const u8, options: files.IFileWriteOptions) !void {
        const found = self.providerFor(resource) orelse return error.ProviderUnavailable;
        try ensureWritable(found.provider);
        try found.provider.writeFile(found.parsed.path, content, options);
        try self.fireOperation(.WRITE, resource);
    }

    pub fn createFolder(self: *ProviderFileService, resource: []const u8) !files.FileStat {
        const found = self.providerFor(resource) orelse return error.ProviderUnavailable;
        try ensureWritable(found.provider);

        var prefix = std.array_list.Managed(u8).init(self.allocator);
        defer prefix.deinit();
        if (found.parsed.path.len > 0 and found.parsed.path[0] == '/') try prefix.append('/');
        var iterator = std.mem.splitScalar(u8, found.parsed.path, '/');
        var first = true;
        while (iterator.next()) |component| {
            if (component.len == 0) continue;
            if (!first and prefix.items[prefix.items.len - 1] != '/') try prefix.append('/');
            try prefix.appendSlice(component);
            first = false;
            _ = found.provider.getStat(prefix.items) catch {
                try found.provider.makeDirectory(prefix.items);
            };
        }

        const stat_info = try self.stat(resource);
        try self.on_did_run_operation.fire(.{ .operation = .CREATE, .resource = resource, .target = stat_info });
        return stat_info;
    }

    pub fn del(self: *ProviderFileService, resource: []const u8) !void {
        const found = self.providerFor(resource) orelse return error.ProviderUnavailable;
        try ensureWritable(found.provider);
        try self.deleteRecursive(found.provider, found.parsed.path);
        try self.fireOperation(.DELETE, resource);
    }

    fn deleteRecursive(self: *ProviderFileService, provider: files.IFileSystemProvider, path: []const u8) !void {
        const stat_info = provider.getStat(path) catch return;
        if (files.FileType.isDirectory(stat_info.type)) {
            const entries = try provider.getDirectoryEntries(path);
            defer self.allocator.free(entries);
            for (entries) |entry| {
                const child = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(child);
                try self.deleteRecursive(provider, child);
            }
        }
        try provider.deleteResource(path, .{ .recursive = true });
    }

    pub fn move(self: *ProviderFileService, from: []const u8, to: []const u8, overwrite: bool) !void {
        const source = self.providerFor(from) orelse return error.ProviderUnavailable;
        const target = self.providerFor(to) orelse return error.ProviderUnavailable;
        try ensureWritable(source.provider);
        try source.provider.renameResource(source.parsed.path, target.parsed.path, .{ .overwrite = overwrite });
        try self.fireOperation(.MOVE, to);
    }

    pub fn copy(self: *ProviderFileService, from: []const u8, to: []const u8, overwrite: bool) !void {
        const source = self.providerFor(from) orelse return error.ProviderUnavailable;
        const target = self.providerFor(to) orelse return error.ProviderUnavailable;
        try ensureWritable(target.provider);
        try self.copyResource(source.provider, source.parsed.path, target.provider, target.parsed.path, overwrite);
        try self.fireOperation(.COPY, to);
    }

    fn copyResource(
        self: *ProviderFileService,
        source: files.IFileSystemProvider,
        from: []const u8,
        target: files.IFileSystemProvider,
        to: []const u8,
        overwrite: bool,
    ) !void {
        const stat_info = source.getStat(from) catch return error.FileNotFound;
        if (files.FileType.isDirectory(stat_info.type)) {
            target.makeDirectory(to) catch |err| switch (err) {
                error.FileExists => {},
                else => return err,
            };
            const entries = try source.getDirectoryEntries(from);
            defer self.allocator.free(entries);
            for (entries) |entry| {
                const child_from = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ from, entry.name });
                defer self.allocator.free(child_from);
                const child_to = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ to, entry.name });
                defer self.allocator.free(child_to);
                try self.copyResource(source, child_from, target, child_to, overwrite);
            }
            return;
        }
        const data = try source.readFile(from);
        defer self.allocator.free(data);
        try target.writeFile(to, data, .{ .create = true, .overwrite = overwrite });
    }

    fn fireOperation(self: *ProviderFileService, operation: files.FileOperation, resource: []const u8) !void {
        const target = self.stat(resource) catch null;
        var target_copy: ?files.FileStat = null;
        if (target) |value| {
            target_copy = value;
            target_copy.?.resource = resource;
            target_copy.?.name = resourceBasename(resource);
        }
        try self.on_did_run_operation.fire(.{ .operation = operation, .resource = resource, .target = target_copy });
    }

    fn providerChanged(context: *anyopaque, changes: []const files.IFileChange) void {
        const registration: *ProviderRegistration = @ptrCast(@alignCast(context));
        const service = registration.service;
        const changes_alloc = service.allocator;
        var converted = std.array_list.Managed(files.FileChange).init(changes_alloc);
        defer {
            for (converted.items) |change| changes_alloc.free(@constCast(change.resource));
            converted.deinit();
        }
        for (changes) |change| {
            const resource = if (registration.provider.change_resources_are_uris)
                changes_alloc.dupe(u8, change.resource) catch continue
            else
                std.fmt.allocPrint(changes_alloc, "{s}:{s}", .{ registration.scheme, change.resource }) catch continue;
            converted.append(.{ .type = change.type, .resource = resource }) catch {
                changes_alloc.free(resource);
                continue;
            };
        }
        var event = files.FileChangesEvent.init(changes_alloc, converted.items, false) catch return;
        defer event.deinit();
        service.on_did_files_change.fire(event) catch {};
    }
};

test "ProviderFileService parses schemes and normalizes leading URI slashes" {
    const uri = ProviderFileService.parseResource("inmemory://folder/file.txt").?;
    try std.testing.expectEqualStrings("inmemory", uri.scheme);
    try std.testing.expectEqualStrings("/folder/file.txt", uri.path);

    // A Windows disk resource keeps its native path unchanged.
    const disk = ProviderFileService.parseResource("file:C:\\temp\\file.txt").?;
    try std.testing.expectEqualStrings("file", disk.scheme);
    try std.testing.expectEqualStrings("C:\\temp\\file.txt", disk.path);

    try std.testing.expect(ProviderFileService.parseResource("no-scheme") == null);
}

test "ProviderFileService: capture full URI and retain independent read after unregister" {
    const a = std.testing.allocator;
    const MemoryProvider = @import("inMemoryFilesystemProvider.zig").InMemoryFileSystemProvider;
    const Encoded = "virtual://host/path%23name?revision=one%20two";
    const uri = try std.Uri.parse(Encoded);
    const Request = struct {
        query: []u8,
        fn capture(_: *anyopaque, resource: std.Uri) !files.FileReadRequest {
            const scratch = std.heap.page_allocator;
            var arena = std.heap.ArenaAllocator.init(scratch);
            defer arena.deinit();
            const temporary = arena.allocator();
            const uri_util = @import("../../../base/common/stdUri.zig");
            try std.testing.expectEqualStrings("host", try uri_util.authority(resource, temporary));
            try std.testing.expectEqualStrings("/path#name", try uri_util.path(resource, temporary));
            const self = try scratch.create(@This());
            errdefer scratch.destroy(self);
            self.* = .{ .query = try scratch.dupe(u8, try uri_util.query(resource, temporary)) };
            return .{ .context = self, .read = read, .destroy = destroy };
        }

        fn read(context: *anyopaque, allocator: Allocator) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return allocator.dupe(u8, self.query);
        }

        fn destroy(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.heap.page_allocator.free(self.query);
            std.heap.page_allocator.destroy(self);
        }

        fn stat(_: *anyopaque, resource: std.Uri) files.FileSystemProviderError!files.IStat {
            if (resource.query == null or resource.host == null) return error.Unknown;
            return .{ .type = files.FileType.File, .size = 16, .mtime = 1, .ctime = 0 };
        }
    };
    const ChangeSink = struct {
        received: bool = false,
        fn event(change: files.FileChangesEvent, self: *@This()) !void {
            try std.testing.expectEqual(@as(usize, 1), change.raw_updated.len);
            try std.testing.expectEqualStrings(Encoded, change.raw_updated[0]);
            self.received = true;
        }
    };
    var provider = try MemoryProvider.init(a);
    defer provider.deinit();
    var service = ProviderFileService.init(a);
    defer service.deinit();
    var api = provider.interface();
    api.capture_read_uri = Request.capture;
    api.stat_uri = Request.stat;
    api.change_resources_are_uris = true;
    const service_api = service.interface();
    const registration = try service_api.registerProvider("virtual", api);
    try std.testing.expect(service_api.hasProvider(uri));
    try std.testing.expectError(error.ProviderAlreadyRegistered, service_api.registerProvider("virtual", api));
    try std.testing.expectEqual(@as(u64, 16), (try service_api.stat(uri)).size);

    var sink: ChangeSink = .{};
    _ = try service.listenFilesChange(&sink, ChangeSink.event);
    ProviderFileService.providerChanged(service.registrations.items[0], &.{.{ .type = .UPDATED, .resource = Encoded }});
    try std.testing.expect(sink.received);
    const captured = (try service_api.captureRead(uri)).?;
    defer captured.destroy(captured.context);
    registration.dispose();
    try std.testing.expect(!service_api.hasProvider(uri));
    try std.testing.expectEqual(@as(usize, 0), service.registrations.items.len);
    const bytes = try captured.read(captured.context, a);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("revision=one two", bytes);
}

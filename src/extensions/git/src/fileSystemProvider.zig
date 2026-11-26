// Port of `vscode/extensions/git/src/fileSystemProvider.ts`.
// Git resources are registered with the shared read-only, case-sensitive
// filesystem provider registry. Native async reads capture immutable
// repository/ref state and deliver raw bytes to the text-file resolver.
// Repository subscriptions and change roots follow the Git model lifecycle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const GitResourceRead = @import("model.zig").GitResourceRead;
const files = @import("../../../vs/platform/files/common/files.zig");
const IDisposable = @import("../../../vs/base/common/lifecycle.zig").IDisposable;
const Repository = @import("repository.zig").Repository;
const dispatch = @import("../../../vs/base/common/windowDispatch.zig");
const event = @import("../../../vs/base/common/event.zig");
const IHostService = @import("../../../vs/workbench/services/host/browser/host.zig").IHostService;
const time = @import("../../../vs/base/common/timeCompat.zig");
const uri_util = @import("../../../vs/base/common/stdUri.zig");

pub const GitFileSystemProvider = struct {
    allocator: Allocator,
    model: *Model,
    io: std.Io,
    registration: ?IDisposable = null,
    listeners: std.ArrayList(files.IFileChangeListener) = .empty,
    cache: std.StringHashMapUnmanaged(CacheRow) = .empty,
    open_documents: ?OpenDocuments = null,
    repository_discovery: ?RepositoryDiscovery = null,
    mtime: i64,
    repository_bindings: std.ArrayList(*RepositoryBinding) = .empty,
    changed_roots: std.AutoHashMapUnmanaged(*Repository, void) = .empty,
    focus_listener: ?event.SignalSubscription = null,
    change_deadline: dispatch.Task = .{},
    cleanup_deadline: dispatch.Task = .{},
    focused: bool = true,
    waiting_for_focus: bool = false,

    const RepositoryBinding = struct {
        owner: *GitFileSystemProvider,
        repository: *Repository,
        repository_listener: ?event.SignalSubscription = null,
        original_listener: ?event.SignalSubscription = null,

        fn dispose(self: *RepositoryBinding) void {
            if (self.repository_listener) |listener| listener.dispose();
            if (self.original_listener) |listener| listener.dispose();
            self.owner.allocator.destroy(self);
        }

        fn changed(_: void, self: *RepositoryBinding) !void {
            try self.owner.changed_roots.put(self.owner.allocator, self.repository, {});
            self.owner.change_deadline.schedule(time.milliTimestamp() + 1100);
        }
    };

    const CacheRow = struct {
        path: []u8,
        timestamp: i64,
    };

    pub const RepositoryDiscovery = struct {
        context: *anyopaque,
        open: *const fn (*anyopaque, []const u8) anyerror!void,
    };

    /// Empty windows (and upstream agent sessions) may open a Git repository
    /// on demand. The window supplies the normal repository-open lifecycle.
    pub fn setRepositoryDiscovery(self: *GitFileSystemProvider, discovery: RepositoryDiscovery) void {
        self.repository_discovery = discovery;
    }

    fn getOrOpenRepository(self: *GitFileSystemProvider, uri: std.Uri) !void {
        const discovery = self.repository_discovery orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const params = try @import("uri.zig").fromGitUri(arena.allocator(), uri);
        const repository = if (params.submoduleOf) |parent| self.model.repositoryForRoot(parent) else self.model.getRepository(params.path);
        if (repository != null) return;
        try discovery.open(discovery.context, params.submoduleOf orelse params.path);
    }

    pub const OpenDocuments = struct {
        context: *anyopaque,
        is_open: *const fn (*anyopaque, []const u8) bool,
    };

    const three_minutes = 3 * 60 * 1000;
    const five_minutes = 5 * 60 * 1000;

    pub fn init(allocator: Allocator, model: *Model, io: std.Io) GitFileSystemProvider {
        return .{ .allocator = allocator, .model = model, .io = io, .mtime = time.milliTimestamp() };
    }

    pub fn register(self: *GitFileSystemProvider, service: files.IFileService, open_documents: OpenDocuments) !void {
        self.registration = try service.registerProvider("git", self.interface());
        self.open_documents = open_documents;
    }

    pub fn attachRepository(self: *GitFileSystemProvider, repository: *Repository, window: *dispatch.Queue, host: IHostService) !void {
        for (self.repository_bindings.items) |binding| if (binding.repository == repository) return;
        if (self.focus_listener == null) {
            self.change_deadline = .{ .queue = window, .context = self, .run = fireChanges };
            self.cleanup_deadline = .{ .queue = window, .context = self, .run = cleanup };
            self.focused = host.hasFocus();
            self.focus_listener = try host.on_did_change_focus.listenDisposable(self, onFocusChanged);
            self.cleanup_deadline.schedule(time.milliTimestamp() + five_minutes);
        }
        const binding = try self.allocator.create(RepositoryBinding);
        binding.* = .{ .owner = self, .repository = repository };
        errdefer binding.dispose();
        binding.repository_listener = try repository.on_change.listenDisposable(binding, RepositoryBinding.changed);
        binding.original_listener = try repository.on_did_change_original_resource.listenDisposable(self, onOriginalResourceChanged);
        try self.repository_bindings.append(self.allocator, binding);
    }

    pub fn detachSingleRepository(self: *GitFileSystemProvider, repository: *Repository) void {
        _ = self.changed_roots.remove(repository);
        for (self.repository_bindings.items, 0..) |binding, i| {
            if (binding.repository != repository) continue;
            _ = self.repository_bindings.orderedRemove(i);
            binding.dispose();
            return;
        }
    }

    pub fn detachRepository(self: *GitFileSystemProvider) void {
        for (self.repository_bindings.items) |binding| binding.dispose();
        self.repository_bindings.clearRetainingCapacity();
        self.changed_roots.clearRetainingCapacity();
        if (self.focus_listener) |listener| listener.dispose();
        self.focus_listener = null;
        self.change_deadline.schedule(null);
        self.cleanup_deadline.schedule(null);
        self.waiting_for_focus = false;
        self.clearCache();
    }

    pub fn deinit(self: *GitFileSystemProvider) void {
        self.detachRepository();
        if (self.registration) |registration| registration.dispose();
        self.registration = null;
        self.listeners.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.repository_bindings.deinit(self.allocator);
        self.changed_roots.deinit(self.allocator);
    }

    fn clearCache(self: *GitFileSystemProvider) void {
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.path);
        }
        self.cache.clearRetainingCapacity();
    }

    fn remember(self: *GitFileSystemProvider, resource: std.Uri, path: []const u8) !void {
        const a = self.allocator;
        const key = try uri_util.encodedResource(a, resource);
        errdefer a.free(key);
        if (self.cache.getPtr(key)) |row| {
            row.timestamp = time.milliTimestamp();
            a.free(key);
            return;
        }
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        try self.cache.put(a, key, .{ .path = owned, .timestamp = time.milliTimestamp() });
    }

    fn cleanup(context: *anyopaque, now: i64, _: bool) bool {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        defer self.cleanup_deadline.schedule(now + five_minutes);
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.allocator);
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            const row = entry.value_ptr;
            if (now - row.timestamp < three_minutes) continue;
            if (self.open_documents) |docs| if (docs.is_open(docs.context, row.path)) continue;
            expired.append(self.allocator, entry.key_ptr.*) catch return false;
        }
        for (expired.items) |key| if (self.cache.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.path);
        };
        return false;
    }

    fn onOriginalResourceChanged(resource: std.Uri, self: *GitFileSystemProvider) !void {
        if (!std.mem.eql(u8, resource.scheme, "file")) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try uri_util.fsPath(resource, a);
        const uri = @import("uri.zig");
        const ordinary = try uri.toGitUri(a, path, "~");
        const quick = try uri.toGitUriWithOptions(a, path, "", .{ .replace_file_extension = true });
        self.mtime = time.milliTimestamp();
        self.emit(&.{
            .{ .type = .UPDATED, .resource = try uri_util.encodedResource(a, ordinary) },
            .{ .type = .UPDATED, .resource = try uri_util.encodedResource(a, quick) },
        });
    }

    fn onFocusChanged(focused: bool, self: *GitFileSystemProvider) !void {
        self.focused = focused;
        if (focused and self.waiting_for_focus) self.change_deadline.post();
    }

    fn fireChanges(context: *anyopaque, _: i64, _: bool) bool {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        if (!self.focused) {
            self.waiting_for_focus = true;
            return false;
        }
        self.waiting_for_focus = false;
        defer self.changed_roots.clearRetainingCapacity();
        var changes: std.ArrayList(files.IFileChange) = .empty;
        defer changes.deinit(self.allocator);
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            var roots = self.changed_roots.keyIterator();
            const affected = while (roots.next()) |repository| {
                if (@import("util.zig").isDescendant(self.allocator, repository.*.root, entry.value_ptr.path) catch false) break true;
            } else false;
            if (!affected) continue;
            changes.append(self.allocator, .{ .type = .UPDATED, .resource = entry.key_ptr.* }) catch return false;
        }
        if (changes.items.len == 0) return false;
        self.mtime = time.milliTimestamp();
        self.emit(changes.items);
        return true;
    }

    fn emit(self: *GitFileSystemProvider, changes: []const files.IFileChange) void {
        for (self.listeners.items) |listener| listener.callback(listener.context, changes);
    }

    fn addListener(context: *anyopaque, listener: files.IFileChangeListener) void {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        self.listeners.append(self.allocator, listener) catch {};
    }

    fn removeListener(context: *anyopaque, listener: files.IFileChangeListener) void {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        for (self.listeners.items, 0..) |candidate, i| {
            if (candidate.context == listener.context and candidate.callback == listener.callback) {
                _ = self.listeners.orderedRemove(i);
                return;
            }
        }
    }

    pub fn interface(self: *GitFileSystemProvider) files.IFileSystemProvider {
        return .{
            .context = self,
            .capabilities = capabilities,
            .stat = statPath,
            .mkdir = unsupportedMutation,
            .readdir = unsupportedDirectory,
            .delete = unsupportedDelete,
            .rename = unsupportedRename,
            .read_file = readPath,
            .write_file = unsupportedWrite,
            .open = unsupportedOpen,
            .close = unsupportedClose,
            .read = unsupportedRead,
            .write = unsupportedFdWrite,
            .watch = watch,
            .add_change_listener = addListener,
            .remove_change_listener = removeListener,
            .capture_read_uri = capture,
            .stat_uri = statUri,
            .change_resources_are_uris = true,
        };
    }

    fn capabilities(_: *anyopaque) u32 {
        const c = files.FileSystemProviderCapabilities;
        return c.FileReadWrite | c.Readonly | c.PathCaseSensitive;
    }

    fn capture(context: *anyopaque, resource: std.Uri) !files.FileReadRequest {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        try self.getOrOpenRepository(resource);
        const request = try self.model.captureGitResource(self.io, resource);
        errdefer request.destroy();
        try self.remember(resource, request.path);
        return .{ .context = request, .read = read, .destroy = destroy, .display_path = request.path };
    }

    fn read(context: *anyopaque, allocator: Allocator) ![]u8 {
        const request: *GitResourceRead = @ptrCast(@alignCast(context));
        return request.read(allocator);
    }

    fn destroy(context: *anyopaque) void {
        const request: *GitResourceRead = @ptrCast(@alignCast(context));
        request.destroy();
    }

    fn statUri(context: *anyopaque, resource: std.Uri) files.FileSystemProviderError!files.IStat {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        self.getOrOpenRepository(resource) catch |err| return mapError(err);
        const request = self.model.captureGitResource(self.io, resource) catch |err| return mapError(err);
        defer request.destroy();
        const size = request.stat(self.allocator) catch |err| return mapError(err);
        return .{ .type = files.FileType.File, .size = size, .mtime = self.mtime, .ctime = 0, .permissions = files.FilePermission.Readonly };
    }

    fn statPath(context: *anyopaque, path: []const u8) files.FileSystemProviderError!files.IStat {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        const encoded = std.fmt.allocPrint(self.allocator, "git:{s}", .{path}) catch return error.OutOfMemory;
        defer self.allocator.free(encoded);
        return statUri(context, std.Uri.parse(encoded) catch return error.FileNotFound);
    }

    fn readPath(context: *anyopaque, path: []const u8) files.FileSystemProviderError![]u8 {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        const encoded = std.fmt.allocPrint(self.allocator, "git:{s}", .{path}) catch return error.OutOfMemory;
        defer self.allocator.free(encoded);
        const request = capture(context, std.Uri.parse(encoded) catch return error.FileNotFound) catch |err| return mapError(err);
        defer request.destroy(request.context);
        return request.read(request.context, self.allocator) catch |err| return mapError(err);
    }

    fn mapError(err: anyerror) files.FileSystemProviderError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound, error.NoRepository, error.OutsideRepository, error.NoGit => error.FileNotFound,
            else => error.Unavailable,
        };
    }

    fn unsupportedMutation(_: *anyopaque, _: []const u8) files.FileSystemProviderError!void {
        return error.FileReadonly;
    }
    fn unsupportedDirectory(_: *anyopaque, _: []const u8) files.FileSystemProviderError![]files.DirectoryEntry {
        return error.Unavailable;
    }
    fn unsupportedDelete(_: *anyopaque, _: []const u8, _: files.IFileDeleteOptions) files.FileSystemProviderError!void {
        return error.FileReadonly;
    }
    fn unsupportedRename(_: *anyopaque, _: []const u8, _: []const u8, _: files.IFileOverwriteOptions) files.FileSystemProviderError!void {
        return error.FileReadonly;
    }
    fn unsupportedWrite(_: *anyopaque, _: []const u8, _: []const u8, _: files.IFileWriteOptions) files.FileSystemProviderError!void {
        return error.FileReadonly;
    }
    fn unsupportedOpen(_: *anyopaque, _: []const u8, _: files.IFileOpenOptions) files.FileSystemProviderError!u32 {
        return error.Unavailable;
    }
    fn unsupportedClose(_: *anyopaque, _: u32) files.FileSystemProviderError!void {
        return error.Unavailable;
    }
    fn unsupportedRead(_: *anyopaque, _: u32, _: usize, _: []u8, _: usize, _: usize) files.FileSystemProviderError!usize {
        return error.Unavailable;
    }
    fn unsupportedFdWrite(_: *anyopaque, _: u32, _: usize, _: []const u8, _: usize, _: usize) files.FileSystemProviderError!usize {
        return error.FileReadonly;
    }
    fn watch(_: *anyopaque, _: []const u8, _: files.IWatchOptions) files.FileSystemProviderError!void {}
};

test "Git file provider cache retains fresh resources and open working documents" {
    const a = std.testing.allocator;
    var model = Model.init(a);
    var provider = GitFileSystemProvider.init(a, &model, std.testing.io);
    defer provider.deinit();
    const Now: i64 = 1_000_000;
    const Open = struct {
        fn isOpen(_: *anyopaque, path: []const u8) bool {
            return std.mem.eql(u8, path, "/repo/open.txt");
        }
    };
    provider.open_documents = .{ .context = @constCast(&{}), .is_open = Open.isOpen };
    try provider.remember(try std.Uri.parse("git:/repo/old.txt?ref=HEAD"), "/repo/old.txt");
    try provider.remember(try std.Uri.parse("git:/repo/open.txt?ref=HEAD"), "/repo/open.txt");
    try provider.remember(try std.Uri.parse("git:/repo/fresh.txt?ref=HEAD"), "/repo/fresh.txt");
    var iterator = provider.cache.valueIterator();
    while (iterator.next()) |row| {
        row.timestamp = if (std.mem.eql(u8, row.path, "/repo/fresh.txt")) Now - 1000 else Now - GitFileSystemProvider.three_minutes;
    }
    _ = GitFileSystemProvider.cleanup(&provider, Now, false);
    try std.testing.expectEqual(@as(usize, 2), provider.cache.count());
    try std.testing.expect(provider.cache.contains("git:/repo/open.txt?ref=HEAD"));
    try std.testing.expect(provider.cache.contains("git:/repo/fresh.txt?ref=HEAD"));
}

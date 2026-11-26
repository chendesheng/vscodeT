// Port of the Git URI read path of `vscode/extensions/git/src/fileSystemProvider.ts`.
// The native asynchronous file-service boundary captures immutable repository
// state on the window thread. Until ProviderFileService supports URI worker
// reads, its read-only content is registered with ITextModelService instead.
// The repository model remains the owner of ref resolution and Git IO.
const std = @import("std");
const Model = @import("model.zig").Model;
const SnapshotSource = @import("../../../vs/editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;
const resolver = @import("../../../vs/editor/common/services/resolverService.zig");
const Repository = @import("repository.zig").Repository;
const dispatch = @import("../../../vs/base/common/windowDispatch.zig");
const event = @import("../../../vs/base/common/event.zig");
const IHostService = @import("../../../vs/workbench/services/host/browser/host.zig").IHostService;
const time = @import("../../../vs/base/common/timeCompat.zig");

pub const GitFileSystemProvider = struct {
    allocator: std.mem.Allocator,
    model: *Model,
    io: std.Io,
    registration: ?resolver.ContentProviderRegistration = null,
    on_did_change: event.Emitter(resolver.ContentChange),
    repository_listener: ?event.SignalSubscription = null,
    original_listener: ?event.SignalSubscription = null,
    focus_listener: ?event.SignalSubscription = null,
    change_deadline: dispatch.Task = .{},
    focused: bool = true,
    waiting_for_focus: bool = false,

    pub fn init(allocator: std.mem.Allocator, model: *Model, io: std.Io) GitFileSystemProvider {
        return .{ .allocator = allocator, .model = model, .io = io, .on_did_change = .init(allocator) };
    }

    pub fn attachRepository(self: *GitFileSystemProvider, repository: *Repository, window: *dispatch.Queue, host: IHostService) !void {
        self.detachRepository();
        self.change_deadline = .{ .queue = window, .context = self, .run = fireChanges };
        self.focused = host.hasFocus();
        self.repository_listener = try repository.on_change.listenDisposable(self, onRepositoryChanged);
        errdefer self.detachRepository();
        self.original_listener = try repository.on_did_change_original_resource.listenDisposable(self, onOriginalResourceChanged);
        self.focus_listener = try host.on_did_change_focus.listenDisposable(self, onFocusChanged);
    }

    pub fn detachRepository(self: *GitFileSystemProvider) void {
        if (self.repository_listener) |listener| listener.dispose();
        if (self.original_listener) |listener| listener.dispose();
        if (self.focus_listener) |listener| listener.dispose();
        self.repository_listener = null;
        self.original_listener = null;
        self.focus_listener = null;
        self.change_deadline.schedule(null);
        self.waiting_for_focus = false;
    }

    fn onRepositoryChanged(_: void, self: *GitFileSystemProvider) !void {
        self.change_deadline.schedule(time.milliTimestamp() + 1100);
    }

    fn onOriginalResourceChanged(resource: std.Uri, self: *GitFileSystemProvider) !void {
        if (!std.mem.eql(u8, resource.scheme, "file")) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try @import("../../../vs/base/common/stdUri.zig").fsPath(resource, a);
        const uri = @import("uri.zig");
        const originals = [_]std.Uri{
            try uri.toGitUri(a, path, "~"),
            try uri.toGitUriWithOptions(a, path, "", .{ .replace_file_extension = true }),
        };
        try self.on_did_change.fire(.{ .resources = &originals });
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
        self.on_did_change.fire(.all) catch {};
        return true;
    }

    pub fn register(self: *GitFileSystemProvider, service: resolver.ITextModelService) !void {
        self.registration = try service.registerTextModelContentProvider("git", self.interface());
    }

    pub fn deinit(self: *GitFileSystemProvider) void {
        self.detachRepository();
        if (self.registration) |registration| registration.dispose();
        self.registration = null;
        self.on_did_change.deinit();
    }

    pub fn interface(self: *GitFileSystemProvider) resolver.ITextModelContentProvider {
        return .{ .context = self, .capture = capture, .on_did_change_content = &self.on_did_change };
    }

    fn capture(context: *anyopaque, resource: std.Uri) !?resolver.TextContentRequest {
        const self: *GitFileSystemProvider = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, resource.scheme, "git")) return null;
        const request = try std.heap.page_allocator.create(ReadRequest);
        errdefer std.heap.page_allocator.destroy(request);
        request.* = .{ .source = try self.model.resourceSnapshotSource(self.io, resource, null, null, null) };
        return .{ .context = request, .read = ReadRequest.read, .destroy = ReadRequest.destroy };
    }

    const ReadRequest = struct {
        source: SnapshotSource,

        fn read(context: *anyopaque, a: std.mem.Allocator) !resolver.TextContentRequest.Result {
            const self: *ReadRequest = @ptrCast(@alignCast(context));
            const result = try self.source.read(self.source.context, a);
            const resource = result.original_resource orelse return error.UnableToResolveResource;
            return .{ .uri = resource.uri, .path = resource.path, .text = if (result.original_available) result.original else null, .encoding = if (resource.encoding) |value| @tagName(value) else null, .failure = resource.failure };
        }

        fn destroy(context: *anyopaque) void {
            const self: *ReadRequest = @ptrCast(@alignCast(context));
            self.source.destroy(self.source.context);
            std.heap.page_allocator.destroy(self);
        }
    };
};

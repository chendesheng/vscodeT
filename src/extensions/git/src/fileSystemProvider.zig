// Port of the Git URI read path of `vscode/extensions/git/src/fileSystemProvider.ts`.
// The native asynchronous file-service boundary captures immutable repository
// state on the window thread. Until ProviderFileService supports URI worker
// reads, its read-only content is registered with ITextModelService instead.
// The repository model remains the owner of ref resolution and Git IO.
const std = @import("std");
const Model = @import("model.zig").Model;
const SnapshotSource = @import("../../../vs/editor/browser/widget/diffEditor/diffProviderFactoryService.zig").SnapshotSource;
const resolver = @import("../../../vs/editor/common/services/resolverService.zig");

pub const GitFileSystemProvider = struct {
    model: *Model,
    io: std.Io,
    registration: ?resolver.ContentProviderRegistration = null,

    pub fn init(model: *Model, io: std.Io) GitFileSystemProvider {
        return .{ .model = model, .io = io };
    }

    pub fn register(self: *GitFileSystemProvider, service: resolver.ITextModelService) !void {
        self.registration = try service.registerTextModelContentProvider("git", self.interface());
    }

    pub fn deinit(self: *GitFileSystemProvider) void {
        if (self.registration) |registration| registration.dispose();
        self.registration = null;
    }

    pub fn interface(self: *GitFileSystemProvider) resolver.ITextModelContentProvider {
        return .{ .context = self, .capture = capture };
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

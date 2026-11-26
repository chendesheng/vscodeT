// Port of `src/vs/workbench/api/browser/mainThreadDocumentContentProviders.ts`.
// The URI resolver owns published models and cancellation; this actor owns
// the extension-host registrations and asynchronous content requests.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const IDisposable = @import("../../../base/common/lifecycle.zig").IDisposable;
const std_uri = @import("../../../base/common/stdUri.zig");
const resolver = @import("../../../editor/common/services/resolverService.zig");

pub const HostProxy = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, []const u8, []const rpc.Arg, rpc.ReplyCallback) anyerror!IDisposable,
};

pub const MainThreadDocumentContentProviders = struct {
    allocator: Allocator,
    resolver_service: resolver.ITextModelService,
    proxy: HostProxy,
    providers: std.AutoHashMapUnmanaged(u32, *Provider) = .empty,

    pub fn init(allocator: Allocator, service: resolver.ITextModelService, proxy: HostProxy) MainThreadDocumentContentProviders {
        return .{ .allocator = allocator, .resolver_service = service, .proxy = proxy };
    }

    pub fn deinit(self: *MainThreadDocumentContentProviders) void {
        var iterator = self.providers.valueIterator();
        while (iterator.next()) |provider| provider.*.destroy();
        self.providers.deinit(self.allocator);
    }

    pub fn invoke(self: *MainThreadDocumentContentProviders, method: []const u8, args: []const rpc.Arg) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$onVirtualDocumentChange")) {
            const uri_value = jsonArg(args, 0) orelse return error.InvalidArguments;
            const content = jsonArg(args, 1) orelse return error.InvalidArguments;
            if (content != .string) return error.InvalidArguments;
            const encoded = try std_uri.encodedResourceFromJson(self.allocator, uri_value);
            defer self.allocator.free(encoded);
            try self.resolver_service.updateVirtualContent(try std.Uri.parse(encoded), content.string);
            return .empty;
        }
        const handle_value = jsonArg(args, 0) orelse return error.InvalidArguments;
        if (handle_value != .integer or handle_value.integer < 0 or handle_value.integer > std.math.maxInt(u32)) return error.InvalidArguments;
        const handle: u32 = @intCast(handle_value.integer);
        if (std.mem.eql(u8, method, "$registerTextContentProvider")) {
            const scheme = jsonArg(args, 1) orelse return error.InvalidArguments;
            if (scheme != .string) return error.InvalidArguments;
            try self.registerProvider(handle, scheme.string);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$unregisterTextContentProvider")) {
            if (self.providers.fetchRemove(handle)) |entry| entry.value.destroy();
            return .empty;
        }
        return .{ .err = .{ .name = "Unsupported", .message = method } };
    }

    fn registerProvider(self: *MainThreadDocumentContentProviders, handle: u32, scheme: []const u8) !void {
        if (self.providers.fetchRemove(handle)) |entry| entry.value.destroy();
        const provider = try self.allocator.create(Provider);
        errdefer self.allocator.destroy(provider);
        provider.* = .{ .owner = self, .handle = handle };
        try self.providers.ensureUnusedCapacity(self.allocator, 1);
        provider.registration = try self.resolver_service.registerTextModelContentProvider(scheme, .{ .context = provider, .request_content = Provider.requestContent });
        self.providers.putAssumeCapacity(handle, provider);
    }

    const Provider = struct {
        owner: *MainThreadDocumentContentProviders,
        handle: u32,
        registration: ?resolver.ContentProviderRegistration = null,
        requests: std.ArrayList(*Request) = .empty,

        fn requestContent(context: *anyopaque, uri: std.Uri, listener: resolver.TextContentListener) !IDisposable {
            const self: *Provider = @ptrCast(@alignCast(context));
            const a = self.owner.allocator;
            const request = try a.create(Request);
            errdefer a.destroy(request);
            request.* = .{ .provider = self, .listener = listener };
            try self.requests.append(a, request);
            errdefer _ = self.requests.pop();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            request.rpc_request = try self.owner.proxy.request(self.owner.proxy.context, "$provideTextDocumentContent", &.{
                .{ .json = .{ .integer = self.handle } },
                .{ .json = try std_uri.jsonComponents(arena.allocator(), uri) },
            }, .{ .context = request, .callback = Request.onReply });
            return IDisposable.from(Request, request, Request.cancel);
        }

        fn removeRequest(self: *Provider, request: *Request) void {
            for (self.requests.items, 0..) |value, i| {
                if (value == request) {
                    _ = self.requests.swapRemove(i);
                    return;
                }
            }
        }

        fn destroy(self: *Provider) void {
            if (self.registration) |registration| registration.dispose();
            while (self.requests.items.len != 0) {
                const request = self.requests.items[self.requests.items.len - 1];
                request.rpc_request.dispose();
                request.finish(null);
            }
            const a = self.owner.allocator;
            self.requests.deinit(a);
            a.destroy(self);
        }
    };

    const Request = struct {
        provider: *Provider,
        listener: resolver.TextContentListener,
        rpc_request: IDisposable = .none,

        fn onReply(context: *anyopaque, reply: rpc.Reply) void {
            const self: *Request = @ptrCast(@alignCast(context));
            const result: anyerror!?[]const u8 = switch (reply) {
                .json => |value| if (value == .string) value.string else null,
                .err => error.ExtensionHostProviderFailed,
                else => null,
            };
            self.finish(result);
        }

        fn finish(self: *Request, result: anyerror!?[]const u8) void {
            const listener = self.listener;
            self.provider.removeRequest(self);
            self.provider.owner.allocator.destroy(self);
            listener.complete(listener.context, result);
        }

        fn cancel(self: *Request) void {
            self.rpc_request.dispose();
            self.provider.removeRequest(self);
            self.provider.owner.allocator.destroy(self);
        }
    };
};

fn jsonArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

// Port of `src/vs/workbench/api/browser/mainThreadQuickDiff.ts`.
// Upstream promises become cancellable RPC requests on the window dispatcher;
// provider metadata and model references retain independent owner lifetimes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const lifecycle = @import("../../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;
const std_uri = @import("../../../base/common/stdUri.zig");
const converters = @import("../common/extHostTypeConverters.zig");
const quick_diff = @import("../../contrib/scm/common/quickDiff.zig");
const models = @import("../../contrib/scm/browser/quickDiffModel.zig");

pub const HostProxy = struct {
    context: *anyopaque,
    request: *const fn (*anyopaque, []const u8, []const rpc.Arg, rpc.ReplyCallback) anyerror!IDisposable,
    notify: *const fn (*anyopaque, []const u8, []const rpc.Arg) anyerror!void,
};

pub const MainThreadQuickDiff = struct {
    allocator: Allocator,
    quick_diff_service: quick_diff.IQuickDiffService,
    model_service: models.IQuickDiffModelService,
    proxy: HostProxy,
    providers: std.AutoHashMapUnmanaged(u32, *Provider) = .empty,
    informations: std.AutoHashMapUnmanaged(u32, *Information) = .empty,

    pub fn init(allocator: Allocator, service: quick_diff.IQuickDiffService, model_service: models.IQuickDiffModelService, proxy: HostProxy) MainThreadQuickDiff {
        return .{ .allocator = allocator, .quick_diff_service = service, .model_service = model_service, .proxy = proxy };
    }

    pub fn deinit(self: *MainThreadQuickDiff) void {
        var informations = self.informations.valueIterator();
        while (informations.next()) |information| information.*.destroy();
        self.informations.deinit(self.allocator);
        var providers = self.providers.valueIterator();
        while (providers.next()) |provider| provider.*.destroy();
        self.providers.deinit(self.allocator);
    }

    pub fn invoke(self: *MainThreadQuickDiff, method: []const u8, args: []const rpc.Arg) !rpc.HandlerReply {
        const handle_value = jsonArg(args, 0) orelse return error.InvalidArguments;
        if (handle_value != .integer or handle_value.integer < 0 or handle_value.integer > std.math.maxInt(u32)) return error.InvalidArguments;
        const handle: u32 = @intCast(handle_value.integer);
        if (std.mem.eql(u8, method, "$registerQuickDiffProvider")) {
            const selector = jsonArg(args, 1) orelse return error.InvalidArguments;
            const id = jsonArg(args, 2) orelse return error.InvalidArguments;
            const label = jsonArg(args, 3) orelse return error.InvalidArguments;
            if (id != .string or label != .string) return error.InvalidArguments;
            try self.registerProvider(handle, selector, id.string, label.string, jsonArg(args, 4));
            return .empty;
        }
        if (std.mem.eql(u8, method, "$unregisterQuickDiffProvider")) {
            if (self.providers.fetchRemove(handle)) |entry| entry.value.destroy();
            return .empty;
        }
        if (std.mem.eql(u8, method, "$createSourceControlDiffInformation")) {
            const uri = jsonArg(args, 1) orelse return error.InvalidArguments;
            try self.createInformation(handle, uri);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$disposeSourceControlDiffInformation")) {
            if (self.informations.fetchRemove(handle)) |entry| entry.value.destroy();
            return .empty;
        }
        return .{ .err = .{ .name = "Unsupported", .message = method } };
    }

    fn registerProvider(self: *MainThreadQuickDiff, handle: u32, selector: std.json.Value, id: []const u8, label: []const u8, root: ?std.json.Value) !void {
        if (self.providers.fetchRemove(handle)) |entry| entry.value.destroy();
        const provider = try self.allocator.create(Provider);
        errdefer self.allocator.destroy(provider);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        provider.* = .{
            .owner = self,
            .handle = handle,
            .arena = undefined,
            .base = .{
                .context = provider,
                .id = try a.dupe(u8, id),
                .label = try a.dupe(u8, label),
                .selector = try converters.parseSelector(a, selector),
                .root_uri = if (root) |value| if (value == .null) null else try std.Uri.parse(try std_uri.encodedResourceFromJson(a, value)) else null,
                .kind = .contributed,
                .request_original_fn = Provider.requestOriginal,
            },
        };
        provider.arena = arena;
        try self.providers.ensureUnusedCapacity(self.allocator, 1);
        provider.registration = try self.quick_diff_service.addQuickDiffProvider(&provider.base);
        self.providers.putAssumeCapacity(handle, provider);
    }

    const Provider = struct {
        owner: *MainThreadQuickDiff,
        handle: u32,
        arena: std.heap.ArenaAllocator,
        base: quick_diff.QuickDiffProvider,
        registration: IDisposable = .none,
        requests: std.ArrayList(*Request) = .empty,

        fn requestOriginal(context: *anyopaque, allocator: Allocator, resource: std.Uri, listener: quick_diff.OriginalListener) !quick_diff.OriginalResolution {
            const self: *Provider = @ptrCast(@alignCast(context));
            const owner = self.owner;
            const request = try owner.allocator.create(Request);
            errdefer owner.allocator.destroy(request);
            request.* = .{ .provider = self, .allocator = allocator, .listener = listener };
            try self.requests.append(owner.allocator, request);
            errdefer _ = self.requests.pop();
            var arena = std.heap.ArenaAllocator.init(owner.allocator);
            defer arena.deinit();
            request.rpc_request = try owner.proxy.request(owner.proxy.context, "$provideOriginalResource", &.{
                .{ .json = .{ .integer = self.handle } },
                .{ .json = try std_uri.jsonComponents(arena.allocator(), resource) },
            }, .{ .context = request, .callback = Request.onReply });
            return .{ .pending = IDisposable.from(Request, request, Request.cancel) };
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
            self.registration.dispose();
            // An unregistered provider settles its pending getOriginalResource
            // requests as absent. Their query slots own the metadata.
            while (self.requests.items.len != 0) {
                const request = self.requests.items[self.requests.items.len - 1];
                request.rpc_request.dispose();
                request.finish(null);
            }
            const allocator = self.owner.allocator;
            self.requests.deinit(allocator);
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    const Request = struct {
        provider: *Provider,
        allocator: Allocator,
        listener: quick_diff.OriginalListener,
        rpc_request: IDisposable = .none,

        fn onReply(context: *anyopaque, reply: rpc.Reply) void {
            const self: *Request = @ptrCast(@alignCast(context));
            const original = if (reply == .json and reply.json != .null) self.parseOriginal(reply.json) catch null else null;
            self.finish(original);
        }

        fn parseOriginal(self: *Request, value: std.json.Value) !?quick_diff.Original {
            if (value != .object) return null;
            const encoded = try std_uri.encodedResourceFromJson(self.allocator, value);
            errdefer self.allocator.free(encoded);
            _ = try std.Uri.parse(encoded);
            return .{ .resource_uri = encoded, .ref_label = try self.allocator.dupe(u8, self.provider.base.label) };
        }

        fn finish(self: *Request, original: ?quick_diff.Original) void {
            const listener = self.listener;
            self.provider.removeRequest(self);
            self.provider.owner.allocator.destroy(self);
            listener.complete(listener.context, original);
        }

        fn cancel(self: *Request) void {
            self.rpc_request.dispose();
            self.provider.removeRequest(self);
            self.provider.owner.allocator.destroy(self);
        }
    };

    fn createInformation(self: *MainThreadQuickDiff, handle: u32, uri_json: std.json.Value) !void {
        if (self.informations.fetchRemove(handle)) |entry| entry.value.destroy();
        const encoded = try std_uri.encodedResourceFromJson(self.allocator, uri_json);
        defer self.allocator.free(encoded);
        const uri = try std.Uri.parse(encoded);
        var reference = (try self.model_service.createQuickDiffModelReference(uri, .{})) orelse return;
        errdefer reference.dispose();
        const information = try self.allocator.create(Information);
        errdefer self.allocator.destroy(information);
        information.* = .{ .owner = self, .handle = handle, .reference = reference };
        information.listener = try reference.object.on_did_change.listen(information, Information.onChanged);
        errdefer reference.object.on_did_change.unlisten(information.listener.?);
        try self.informations.put(self.allocator, handle, information);
        information.send() catch {};
    }

    const Information = struct {
        owner: *MainThreadQuickDiff,
        handle: u32,
        reference: models.QuickDiffModelReference,
        listener: ?usize = null,

        fn onChanged(_: void, self: *Information) !void {
            self.send() catch {};
        }

        fn send(self: *Information) !void {
            const model = self.reference.object;
            const allocator = self.owner.allocator;
            const results = try model.getQuickDiffResults(allocator);
            defer models.QuickDiffModel.freeQuickDiffResults(allocator, results);
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var value: rpc.Arg = .undefined;
            for (results) |result| {
                if (result.provider_kind != .primary) continue;
                var changes = std.json.Array.init(a);
                for (result.changes2) |change| {
                    var range = std.json.Array.init(a);
                    for ([_]usize{ change.original.startLineNumber, change.original.endLineNumberExclusive, change.modified.startLineNumber, change.modified.endLineNumberExclusive }) |line| {
                        try range.append(.{ .integer = @intCast(line) });
                    }
                    try changes.append(.{ .array = range });
                }
                var object: std.json.ObjectMap = .empty;
                try object.put(a, "documentVersion", .{ .integer = model.changes_version_id });
                try object.put(a, "original", try std_uri.jsonComponents(a, result.original));
                try object.put(a, "modified", try std_uri.jsonComponents(a, result.modified));
                try object.put(a, "changes", .{ .array = changes });
                value = .{ .json = .{ .object = object } };
                break;
            }
            try self.owner.proxy.notify(self.owner.proxy.context, "$acceptSourceControlDiffInformation", &.{
                .{ .json = .{ .integer = self.handle } },
                value,
            });
        }

        fn destroy(self: *Information) void {
            if (self.listener) |id| self.reference.object.on_did_change.unlisten(id);
            self.reference.dispose();
            self.owner.allocator.destroy(self);
        }
    };
};

fn jsonArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

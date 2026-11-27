// Port of `src/vs/workbench/api/browser/mainThreadDocuments.ts`.
// Native model resolution completes on the window dispatcher. Opened
// documents are held by the upstream-style bounded reference collection,
// independently of any visible editor. Encoding changes and creation of
// untitled documents remain separate portions of the actor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const resolver = @import("../../../editor/common/services/resolverService.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const dispatch = @import("../../../base/common/windowDispatch.zig");
const time = @import("../../../base/common/timeCompat.zig");

pub const Host = struct {
    context: *anyopaque,
    synchronize: *const fn (*anyopaque, resolver.IResolvedTextEditorModel) anyerror!void,
    create: *const fn (context: *anyopaque, options: std.json.Value, arena: Allocator) anyerror!std.json.Value,
    save: *const fn (context: *anyopaque, uri: std.json.Value) anyerror!rpc.HandlerReply,
};

pub const MainThreadDocuments = struct {
    allocator: Allocator,
    resolver_service: resolver.ITextModelService,
    window: *dispatch.Queue,
    host: Host,
    references: BoundModelReferenceCollection,
    pending: std.ArrayList(*OpenRequest) = .empty,

    pub fn init(allocator: Allocator, resolver_service: resolver.ITextModelService, window: *dispatch.Queue, host: Host) MainThreadDocuments {
        return .{ .allocator = allocator, .resolver_service = resolver_service, .window = window, .host = host, .references = .{ .allocator = allocator, .window = window } };
    }

    pub fn deinit(self: *MainThreadDocuments) void {
        while (self.pending.pop()) |request| {
            if (request.request) |pending| pending.cancel();
            request.destroy();
        }
        self.pending.deinit(self.allocator);
        self.references.deinit();
    }

    pub fn invoke(self: *MainThreadDocuments, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$tryOpenDocument")) {
            const uri = valueArg(args, 0) orelse return error.InvalidArguments;
            return self.open(uri);
        }
        if (std.mem.eql(u8, method, "$tryCreateDocument")) {
            const options = valueArg(args, 0) orelse std.json.Value.null;
            return .{ .json = try self.host.create(self.host.context, options, arena) };
        }
        if (std.mem.eql(u8, method, "$trySaveDocument")) {
            const uri = valueArg(args, 0) orelse return error.InvalidArguments;
            return self.host.save(self.host.context, uri);
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }

    fn open(self: *MainThreadDocuments, uri: std.json.Value) !rpc.HandlerReply {
        const request = try self.allocator.create(OpenRequest);
        errdefer self.allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const resource = try std.Uri.parse(try std_uri.encodedResourceFromJson(arena.allocator(), uri));
        if (resource.scheme.len == 0 or ((try std_uri.fsPath(resource, arena.allocator())).len == 0 and resource.host == null)) return error.InvalidArguments;
        request.* = .{ .owner = self, .arena = arena, .uri = resource };
        try self.pending.append(self.allocator, request);
        return .{ .deferred = .{ .context = request, .start = OpenRequest.start } };
    }

    const OpenRequest = struct {
        owner: *MainThreadDocuments,
        arena: std.heap.ArenaAllocator,
        uri: std.Uri,
        channel: ?*rpc.RpcProtocol = null,
        id: u32 = 0,
        request: ?resolver.ModelReferenceRequest = null,

        fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
            const self: *OpenRequest = @ptrCast(@alignCast(context));
            self.channel = channel;
            self.id = id;
            self.request = self.owner.resolver_service.createModelReference(self.uri, .{ .context = self, .complete = complete }) catch |err| {
                complete(self, .{ .failure = err });
                return;
            };
        }

        fn complete(context: *anyopaque, result: resolver.ModelReferenceResult) void {
            const self: *OpenRequest = @ptrCast(@alignCast(context));
            self.request = null;
            const response: rpc.HandlerReply = self.reply(result) catch |err| blk: {
                const message = std.fmt.allocPrint(self.arena.allocator(), "cannot open {f}. Detail: {s}", .{ self.uri, @errorName(err) }) catch @errorName(err);
                break :blk .{ .err = .{ .name = "Error", .message = message } };
            };
            if (self.channel) |channel| channel.sendReply(self.id, response);
            if (std.mem.indexOfScalar(*OpenRequest, self.owner.pending.items, self)) |index| _ = self.owner.pending.swapRemove(index);
            self.destroy();
        }

        fn reply(self: *OpenRequest, result: resolver.ModelReferenceResult) !rpc.HandlerReply {
            var reference = switch (result) {
                .resolved => |value| value,
                .failure => |err| return err,
            };
            errdefer reference.dispose();
            const model = reference.object.textEditorModel;
            if (!model.shouldSynchronizeModel()) return error.ModelTooLargeForExtensionHost;
            try self.owner.host.synchronize(self.owner.host.context, reference.object);
            const canonical_uri = try std_uri.jsonComponents(self.arena.allocator(), model.uri());
            try self.owner.references.add(model.uri(), reference, model.getValueLength(null, false));
            return .{ .json = canonical_uri };
        }

        fn destroy(self: *OpenRequest) void {
            self.arena.deinit();
            self.owner.allocator.destroy(self);
        }
    };
};

/// The upstream age, total-size, and count bounds release background models
/// even when an extension never displays them in an editor.
pub const BoundModelReferenceCollection = struct {
    allocator: Allocator,
    window: *dispatch.Queue,
    length: usize = 0,
    data: std.ArrayList(*Entry) = .empty,

    max_age: i64 = 3 * 60 * 1000,
    max_length: usize = 80 * 1024 * 1024,
    max_size: usize = 50,

    const Entry = struct {
        owner: *BoundModelReferenceCollection,
        reference: resolver.ModelReference,
        resource: []u8,
        length: usize,
        timer: dispatch.Task,

        fn expire(context: *anyopaque, _: i64, _: bool) bool {
            const self: *Entry = @ptrCast(@alignCast(context));
            self.dispose();
            return true;
        }

        fn dispose(self: *Entry) void {
            const owner = self.owner;
            if (std.mem.indexOfScalar(*Entry, owner.data.items, self)) |index| _ = owner.data.orderedRemove(index);
            owner.length -= self.length;
            self.timer.schedule(null);
            self.reference.dispose();
            owner.allocator.free(self.resource);
            owner.allocator.destroy(self);
        }
    };

    pub fn deinit(self: *BoundModelReferenceCollection) void {
        while (self.data.items.len > 0) self.data.items[0].dispose();
        self.data.deinit(self.allocator);
    }

    pub fn remove(self: *BoundModelReferenceCollection, resource: std.Uri) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ignore_case = std.mem.eql(u8, resource.scheme, "file") and @import("builtin").os.tag != .linux;
        var index: usize = 0;
        while (index < self.data.items.len) {
            const entry = self.data.items[index];
            const uri = std.Uri.parse(entry.resource) catch {
                index += 1;
                continue;
            };
            if (std_uri.isEqualOrParent(uri, resource, arena.allocator(), ignore_case) catch false) {
                entry.dispose();
            } else index += 1;
        }
    }

    pub fn add(self: *BoundModelReferenceCollection, resource: std.Uri, reference: resolver.ModelReference, length: usize) !void {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        const encoded = try std_uri.encodedResource(self.allocator, resource);
        errdefer self.allocator.free(encoded);
        entry.* = .{
            .owner = self,
            .reference = reference,
            .resource = encoded,
            .length = length,
            .timer = .{ .queue = self.window, .context = entry, .run = Entry.expire },
        };
        try self.data.append(self.allocator, entry);
        self.length += length;
        entry.timer.schedule(time.milliTimestamp() + self.max_age);
        while (self.length > self.max_length) self.data.items[0].dispose();
        const extra_size = (self.max_size * 12 + 9) / 10;
        if (self.data.items.len >= extra_size) {
            var index: usize = 0;
            while (index < extra_size - self.max_size) : (index += 1) self.data.items[0].dispose();
        }
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadDocuments.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn valueArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

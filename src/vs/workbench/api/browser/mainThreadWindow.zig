// Port of `src/vs/workbench/api/browser/mainThreadWindow.ts` (terminal subset).
//
// The terminal window is always focused/active. The native host opens local
// files in the workbench and HTTP(S) links in the system browser.
// `$asExternalUri` preserves the original URI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const window_dispatch = @import("../../../base/common/windowDispatch.zig");
const protocol = @import("../common/extHost.protocol.zig");

pub const Host = struct {
    context: *anyopaque,
    open_uri: *const fn (context: *anyopaque, uri: std.json.Value) anyerror!bool,
};

pub const MainThreadWindow = struct {
    host: Host,
    allocator: Allocator = std.heap.page_allocator,
    window: ?*window_dispatch.Queue = null,
    requests: std.Io.Group = .init,

    pub fn deinit(self: *MainThreadWindow) void {
        if (self.window) |window| self.requests.cancel(window.io);
    }

    pub fn invokeAsync(self: *MainThreadWindow, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (self.window == null or self.window.?.scheduler == null or !std.mem.eql(u8, method, "$openUri"))
            return self.invoke(method, args, arena);
        const uri = valueArg(args, 0) orelse return .{ .json = .{ .bool = false } };
        const request = try self.allocator.create(OpenRequest);
        errdefer self.allocator.destroy(request);
        request.* = .{ .owner = self, .arena = .init(self.allocator), .uri = undefined };
        errdefer request.arena.deinit();
        request.uri = try rpc.cloneJsonValue(request.arena.allocator(), uri);
        return .{ .deferred = .{ .context = request, .start = OpenRequest.start } };
    }

    const OpenRequest = struct {
        owner: *MainThreadWindow,
        arena: std.heap.ArenaAllocator,
        uri: std.json.Value,

        fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
            const self: *OpenRequest = @ptrCast(@alignCast(context));
            self.owner.requests.concurrent(self.owner.window.?.io, run, .{ self, channel, id }) catch {
                channel.sendReply(id, .{ .json = .{ .bool = false } });
                self.destroy();
            };
        }

        fn run(self: *OpenRequest, channel: *rpc.RpcProtocol, id: u32) void {
            defer self.destroy();
            self.owner.window.?.io.checkCancel() catch {
                channel.sendReply(id, .{ .json = .{ .bool = false } });
                return;
            };
            const opened = self.owner.host.open_uri(self.owner.host.context, self.uri) catch false;
            channel.sendReply(id, .{ .json = .{ .bool = opened } });
        }

        fn destroy(self: *OpenRequest) void {
            const allocator = self.owner.allocator;
            self.arena.deinit();
            allocator.destroy(self);
        }
    };

    pub fn invoke(self: *MainThreadWindow, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$getInitialState")) {
            var state: std.json.ObjectMap = .empty;
            try state.put(arena, "isFocused", .{ .bool = true });
            try state.put(arena, "isActive", .{ .bool = true });
            return .{ .json = .{ .object = state } };
        }
        if (std.mem.eql(u8, method, "$openUri")) {
            const uri = valueArg(args, 0) orelse return .{ .json = .{ .bool = false } };
            return .{ .json = .{ .bool = try self.host.open_uri(self.host.context, uri) } };
        }
        if (std.mem.eql(u8, method, "$asExternalUri")) {
            const uri = valueArg(args, 0) orelse return error.InvalidArguments;
            return .{ .json = uri };
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadWindow.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn valueArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

// Port of `src/vs/workbench/api/browser/mainThreadWindow.ts` (terminal subset).
//
// The terminal window is always focused/active. `$openUri` opens local paths in
// the workbench; unhandled schemes return false. `$asExternalUri` returns the
// input URI because there is no URI opener service.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");

pub const Host = struct {
    context: *anyopaque,
    open_uri: *const fn (context: *anyopaque, uri: std.json.Value) anyerror!bool,
};

pub const MainThreadWindow = struct {
    host: Host,

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

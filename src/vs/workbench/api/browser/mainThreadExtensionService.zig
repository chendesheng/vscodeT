// Port of the terminal subset of
// `src/vs/workbench/api/browser/mainThreadExtensionService.ts`.
//
// Activation-start bookkeeping prevents removing an extension once its code
// has started. Performance marks and browser-URI translation remain no-ops/identity.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");

pub const Host = struct {
    context: *anyopaque,
    on_will_activate: *const fn (context: *anyopaque, identifier: []const u8) anyerror!void,
    on_did_activate: *const fn (context: *anyopaque) void,
    as_browser_uri: *const fn (context: *anyopaque, uri: std.json.Value) std.json.Value,
};

pub const MainThreadExtensionService = struct {
    host: Host,

    pub fn invoke(self: *MainThreadExtensionService, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        _ = arena;
        if (std.mem.eql(u8, method, "$onWillActivateExtension")) {
            const identifier = valueArg(args, 0) orelse return error.InvalidArguments;
            if (identifier != .object) return error.InvalidArguments;
            const value = identifier.object.get("value") orelse return error.InvalidArguments;
            if (value != .string) return error.InvalidArguments;
            try self.host.on_will_activate(self.host.context, value.string);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$onDidActivateExtension")) {
            self.host.on_did_activate(self.host.context);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$asBrowserUri")) {
            const uri = valueArg(args, 0) orelse return error.InvalidArguments;
            return .{ .json = self.host.as_browser_uri(self.host.context, uri) };
        }
        if (std.mem.eql(u8, method, "$getExtension")) {
            // The host resolves extension descriptions from its local registry;
            // this actor is not on that path in the terminal.
            return .empty;
        }
        if (methodKind(method) == .request) {
            return .empty;
        }
        return .empty;
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadExtensionService.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn valueArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

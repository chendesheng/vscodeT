// Port of the terminal subset of
// `src/vs/workbench/api/browser/mainThreadExtensionService.ts`.
//
// Activation-start bookkeeping prevents removing an extension once its code
// has started. Performance marks and browser-URI translation remain no-ops/identity.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const ActivationTimes = @import("../../services/extensions/common/extensions.zig").ActivationTimes;
const protocol = @import("../common/extHost.protocol.zig");

pub const Host = struct {
    context: *anyopaque,
    on_will_activate: *const fn (context: *anyopaque, identifier: []const u8) anyerror!void,
    on_did_activate: *const fn (context: *anyopaque, identifier: []const u8, times: ActivationTimes) anyerror!void,
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
            const identifier = identifierArg(args) orelse return error.InvalidArguments;
            const reason = valueArg(args, 4) orelse return error.InvalidArguments;
            if (reason != .object) return error.InvalidArguments;
            const startup = reason.object.get("startup") orelse return error.InvalidArguments;
            const activation_event = reason.object.get("activationEvent") orelse return error.InvalidArguments;
            if (startup != .bool or activation_event != .string) return error.InvalidArguments;
            try self.host.on_did_activate(self.host.context, identifier, .{
                .code_loading_time = numberArg(args, 1) orelse return error.InvalidArguments,
                .activate_call_time = numberArg(args, 2) orelse return error.InvalidArguments,
                .activate_resolved_time = numberArg(args, 3) orelse return error.InvalidArguments,
                .startup = startup.bool,
                .activation_event = activation_event.string,
            });
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

fn identifierArg(args: []const rpc.Arg) ?[]const u8 {
    const identifier = valueArg(args, 0) orelse return null;
    if (identifier != .object) return null;
    const value = identifier.object.get("value") orelse return null;
    return if (value == .string) value.string else null;
}

fn numberArg(args: []const rpc.Arg, index: usize) ?f64 {
    return switch (valueArg(args, index) orelse return null) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

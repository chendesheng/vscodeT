// Port of `src/vs/workbench/api/browser/mainThreadDocuments.ts`.
//
// Terminal adaptation: the adapter owns the single active editor mirror;
// `$tryOpenDocument` opens a path in the workbench and returns its URI,
// `$tryCreateDocument` returns an untitled URI and `$trySaveDocument` saves the
// active editor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");

pub const Host = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, uri: std.json.Value, options: std.json.Value, arena: Allocator) anyerror!std.json.Value,
    create: *const fn (context: *anyopaque, options: std.json.Value, arena: Allocator) anyerror!std.json.Value,
    save: *const fn (context: *anyopaque, uri: std.json.Value) anyerror!rpc.HandlerReply,
};

pub const MainThreadDocuments = struct {
    host: Host,

    pub fn invoke(self: *MainThreadDocuments, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$tryOpenDocument")) {
            const uri = valueArg(args, 0) orelse return error.InvalidArguments;
            const options = valueArg(args, 1) orelse std.json.Value.null;
            return .{ .json = try self.host.open(self.host.context, uri, options, arena) };
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

// Session-only secret storage for the native host. Values are scoped to an
// extension and are never serialized to profile files or ordinary settings.
const std = @import("std");
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");
const protocol = @import("../common/extHost.protocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig").identifierFromEnum;
const A = std.mem.Allocator;

const Entry = struct {
    extension: []u8,
    key: []u8,
    value: []u8,

    fn free(self: Entry, a: A) void {
        a.free(self.extension);
        a.free(self.key);
        erase(a, self.value);
    }
};
fn erase(a: A, value: []u8) void {
    @memset(@as([]volatile u8, value), 0);
    a.free(value);
}

pub const SecretState = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *SecretState, a: A) void {
        for (self.entries.items) |entry| entry.free(a);
        self.entries.deinit(a);
    }

    pub fn invoke(self: *SecretState, a: A, host: *manager.HostManager, method: []const u8, args: []const rpc.Arg, arena: A) !rpc.HandlerReply {
        const ext = string(args, 0) orelse return error.InvalidArguments;
        if (std.mem.eql(u8, method, "$getKeys")) {
            var keys = std.json.Array.init(arena);
            for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.extension, ext)) try keys.append(.{ .string = entry.key });
            }
            return .{ .json = .{ .array = keys } };
        }
        const key = string(args, 1) orelse return error.InvalidArguments;
        const idx: ?usize = for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.extension, ext) and std.mem.eql(u8, entry.key, key)) break i;
        } else null;
        if (std.mem.eql(u8, method, "$getPassword")) {
            return if (idx) |i| .{ .json = .{ .string = self.entries.items[i].value } } else .empty;
        }
        if (std.mem.eql(u8, method, "$setPassword")) {
            const value = string(args, 2) orelse return error.InvalidArguments;
            const copy = try a.dupe(u8, value);
            errdefer erase(a, copy);
            if (idx) |i| {
                erase(a, self.entries.items[i].value);
                self.entries.items[i].value = copy;
            } else {
                const owner = try a.dupe(u8, ext);
                errdefer a.free(owner);
                const name = try a.dupe(u8, key);
                errdefer a.free(name);
                try self.entries.append(a, .{ .extension = owner, .key = name, .value = copy });
            }
        } else if (std.mem.eql(u8, method, "$deletePassword")) {
            if (idx) |i| self.entries.swapRemove(i).free(a) else return .empty;
        } else return error.UnsupportedSecretStateOperation;
        var event: std.json.ObjectMap = .empty;
        try event.put(arena, "extensionId", .{ .string = ext });
        try event.put(arena, "key", .{ .string = key });
        try host.notify(proxy(protocol.ExtHostContext.ExtHostSecretState), "$onDidChangePassword", &.{.{ .json = .{ .object = event } }});
        return .empty;
    }

    fn string(args: []const rpc.Arg, i: usize) ?[]const u8 {
        if (i >= args.len or args[i] != .json or args[i].json != .string) return null;
        return args[i].json.string;
    }
};

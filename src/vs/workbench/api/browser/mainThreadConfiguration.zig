// Port of `src/vs/workbench/api/browser/mainThreadConfiguration.ts`.
//
// Terminal adaptation: the workbench configuration service is read-only, so
// extension writes are kept in a session-memory overlay (upstream's
// `ConfigurationTarget.MEMORY` path) and pushed to the host as a
// `$acceptConfigurationChanged` delta. The base scope data comes from the
// ported configuration service; only the changed key is reported.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const configuration = @import("../../../platform/configuration/common/configuration.zig");

pub const DataHost = struct {
    context: *anyopaque,
    data: *const fn (context: *anyopaque, arena: Allocator) anyerror!std.json.Value,
};

pub const NotifyHost = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, arena: Allocator, data: std.json.Value, changed_key: []const u8) anyerror!void,
};

pub const MainThreadConfiguration = struct {
    allocator: Allocator,
    data_host: DataHost,
    notify_host: NotifyHost,
    /// `ConfigurationTarget.MEMORY` overlay, stored as raw JSON text.
    memory: std.StringHashMap([]u8),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, data_host: DataHost, notify_host: NotifyHost) MainThreadConfiguration {
        return .{
            .allocator = allocator,
            .data_host = data_host,
            .notify_host = notify_host,
            .memory = std.StringHashMap([]u8).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadConfiguration) void {
        var iterator = self.memory.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.memory.deinit();
        self.arena.deinit();
    }

    pub fn invoke(
        self: *MainThreadConfiguration,
        method: []const u8,
        args: []const rpc.Arg,
        arena: Allocator,
    ) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$updateConfigurationOption")) {
            const key = stringArg(args, 1) orelse return error.InvalidArguments;
            const value = valueArg(args, 2) orelse return error.InvalidArguments;
            try self.setValue(key, value);
            try self.push(arena, key);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$removeConfigurationOption")) {
            const key = stringArg(args, 1) orelse return error.InvalidArguments;
            if (self.memory.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value);
            }
            try self.push(arena, key);
            return .empty;
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }

    fn setValue(self: *MainThreadConfiguration, key: []const u8, value: std.json.Value) !void {
        _ = self.arena.reset(.retain_capacity);
        var output: std.Io.Writer.Allocating = .init(self.arena.allocator());
        try std.json.Stringify.value(value, .{}, &output.writer);
        const text = try self.allocator.dupe(u8, output.written());
        errdefer self.allocator.free(text);
        if (self.memory.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = text;
            return;
        }
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.memory.put(owned_key, text);
    }

    fn push(self: *MainThreadConfiguration, arena: Allocator, changed_key: []const u8) !void {
        var data = try self.data_host.data(self.data_host.context, arena);
        try overlayMemory(arena, &data, &self.memory);
        try self.notify_host.notify(self.notify_host.context, arena, data, changed_key);
    }
};

fn overlayMemory(arena: Allocator, data: *std.json.Value, memory: *const std.StringHashMap([]u8)) !void {
    if (data.* != .object or memory.count() == 0) return;
    const user_local = data.object.getPtr("userLocal") orelse return;
    if (user_local.* != .object) return;
    const contents = user_local.object.getPtr("contents") orelse return;
    if (contents.* != .object) return;
    const keys_ptr = user_local.object.getPtr("keys") orelse return;
    if (keys_ptr.* != .array) return;

    var iterator = memory.iterator();
    while (iterator.next()) |entry| {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, entry.value_ptr.*, .{}) catch continue;
        try configuration.addToValueTree(arena, contents, entry.key_ptr.*, value);
        var present = false;
        for (keys_ptr.array.items) |existing| {
            if (existing == .string and std.mem.eql(u8, existing.string, entry.key_ptr.*)) {
                present = true;
                break;
            }
        }
        if (!present) try keys_ptr.array.append(.{ .string = try arena.dupe(u8, entry.key_ptr.*) });
    }
}

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadConfiguration.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn stringArg(args: []const rpc.Arg, index: usize) ?[]const u8 {
    if (index >= args.len or args[index] != .json or args[index].json != .string) return null;
    return args[index].json.string;
}

fn valueArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

test "MainThreadConfiguration: memory updates overlay userLocal data" {
    const allocator = std.testing.allocator;
    const Fake = struct {
        var last_key: []const u8 = "";
        fn data(_: *anyopaque, arena: Allocator) anyerror!std.json.Value {
            var user_local: std.json.ObjectMap = .empty;
            try user_local.put(arena, "contents", .{ .object = .empty });
            try user_local.put(arena, "keys", .{ .array = std.json.Array.init(arena) });
            try user_local.put(arena, "overrides", .{ .array = std.json.Array.init(arena) });
            var root: std.json.ObjectMap = .empty;
            try root.put(arena, "defaults", .{ .object = .empty });
            try root.put(arena, "userLocal", .{ .object = user_local });
            return .{ .object = root };
        }
        fn notify(_: *anyopaque, _: Allocator, payload: std.json.Value, key: []const u8) anyerror!void {
            last_key = key;
            const user_local = payload.object.get("userLocal").?;
            const contents = user_local.object.get("contents").?;
            try std.testing.expect(configuration.getConfigurationValue(&contents, "js/ts.format.enabled") != null);
        }
    };
    var actor = MainThreadConfiguration.init(allocator, .{ .context = undefined, .data = Fake.data }, .{ .context = undefined, .notify = Fake.notify });
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var args = [_]rpc.Arg{
        .{ .json = .{ .integer = 1 } },
        .{ .json = .{ .string = "js/ts.format.enabled" } },
        .{ .json = .{ .bool = false } },
        .{ .json = .null },
        .{ .json = .null },
    };
    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$updateConfigurationOption", &args, arena.allocator()));
    try std.testing.expectEqualStrings("js/ts.format.enabled", Fake.last_key);
}

// Port of `src/vs/workbench/api/browser/mainThreadCommands.ts`.
//
// Terminal adaptation: extension commands are registered with the host's
// `ExtHostCommands` actor already; this actor tracks the registered ids for
// activation, reports them from `$getCommands`, fires `onCommand:` activation
// and forwards `$executeCommand` to the terminal command dispatcher. Reviving
// marshalled arguments is a no-op in the terminal JSON path.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const manager = @import("../../services/extensions/common/extensionHostManager.zig");

pub const CommandHost = struct {
    context: *anyopaque,
    /// Executes a terminal/workbench command. Returns null for a void command.
    execute: *const fn (
        context: *anyopaque,
        id: []const u8,
        args: std.json.Value,
        arena: Allocator,
    ) anyerror!?std.json.Value,
};

pub const MainThreadCommands = struct {
    allocator: Allocator,
    host: *manager.HostManager,
    command_host: CommandHost,
    registrations: std.StringHashMap(void),

    pub fn init(
        allocator: Allocator,
        host: *manager.HostManager,
        command_host: CommandHost,
    ) !MainThreadCommands {
        return .{
            .allocator = allocator,
            .host = host,
            .command_host = command_host,
            .registrations = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadCommands) void {
        var iterator = self.registrations.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.registrations.deinit();
    }

    pub fn invoke(
        self: *MainThreadCommands,
        method: []const u8,
        args: []const rpc.Arg,
        arena: Allocator,
    ) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$registerCommand")) {
            const id = stringArg(args, 0) orelse return error.InvalidArguments;
            if (!self.registrations.contains(id)) {
                try self.registrations.put(try self.allocator.dupe(u8, id), {});
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$unregisterCommand")) {
            const id = stringArg(args, 0) orelse return error.InvalidArguments;
            if (self.registrations.fetchRemove(id)) |entry| self.allocator.free(entry.key);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$fireCommandActivationEvent")) {
            const id = stringArg(args, 0) orelse return error.InvalidArguments;
            var buffer: [256]u8 = undefined;
            const event = std.fmt.bufPrint(&buffer, "onCommand:{s}", .{id}) catch return error.InvalidArguments;
            try self.activate(event);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$executeCommand")) {
            const id = stringArg(args, 0) orelse return error.InvalidArguments;
            const command_args = if (args.len > 1 and args[1] == .json) args[1].json else std.json.Value{ .array = std.json.Array.init(arena) };
            const result = self.command_host.execute(self.command_host.context, id, command_args, arena) catch return error.RequestFailed;
            if (result) |value| return .{ .json = value };
            return .empty;
        }
        if (std.mem.eql(u8, method, "$getCommands")) {
            var list = std.json.Array.init(arena);
            var iterator = self.registrations.keyIterator();
            while (iterator.next()) |key| try list.append(.{ .string = try arena.dupe(u8, key.*) });
            return .{ .json = .{ .array = list } };
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }

    fn activate(self: *MainThreadCommands, event: []const u8) !void {
        try self.host.activateByEvent(event, 0);
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadCommands.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn stringArg(args: []const rpc.Arg, index: usize) ?[]const u8 {
    if (index >= args.len or args[index] != .json or args[index].json != .string) return null;
    return args[index].json.string;
}

test "MainThreadCommands: tracks registrations and dispatches" {
    const allocator = std.testing.allocator;
    // The test never sends a request, so a null host is enough.
    const Fake = struct {
        fn execute(_: *anyopaque, id: []const u8, args: std.json.Value, _: Allocator) anyerror!?std.json.Value {
            _ = args;
            if (std.mem.eql(u8, id, "echo")) return .{ .string = "echo" };
            return null;
        }
    };
    var actor = MainThreadCommands{
        .allocator = allocator,
        .host = undefined,
        .command_host = .{ .context = undefined, .execute = Fake.execute },
        .registrations = std.StringHashMap(void).init(allocator),
    };
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var register = [_]rpc.Arg{.{ .json = .{ .string = "echo" } }};
    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$registerCommand", &register, arena.allocator()));
    const commands = try actor.invoke("$getCommands", &.{}, arena.allocator());
    try std.testing.expect(commands == .json);
    try std.testing.expectEqual(@as(usize, 1), commands.json.array.items.len);

    var execute_args = [_]rpc.Arg{
        .{ .json = .{ .string = "echo" } },
        .{ .json = .{ .array = std.json.Array.init(arena.allocator()) } },
    };
    const reply = try actor.invoke("$executeCommand", &execute_args, arena.allocator());
    try std.testing.expect(reply == .json);
    try std.testing.expectEqualStrings("echo", reply.json.string);

    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$unregisterCommand", &register, arena.allocator()));
}

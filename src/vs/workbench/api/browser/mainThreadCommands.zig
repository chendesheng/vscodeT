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

const CommandRegistry = @import("../../browser/commands.zig").CommandRegistry;

const ContributedCommand = struct {
    host: *manager.HostManager,
    id: []const u8,

    fn run(context: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.host.executeContributedCommand(self.id, &.{});
    }
};

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
    registry: *CommandRegistry,
    extensions: []const manager.ExtensionDescription,
    registrations: std.StringHashMap(?*ContributedCommand),

    pub fn init(
        allocator: Allocator,
        host: *manager.HostManager,
        command_host: CommandHost,
        registry: *CommandRegistry,
        extensions: []const manager.ExtensionDescription,
    ) !MainThreadCommands {
        return .{
            .allocator = allocator,
            .host = host,
            .command_host = command_host,
            .registry = registry,
            .extensions = extensions,
            .registrations = .init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadCommands) void {
        var iterator = self.registrations.iterator();
        while (iterator.next()) |entry| {
            self.disposeCommand(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.registrations.deinit();
    }

    fn disposeCommand(self: *MainThreadCommands, value: ?*ContributedCommand) void {
        const cmd = value orelse return;
        if (self.registry.get(cmd.id)) |info| {
            if (info.context == @as(*anyopaque, @ptrCast(cmd))) self.registry.unregister(cmd.id);
        }
        self.allocator.destroy(cmd);
    }

    fn registerContributed(self: *MainThreadCommands, id: []const u8) !?*ContributedCommand {
        if (self.registry.get(id) != null) return null;
        for (self.extensions) |extension| {
            const points = extension.manifest.object.get("contributes") orelse continue;
            if (points != .object) continue;
            const commands = points.object.get("commands") orelse continue;
            if (commands != .array) continue;
            for (commands.array.items) |item| {
                if (item != .object) continue;
                const command = item.object.get("command") orelse continue;
                if (command != .string or !std.mem.eql(u8, command.string, id)) continue;
                const title = item.object.get("title") orelse continue;
                if (title != .string) continue;
                const binding = try self.allocator.create(ContributedCommand);
                errdefer self.allocator.destroy(binding);
                binding.* = .{ .host = self.host, .id = id };
                const category = item.object.get("category");
                // Conditional menu items remain callable from other extensions.
                // The picker can expose them once it evaluates their when clause.
                const visible = !item.object.contains("enablement") and !hasPaletteCondition(points.object, id);
                errdefer self.registry.unregister(id);
                try self.registry.register(.{ .id = id, .label = title.string, .category = if (category != null and category.? == .string) category.?.string else "", .context = binding, .run = ContributedCommand.run, .show_in_palette = visible });
                return binding;
            }
        }
        return null;
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
                const owned = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(owned);
                try self.registrations.ensureUnusedCapacity(1);
                self.registrations.putAssumeCapacity(owned, try self.registerContributed(owned));
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$unregisterCommand")) {
            const id = stringArg(args, 0) orelse return error.InvalidArguments;
            if (self.registrations.fetchRemove(id)) |entry| {
                self.disposeCommand(entry.value);
                self.allocator.free(entry.key);
            }
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
    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();
    var description = try manager.readExtensionDescription(allocator, "host/test-fixtures/language-features");
    defer description.deinit(allocator);
    var actor = try MainThreadCommands.init(allocator, undefined, .{ .context = undefined, .execute = Fake.execute }, &registry, &.{description});
    defer actor.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var register = [_]rpc.Arg{.{ .json = .{ .string = "echo" } }};
    try std.testing.expectEqual(rpc.HandlerReply.empty, try actor.invoke("$registerCommand", &register, arena.allocator()));
    try std.testing.expectEqualStrings("Fixture Echo", registry.get("echo").?.label);
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
    try std.testing.expect(registry.get("echo") == null);
}

fn hasPaletteCondition(points: std.json.ObjectMap, id: []const u8) bool {
    const menus = points.get("menus") orelse return false;
    if (menus != .object) return false;
    const palette = menus.object.get("commandPalette") orelse return false;
    if (palette != .array) return false;
    for (palette.array.items) |entry| {
        if (entry != .object or !entry.object.contains("when")) continue;
        const command = entry.object.get("command") orelse continue;
        if (command == .string and std.mem.eql(u8, command.string, id)) return true;
    }
    return false;
}

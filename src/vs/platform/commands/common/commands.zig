// Port of the portable registry subset of
// `src/vs/platform/commands/common/commands.ts`.
//
// Upstream separates registration (`CommandsRegistry`) from the service
// wrapper (`ICommandService`) and carries aliases, accessor-based injection
// and disposable registrations. The TUI has no service container, so a
// command is a value with an explicit context pointer and run callback, and
// registration lasts for the lifetime of the registry.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A synchronously borrowed command argument, corresponding to the upstream
/// variadic JS command arguments. The terminal passes a typed object without
/// JSON serialization; handlers validate its type before reading it.
pub const CommandArgument = struct {
    type_name: []const u8,
    value: *const anyopaque,

    pub fn from(comptime T: type, value: *const T) CommandArgument {
        return .{ .type_name = @typeName(T), .value = value };
    }

    pub fn as(self: CommandArgument, comptime T: type) ?*const T {
        if (!std.mem.eql(u8, self.type_name, @typeName(T))) return null;
        return @ptrCast(@alignCast(self.value));
    }
};

pub const Command = struct {
    id: []const u8,
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,
    run_with_argument: ?*const fn (context: *anyopaque, argument: CommandArgument) anyerror!void = null,

    pub fn execute(self: Command) !void {
        return self.run(self.context);
    }

    pub fn executeWithArgument(self: Command, argument: CommandArgument) !void {
        if (self.run_with_argument) |handler| return handler(self.context, argument);
        return self.execute();
    }
};

pub const CommandRegistry = struct {
    allocator: Allocator,
    commands: std.array_list.Managed(Command),

    pub fn init(allocator: Allocator) CommandRegistry {
        return .{
            .allocator = allocator,
            .commands = std.array_list.Managed(Command).init(allocator),
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.commands.deinit();
    }

    pub fn register(self: *CommandRegistry, command: Command) !void {
        for (self.commands.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing.id, command.id)) {
                self.commands.items[index] = command;
                return;
            }
        }
        try self.commands.append(command);
    }

    pub fn get(self: *const CommandRegistry, id: []const u8) ?Command {
        for (self.commands.items) |command| {
            if (std.mem.eql(u8, command.id, id)) return command;
        }
        return null;
    }

    /// Removes a command registration. Used by built-in extension disposal;
    /// command ids are unique, so a single match is removed.
    pub fn unregister(self: *CommandRegistry, id: []const u8) void {
        for (self.commands.items, 0..) |command, index| {
            if (std.mem.eql(u8, command.id, id)) {
                _ = self.commands.orderedRemove(index);
                return;
            }
        }
    }

    /// Runs the command with `id`; returns false when it is not registered.
    pub fn execute(self: *const CommandRegistry, id: []const u8) !bool {
        const command = self.get(id) orelse return false;
        try command.execute();
        return true;
    }
    pub fn executeWithArgument(self: *const CommandRegistry, id: []const u8, argument: CommandArgument) !bool {
        const command = self.get(id) orelse return false;
        try command.executeWithArgument(argument);
        return true;
    }
};

test "commands: register, replace and execute" {
    const State = struct {
        hits: usize = 0,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hits += 1;
        }
    };

    var state = State{};
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{ .id = "test.run", .context = &state, .run = State.run });
    try std.testing.expect(try registry.execute("test.run"));
    try std.testing.expectEqual(@as(usize, 1), state.hits);

    // Registering the same id replaces the handler instead of duplicating it.
    try registry.register(.{ .id = "test.run", .context = &state, .run = State.run });
    try std.testing.expectEqual(@as(usize, 1), registry.commands.items.len);
    try std.testing.expect(try registry.execute("test.run"));
    try std.testing.expectEqual(@as(usize, 2), state.hits);

    try std.testing.expect(!try registry.execute("test.missing"));
}

test "commands: forwards borrowed typed argument to registered handler" {
    const State = struct {
        result: u32 = 0,
        fn run(_: *anyopaque) !void {}
        fn runWithArgument(context: *anyopaque, argument: CommandArgument) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.result = (argument.as(u32) orelse return error.InvalidArgument).*;
        }
    };
    var state: State = .{};
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{ .id = "test.context", .context = &state, .run = State.run, .run_with_argument = State.runWithArgument });
    const value: u32 = 42;
    try std.testing.expect(try registry.executeWithArgument("test.context", .from(u32, &value)));
    try std.testing.expectEqual(value, state.result);
    const wrong: u8 = 1;
    try std.testing.expectError(error.InvalidArgument, registry.executeWithArgument("test.context", .from(u8, &wrong)));
}

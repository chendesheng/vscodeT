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

pub const Command = struct {
    id: []const u8,
    context: *anyopaque,
    run: *const fn (context: *anyopaque) anyerror!void,

    pub fn execute(self: Command) !void {
        return self.run(self.context);
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

    /// Runs the command with `id`; returns false when it is not registered.
    pub fn execute(self: *const CommandRegistry, id: []const u8) !bool {
        const command = self.get(id) orelse return false;
        try command.execute();
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

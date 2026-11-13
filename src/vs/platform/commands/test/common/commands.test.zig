// Ported cases from `src/vs/platform/commands/test/common/commands.test.ts`
// for the portable TUI registry subset.

const std = @import("std");
const commands = @import("../../common/commands.zig");

test "commands: registers, runs and reports missing commands" {
    const State = struct {
        value: usize = 0,
        fn run(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.value += 1;
        }
    };

    var state = State{};
    var registry = commands.CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{ .id = "test.first", .context = &state, .run = State.run });
    try registry.register(.{ .id = "test.second", .context = &state, .run = State.run });

    try std.testing.expect(registry.get("test.first") != null);
    try std.testing.expect(try registry.execute("test.first"));
    try std.testing.expect(try registry.execute("test.second"));
    try std.testing.expectEqual(@as(usize, 2), state.value);
    try std.testing.expect(!try registry.execute("test.missing"));
}

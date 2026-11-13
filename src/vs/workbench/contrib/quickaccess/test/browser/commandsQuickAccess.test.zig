// Adapted command-picker cases for the TUI command provider: filtering,
// duplicate labels, recently-used ordering and accept execution.

const std = @import("std");
const cancellation = @import("../../../../../base/common/cancellation.zig");
const platform = @import("../../../../../platform/quickinput/browser/commandsQuickAccess.zig");
const provider_mod = @import("../../browser/commandsQuickAccess.zig");
const QuickPick = @import("../../../../../platform/quickinput/browser/quickInput.zig").QuickPick;

const State = struct {
    picks: [3]platform.CommandPick = .{
        .{ .command_id = "workbench.action.files.save", .label = "Save", .category = "File" },
        .{ .command_id = "actions.find", .label = "Find" },
        .{ .command_id = "actions.find", .label = "Find" },
    },
    executed: [64]u8 = std.mem.zeroes([64]u8),
    executed_len: usize = 0,
    executions: usize = 0,

    fn getPicks(context: *anyopaque, _: std.mem.Allocator) anyerror![]platform.CommandPick {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.picks[0..];
    }

    fn execute(context: *anyopaque, command_id: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const len = @min(command_id.len, self.executed.len);
        @memcpy(self.executed[0..len], command_id[0..len]);
        self.executed_len = len;
        self.executions += 1;
    }

    fn report(_: *anyopaque, _: []const u8) void {}
};

test "commandsQuickAccess: filter, duplicate labels, recent separator and execute" {
    var state = State{};
    const provider = try provider_mod.CommandsQuickAccessProvider.init(
        std.testing.allocator,
        .{ .context = &state, .get_picks = State.getPicks },
        .{ .context = &state, .execute = State.execute, .on_error = State.report },
    );
    defer {
        if (provider.interface().dispose) |dispose| dispose(provider);
    }

    var picker = QuickPick.init(std.testing.allocator);
    defer picker.deinit();
    var source = try cancellation.CancellationTokenSource.init(std.testing.allocator);
    defer source.deinit();
    const token = try source.token();
    const interface = provider.interface();

    picker.show();
    try interface.provide(interface.context, &picker, token);
    try std.testing.expect(picker.items.items.len >= 2);
    var saw_save = false;
    for (picker.items.items) |item| {
        switch (item) {
            .item => |entry| {
                if (std.mem.eql(u8, entry.label, "File: Save")) saw_save = true;
                if (std.mem.eql(u8, entry.label, "Find")) {
                    // Duplicate labels are disambiguated with the command id.
                    try std.testing.expectEqualStrings("actions.find", entry.description);
                }
            },
            .separator => {},
        }
    }
    try std.testing.expect(saw_save);

    try picker.setValue(">find");
    try interface.refresh(interface.context, &picker);
    try std.testing.expectEqualStrings("Find", picker.activeItem().?.label);

    picker.accept();
    try interface.accept(interface.context, &picker);
    try std.testing.expectEqual(@as(usize, 1), state.executions);
    try std.testing.expectEqualStrings("actions.find", state.executed[0..state.executed_len]);
    try std.testing.expect(!picker.visible);

    // Reopening with the empty query puts the just-used command first under a
    // "recently used" separator.
    try picker.setValue(">");
    picker.show();
    try interface.refresh(interface.context, &picker);
    try std.testing.expectEqualStrings("Find", picker.activeItem().?.label);
    try std.testing.expect(switch (picker.items.items[0]) {
        .separator => |separator| std.mem.eql(u8, separator.label, "recently used"),
        .item => false,
    });
}

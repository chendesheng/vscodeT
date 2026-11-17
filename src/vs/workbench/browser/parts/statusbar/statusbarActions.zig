// Port of `src/vs/workbench/browser/parts/statusbar/statusbarActions.ts`.
//
// The browser actions are menu items in the status-bar context menu. The TUI
// has no context-menu service, so the portable actions are exposed as values
// that the model/view can run; wiring them into a terminal menu is a follow-up.

const std = @import("std");

const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const StatusbarCommand = statusbar.StatusbarCommand;
const StatusbarCommandExecutor = statusbar.StatusbarCommandExecutor;
const StatusbarModel = @import("statusbarModel.zig").StatusbarModel;

pub const ToggleStatusbarEntryVisibilityAction = struct {
    id: []const u8,
    label: []const u8,
    model: *StatusbarModel,
    checked: bool,

    pub fn init(id: []const u8, label: []const u8, model: *StatusbarModel) ToggleStatusbarEntryVisibilityAction {
        return .{
            .id = id,
            .label = label,
            .model = model,
            .checked = !model.isHidden(id),
        };
    }

    pub fn run(self: *ToggleStatusbarEntryVisibilityAction) void {
        if (self.model.isHidden(self.id)) {
            self.model.show(self.id);
            self.checked = true;
        } else {
            self.model.hide(self.id);
            self.checked = false;
        }
    }
};

pub const HideStatusbarEntryAction = struct {
    id: []const u8,
    label: []const u8,
    model: *StatusbarModel,

    pub fn run(self: *HideStatusbarEntryAction) void {
        self.model.hide(self.id);
    }
};

pub const ManageExtensionAction = struct {
    extension_id: []const u8,
    executor: StatusbarCommandExecutor,

    pub fn run(self: *ManageExtensionAction) !void {
        const arguments = [_][]const u8{self.extension_id};
        try self.executor.execute(self.executor.context, .{
            .id = "_extensions.manage",
            .arguments = &arguments,
        });
    }
};

test "statusbarActions: toggle, hide and manage extension" {
    const allocator = std.testing.allocator;
    var model = StatusbarModel.init(allocator);
    defer model.deinit();
    _ = try model.add(.{ .name = "test", .text = "test" }, "test", .left, .{
        .primary = .{ .number = 1 },
        .secondary = 0,
    });

    var toggle = ToggleStatusbarEntryVisibilityAction.init("test", "Test", &model);
    toggle.run();
    try std.testing.expect(model.isHidden("test"));
    try std.testing.expect(!toggle.checked);
    toggle.run();
    try std.testing.expect(!model.isHidden("test"));

    var hide = HideStatusbarEntryAction{ .id = "test", .label = "Hide 'Test'", .model = &model };
    hide.run();
    try std.testing.expect(model.isHidden("test"));

    const Executor = struct {
        called: bool = false,
        command_id: []const u8 = "",
        argument: []const u8 = "",
        fn execute(context: *anyopaque, command: StatusbarCommand) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            self.command_id = command.id;
            if (command.arguments.len > 0) self.argument = command.arguments[0];
        }
    };
    var executor = Executor{};
    var manage = ManageExtensionAction{
        .extension_id = "publisher.extension",
        .executor = .{ .context = &executor, .execute = Executor.execute },
    };
    try manage.run();
    try std.testing.expect(executor.called);
    try std.testing.expectEqualStrings("_extensions.manage", executor.command_id);
    try std.testing.expectEqualStrings("publisher.extension", executor.argument);
}

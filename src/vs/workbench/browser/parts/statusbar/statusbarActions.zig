// Port of `src/vs/workbench/browser/parts/statusbar/statusbarActions.ts`.
//
// The workbench context menu uses these actions for entry visibility and
// extension management.

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

pub const focus_statusbar_action: @import("../../../../platform/actions/common/actions.zig").Action2 = .{
    .command = .{ .id = "workbench.action.focusStatusBar", .title = "Focus Status Bar", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = focusStatusBar,
};

fn focusStatusBar(_: *anyopaque, accessor: @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor) !void {
    (try accessor.get(layout.layout_service_id)).focusPart(.statusbar);
}

const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const keys = @import("../../../../platform/contextkey/common/contextkey.zig");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const layout = @import("../../../services/layout/browser/layoutService.zig");
const editors = @import("../../../services/editor/common/editorService.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;

const status_bar_focused: keys.Expr = .{ .Defined = "statusBarFocused" };
// The terminal must allow the global Escape Escape zen chord while the bar
// owns input; there is no separate browser focus-event dispatcher.
const not_zen: keys.Expr = .{ .Not = "inZenMode" };
const status_bar_clear_when: keys.Expr = .{ .And = @constCast(&[_]*const keys.Expr{ &status_bar_focused, &not_zen }) };
const Navigation = enum { previous, next, first, last, clear, execute };

fn navigation(comptime id: []const u8, title: []const u8, comptime operation: Navigation, comptime primary: ?key_codes.KeyCode, comptime secondary: []const u32) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title },
        .f1 = false,
        .keybindings = if (primary) |key| &.{.{ .id = id, .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib), .when = if (operation == .clear) &status_bar_clear_when else &status_bar_focused, .bindings = .{ .primary = @backingInt(key), .secondary = secondary } }} else &.{},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(statusbar.statusbar_service_id);
                switch (operation) {
                    .previous => service.focusPreviousEntry(),
                    .next => service.focusNextEntry(),
                    .first => {
                        service.focus(false);
                        service.focusNextEntry();
                    },
                    .last => {
                        service.focus(false);
                        service.focusPreviousEntry();
                    },
                    .clear => {
                        if (service.isEntryFocused()) {
                            service.focus(false);
                        } else if ((try accessor.get(editors.editor_service_id)).activeEditorPane() != null) {
                            (try accessor.get(layout.layout_service_id)).focusPart(.editor);
                        }
                    },
                    .execute => try service.executeFocused(),
                }
            }
        }.run,
    };
}

pub const navigation_actions = [_]actions.Action2{
    navigation("workbench.statusBar.focusPrevious", "Focus Previous Status Bar Entry", .previous, .LeftArrow, &.{@backingInt(key_codes.KeyCode.UpArrow)}),
    navigation("workbench.statusBar.focusNext", "Focus Next Status Bar Entry", .next, .RightArrow, &.{@backingInt(key_codes.KeyCode.DownArrow)}),
    navigation("workbench.statusBar.focusFirst", "Focus First Status Bar Entry", .first, .Home, &.{}),
    navigation("workbench.statusBar.focusLast", "Focus Last Status Bar Entry", .last, .End, &.{}),
    navigation("workbench.statusBar.clearFocus", "Clear Status Bar Focus", .clear, .Escape, &.{}),
    // Enter/Space activation is a native button default action upstream.
    navigation("workbench.action.statusbar.executeFocused", "Execute Focused Status Bar Entry", .execute, .Enter, &.{@backingInt(key_codes.KeyCode.Space)}),
    // Keep previous TUI command IDs usable in user keybindings; use upstream
    // IDs for the defaults and context-key expressions.
    navigation("workbench.action.statusbar.focusPreviousEntry", "Focus Previous Status Bar Entry", .previous, null, &.{}),
    navigation("workbench.action.statusbar.focusNextEntry", "Focus Next Status Bar Entry", .next, null, &.{}),
    navigation("workbench.action.statusbar.focusFirstEntry", "Focus First Status Bar Entry", .first, null, &.{}),
    navigation("workbench.action.statusbar.focusLastEntry", "Focus Last Status Bar Entry", .last, null, &.{}),
    navigation("workbench.action.statusbar.escapeFocus", "Clear Status Bar Focus", .clear, null, &.{}),
};

pub const ToggleStatusbarVisibilityAction = struct {
    layout_service: layout.IWorkbenchLayoutService,
    configuration_service: configuration.IConfigurationService,

    pub fn run(self: *@This()) !void {
        const visible = self.layout_service.isVisible(.statusbar);
        try self.configuration_service.requestUpdateValue(layout.LayoutSettings.status_bar_visible, .{ .bool = !visible }, .USER);
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

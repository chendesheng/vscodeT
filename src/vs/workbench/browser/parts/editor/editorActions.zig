// Port of the portable editor actions in `src/vs/workbench/browser/parts/editor/editorActions.ts`.
const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const layout = @import("../../../services/layout/browser/layoutService.zig");
const groups = @import("../../../services/editor/common/editorGroupsService.zig");

fn focusGroupAction(comptime id: []const u8, title: []const u8, comptime scope: ?groups.IFindGroupScope, comptime binding: ?u32) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .keybindings = if (binding) |primary| &.{.{ .id = id, .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib), .bindings = .{ .primary = primary } }} else &.{},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
                const service = try accessor.get(groups.editor_groups_service_id);
                const active = service.activeGroup() orelse return;
                const target = if (scope) |find| try service.findGroup(find, active, true) orelse return else active;
                target.focus();
            }
        }.run,
    };
}

fn chord(comptime arrow: key_codes.KeyCode) u32 {
    const modifier = key_codes.KeyMod.CtrlCmd;
    return key_codes.KeyChord(modifier | @backingInt(key_codes.KeyCode.KeyK), modifier | @backingInt(arrow));
}

pub const focus_group_actions = [_]actions.Action2{
    focusGroupAction("workbench.action.focusActiveEditorGroup", "Focus Active Editor Group", null, null),
    focusGroupAction("workbench.action.focusFirstEditorGroup", "Focus First Editor Group", .{ .location = .first }, key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.Digit1)),
    focusGroupAction("workbench.action.focusLastEditorGroup", "Focus Last Editor Group", .{ .location = .last }, null),
    focusGroupAction("workbench.action.focusNextGroup", "Focus Next Editor Group", .{ .location = .next }, null),
    focusGroupAction("workbench.action.focusPreviousGroup", "Focus Previous Editor Group", .{ .location = .previous }, null),
    focusGroupAction("workbench.action.focusLeftGroup", "Focus Left Editor Group", .{ .direction = .LEFT }, chord(.LeftArrow)),
    focusGroupAction("workbench.action.focusRightGroup", "Focus Right Editor Group", .{ .direction = .RIGHT }, chord(.RightArrow)),
    focusGroupAction("workbench.action.focusAboveGroup", "Focus Editor Group Above", .{ .direction = .UP }, chord(.UpArrow)),
    focusGroupAction("workbench.action.focusBelowGroup", "Focus Editor Group Below", .{ .direction = .DOWN }, chord(.DownArrow)),
};

// The palette retains these existing terminal labels and IDs.
pub const navigate_between_groups_action = focusGroupAction("workbench.action.navigateEditorGroups", "Cycle Editor Groups", .{ .location = .next }, null);

pub const reset_group_sizes_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.evenEditorWidths", .title = "Reset Editor Group Sizes", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = resetGroupSizes,
};

fn resetGroupSizes(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(groups.editor_groups_service_id);
    service.arrangeGroups(.EVEN);
}

// AbstractCreateEditorGroupAction: the new group becomes active, but a
// focused sidebar/list stays focused so it can open an input in that group.
fn newGroupAction(comptime id: []const u8, title: []const u8, comptime direction: groups.GroupDirection) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(groups.editor_groups_service_id);
                const layout_service = try accessor.get(layout.layout_service_id);
                const focus_new_group = layout_service.hasFocus(.editor);
                const source = service.activeGroup() orelse return;
                const group = try service.addGroup(source, direction);
                service.activateGroup(group);
                if (focus_new_group) group.focus();
            }
        }.run,
    };
}

pub const new_group_actions = [_]actions.Action2{
    newGroupAction("workbench.action.newGroupLeft", "New Editor Group to the Left", .LEFT),
    newGroupAction("workbench.action.newGroupRight", "New Editor Group to the Right", .RIGHT),
    newGroupAction("workbench.action.newGroupAbove", "New Editor Group Above", .UP),
    newGroupAction("workbench.action.newGroupBelow", "New Editor Group Below", .DOWN),
};

fn moveGroupAction(comptime id: []const u8, title: []const u8, comptime direction: groups.GroupDirection, comptime arrow: key_codes.KeyCode) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .keybindings = &.{.{ .id = id, .weight = @backingInt(bindings.KeybindingWeight.WorkbenchContrib), .bindings = .{ .primary = key_codes.KeyChord(key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyK), @backingInt(arrow)) } }},
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(groups.editor_groups_service_id);
                const source = service.activeGroup() orelse return;
                const directions: [3]groups.GroupDirection = switch (direction) {
                    .LEFT, .RIGHT => .{ direction, .UP, .DOWN },
                    .UP, .DOWN => .{ direction, .LEFT, .RIGHT },
                };
                for (directions) |candidate| {
                    const target = try service.findGroup(.{ .direction = candidate }, source, false) orelse continue;
                    if (target.id == source.id) continue;
                    const moved = try service.moveGroup(source, target, direction);
                    service.activateGroup(moved);
                    return;
                }
            }
        }.run,
    };
}

pub const move_group_actions = [_]actions.Action2{
    moveGroupAction("workbench.action.moveActiveEditorGroupLeft", "Move Editor Group Left", .LEFT, .LeftArrow),
    moveGroupAction("workbench.action.moveActiveEditorGroupRight", "Move Editor Group Right", .RIGHT, .RightArrow),
    moveGroupAction("workbench.action.moveActiveEditorGroupUp", "Move Editor Group Up", .UP, .UpArrow),
    moveGroupAction("workbench.action.moveActiveEditorGroupDown", "Move Editor Group Down", .DOWN, .DownArrow),
};

const std = @import("std");
const dialogs = @import("../../../../platform/dialogs/common/dialogs.zig");
const file_dialogs = @import("../../../services/dialogs/browser/abstractFileDialogService.zig");
const Tab = @import("editorPane.zig").Tab;
const GroupView = @import("editorGroupView.zig").EditorGroupView(*Tab);
const EditorPart = @import("editorPart.zig").EditorPart(GroupView);

/// Terminal window-close adaptation of AbstractCloseAllAction. The owner
/// reveals the affected editors, requests one file confirmation, saves or
/// reverts through EditorInput, then closes them. The exit flag and final
/// disposal/focus calls belong to the window host. The upstream auto-save
/// buckets, async custom confirmation and progress service are not yet ported.
pub const CloseAllEditorsForWindow = struct {
    allocator: std.mem.Allocator,
    part: *EditorPart,
    host: GroupView.CloseHost,
    on_exit: *const fn (*anyopaque) void,

    pub fn hasDirtyEditors(part: *const EditorPart) bool {
        for (part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.input.isDirty()) return true;
            }
        }
        return false;
    }

    pub fn run(part: *EditorPart, dialog_service: dialogs.IDialogService, host: GroupView.CloseHost, on_exit: *const fn (*anyopaque) void) !void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(part.allocator);
        for (part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (tab.input.isDirty()) try names.append(part.allocator, tab.input.getName());
            }
        }
        if (names.items.len == 0) return;
        host.prepare_dialog(host.context);
        // Upstream revealEditorsToConfirm opens the first affected editor
        // in every group, not each dirty editor in turn.
        var reveal_pane: ?*GroupView = null;
        for (part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.input.isDirty()) continue;
                try pane.activateTab(tab);
                reveal_pane = pane;
                break;
            }
        }
        if (reveal_pane) |pane| part.service.activateGroup(pane.group);
        if (part.activeView()) |pane| if (pane.activeTab()) |tab| try tab.ensureControllers();
        host.focus_editor(host.context, null);

        const pending = try part.allocator.create(CloseAllEditorsForWindow);
        errdefer part.allocator.destroy(pending);
        pending.* = .{ .allocator = part.allocator, .part = part, .host = host, .on_exit = on_exit };
        _ = try file_dialogs.showSaveConfirm(part.allocator, dialog_service, names.items, .{
            .context = pending,
            .complete = complete,
            .dispose = dispose,
        });
    }

    fn complete(context: *anyopaque, result: dialogs.ConfirmResult) void {
        const self: *CloseAllEditorsForWindow = @ptrCast(@alignCast(context));
        self.resolve(result) catch |err| self.host.report_error(self.host.context, err);
    }

    fn dispose(context: *anyopaque) void {
        const self: *CloseAllEditorsForWindow = @ptrCast(@alignCast(context));
        self.allocator.destroy(self);
    }

    fn resolve(self: *CloseAllEditorsForWindow, result: dialogs.ConfirmResult) !void {
        const host = self.host;
        if (result == .CANCEL) {
            host.focus_editor(host.context, null);
            return;
        }
        for (self.part.group_views.items) |pane| {
            for (pane.tabs.items) |tab| {
                if (!tab.input.isDirty()) continue;
                switch (result) {
                    .SAVE => {
                        _ = tab.input.save(pane.group.id) catch |err| {
                            tab.editor.setMessage("Unable to save {s}: {s}", .{ tab.input.getName(), @errorName(err) });
                            try self.revealFailure(pane, tab);
                            return;
                        };
                        if (tab.input.isDirty()) {
                            try self.revealFailure(pane, tab);
                            return;
                        }
                    },
                    .DONT_SAVE => tab.input.revert(pane.group.id) catch {},
                    .CANCEL => unreachable,
                }
            }
        }
        try self.doCloseAll();
        self.on_exit(host.context);
    }

    fn revealFailure(self: *CloseAllEditorsForWindow, pane: *GroupView, tab: *Tab) !void {
        self.part.service.activateGroup(pane.group);
        try pane.activateTab(tab);
        try tab.ensureControllers();
        self.host.focus_editor(self.host.context, tab);
    }

    fn doCloseAll(self: *CloseAllEditorsForWindow) !void {
        while (true) {
            var closed = false;
            for (self.part.group_views.items) |pane| {
                if (pane.tabs.items.len == 0) continue;
                try self.host.close_tab(self.host.context, pane, pane.tabs.items[0]);
                closed = true;
                break;
            }
            if (!closed) break;
        }
    }
};

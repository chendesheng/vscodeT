// Port of the focus group actions in `src/vs/workbench/browser/parts/editor/editorActions.ts`.
const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
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

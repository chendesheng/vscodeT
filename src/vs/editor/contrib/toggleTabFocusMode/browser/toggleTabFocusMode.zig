// Port of `src/vs/editor/contrib/toggleTabFocusMode/browser/toggleTabFocusMode.ts`.
const std = @import("std");
const tab_focus = @import("../../../browser/config/tabFocus.zig");
const actions = @import("../../../../platform/actions/common/actions.zig");
const bindings = @import("../../../../platform/keybinding/common/keybindingsRegistry.zig");
const key_codes = @import("../../../../base/common/keyCodes.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;

pub const ToggleTabFocusModeAction = struct {
    pub const id = "editor.action.toggleTabFocusMode";
    pub const label = "Toggle Tab Key Moves Focus";
    pub const description = "Determines whether the tab key moves focus around the workbench or inserts the tab character in the current editor. This is also called tab trapping, tab navigation, or tab focus mode.";

    pub const action: actions.Action2 = .{
        .command = .{ .id = id, .title = label },
        .f1 = true,
        .keybindings = &.{.{
            .id = id,
            .weight = @backingInt(bindings.KeybindingWeight.EditorContrib),
            .bindings = .{
                .primary = key_codes.KeyMod.CtrlCmd | @backingInt(key_codes.KeyCode.KeyM),
                .mac = .{ .primary = key_codes.KeyMod.WinCtrl | key_codes.KeyMod.Shift | @backingInt(key_codes.KeyCode.KeyM) },
            },
        }},
        .context = @constCast(&{}),
        .run_fn = run,
    };

    fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
        const mode = try accessor.get(tab_focus.tab_focus_id);
        try toggle(mode);
    }

    fn toggle(mode: *tab_focus.TabFocus) !void {
        try mode.setTabFocusMode(!mode.getTabFocusMode());
    }
};

test "toggleTabFocusMode: toggles and publishes state" {
    var mode = tab_focus.TabFocus.init(std.testing.allocator);
    defer mode.deinit();
    var changes: usize = 0;
    _ = try mode.on_did_change_tab_focus.listen(&changes, struct {
        fn changed(value: bool, count: *usize) !void {
            try std.testing.expectEqual(count.* == 0, value);
            count.* += 1;
        }
    }.changed);
    try std.testing.expect(!mode.getTabFocusMode());
    try ToggleTabFocusModeAction.toggle(&mode);
    try std.testing.expect(mode.getTabFocusMode());
    try ToggleTabFocusModeAction.toggle(&mode);
    try std.testing.expect(!mode.getTabFocusMode());
    try std.testing.expectEqual(@as(usize, 2), changes);
}

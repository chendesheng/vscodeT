// Port of the centered layout, editor view resize and Zen Mode tab actions from src/vs/workbench/browser/actions/layoutActions.ts.
const actions = @import("../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const layout = @import("../../services/layout/browser/layoutService.zig");
const groups = @import("../../services/editor/common/editorGroupsService.zig");

pub const toggle_centered_layout_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.toggleCenteredLayout", .title = "Toggle Centered Layout", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = toggleCenteredLayout,
};

fn toggleCenteredLayout(_: *anyopaque, accessor: ServicesAccessor) !void {
    const layout_service = try accessor.get(layout.layout_service_id);
    const editor_groups = try accessor.get(groups.editor_groups_service_id);
    try layout_service.centerMainEditorLayout(!layout_service.isMainEditorLayoutCentered());
    if (editor_groups.activeGroup()) |group| group.focus();
}

fn resizeAction(id: []const u8, title: []const u8, comptime width: isize, comptime height: isize) actions.Action2 {
    return .{ .command = .{ .id = id, .title = title, .category = "View" }, .f1 = true, .context = @constCast(&{}), .run_fn = struct {
        fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
            try (try accessor.get(layout.layout_service_id)).resizePart(.editor, width, height);
        }
    }.run };
}

// The browser uses a screen-aware pixel increment. These are the existing
// native cell increments; there is no auxiliary window in the terminal.
pub const resize_actions = [_]actions.Action2{
    resizeAction("workbench.action.increaseViewWidth", "Increase Editor Width", 4, 0),
    resizeAction("workbench.action.decreaseViewWidth", "Decrease Editor Width", -4, 0),
    resizeAction("workbench.action.increaseViewHeight", "Increase Editor Height", 0, 2),
    resizeAction("workbench.action.decreaseViewHeight", "Decrease Editor Height", 0, -2),
};

const configuration = @import("../../../platform/configuration/common/configuration.zig");
const Expr = @import("../../../platform/contextkey/common/contextkey.zig").Expr;
const zen = @import("../workbench.zenMode.contribution.zig");
const in_zen_mode = Expr{ .Defined = "inZenMode" };

/// AbstractSetShowTabsAction: only offer a different tab mode while Zen
/// Mode is active. The config.* keys are provided by the context service.
fn zenTabsAction(comptime id: []const u8, comptime title: []const u8, comptime description: []const u8, comptime mode: layout.EditorTabsMode) actions.Action2 {
    const Condition = struct {
        const differs = Expr{ .NotEquals = .{ .key = "config." ++ layout.ZenModeSettings.show_tabs, .value = .{ .string = zen.showTabsValue(mode) } } };
        const expr = Expr{ .And = @constCast(&[_]*const Expr{ &in_zen_mode, &differs }) };
    };
    return .{
        .command = .{ .id = id, .title = title, .category = zen.category, .tooltip = description, .precondition = &Condition.expr },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                const service = try accessor.get(configuration.configuration_service_id);
                try service.updateValue(layout.ZenModeSettings.show_tabs, .{ .string = zen.showTabsValue(mode) }, .USER);
            }
        }.run,
    };
}

pub const zen_tabs_actions = [_]actions.Action2{
    zenTabsAction(zen.zen_hide_editor_tabs_id, zen.zen_hide_editor_tabs_label, zen.zen_hide_editor_tabs_description, .none),
    zenTabsAction(zen.zen_show_multiple_editor_tabs_id, zen.zen_show_multiple_editor_tabs_label, zen.zen_show_multiple_editor_tabs_description, .multiple),
    zenTabsAction(zen.zen_show_single_editor_tab_id, zen.zen_show_single_editor_tab_label, zen.zen_show_single_editor_tab_description, .single),
};

/// ToggleSidebarVisibilityAction. Palette metadata remains compatible with
/// the native command inventory; the ARIA alert is browser-only.
pub const toggle_sidebar_visibility_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.toggleSidebarVisibility", .title = "Toggle Primary Side Bar Visibility", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = toggleSidebarVisibility,
};

fn toggleSidebarVisibility(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    try service.setPartHidden(service.isVisible(.sidebar), .sidebar);
}

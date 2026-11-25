// Port of the terminal-supported actions in
// src/vs/workbench/browser/parts/panel/panelActions.ts.
// The original terminal palette metadata is retained during extraction.
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const layout = @import("../../../services/layout/browser/layoutService.zig");
const SwitchCompositeViewAction = @import("../compositeBarActions.zig").SwitchCompositeViewAction;

pub const toggle_panel_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.togglePanel", .title = "View: Toggle Panel Visibility", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = togglePanel,
};

pub const close_panel_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.closePanel", .title = "Close Panel", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = closePanel,
};

pub const focus_and_switch_actions = [_]actions.Action2{
    .{ .command = .{ .id = "workbench.action.focusPanel", .title = "View: Focus Panel", .category = "View" }, .f1 = true, .context = @constCast(&{}), .run_fn = focusPanel },
    .{ .command = .{ .id = "workbench.action.previousPanelView", .title = "View: Previous Panel View", .category = "View" }, .f1 = true, .context = @constCast(&{}), .run_fn = previousPanel },
    .{ .command = .{ .id = "workbench.action.nextPanelView", .title = "View: Next Panel View", .category = "View" }, .f1 = true, .context = @constCast(&{}), .run_fn = nextPanel },
};

fn togglePanel(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    try service.setPartHidden(service.isVisible(.panel), .panel);
}

fn closePanel(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    try service.setPartHidden(true, .panel);
}

fn focusPanel(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    if (!service.isVisible(.panel)) try service.setPartHidden(false, .panel);
    service.focusPart(.panel);
}

fn previousPanel(_: *anyopaque, accessor: ServicesAccessor) !void {
    try SwitchCompositeViewAction.run(accessor, .panel, -1);
}

fn nextPanel(_: *anyopaque, accessor: ServicesAccessor) !void {
    try SwitchCompositeViewAction.run(accessor, .panel, 1);
}

pub const toggle_maximized_panel_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.toggleMaximizedPanel", .title = "Toggle Maximized Panel", .tooltip = "Maximize Panel", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = toggleMaximizedPanel,
};

fn toggleMaximizedPanel(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    if (!service.isVisible(.panel)) {
        try service.setPartHidden(false, .panel);
        if (!service.isPanelMaximized()) try service.toggleMaximizedPanel();
    } else {
        try service.toggleMaximizedPanel();
    }
}

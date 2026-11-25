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

const Expr = @import("../../../../platform/contextkey/common/contextkey.zig").Expr;
const aligned_center = Expr{ .Equals = .{ .key = "panelAlignment", .value = .{ .string = "center" } } };
const not_bottom = Expr{ .NotEquals = .{ .key = "panelPosition", .value = .{ .string = "bottom" } } };
const not_top = Expr{ .NotEquals = .{ .key = "panelPosition", .value = .{ .string = "top" } } };
const vertical_panel = Expr{ .And = @constCast(&[_]*const Expr{ &not_bottom, &not_top }) };
const panel_maximization_supported = Expr{ .Or = @constCast(&[_]*const Expr{ &aligned_center, &vertical_panel }) };

pub const toggle_maximized_panel_action: actions.Action2 = .{
    .command = .{ .id = "workbench.action.toggleMaximizedPanel", .title = "Toggle Maximized Panel", .tooltip = "Maximize Panel", .category = "View", .precondition = &panel_maximization_supported, .toggled = &.{ .Defined = "panelMaximized" } },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = toggleMaximizedPanel,
};

fn toggleMaximizedPanel(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    if (service.getPanelAlignment() != .center and layout.isHorizontal(service.getPanelPosition())) {
        const notifications = @import("../../../../platform/notification/common/notification.zig");
        (try accessor.get(notifications.notification_service_id)).warn(.{ .text = "Maximizing the panel is only supported when it is center aligned." });
        return;
    }
    if (!service.isVisible(.panel)) {
        try service.setPartHidden(false, .panel);
        if (!service.isPanelMaximized()) try service.toggleMaximizedPanel();
    } else {
        try service.toggleMaximizedPanel();
    }
}

fn positionAction(comptime id: []const u8, title: []const u8, comptime position: layout.Position) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                try (try accessor.get(layout.layout_service_id)).setPanelPosition(position);
            }
        }.run,
    };
}

fn alignmentAction(comptime id: []const u8, title: []const u8, comptime alignment: layout.PanelAlignment) actions.Action2 {
    const Condition = struct {
        const active = Expr{ .Equals = .{ .key = "panelAlignment", .value = .{ .string = @tagName(alignment) } } };
    };
    return .{
        .command = .{ .id = id, .title = title, .category = "View", .toggled = &Condition.active },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                try (try accessor.get(layout.layout_service_id)).setPanelAlignment(alignment);
            }
        }.run,
    };
}

pub const positioning_actions = [_]actions.Action2{
    positionAction("workbench.action.positionPanelTop", "Move Panel To Top", .top),
    positionAction("workbench.action.positionPanelLeft", "Move Panel Left", .left),
    positionAction("workbench.action.positionPanelRight", "Move Panel Right", .right),
    positionAction("workbench.action.positionPanelBottom", "Move Panel To Bottom", .bottom),
    alignmentAction("workbench.action.alignPanelLeft", "Set Panel Alignment to Left", .left),
    alignmentAction("workbench.action.alignPanelRight", "Set Panel Alignment to Right", .right),
    alignmentAction("workbench.action.alignPanelCenter", "Set Panel Alignment to Center", .center),
    alignmentAction("workbench.action.alignPanelJustify", "Set Panel Alignment to Justify", .justify),
};

// Port of the portable actions from src/vs/workbench/browser/parts/sidebar/sidebarActions.ts.
// Native focus is supplied through IWorkbenchLayoutService; no browser DOM.
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const layout = @import("../../../services/layout/browser/layoutService.zig");
const pane_composite = @import("../../../services/panecomposite/browser/panecomposite.zig");

pub const sidebar_actions = [_]actions.Action2{
    .{
        .command = .{ .id = "workbench.action.closeSidebar", .title = "Close Primary Side Bar", .category = "View" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = closeSidebar,
    },
    .{
        .command = .{ .id = "workbench.action.focusSideBar", .title = "Focus into Primary Side Bar", .category = "View" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = focusSidebar,
    },
};

fn closeSidebar(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    try service.setPartHidden(true, .sidebar);
}

fn focusSidebar(_: *anyopaque, accessor: ServicesAccessor) !void {
    const service = try accessor.get(layout.layout_service_id);
    const panes = try accessor.get(pane_composite.pane_composite_part_service_id);
    if (!service.isVisible(.sidebar)) try service.setPartHidden(false, .sidebar);
    if (panes.getActivePaneComposite(.sidebar) != null) service.focusPart(.sidebar);
}

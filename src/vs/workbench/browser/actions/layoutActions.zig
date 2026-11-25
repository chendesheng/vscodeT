// Port of the centered layout action from src/vs/workbench/browser/actions/layoutActions.ts.
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

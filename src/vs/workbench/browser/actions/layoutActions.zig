// Port of the centered layout and editor view resize actions from src/vs/workbench/browser/actions/layoutActions.ts.
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

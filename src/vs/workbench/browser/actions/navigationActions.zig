// Port of BaseNavigationAction from src/vs/workbench/browser/actions/navigationActions.ts.
// The single-window terminal has no auxiliary windows/bar. The existing
// native palette labels are retained; contributed view-navigation overrides
// and next/previous-part actions are not yet ported.
const actions = @import("../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const layout = @import("../../services/layout/browser/layoutService.zig");
const groups = @import("../../services/editor/common/editorGroupsService.zig");
const panes = @import("../../services/panecomposite/browser/panecomposite.zig");
const Location = @import("../../common/views.zig").ViewContainerLocation;

fn toGroupDirection(direction: layout.Direction) groups.GroupDirection {
    return switch (direction) {
        .up => .UP,
        .down => .DOWN,
        .left => .LEFT,
        .right => .RIGHT,
    };
}

fn oppositeDirection(direction: groups.GroupDirection) groups.GroupDirection {
    return switch (direction) {
        .UP => .DOWN,
        .DOWN => .UP,
        .LEFT => .RIGHT,
        .RIGHT => .LEFT,
    };
}

fn doNavigateToEditorGroup(service: groups.IEditorGroupsService, scope: groups.IFindGroupScope) !bool {
    const active = service.activeGroup() orelse return false;
    const target = try service.findGroup(scope, active, false) orelse return false;
    target.focus();
    return true;
}

fn navigateBackToEditorGroup(service: groups.IEditorGroupsService, direction: groups.GroupDirection) !bool {
    const active = service.activeGroup() orelse return false;
    if (try service.findGroup(.{ .direction = oppositeDirection(direction) }, active, false) != null) return false;
    active.focus();
    return true;
}

fn navigateToComposite(service: layout.IWorkbenchLayoutService, composites: panes.IPaneCompositePartService, part: layout.Parts, location: Location) !void {
    if (!service.isVisible(part)) return;
    const active = composites.getActivePaneComposite(location) orelse return;
    _ = try composites.openPaneComposite(active.id, location, true);
}

pub fn navigate(accessor: ServicesAccessor, direction: layout.Direction) !void {
    const service = try accessor.get(layout.layout_service_id);
    const editor_groups = try accessor.get(groups.editor_groups_service_id);
    const composites = try accessor.get(panes.pane_composite_part_service_id);
    const group_direction = toGroupDirection(direction);
    var neighbor: ?layout.Parts = null;
    if (service.hasFocus(.editor)) {
        if (try doNavigateToEditorGroup(editor_groups.*, .{ .direction = group_direction })) return;
        neighbor = service.getVisibleNeighborPart(.editor, direction);
    }
    if (service.hasFocus(.panel)) neighbor = service.getVisibleNeighborPart(.panel, direction);
    if (service.hasFocus(.sidebar)) neighbor = service.getVisibleNeighborPart(.sidebar, direction);
    switch (neighbor orelse return) {
        .editor => {
            if (!try navigateBackToEditorGroup(editor_groups.*, group_direction)) {
                _ = try doNavigateToEditorGroup(editor_groups.*, .{ .location = if (direction == .right) .first else .last });
            }
        },
        .sidebar => try navigateToComposite(service.*, composites.*, .sidebar, .sidebar),
        .panel => try navigateToComposite(service.*, composites.*, .panel, .panel),
        else => {},
    }
}

fn navigationAction(comptime id: []const u8, title: []const u8, comptime direction: layout.Direction) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "View" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn run(_: *anyopaque, accessor: ServicesAccessor) !void {
                try navigate(accessor, direction);
            }
        }.run,
    };
}

pub const navigation_actions = [_]actions.Action2{
    navigationAction("workbench.action.navigateLeft", "Focus Group Left", .left),
    navigationAction("workbench.action.navigateRight", "Focus Group Right", .right),
    navigationAction("workbench.action.navigateUp", "Focus Group Up", .up),
    navigationAction("workbench.action.navigateDown", "Focus Group Down", .down),
};

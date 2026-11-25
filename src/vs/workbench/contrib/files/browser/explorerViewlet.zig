// Port of the Explorer view-container registration in
// src/vs/workbench/contrib/files/browser/explorerViewlet.ts.
// The terminal's existing activity ID is the native alias for VIEWLET_ID.
const views = @import("../../../common/views.zig");

pub fn registerViewContainer(registry: *views.ViewContainersRegistry) !void {
    _ = try registry.register(.{
        .id = "explorer",
        .title = "Explorer",
        .glyph = '\u{f07b}',
        .order = 0,
    }, .sidebar, .{ .is_default = true });
}

pub fn registerViews(registry: *views.ViewsRegistry) !void {
    // The terminal retains its existing single folders pane in both empty
    // and folder workspaces; Open Editors/EmptyView remain unported.
    try registry.registerViews(&.{.{ .id = "explorer", .name = "Explorer", .order = 0, .weight = 70, .can_toggle_visibility = false }}, "explorer");
}

const Action2 = @import("../../../../platform/actions/common/actions.zig").Action2;
const Accessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const pane_composite = @import("../../../services/panecomposite/browser/panecomposite.zig");

pub const show_explorer_action: Action2 = .{
    .command = .{ .id = "workbench.view.explorer", .title = "View: Show Explorer", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = showExplorer,
};

fn showExplorer(_: *anyopaque, accessor: Accessor) !void {
    const service = try accessor.get(pane_composite.pane_composite_part_service_id);
    _ = try service.openPaneComposite("explorer", .sidebar, true);
}

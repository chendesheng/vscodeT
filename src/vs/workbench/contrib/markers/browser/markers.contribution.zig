// Port of the Problems view registration and toggle action from
// src/vs/workbench/contrib/markers/browser/markers.contribution.ts.
// The terminal retains its original command-palette labels and exposure.
const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const views = @import("../../../common/views.zig");
const views_service = @import("../../../services/views/common/viewsService.zig");
const markers = @import("../common/markers.zig");
const MarkersView = @import("markersView.zig").MarkersView;

pub const properties = [_]@import("../../../../platform/configuration/common/configurationRegistry.zig").PropertySchema{
    .{ .key = "problems.sortOrder", .value_type = "string", .default = .{ .string = "severity" }, .enum_values = &.{ "severity", "position" } },
};

pub fn registerViewContainer(registry: *views.ViewContainersRegistry) !void {
    _ = try registry.register(.{
        .id = markers.Markers.MARKERS_CONTAINER_ID,
        .title = markers.PROBLEMS_TITLE,
        .glyph = '!',
        .hide_if_empty = true,
        .order = 0,
    }, .panel, .{});
}

pub const view_actions = [_]actions.Action2{
    .{ .command = .{ .id = markers.Markers.SHOW_MARKERS_VIEW_ACTION_ID, .title = "View: Show Problems", .category = "View" }, .f1 = true, .context = @constCast(&{}), .run_fn = showAction },
    .{ .command = .{ .id = markers.Markers.TOGGLE_MARKERS_VIEW_ACTION_ID, .title = "View: Toggle Problems", .category = "View" }, .f1 = true, .context = @constCast(&{}), .run_fn = toggleAction },
};

pub fn show(views_api: views_service.IViewsService) !void {
    _ = try views_api.openView(MarkersView, true);
}

pub fn toggle(views_api: views_service.IViewsService) !void {
    if (views_api.isViewVisible(MarkersView.ID)) {
        try views_api.closeView(MarkersView.ID);
    } else try show(views_api);
}

fn showAction(_: *anyopaque, accessor: ServicesAccessor) !void {
    try show((try accessor.get(views_service.views_service_id)).*);
}

fn toggleAction(_: *anyopaque, accessor: ServicesAccessor) !void {
    try toggle((try accessor.get(views_service.views_service_id)).*);
}

// Port of the Extensions view-container, view and command registrations in
// `src/vs/workbench/contrib/extensions/browser/extensions.contribution.ts`.
//
// Terminal adaptation: the container/view ids use the workbench's native
// "extensions" alias for upstream `workbench.view.extensions` /
// `workbench.views.extensions.installed`. The container hosts one combined
// view, so the one visible view cannot be hidden. Marketplace actions,
// recommendations, update checks and the extension-details editor are not
// ported.
const views = @import("../../../common/views.zig");
const Action2 = @import("../../../../platform/actions/common/actions.zig").Action2;
const Accessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const pane_composite = @import("../../../services/panecomposite/browser/panecomposite.zig");
const views_service = @import("../../../services/views/common/viewsService.zig");
const model = @import("../common/extensions.zig");
const view_mod = @import("extensionsViews.zig");
const ExtensionsListView = view_mod.ExtensionsListView;

/// Codicon `extensions` (EAE6); the activity bar and container share it.
pub const extensions_glyph: u21 = 0xEAE6;

pub fn registerViewContainer(registry: *views.ViewContainersRegistry) !void {
    _ = try registry.register(.{
        .id = model.VIEW_ID,
        .title = "Extensions",
        .glyph = extensions_glyph,
        .order = 4,
    }, .sidebar, .{});
}

pub fn registerViews(registry: *views.ViewsRegistry) !void {
    // The single combined view merges with the container title. It cannot be
    // hidden because that would leave the activity-bar container empty.
    try registry.registerViews(&.{.{
        .id = model.VIEW_ID,
        .name = "Extensions",
        .order = 0,
        .weight = 100,
        .can_toggle_visibility = false,
    }}, model.VIEW_ID);
}

pub const show_extensions_action: Action2 = .{
    .command = .{ .id = model.VIEWLET_ID, .title = "View: Show Extensions", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = showExtensions,
};

fn showExtensions(_: *anyopaque, accessor: Accessor) !void {
    const service = try accessor.get(pane_composite.pane_composite_part_service_id);
    _ = try service.openPaneComposite(model.VIEW_ID, .sidebar, true);
}

pub const refresh_action: Action2 = .{
    .command = .{ .id = view_mod.refresh_action_id, .title = "Refresh", .category = model.EXTENSIONS_CATEGORY },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = refreshExtensions,
};

fn refreshExtensions(_: *anyopaque, accessor: Accessor) !void {
    const service = try accessor.get(views_service.views_service_id);
    const view = service.getViewWithId(ExtensionsListView) orelse return;
    try view.refresh();
}

pub const clear_search_action: Action2 = .{
    .command = .{ .id = view_mod.clear_search_action_id, .title = "Clear Extensions Search Results", .category = model.EXTENSIONS_CATEGORY },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = clearSearch,
};

fn clearSearch(_: *anyopaque, accessor: Accessor) !void {
    const service = try accessor.get(views_service.views_service_id);
    const view = service.getViewWithId(ExtensionsListView) orelse return;
    view.clearSearch();
}

pub const actions = [_]Action2{
    show_extensions_action,
    refresh_action,
    clear_search_action,
};

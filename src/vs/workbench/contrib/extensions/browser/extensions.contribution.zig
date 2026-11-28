// Port of the Extensions view-container, view and command registrations in
// `src/vs/workbench/contrib/extensions/browser/extensions.contribution.ts`.
// The activity container retains the terminal's historic "extensions" alias;
// individual views use upstream IDs and query-driven availability.
const views = @import("../../../common/views.zig");
const Action2 = @import("../../../../platform/actions/common/actions.zig").Action2;
const Accessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const pane_composite = @import("../../../services/panecomposite/browser/panecomposite.zig");
const views_service = @import("../../../services/views/common/viewsService.zig");
const model = @import("../common/extensions.zig");
const view_mod = @import("extensionsViews.zig");
const ExtensionsListView = view_mod.ExtensionsListView;
const workbench_service = @import("extensionsWorkbenchService.zig");

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
    try @import("extensionsViewlet.zig").registerViews(registry);
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

pub const restart_extensions_action: Action2 = .{
    .command = .{ .id = "workbench.action.restartExtensionHost", .title = "Restart Extension Host", .category = "Developer" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = restartExtensions,
};

fn restartExtensions(_: *anyopaque, accessor: Accessor) !void {
    const service = try accessor.get(workbench_service.extensions_workbench_service_id);
    try service.restartExtensions();
}

pub const install_vsix_action: Action2 = .{
    .command = .{ .id = "workbench.extensions.action.installVSIX", .title = "Install from VSIX...", .category = model.EXTENSIONS_CATEGORY },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = installVSIX,
};

fn installVSIX(_: *anyopaque, accessor: Accessor) !void {
    const service = try accessor.get(workbench_service.extensions_workbench_service_id);
    try service.installFromVSIX();
}

pub const actions = [_]Action2{
    show_extensions_action,
    refresh_action,
    clear_search_action,
    restart_extensions_action,
    install_vsix_action,
};

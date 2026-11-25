// Port of the Action2 and ViewTitle context-menu contributions in
// src/vs/workbench/contrib/outline/browser/outlineActions.ts.
const actions = @import("../../../../platform/actions/common/actions.zig");
const keys = @import("../../../../platform/contextkey/common/contextkey.zig");
const OverlayContext = @import("../../../../platform/contextkey/browser/contextKeyService.zig").OverlayContext;
const MenuService = @import("../../../../platform/actions/common/menuService.zig").MenuService;
const Menu = @import("../../../../platform/contextview/browser/contextMenuService.zig").Menu;
const outline = @import("outline.zig");
const in_outline = keys.Expr{ .Equals = .{ .key = "view", .value = .{ .string = outline.outline_id } } };

fn sortMode(comptime mode: outline.OutlineSortOrder) keys.Expr {
    return .{ .Equals = .{ .key = "outlineSortMode", .value = .{ .number = @floatFromInt(@backingInt(mode)) } } };
}

pub fn registerMenus(registry: *actions.MenuRegistry) !void {
    const title = actions.menu_ids.ViewTitle;
    for ([_]actions.IMenuItem{
        .{ .command = .{ .id = "outline.followCursor", .title = "Follow Cursor", .toggled = &.{ .Defined = "outlineFollowsCursor" } }, .when = &in_outline, .group = "config", .order = 1 },
        .{ .command = .{ .id = "outline.filterOnType", .title = "Filter on Type", .toggled = &.{ .Defined = "outlineFiltersOnType" } }, .when = &in_outline, .group = "config", .order = 2 },
        .{ .command = .{ .id = "outline.sortByPosition", .title = "Sort By: Position", .toggled = &comptime sortMode(.ByPosition) }, .when = &in_outline, .group = "sort", .order = 1 },
        .{ .command = .{ .id = "outline.sortByName", .title = "Sort By: Name", .toggled = &comptime sortMode(.ByName) }, .when = &in_outline, .group = "sort", .order = 2 },
        .{ .command = .{ .id = "outline.sortByKind", .title = "Sort By: Category", .toggled = &comptime sortMode(.ByKind) }, .when = &in_outline, .group = "sort", .order = 3 },
    }) |item| try registry.appendMenuItem(title, item);
}

pub fn appendSecondary(menu: *Menu, service: *MenuService, global: keys.IContext, state: *const outline.OutlineViewState) !void {
    var context = OverlayContext{ .parent = global, .overlay = &.{
        .{ .key = "view", .value = .{ .string = outline.outline_id } },
        .{ .key = "outlineFollowsCursor", .value = .{ .boolean = state.follow_cursor } },
        .{ .key = "outlineFiltersOnType", .value = .{ .boolean = state.filter_on_type } },
        .{ .key = "outlineSortMode", .value = .{ .number = @floatFromInt(@backingInt(state.sort_by)) } },
    } };
    try menu.appendMenuActions(service, actions.menu_ids.ViewTitle, context.interface(), true);
}

const OutlinePane = @import("outlinePane.zig").OutlinePane;
const viewAction = @import("../../../browser/parts/views/viewPane.zig").viewAction;
const views = @import("../../../services/views/common/viewsService.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;

pub const focus_action: actions.Action2 = .{
    .command = .{ .id = "outline.focus", .title = "Focus Outline", .category = "View" },
    .f1 = true,
    .context = @constCast(&{}),
    .run_fn = focus,
};

fn focus(_: *anyopaque, accessor: ServicesAccessor) !void {
    _ = try (try accessor.get(views.views_service_id)).openView(OutlinePane, true);
}

fn followCursor(view: *OutlinePane) !void {
    try view.setFollowCursor(!view.view_state.follow_cursor);
}

fn filterOnType(view: *OutlinePane) !void {
    try view.setFilterOnType(!view.view_state.filter_on_type);
}

// Keep the existing terminal palette entries and the registered-view lookup
// when extracting these actions. Upstream hides these title actions from F1.
pub const outline_actions = [_]actions.Action2{
    viewAction(OutlinePane, .registered, .{ .id = "outline.collapse", .title = "Collapse All", .category = "View" }, true, OutlinePane.collapseAll, .{}),
    viewAction(OutlinePane, .registered, .{ .id = "outline.expand", .title = "Expand All", .category = "View" }, true, OutlinePane.expandAll, .{}),
    viewAction(OutlinePane, .registered, .{ .id = "outline.followCursor", .title = "Follow Cursor", .category = "View" }, true, followCursor, .{}),
    viewAction(OutlinePane, .registered, .{ .id = "outline.filterOnType", .title = "Filter on Type", .category = "View" }, true, filterOnType, .{}),
    viewAction(OutlinePane, .registered, .{ .id = "outline.sortByPosition", .title = "Sort By: Position", .category = "View" }, true, OutlinePane.setSortBy, .{outline.OutlineSortOrder.ByPosition}),
    viewAction(OutlinePane, .registered, .{ .id = "outline.sortByName", .title = "Sort By: Name", .category = "View" }, true, OutlinePane.setSortBy, .{outline.OutlineSortOrder.ByName}),
    viewAction(OutlinePane, .registered, .{ .id = "outline.sortByKind", .title = "Sort By: Category", .category = "View" }, true, OutlinePane.setSortBy, .{outline.OutlineSortOrder.ByKind}),
};

pub const more_actions = @import("../../../browser/parts/sidebar/sidebarPart.zig").viewMenuAction(OutlinePane.more_actions_id, "Outline More Actions", "outline");

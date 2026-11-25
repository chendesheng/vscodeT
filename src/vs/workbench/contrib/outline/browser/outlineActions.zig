// Port of the ViewTitle context-menu contributions in
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

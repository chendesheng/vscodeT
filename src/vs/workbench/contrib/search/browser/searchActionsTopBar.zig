// Port of the top-bar runners in
// `src/vs/workbench/contrib/search/browser/searchActionsTopBar.ts`.
//
// The terminal has no compressed tree nodes, so `collapseDeepestExpandedLevel`
// is represented by `collapseAll`; this is a documented terminal
// simplification. AI actions are not ported.

const tree = @import("searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const view_mod = @import("searchView.zig");
const SearchView = view_mod.SearchView;
const base = @import("searchActionsBase.zig");
const Viewer = base.Viewer;

pub fn cancelSearch(view: *SearchView) bool {
    return view.cancelSearch();
}

pub fn refreshSearch(view: *SearchView) !void {
    try view.triggerQueryChange(false, false);
}

pub fn clearSearchResults(view: *SearchView) void {
    view.clearResults(true);
}

pub fn viewAsTree(view: *SearchView) void {
    view.setTreeView(true);
}

pub fn viewAsList(view: *SearchView) void {
    view.setTreeView(false);
}

pub fn expandAll(viewer: Viewer) void {
    viewer.expand_all(viewer.context);
}

pub fn collapseAll(viewer: Viewer) void {
    viewer.collapse_all(viewer.context);
}

/// Upstream `forcedExpandRecursively` walks the tree model. The terminal
/// viewer exposes the same effect through `expand_all`.
pub fn forcedExpandRecursively(viewer: Viewer, _: ?Node) void {
    viewer.expand_all(viewer.context);
}

const TerminalSearchView = @import("searchViewTerminal.zig").SearchView;
const SearchCommandIds = @import("../common/constants.zig").SearchCommandIds;
pub const clear_search_results = base.viewAction(SearchCommandIds.clear_search_results, "Clear Search Results", .active, TerminalSearchView.commandClear, .{});
pub const open_in_editor = base.viewAction(SearchCommandIds.open_in_editor, "Open Results in Editor", .open_without_focus, TerminalSearchView.openInEditor, .{});
pub const refresh_search_results = base.viewAction(SearchCommandIds.refresh_search_results, "Refresh Search Results", .active, TerminalSearchView.commandRefresh, .{});
pub const view_as_tree = base.viewAction(SearchCommandIds.view_as_tree, "View as Tree", .active, TerminalSearchView.commandViewAsTree, .{true});
pub const view_as_list = base.viewAction(SearchCommandIds.view_as_list, "View as List", .active, TerminalSearchView.commandViewAsTree, .{false});
pub const collapse_search_results = base.viewAction(SearchCommandIds.collapse_search_results, "Collapse Search Results", .active, TerminalSearchView.commandSetExpanded, .{false});
pub const expand_search_results = base.viewAction(SearchCommandIds.expand_search_results, "Expand Search Results", .active, TerminalSearchView.commandSetExpanded, .{true});

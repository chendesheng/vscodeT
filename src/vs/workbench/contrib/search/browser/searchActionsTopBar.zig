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

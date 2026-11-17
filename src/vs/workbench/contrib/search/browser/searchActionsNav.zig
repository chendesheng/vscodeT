// Port of the navigation/input-focus runners in
// `src/vs/workbench/contrib/search/browser/searchActionsNav.ts`.
//
// The TUI owns key dispatch and command ids; these functions are the portable
// behavior behind those commands. Search-editor, accessibility and menu paths
// are not ported.

const tree = @import("searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const view_mod = @import("searchView.zig");
const SearchView = view_mod.SearchView;
const Option = view_mod.Option;

pub fn openSelected(view: *SearchView, side_by_side: bool) !void {
    const node = view.viewer.selectedNode() orelse return;
    _ = side_by_side;
    try view.openElement(node, false);
}

pub fn openElement(view: *SearchView, node: Node, side_by_side: bool) !void {
    _ = side_by_side;
    try view.openElement(node, false);
}

pub fn toggleCaseSensitive(view: *SearchView) !void {
    try view.toggleOption(.match_case);
}

pub fn toggleWholeWord(view: *SearchView) !void {
    try view.toggleOption(.whole_word);
}

pub fn toggleRegex(view: *SearchView) !void {
    try view.toggleOption(.regex);
}

pub fn togglePreserveCase(view: *SearchView) !void {
    try view.toggleOption(.preserve_case);
}

pub fn focusNextInput(view: *SearchView) void {
    view.focusNextInputBox();
}

pub fn focusPreviousInput(view: *SearchView) void {
    view.focusPreviousInputBox();
}

pub fn focusSearchList(view: *SearchView) void {
    view.focusResults();
}

pub fn focusNextResult(view: *SearchView) !void {
    try view.selectNextMatch();
}

pub fn focusPreviousResult(view: *SearchView) !void {
    try view.selectPreviousMatch();
}

pub fn toggleQueryDetails(view: *SearchView) void {
    view.toggleQueryDetails(null);
}

pub fn closeReplace(view: *SearchView) void {
    view.widget.set_replace_visible(view.widget.context, false);
    view.widget.focus(view.widget.context, .search);
}

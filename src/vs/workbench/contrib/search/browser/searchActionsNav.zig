// Port of the navigation/input-focus runners in
// `src/vs/workbench/contrib/search/browser/searchActionsNav.ts`.
//
// Search view commands are Action2 contributions. Terminal key events also
// use the view runners. Search-editor result navigation and accessibility
// announcements are outside these runners.

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

const TerminalSearchView = @import("searchViewTerminal.zig").SearchView;
const SearchCommandIds = @import("../common/constants.zig").SearchCommandIds;
const base = @import("searchActionsBase.zig");
pub const toggle_case_sensitive = base.viewAction(SearchCommandIds.toggle_case_sensitive, "Toggle Case Sensitive", .active, TerminalSearchView.commandToggle, .{.match_case});
pub const toggle_whole_word = base.viewAction(SearchCommandIds.toggle_whole_word, "Toggle Whole Word", .active, TerminalSearchView.commandToggle, .{.whole_word});
pub const toggle_regex = base.viewAction(SearchCommandIds.toggle_regex, "Toggle Regex", .active, TerminalSearchView.commandToggle, .{.regex});
pub const toggle_preserve_case = base.viewAction(SearchCommandIds.toggle_preserve_case, "Toggle Preserve Case", .active, TerminalSearchView.commandToggle, .{.preserve_case});
pub const focus_next_search_result = base.viewAction(SearchCommandIds.focus_next_search_result, "Focus Next Search Result", .open, TerminalSearchView.commandFocusNext, .{});
pub const focus_previous_search_result = base.viewAction(SearchCommandIds.focus_previous_search_result, "Focus Previous Search Result", .open, TerminalSearchView.commandFocusPrevious, .{});
pub const toggle_query_details = base.viewAction(SearchCommandIds.toggle_query_details, "Toggle Search Details", .active, TerminalSearchView.commandToggleDetails, .{});

// Port of `src/vs/workbench/contrib/search/common/constants.ts`.
//
// The terminal workbench has no context-key service or menu registry. The
// upstream ids and key names are kept so the TUI command table and action
// metadata stay aligned.

pub const SearchCommandIds = struct {
    pub const find_in_files = "workbench.action.findInFiles";
    pub const focus_active_editor = "search.action.focusActiveEditor";
    pub const focus_search_from_results = "search.action.focusSearchFromResults";
    pub const open_match = "search.action.openResult";
    pub const open_match_to_side = "search.action.openResultToSide";
    pub const remove = "search.action.remove";
    pub const copy_path = "search.action.copyPath";
    pub const copy_match = "search.action.copyMatch";
    pub const copy_all = "search.action.copyAll";
    pub const open_in_editor = "search.action.openInEditor";
    pub const clear_search_history = "search.action.clearHistory";
    pub const focus_search_list = "search.action.focusSearchList";
    pub const replace = "search.action.replace";
    pub const replace_all_in_file = "search.action.replaceAllInFile";
    pub const replace_all_in_folder = "search.action.replaceAllInFolder";
    pub const close_replace_widget = "closeReplaceInFilesWidget";
    pub const toggle_case_sensitive = "toggleSearchCaseSensitive";
    pub const toggle_whole_word = "toggleSearchWholeWord";
    pub const toggle_regex = "toggleSearchRegex";
    pub const toggle_preserve_case = "toggleSearchPreserveCase";
    pub const add_cursors_at_search_results = "addCursorsAtSearchResults";
    pub const reveal_in_sidebar = "search.action.revealInSideBar";
    pub const replace_in_files = "workbench.action.replaceInFiles";
    pub const cancel_search = "search.action.cancel";
    pub const refresh_search_results = "search.action.refreshSearchResults";
    pub const focus_next_search_result = "search.action.focusNextSearchResult";
    pub const focus_previous_search_result = "search.action.focusPreviousSearchResult";
    pub const toggle_search_on_type = "workbench.action.toggleSearchOnType";
    pub const collapse_search_results = "search.action.collapseSearchResults";
    pub const expand_search_results = "search.action.expandSearchResults";
    pub const expand_recursively = "search.action.expandRecursively";
    pub const clear_search_results = "search.action.clearSearchResults";
    pub const get_search_results = "search.action.getSearchResults";
    pub const view_as_tree = "search.action.viewAsTree";
    pub const view_as_list = "search.action.viewAsList";
    pub const toggle_query_details = "workbench.action.search.toggleQueryDetails";
    pub const exclude_folder_from_search = "search.action.excludeFromSearch";
    pub const exclude_file_type_from_search = "search.action.excludeFileTypeFromSearch";
    pub const include_file_type_in_search = "search.action.includeFileTypeInSearch";
    pub const focus_next_input = "search.focus.nextInputBox";
    pub const focus_previous_input = "search.focus.previousInputBox";
    pub const restrict_search_to_folder = "search.action.restrictSearchToFolder";
    pub const find_in_folder = "filesExplorer.findInFolder";
    pub const find_in_workspace = "filesExplorer.findInWorkspace";
};

pub const SearchContext = struct {
    pub const search_view_visible = "searchViewletVisible";
    pub const search_view_focused = "searchViewletFocus";
    pub const search_result_list_focused = "searchResultListFocused";
    pub const input_box_focused = "inputBoxFocus";
    pub const search_input_box_focused = "searchInputBoxFocus";
    pub const replace_input_box_focused = "replaceInputBoxFocus";
    pub const pattern_includes_focused = "patternIncludesInputBoxFocus";
    pub const pattern_excludes_focused = "patternExcludesInputBoxFocus";
    pub const replace_active = "replaceActive";
    pub const has_search_results = "hasSearchResult";
    pub const first_match_focus = "firstMatchFocus";
    pub const file_match_or_match_focus = "fileMatchOrMatchFocus";
    pub const file_match_or_folder_match_focus = "fileMatchOrFolderMatchFocus";
    pub const file_match_or_folder_match_with_resource_focus = "fileMatchOrFolderMatchWithResourceFocus";
    pub const file_focus = "fileMatchFocus";
    pub const folder_focus = "folderMatchFocus";
    pub const resource_folder_focus = "folderMatchWithResourceFocus";
    pub const is_editable_item = "isEditableItem";
    pub const match_focus = "matchFocus";
    pub const search_result_header_focused = "searchResultHeaderFocused";
    pub const view_has_search_pattern = "viewHasSearchPattern";
    pub const view_has_replace_pattern = "viewHasReplacePattern";
    pub const view_has_file_pattern = "viewHasFilePattern";
    pub const view_has_some_collapsible = "viewHasSomeCollapsibleResult";
    pub const in_tree_view = "inTreeView";
};

// Port of the search action registrations in `src/vs/workbench/contrib/search/browser/search.contribution.ts`.
// The terminal registers these groups in its existing command-palette order.
const base = @import("searchActionsBase.zig");
const nav = @import("searchActionsNav.zig");
const replace = @import("searchActionsRemoveReplace.zig");
const toolbar = @import("searchActionsTopBar.zig");

pub const search_actions = [_]@import("../../../../platform/actions/common/actions.zig").Action2{
    base.find_in_files,
    base.replace_in_files,
    nav.toggle_case_sensitive,
    nav.toggle_whole_word,
    nav.toggle_regex,
    nav.toggle_preserve_case,
    nav.focus_next_search_result,
    nav.focus_previous_search_result,
    replace.remove,
    replace.replace,
    replace.replace_all_in_file,
    replace.replace_all_in_folder,
    toolbar.clear_search_results,
};

pub const result_actions = [_]@import("../../../../platform/actions/common/actions.zig").Action2{
    toolbar.open_in_editor,
    toolbar.refresh_search_results,
    toolbar.view_as_tree,
    toolbar.view_as_list,
    toolbar.collapse_search_results,
    toolbar.expand_search_results,
    nav.toggle_query_details,
};

// "search" is the native activity alias for the upstream VIEWLET_ID.
pub fn registerViewContainer(registry: *@import("../../../common/views.zig").ViewContainersRegistry) !void {
    _ = try registry.register(.{
        .id = "search",
        .title = "Search",
        .glyph = '\u{f002}',
        .order = 1,
    }, .sidebar, .{});
}

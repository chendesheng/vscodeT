// Port of the portable helpers in
// `src/vs/workbench/contrib/search/browser/searchActionsBase.ts`.
//
// Command palette labels follow the terminal port. Actions resolve the active
// Search view or open it according to the upstream command.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const search = @import("../../../services/search/common/search.zig");
const SearchSortOrder = search.SearchSortOrder;
const compare = @import("searchCompare.zig");

/// View over the terminal's flattened search rows. The TUI implements this; a
/// test can implement the same shape over an array.
pub const Viewer = struct {
    context: *anyopaque,
    row_count: *const fn (context: *anyopaque) usize,
    row_at: *const fn (context: *anyopaque, index: usize) ?Node,
    index_of: *const fn (context: *anyopaque, node: Node) ?usize,
    last_visible: *const fn (context: *anyopaque) ?Node,
    is_collapsed: *const fn (context: *anyopaque, node: Node) bool,
    expand: *const fn (context: *anyopaque, node: Node, recursive: bool) bool,
    collapse: *const fn (context: *anyopaque, node: Node, recursive: bool) bool,
    collapse_all: *const fn (context: *anyopaque) void,
    expand_all: *const fn (context: *anyopaque) void,
    selected: *const fn (context: *anyopaque) ?Node,
    set_selected: *const fn (context: *anyopaque, node: ?Node) void,
    focus: *const fn (context: *anyopaque) void,
    refresh: *const fn (context: *anyopaque) void,

    pub fn count(self: Viewer) usize {
        return self.row_count(self.context);
    }

    pub fn at(self: Viewer, index: usize) ?Node {
        return self.row_at(self.context, index);
    }

    pub fn indexOf(self: Viewer, node: Node) ?usize {
        return self.index_of(self.context, node);
    }

    pub fn last(self: Viewer) ?Node {
        return self.last_visible(self.context);
    }

    pub fn isCollapsed(self: Viewer, node: Node) bool {
        return self.is_collapsed(self.context, node);
    }

    pub fn expandNode(self: Viewer, node: Node, recursive: bool) bool {
        return self.expand(self.context, node, recursive);
    }

    pub fn collapseNode(self: Viewer, node: Node, recursive: bool) bool {
        return self.collapse(self.context, node, recursive);
    }

    pub fn selectedNode(self: Viewer) ?Node {
        return self.selected(self.context);
    }

    pub fn select(self: Viewer, node: ?Node) void {
        self.set_selected(self.context, node);
    }

    pub fn focusView(self: Viewer) void {
        self.focus(self.context);
    }

    pub fn refreshView(self: Viewer) void {
        self.refresh(self.context);
    }
};

/// Port of upstream `ITreeNavigator` over the visible rows.
pub const Navigator = struct {
    viewer: Viewer,
    index: isize,

    pub fn current(self: Navigator) ?Node {
        if (self.index < 0) return null;
        return self.viewer.at(@intCast(self.index));
    }

    pub fn first(self: *Navigator) ?Node {
        self.index = 0;
        return self.current();
    }

    pub fn last(self: *Navigator) ?Node {
        self.index = @as(isize, @intCast(self.viewer.count())) - 1;
        return self.current();
    }

    pub fn next(self: *Navigator) ?Node {
        self.index += 1;
        return self.current();
    }

    pub fn previous(self: *Navigator) ?Node {
        self.index -= 1;
        return self.current();
    }
};

pub fn navigate(viewer: Viewer, start: ?Node) Navigator {
    if (start) |node| {
        if (viewer.indexOf(node)) |index| {
            return .{ .viewer = viewer, .index = @intCast(index) };
        }
    }
    return .{ .viewer = viewer, .index = -1 };
}

/// Port of `getElementsToOperateOn`. The terminal tree has a single selected
/// row, but the multi-selection shape is kept so a future terminal
/// multi-selection can plug in without changing the runners.
pub fn getElementsToOperateOn(
    allocator: Allocator,
    viewer: Viewer,
    current_element: ?Node,
    sort_order: SearchSortOrder,
) ![]Node {
    var elements = std.array_list.Managed(Node).init(allocator);
    errdefer elements.deinit();
    if (viewer.selectedNode()) |selected| {
        try elements.append(selected);
    }
    if (current_element) |current| {
        var contains = false;
        for (elements.items) |element| {
            if (tree.nodeEql(element, current)) {
                contains = true;
                break;
            }
        }
        if (!contains) {
            elements.clearRetainingCapacity();
            try elements.append(current);
        }
    }
    std.sort.heap(Node, elements.items, sort_order, nodeLessThan);
    return try elements.toOwnedSlice();
}

/// Port of `shouldRefocus`.
pub fn shouldRefocus(elements: []const Node, focus_element: ?Node) bool {
    const focus = focus_element orelse return false;
    for (elements) |element| {
        if (tree.nodeEql(element, focus)) return true;
        if (hasDownstreamMatch(element, focus)) return true;
    }
    return false;
}

pub fn hasDownstreamMatch(element: Node, focus_element: Node) bool {
    if (element == .file and focus_element == .match) {
        const file = element.file;
        for (file.matches()) |match| {
            if (focus_element.match == match) return true;
        }
    }
    if (element == .folder) {
        const folder = element.folder;
        switch (focus_element) {
            .file => |file| if (folder.getDownstreamFileMatch(file.path) != null) return true,
            .match => |match| if (folder.getDownstreamFileMatch(match.parent_file.path) != null) return true,
            else => {},
        }
    }
    return false;
}

/// Port of `arrayContainsElementOrParent`.
pub fn arrayContainsElementOrParent(element: Node, elements: []const Node) bool {
    var current: ?Node = element;
    while (current) |node| {
        for (elements) |candidate| {
            if (tree.nodeEql(candidate, node)) return true;
        }
        current = tree.nodeParent(node);
    }
    return false;
}

/// Upstream `IFindInFilesArgs`. The TUI currently exposes only the direct
/// find/replace commands; the struct keeps the command argument shape for a
/// later wiring pass.
pub const IFindInFilesArgs = struct {
    query: ?[]const u8 = null,
    replace: ?[]const u8 = null,
    preserve_case: ?bool = null,
    trigger_search: bool = true,
    files_to_include: ?[]const u8 = null,
    files_to_exclude: ?[]const u8 = null,
    is_regex: ?bool = null,
    is_case_sensitive: ?bool = null,
    match_whole_word: ?bool = null,
    use_exclude_settings_and_ignore_files: ?bool = null,
    only_open_editors: ?bool = null,
    show_includes_excludes: bool = false,
};

fn nodeLessThan(sort_order: SearchSortOrder, a: Node, b: Node) bool {
    return compare.searchComparer(a, b, sort_order) < 0;
}

const actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const views_service = @import("../../../services/views/common/viewsService.zig");
const IViewsService = views_service.IViewsService;
const SearchView = @import("searchViewTerminal.zig").SearchView;

pub fn getSearchView(views: IViewsService) ?*SearchView {
    return views.getActiveViewWithId(SearchView);
}

pub fn openSearchView(views: IViewsService, focus: bool) !?*SearchView {
    return views.openView(SearchView, focus);
}

pub const ViewLookup = enum { open, open_without_focus, active };

/// Binds a search action to its live view through the scoped services accessor.
/// Compile-time arguments express the fixed option of each upstream subclass.
pub fn viewAction(
    comptime id: []const u8,
    comptime title: []const u8,
    comptime lookup: ViewLookup,
    comptime run: anytype,
    comptime args: anytype,
) actions.Action2 {
    return .{
        .command = .{ .id = id, .title = title, .category = "Search" },
        .f1 = true,
        .context = @constCast(&{}),
        .run_fn = struct {
            fn invoke(_: *anyopaque, accessor: ServicesAccessor) anyerror!void {
                const views = (try accessor.get(views_service.views_service_id)).*;
                const view = (if (lookup == .active) getSearchView(views) else try openSearchView(views, lookup == .open)) orelse return;
                const result = @call(.auto, run, .{view} ++ args);
                if (@typeInfo(@TypeOf(result)) == .error_union) try result;
            }
        }.invoke,
    };
}

pub fn findInFiles(view: *SearchView) !void {
    try view.seedFromSelection();
    view.focus();
}

pub fn replaceInFiles(view: *SearchView) void {
    view.focusReplace();
}

const SearchCommandIds = @import("../common/constants.zig").SearchCommandIds;
pub const find_in_files = viewAction(SearchCommandIds.find_in_files, "Find in Files", .open, findInFiles, .{});
pub const replace_in_files = viewAction(SearchCommandIds.replace_in_files, "Replace in Files", .open, replaceInFiles, .{});

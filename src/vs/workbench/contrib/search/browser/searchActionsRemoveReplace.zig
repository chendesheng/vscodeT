// Port of the focus helpers and removal runner in
// `src/vs/workbench/contrib/search/browser/searchActionsRemoveReplace.ts`.
//
// The full replace runners depend on the view controller and replacement
// service; they are added below the helpers once the controller is wired.
// Notebook/AI actions are not ported.

const std = @import("std");
const tree = @import("searchTreeModel/searchTreeCommon.zig");
const Node = tree.Node;
const SearchResult = tree.SearchResult;
const compare = @import("searchCompare.zig");
const base = @import("searchActionsBase.zig");
const Viewer = base.Viewer;
const Navigator = base.Navigator;

/// Returns the element that should receive focus after `element` and the
/// elements in `elements_to_remove` are removed.
pub fn getElementToFocusAfterRemoved(
    viewer: Viewer,
    element: Node,
    elements_to_remove: []const Node,
) ?Node {
    var navigator = base.navigate(viewer, element);
    if (element == .folder) {
        while (navigator.next()) |candidate| {
            if (candidate != .folder) continue;
            if (base.arrayContainsElementOrParent(candidate, elements_to_remove)) continue;
            return candidate;
        }
    } else if (element == .file) {
        while (navigator.next()) |candidate| {
            if (candidate != .file) continue;
            if (base.arrayContainsElementOrParent(candidate, elements_to_remove)) continue;
            return candidate;
        }
    } else {
        while (navigator.next()) |candidate| {
            if (candidate != .match) continue;
            if (base.arrayContainsElementOrParent(candidate, elements_to_remove)) continue;
            return candidate;
        }
    }
    return navigator.current();
}

/// Finds the last visible element in the tree with the same type as `element`.
pub fn getLastNodeFromSameType(viewer: Viewer, element: Node) ?Node {
    var last = viewer.last() orelse return null;
    while (true) {
        const level = compare.compareLevels(element, last);
        if (level == -1) {
            if (!viewer.expandNode(last, false)) return last;
            last = viewer.last() orelse return null;
        } else if (level == 1) {
            const parent = tree.nodeParent(last) orelse break;
            if (parent == .heading) break;
            last = parent;
        } else {
            return last;
        }
    }
    return null;
}

/// Dismisses one element and restores focus like upstream `RemoveAction`.
pub fn removeElement(
    allocator: std.mem.Allocator,
    viewer: Viewer,
    result: *SearchResult,
    element: Node,
) !void {
    const elements = try allocator.alloc(Node, 1);
    defer allocator.free(elements);
    elements[0] = element;

    const focus_element = viewer.selectedNode() orelse element;
    const refocus = base.shouldRefocus(elements, focus_element);
    const next = if (refocus)
        getElementToFocusAfterRemoved(viewer, focus_element, elements)
    else
        null;

    result.batchRemove(elements);
    viewer.refreshView();

    if (refocus) {
        var target = next;
        if (target == null) target = getLastNodeFromSameType(viewer, focus_element);
        if (target) |node| {
            viewer.select(node);
        }
    }
    viewer.focusView();
}

const SearchView = @import("searchViewTerminal.zig").SearchView;
const base_actions = @import("searchActionsBase.zig");

const SearchCommandIds = @import("../common/constants.zig").SearchCommandIds;
pub const remove = base_actions.viewAction(SearchCommandIds.remove, "Dismiss Search Result", .active, SearchView.commandRemove, .{});
pub const replace = base_actions.viewAction(SearchCommandIds.replace, "Replace", .active, SearchView.commandReplace, .{});
pub const replace_all_in_file = base_actions.viewAction(SearchCommandIds.replace_all_in_file, "Replace All in File", .active, SearchView.commandReplace, .{});
pub const replace_all_in_folder = base_actions.viewAction(SearchCommandIds.replace_all_in_folder, "Replace All in Folder", .active, SearchView.commandReplace, .{});

// Port of registerEditorMoveCopyCommand from
// src/vs/workbench/browser/parts/editor/editorCommands.ts.
// The terminal has no separate auxiliary-window groups; tab and group
// movement use the mounted EditorGroupView and its model/transfer contracts.
const std = @import("std");
const Tab = @import("editorPane.zig").Tab;
const GroupView = @import("editorGroupView.zig").EditorGroupView(*Tab);
const GroupActions = @import("editorActions.zig").GroupActions;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;

const MoveTo = enum { first, last, left, right, up, down, center, position, previous, next };

/// moveCopySelectedEditors: upstream argument defaults and selected-editor
/// ordering. This entry point backs moveActiveEditor from the extension API.
pub fn moveActiveEditor(groups: *GroupActions, to_arg: []const u8, by_arg: []const u8, value: usize) !void {
    const to = if (to_arg.len == 0) .right else std.meta.stringToEnum(MoveTo, to_arg) orelse return;
    const source = groups.part.activeView() orelse return;
    const selected = try source.group.model.selectedEditors(groups.part.allocator);
    defer groups.part.allocator.free(selected);
    if (selected.len == 0) return;
    if (by_arg.len == 0 or std.mem.eql(u8, by_arg, "tab")) {
        try moveTabs(source, selected, to, value);
        groups.transfer.layout(groups.transfer.copy.context);
    } else if (std.mem.eql(u8, by_arg, "group")) {
        try moveEditorsToGroup(groups, source, selected, to, value);
    }
}

fn moveTabs(group: *GroupView, editors: []*EditorInput, to: MoveTo, value: usize) !void {
    const first_index = group.group.model.indexOf(.{ .input = editors[0] }) orelse return;
    if (to == .first or to == .right or (to == .position and value < first_index))
        std.mem.reverse(*EditorInput, editors);
    for (editors) |input| try moveTab(group, input, to, value);
    group.syncActivePane();
}

fn moveTab(group: *GroupView, input: *EditorInput, to: MoveTo, value: usize) !void {
    const count = group.group.model.count();
    if (count == 0) return;
    const index = group.group.model.indexOf(.{ .input = input }) orelse return;
    const next = switch (to) {
        .first => 0,
        .last => count - 1,
        .left => index -| value,
        .right => @min(index +| value, count - 1),
        .center => (count + 1) / 2 - 1, // Math.round(count / 2) - 1
        .position => @min(value -| 1, count - 1),
        else => index,
    };
    _ = try group.group.model.moveEditor(input, @intCast(next));
}

fn moveEditorsToGroup(groups: *GroupActions, source: *GroupView, editors: []*EditorInput, to: MoveTo, value: usize) !void {
    const target: *GroupView = switch (to) {
        .center, .position => blk: {
            const ordered = try groups.part.orderedViews(groups.part.allocator);
            defer groups.part.allocator.free(ordered);
            const position = if (to == .center) @divFloor(ordered.len, 2) else value;
            if (to == .center and ordered.len % 2 != 0) return;
            if (position == 0 or position > ordered.len) return;
            break :blk ordered[position - 1];
        },
        else => try groups.resolveGroupTarget(source, std.meta.stringToEnum(GroupActions.GroupTarget, @tagName(to)) orelse return, true) orelse return,
    };
    if (target == source) {
        target.focus();
        return;
    }
    // prepareMoveCopyEditors: active selected editor first, then inactive
    // editors in inverse visual order. Opening inactive tabs to its right
    // preserves their original visual ordering.
    const active = source.group.model.activeEditor() orelse editors[0];
    const active_selected = if (std.mem.indexOfScalar(*EditorInput, editors, active) != null) active else editors[0];
    const moved_active = try moveOne(groups, source, target, active_selected, true);
    var index = editors.len;
    while (index > 0) {
        index -= 1;
        if (editors[index] == active_selected) continue;
        _ = try moveOne(groups, source, target, editors[index], false);
    }
    if (source.tabs.items.len == 0) groups.part.collapseGroup(source, groups.transfer);
    if (moved_active) |tab| try target.activateTab(tab);
    target.focus();
}

fn moveOne(groups: *GroupActions, source: *GroupView, target: *GroupView, input: *EditorInput, active: bool) !?*Tab {
    const tab = source.tabForInput(input) orelse return null;
    return try source.moveEditor(target, tab, .{
        .pinned = true,
        .sticky = source.group.model.isSticky(.{ .editor = input }),
        .active = active,
    }, groups.transfer.move);
}

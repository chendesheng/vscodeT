// Port of `src/vs/workbench/services/editor/common/editorGroupColumn.ts`.
// The grid-order group service is the terminal equivalent of GRID_APPEARANCE.
const std = @import("std");
const groups = @import("editorGroupsService.zig");

pub const ACTIVE_GROUP: i64 = -1;
pub const SIDE_GROUP: i64 = -2;
pub const AUX_WINDOW_GROUP: i64 = -3;
pub const MODAL_GROUP: i64 = -4;
pub const max_columns: usize = 9;

pub fn columnToEditorGroup(service: groups.IEditorGroupsService, allocator: std.mem.Allocator, direction: groups.GroupDirection, column: i64) !i64 {
    // These special target identifiers are returned to the caller unchanged.
    if (column == ACTIVE_GROUP or column == SIDE_GROUP or column == AUX_WINDOW_GROUP or column == MODAL_GROUP) return column;
    if (column < 0) return SIDE_GROUP;
    const index = std.math.cast(usize, column) orelse return SIDE_GROUP;
    var ordered = try service.getGroupsInGridOrder(allocator);
    defer allocator.free(ordered);
    if (index < ordered.len) return ordered[index].id;
    if (index >= max_columns or ordered.len == 0) return SIDE_GROUP;
    while (index >= ordered.len) {
        _ = try service.addGroup(ordered[ordered.len - 1], direction);
        const next = try service.getGroupsInGridOrder(allocator);
        allocator.free(ordered);
        ordered = next;
    }
    return ordered[index].id;
}

pub fn editorGroupToColumn(service: groups.IEditorGroupsService, allocator: std.mem.Allocator, group_id: u32) !?usize {
    const ordered = try service.getGroupsInGridOrder(allocator);
    defer allocator.free(ordered);
    for (ordered, 0..) |group, column| if (group.id == group_id) return column;
    return null;
}

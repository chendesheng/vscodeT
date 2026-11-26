// Port of `src/vs/workbench/contrib/accessibility/browser/accessibleViewKeybindingResolver.ts`.
const std = @import("std");
pub const Lookup = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]const u8,
};

pub fn resolveContent(allocator: std.mem.Allocator, value: []const u8, lookup: Lookup) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const marker = "<keybinding:";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, value, cursor, marker)) |start| {
        const end = std.mem.indexOfScalarPos(u8, value, start + marker.len, '>') orelse break;
        try result.appendSlice(allocator, value[cursor..start]);
        const id = value[start + marker.len .. end];
        const label = try lookup.get(lookup.context, arena.allocator(), id) orelse "unassigned keybinding";
        try result.appendSlice(allocator, " (");
        try result.appendSlice(allocator, label);
        try result.append(allocator, ')');
        cursor = end + 1;
    }
    try result.appendSlice(allocator, value[cursor..]);
    return result.toOwnedSlice(allocator);
}

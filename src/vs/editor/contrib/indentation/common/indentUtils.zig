// Port of `src/vs/editor/contrib/indentation/common/indentUtils.ts`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

pub fn getSpaceCnt(text: []const u8, tab_size: usize) usize {
    var spaces_cnt: usize = 0;
    for (text) |ch| {
        if (ch == '\t') {
            spaces_cnt += tab_size;
        } else {
            spaces_cnt += 1;
        }
    }
    return spaces_cnt;
}

pub fn generateIndent(allocator: Allocator, spaces_cnt_: usize, tab_size: usize, insert_spaces: bool) ![]u8 {
    var spaces_cnt = spaces_cnt_;
    var result = ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (!insert_spaces) {
        const tabs_cnt = spaces_cnt / tab_size;
        spaces_cnt = spaces_cnt % tab_size;
        for (0..tabs_cnt) |_| try result.append('\t');
    }
    try result.appendNTimes(' ', spaces_cnt);
    return try result.toOwnedSlice();
}

test "indentUtils: counts and generates indentation" {
    try std.testing.expectEqual(@as(usize, 6), getSpaceCnt("  \t", 4));
    try std.testing.expectEqual(@as(usize, 2), getSpaceCnt("ab", 4));

    const spaces = try generateIndent(std.testing.allocator, 6, 4, true);
    defer std.testing.allocator.free(spaces);
    try std.testing.expectEqualStrings("      ", spaces);

    const tabs = try generateIndent(std.testing.allocator, 6, 4, false);
    defer std.testing.allocator.free(tabs);
    try std.testing.expectEqualStrings("\t  ", tabs);
}

//! Shared terminal cell width measurement for `ui.Surface` builders.

const std = @import("std");
const ui = @import("ui");
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;

pub fn measureCodepoint(cp: u21) u2 {
    const next = CursorColumns.nextVisibleColumn(cp, 0, 1);
    return @intCast(@min(next, 2));
}

test "cellMetrics: ASCII and wide glyphs" {
    try std.testing.expectEqual(@as(u2, 1), measureCodepoint('a'));
    try std.testing.expectEqual(@as(u2, 2), measureCodepoint(0x4e2d));
}

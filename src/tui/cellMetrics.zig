//! Shared terminal cell width measurement for `ui.Surface` builders.

const std = @import("std");
const CursorColumns = @import("../vs/editor/common/core/cursorColumns.zig").CursorColumns;

pub const measureCodepoint = CursorColumns.measureCodepoint;

test "cellMetrics: ASCII and wide glyphs" {
    try std.testing.expectEqual(@as(u2, 1), measureCodepoint('a'));
    try std.testing.expectEqual(@as(u2, 2), measureCodepoint(0x4e2d));
}

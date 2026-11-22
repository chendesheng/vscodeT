// Port of `src/vs/editor/common/model/utils.ts`.
const std = @import("std");

/// Returns:
///  - -1 => the line consists of whitespace
///  - otherwise => the indent level is returned value
pub fn computeIndentLevel(line: []const u8, tabSize: usize) isize {
    var indent: usize = 0;
    var i: usize = 0;
    const len = line.len;

    while (i < len) {
        const ch = line[i];
        if (ch == ' ') {
            indent += 1;
        } else if (ch == '\t') {
            indent = indent - @mod(indent, tabSize) + tabSize;
        } else {
            break;
        }
        i += 1;
    }

    if (i == len) {
        return -1; // line only consists of whitespace
    }

    return @intCast(indent);
}

test "modelUtils: computeIndentLevel" {
    try std.testing.expectEqual(@as(isize, 0), computeIndentLevel("abc", 4));
    try std.testing.expectEqual(@as(isize, 2), computeIndentLevel("  abc", 4));
    try std.testing.expectEqual(@as(isize, 4), computeIndentLevel("\tabc", 4));
    try std.testing.expectEqual(@as(isize, 8), computeIndentLevel("\t\tabc", 4));
    try std.testing.expectEqual(@as(isize, 4), computeIndentLevel("  \tabc", 4));
    try std.testing.expectEqual(@as(isize, 6), computeIndentLevel("\t  abc", 4));
    try std.testing.expectEqual(@as(isize, -1), computeIndentLevel("", 4));
    try std.testing.expectEqual(@as(isize, -1), computeIndentLevel(" \t ", 4));
}

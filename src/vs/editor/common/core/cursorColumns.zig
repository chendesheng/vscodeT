const std = @import("std");

/// A column in a position is the gap between two adjacent characters. These
/// helpers work with a "visible column": a rough approximation of the screen
/// position of a column.
pub const CursorColumns = struct {
    pub fn nextVisibleColumn(codePoint: u21, visibleColumn: usize, tabSize: usize) usize {
        if (codePoint == '\t') return nextRenderTabStop(visibleColumn, tabSize);
        if (isFullWidthCharacter(codePoint) or isEmojiImprecise(codePoint)) return visibleColumn + 2;
        return visibleColumn + 1;
    }

    pub fn visibleColumnFromColumn(lineContent: []const u8, column: usize, tabSize: usize) usize {
        const textLen = @min(column -| 1, lineContent.len);
        var result: usize = 0;
        var offset: usize = 0;
        while (offset < textLen) {
            const decoded = decodeAt(lineContent, offset);
            const next_offset = @min(offset + decoded.len, textLen);
            if (next_offset == offset) break;
            result = nextVisibleColumn(decoded.code_point, result, tabSize);
            offset = next_offset;
        }
        return result;
    }

    /// Returns the value to display as "Col" in the status bar.
    pub fn toStatusbarColumn(lineContent: []const u8, column: usize, tabSize: usize) usize {
        const textLen = @min(column -| 1, lineContent.len);
        var result: usize = 0;
        var offset: usize = 0;
        while (offset < textLen) {
            const decoded = decodeAt(lineContent, offset);
            if (decoded.code_point == '\t') {
                result = nextRenderTabStop(result, tabSize);
            } else {
                result += 1;
            }
            offset = @min(offset + decoded.len, textLen);
        }
        return result + 1;
    }

    pub fn columnFromVisibleColumn(lineContent: []const u8, visibleColumn: usize, tabSize: usize) usize {
        if (visibleColumn == 0) return 1;

        var beforeVisibleColumn: usize = 0;
        var beforeColumn: usize = 1;
        var offset: usize = 0;
        while (offset < lineContent.len) {
            const decoded = decodeAt(lineContent, offset);
            const afterVisibleColumn = nextVisibleColumn(decoded.code_point, beforeVisibleColumn, tabSize);
            const afterColumn = offset + decoded.len + 1;

            if (afterVisibleColumn >= visibleColumn) {
                const beforeDelta = visibleColumn - beforeVisibleColumn;
                const afterDelta = afterVisibleColumn - visibleColumn;
                return if (afterDelta < beforeDelta) afterColumn else beforeColumn;
            }

            beforeVisibleColumn = afterVisibleColumn;
            beforeColumn = afterColumn;
            offset += decoded.len;
        }

        return lineContent.len + 1;
    }

    pub fn nextRenderTabStop(visibleColumn: usize, tabSize: usize) usize {
        return visibleColumn + tabSize - visibleColumn % tabSize;
    }

    pub fn nextIndentTabStop(visibleColumn: usize, indentSize: usize) usize {
        return nextRenderTabStop(visibleColumn, indentSize);
    }

    pub fn prevRenderTabStop(column: usize, tabSize: usize) usize {
        return if (column == 0) 0 else column - 1 - (column - 1) % tabSize;
    }

    pub fn prevIndentTabStop(column: usize, indentSize: usize) usize {
        return prevRenderTabStop(column, indentSize);
    }
};

const Decoded = struct { code_point: u21, len: usize };

fn decodeAt(text: []const u8, offset: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return .{ .code_point = text[offset], .len = 1 };
    if (offset + len > text.len) return .{ .code_point = text[offset], .len = 1 };
    const code_point = std.unicode.utf8Decode(text[offset .. offset + len]) catch return .{ .code_point = text[offset], .len = 1 };
    return .{ .code_point = code_point, .len = len };
}

fn inRange(c: u21, start: u21, end: u21) bool {
    return c >= start and c <= end;
}

fn isFullWidthCharacter(c: u21) bool {
    return inRange(c, 0x1100, 0x115F) or
        inRange(c, 0x2E80, 0x303E) or
        inRange(c, 0x3041, 0x33FF) or
        inRange(c, 0x3400, 0x4DBF) or
        inRange(c, 0x4E00, 0x9FFF) or
        inRange(c, 0xA000, 0xA4CF) or
        inRange(c, 0xAC00, 0xD7A3) or
        inRange(c, 0xF900, 0xFAFF) or
        inRange(c, 0xFE10, 0xFE19) or
        inRange(c, 0xFE30, 0xFE6F) or
        inRange(c, 0xFF00, 0xFF60) or
        inRange(c, 0xFFE0, 0xFFE6) or
        inRange(c, 0x1F300, 0x1F64F) or
        inRange(c, 0x1F900, 0x1F9FF) or
        inRange(c, 0x20000, 0x3FFFD);
}

fn isEmojiImprecise(c: u21) bool {
    return inRange(c, 0x1F000, 0x1FAFF) or
        inRange(c, 0x2600, 0x27BF) or
        inRange(c, 0x2B00, 0x2BFF);
}

test "cursorColumns: tab stops" {
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.nextRenderTabStop(0, 4));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.nextRenderTabStop(3, 4));
    try std.testing.expectEqual(@as(usize, 8), CursorColumns.nextRenderTabStop(4, 4));
    try std.testing.expectEqual(@as(usize, 0), CursorColumns.prevRenderTabStop(0, 4));
    try std.testing.expectEqual(@as(usize, 0), CursorColumns.prevRenderTabStop(4, 4));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.prevRenderTabStop(5, 4));
}

test "cursorColumns: visible and statusbar columns" {
    try std.testing.expectEqual(@as(usize, 0), CursorColumns.visibleColumnFromColumn("\t\tvar x = 3;", 1, 4));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.visibleColumnFromColumn("\t\tvar x = 3;", 2, 4));
    try std.testing.expectEqual(@as(usize, 8), CursorColumns.visibleColumnFromColumn("\t\tvar x = 3;", 3, 4));
    try std.testing.expectEqual(@as(usize, 9), CursorColumns.visibleColumnFromColumn("\t\tvar x = 3;", 4, 4));
    try std.testing.expectEqual(@as(usize, 5), CursorColumns.toStatusbarColumn("\ttab", 2, 4));
    try std.testing.expectEqual(@as(usize, 2), CursorColumns.toStatusbarColumn("何何", 4, 4));
    try std.testing.expectEqual(@as(usize, 2), CursorColumns.visibleColumnFromColumn("何何", 4, 4));
    try std.testing.expectEqual(@as(usize, 2), CursorColumns.visibleColumnFromColumn("📚az", 5, 4));
    try std.testing.expectEqual(@as(usize, 3), CursorColumns.visibleColumnFromColumn("📚az", 6, 4));
}

test "cursorColumns: column from visible column" {
    try std.testing.expectEqual(@as(usize, 1), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 0, 4));
    try std.testing.expectEqual(@as(usize, 2), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 3, 4));
    try std.testing.expectEqual(@as(usize, 3), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 7, 4));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 9, 4));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.columnFromVisibleColumn("baz", 3, 4));
    try std.testing.expectEqual(@as(usize, 5), CursorColumns.columnFromVisibleColumn("📚az", 2, 4));
}

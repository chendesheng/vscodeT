// Port of `src/vs/editor/common/core/cursorColumns.ts`.
const std = @import("std");
const strings = @import("../../../base/common/strings.zig");
const grapheme = @import("../../../base/common/graphemeBreak.zig");

/// A column in a position is the gap between two adjacent characters. These
/// helpers work with a "visible column": a rough approximation of the screen
/// position of a column.
pub const CursorColumns = struct {
    pub fn nextVisibleColumn(codePoint: u21, visibleColumn: usize, tabSize: usize) usize {
        if (codePoint == '\t') return nextRenderTabStop(visibleColumn, tabSize);
        if (strings.isFullWidthCharacter(codePoint) or isEmojiImprecise(codePoint)) return visibleColumn + 2;
        return visibleColumn + 1;
    }

    pub fn visibleColumnFromColumn(lineContent: []const u8, column: usize, tabSize: usize) usize {
        const textLen = @min(column -| 1, lineContent.len);
        const text = lineContent[0..textLen];

        var result: usize = 0;
        var iterator = grapheme.GraphemeIterator.init(text);
        while (!iterator.eol()) {
            const decoded = grapheme.nextCodePoint(text, iterator.offset);
            _ = iterator.nextGraphemeLength();
            result = nextVisibleColumn(decoded.code_point, result, tabSize);
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
        return columnFromVisibleColumnFrom(lineContent, visibleColumn, tabSize, 0);
    }

    /// `columnFromVisibleColumn` for content that begins at a non-zero visible
    /// column, as a wrapped continuation line does: tab stops are resolved
    /// against the line's absolute columns, not against zero.
    pub fn columnFromVisibleColumnFrom(
        lineContent: []const u8,
        visibleColumn: usize,
        tabSize: usize,
        startVisibleColumn: usize,
    ) usize {
        if (visibleColumn <= startVisibleColumn) return 1;

        var beforeVisibleColumn = startVisibleColumn;
        var beforeColumn: usize = 1;
        var iterator = grapheme.GraphemeIterator.init(lineContent);
        while (!iterator.eol()) {
            const decoded = grapheme.nextCodePoint(lineContent, iterator.offset);
            const afterVisibleColumn = nextVisibleColumn(decoded.code_point, beforeVisibleColumn, tabSize);
            _ = iterator.nextGraphemeLength();
            const afterColumn = iterator.offset + 1;

            if (afterVisibleColumn >= visibleColumn) {
                const beforeDelta = visibleColumn - beforeVisibleColumn;
                const afterDelta = afterVisibleColumn - visibleColumn;
                return if (afterDelta < beforeDelta) afterColumn else beforeColumn;
            }

            beforeVisibleColumn = afterVisibleColumn;
            beforeColumn = afterColumn;
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

fn isEmojiImprecise(c: u21) bool {
    return (c >= 0x1F1E6 and c <= 0x1F1FF) or
        c == 0x231A or c == 0x231B or c == 0x23F0 or c == 0x23F3 or
        (c >= 0x2600 and c <= 0x27BF) or
        c == 0x2B50 or c == 0x2B55 or
        (c >= 0x1F300 and c <= 0x1F5FF) or
        (c >= 0x1F680 and c <= 0x1F8FC) or
        (c >= 0x1F7E0 and c <= 0x1F7F0) or
        (c >= 0x1F900 and c <= 0x1F9FF) or
        (c >= 0x1FA70 and c <= 0x1FAF6);
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
    // A combining sequence is one grapheme (one visible column).
    try std.testing.expectEqual(@as(usize, 1), CursorColumns.visibleColumnFromColumn("e\u{0301}x", 4, 4));
    // A ZWJ emoji sequence is one grapheme (two visible columns).
    try std.testing.expectEqual(@as(usize, 2), CursorColumns.visibleColumnFromColumn("👨‍👩‍👧a", 19, 4));
}

test "cursorColumns: column from visible column" {
    try std.testing.expectEqual(@as(usize, 1), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 0, 4));
    try std.testing.expectEqual(@as(usize, 2), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 3, 4));
    try std.testing.expectEqual(@as(usize, 3), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 7, 4));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.columnFromVisibleColumn("\t\tvar x = 3;", 9, 4));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.columnFromVisibleColumn("baz", 3, 4));
    try std.testing.expectEqual(@as(usize, 5), CursorColumns.columnFromVisibleColumn("📚az", 2, 4));
}

test "cursorColumns: column from visible column at a wrapped start" {
    // A continuation line's tab stops are absolute: the tab at visible 4
    // reaches 8, not 4-from-zero.
    try std.testing.expectEqual(@as(usize, 1), CursorColumns.columnFromVisibleColumnFrom("\tx", 6, 4, 4));
    try std.testing.expectEqual(@as(usize, 2), CursorColumns.columnFromVisibleColumnFrom("\tx", 7, 4, 4));
    try std.testing.expectEqual(@as(usize, 3), CursorColumns.columnFromVisibleColumnFrom("\tx", 9, 4, 4));
    try std.testing.expectEqual(@as(usize, 1), CursorColumns.columnFromVisibleColumnFrom("何z", 2, 4, 2));
    try std.testing.expectEqual(@as(usize, 4), CursorColumns.columnFromVisibleColumnFrom("何z", 4, 4, 2));
    try std.testing.expectEqual(@as(usize, 1), CursorColumns.columnFromVisibleColumnFrom("abc", 2, 4, 5));
}

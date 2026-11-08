const std = @import("std");
const CursorColumns = @import("../core/cursorColumns.zig").CursorColumns;

pub const Direction = enum {
    Left,
    Right,
    Nearest,
};

pub const WhitespaceColumn = struct {
    prev_tab_stop_position: isize,
    prev_tab_stop_visible_column: isize,
    visible_column: isize,
};

pub const AtomicTabMoveOperations = struct {
    /// Get the visible column at the position. If we get to a non-whitespace
    /// character first or past the end of string then return -1.
    /// Positions and return values are 0-based.
    pub fn whitespaceVisibleColumn(lineContent: []const u8, position: usize, tabSize: usize) WhitespaceColumn {
        const lineLength = lineContent.len;
        var visibleColumn: usize = 0;
        var prevTabStopPosition: isize = -1;
        var prevTabStopVisibleColumn: isize = -1;

        for (lineContent, 0..) |ch, i| {
            if (i == position) {
                return .{
                    .prev_tab_stop_position = prevTabStopPosition,
                    .prev_tab_stop_visible_column = prevTabStopVisibleColumn,
                    .visible_column = @intCast(visibleColumn),
                };
            }
            if (visibleColumn % tabSize == 0) {
                prevTabStopPosition = @intCast(i);
                prevTabStopVisibleColumn = @intCast(visibleColumn);
            }
            switch (ch) {
                ' ' => visibleColumn += 1,
                '\t' => visibleColumn = CursorColumns.nextRenderTabStop(visibleColumn, tabSize),
                else => return .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = -1 },
            }
        }

        if (position == lineLength) {
            return .{
                .prev_tab_stop_position = prevTabStopPosition,
                .prev_tab_stop_visible_column = prevTabStopVisibleColumn,
                .visible_column = @intCast(visibleColumn),
            };
        }
        return .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = -1 };
    }

    /// Return the 0-based position after an atomic left/right/nearest move,
    /// or -1 when atomic tabs do not apply.
    pub fn atomicPosition(lineContent: []const u8, position: usize, tabSize: usize, direction: Direction) isize {
        const lineLength = lineContent.len;
        const column = whitespaceVisibleColumn(lineContent, position, tabSize);
        if (column.visible_column == -1) return -1;

        const left = switch (direction) {
            .Left => true,
            .Right => false,
            .Nearest => blk: {
                if (@as(usize, @intCast(column.visible_column)) % tabSize == 0) return @intCast(position);
                break :blk (@as(usize, @intCast(column.visible_column)) % tabSize) <= (tabSize / 2);
            },
        };

        if (left) {
            if (column.prev_tab_stop_position == -1) return -1;
            const prev_pos: usize = @intCast(column.prev_tab_stop_position);
            const prev_visible: usize = @intCast(column.prev_tab_stop_visible_column);
            var currentVisibleColumn = prev_visible;
            var i = prev_pos;
            while (i < lineLength) : (i += 1) {
                if (currentVisibleColumn == prev_visible + tabSize) return @intCast(prev_pos);
                switch (lineContent[i]) {
                    ' ' => currentVisibleColumn += 1,
                    '\t' => currentVisibleColumn = CursorColumns.nextRenderTabStop(currentVisibleColumn, tabSize),
                    else => return -1,
                }
            }
            if (currentVisibleColumn == prev_visible + tabSize) return @intCast(prev_pos);
            return -1;
        }

        const targetVisibleColumn = CursorColumns.nextRenderTabStop(@intCast(column.visible_column), tabSize);
        var currentVisibleColumn: usize = @intCast(column.visible_column);
        var i = position;
        while (i < lineLength) : (i += 1) {
            if (currentVisibleColumn == targetVisibleColumn) return @intCast(i);
            switch (lineContent[i]) {
                ' ' => currentVisibleColumn += 1,
                '\t' => currentVisibleColumn = CursorColumns.nextRenderTabStop(currentVisibleColumn, tabSize),
                else => return -1,
            }
        }
        if (currentVisibleColumn == targetVisibleColumn) return @intCast(lineLength);
        return -1;
    }
};

fn expectWhitespace(line: []const u8, tabSize: usize, expected: []const WhitespaceColumn) !void {
    for (expected, 0..) |expected_column, position| {
        try std.testing.expectEqualDeep(expected_column, AtomicTabMoveOperations.whitespaceVisibleColumn(line, position, tabSize));
    }
}

test "cursor atomic move: whitespaceVisibleColumn" {
    try expectWhitespace("        ", 4, &.{
        .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = 0 },
        .{ .prev_tab_stop_position = 0, .prev_tab_stop_visible_column = 0, .visible_column = 1 },
        .{ .prev_tab_stop_position = 0, .prev_tab_stop_visible_column = 0, .visible_column = 2 },
        .{ .prev_tab_stop_position = 0, .prev_tab_stop_visible_column = 0, .visible_column = 3 },
        .{ .prev_tab_stop_position = 0, .prev_tab_stop_visible_column = 0, .visible_column = 4 },
        .{ .prev_tab_stop_position = 4, .prev_tab_stop_visible_column = 4, .visible_column = 5 },
        .{ .prev_tab_stop_position = 4, .prev_tab_stop_visible_column = 4, .visible_column = 6 },
        .{ .prev_tab_stop_position = 4, .prev_tab_stop_visible_column = 4, .visible_column = 7 },
        .{ .prev_tab_stop_position = 4, .prev_tab_stop_visible_column = 4, .visible_column = 8 },
        .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = -1 },
    });
    try expectWhitespace("\t", 4, &.{
        .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = 0 },
        .{ .prev_tab_stop_position = 0, .prev_tab_stop_visible_column = 0, .visible_column = 4 },
        .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = -1 },
    });
    try expectWhitespace(" \tA", 4, &.{
        .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = 0 },
        .{ .prev_tab_stop_position = 0, .prev_tab_stop_visible_column = 0, .visible_column = 1 },
        .{ .prev_tab_stop_position = 0, .prev_tab_stop_visible_column = 0, .visible_column = 4 },
        .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = -1 },
        .{ .prev_tab_stop_position = -1, .prev_tab_stop_visible_column = -1, .visible_column = -1 },
    });
}

test "cursor atomic move: atomicPosition" {
    const line = "        ";
    const left = [_]isize{ -1, 0, 0, 0, 0, 4, 4, 4, 4, -1 };
    const right = [_]isize{ 4, 4, 4, 4, 8, 8, 8, 8, -1, -1 };
    const nearest = [_]isize{ 0, 0, 0, 4, 4, 4, 4, 8, 8, -1 };
    for (left, 0..) |expected, position| {
        try std.testing.expectEqual(expected, AtomicTabMoveOperations.atomicPosition(line, position, 4, .Left));
    }
    for (right, 0..) |expected, position| {
        try std.testing.expectEqual(expected, AtomicTabMoveOperations.atomicPosition(line, position, 4, .Right));
    }
    for (nearest, 0..) |expected, position| {
        try std.testing.expectEqual(expected, AtomicTabMoveOperations.atomicPosition(line, position, 4, .Nearest));
    }

    const partial = "      foo";
    try std.testing.expectEqual(@as(isize, 0), AtomicTabMoveOperations.atomicPosition(partial, 4, 4, .Left));
    try std.testing.expectEqual(@as(isize, 4), AtomicTabMoveOperations.atomicPosition(partial, 0, 4, .Right));
    try std.testing.expectEqual(@as(isize, 4), AtomicTabMoveOperations.atomicPosition(partial, 3, 4, .Nearest));
}

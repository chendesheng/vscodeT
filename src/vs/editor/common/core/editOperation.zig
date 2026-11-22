// Port of `src/vs/editor/common/core/editOperation.ts`.
const std = @import("std");
const Position = @import("position.zig").Position;
const Range = @import("range.zig").Range;

/// A simple replace edit operation.
pub const ISingleEditOperation = struct {
    range: Range,
    text: ?[]const u8,
    forceMoveMarkers: bool = false,
};

pub const EditOperation = struct {
    pub fn insert(position: Position, text: []const u8) ISingleEditOperation {
        return .{
            .range = Range.init(position.lineNumber, position.column, position.lineNumber, position.column),
            .text = text,
            .forceMoveMarkers = true,
        };
    }

    pub fn delete(range: Range) ISingleEditOperation {
        return .{ .range = range, .text = null };
    }

    pub fn replace(range: Range, text: ?[]const u8) ISingleEditOperation {
        return .{ .range = range, .text = text };
    }

    pub fn replaceMove(range: Range, text: ?[]const u8) ISingleEditOperation {
        return .{ .range = range, .text = text, .forceMoveMarkers = true };
    }
};

test "editOperation: insert, delete, replace" {
    const insert = EditOperation.insert(Position.init(1, 2), "x");
    try std.testing.expectEqual(@as(usize, 2), insert.range.startColumn);
    try std.testing.expect(insert.forceMoveMarkers);
    try std.testing.expect(EditOperation.delete(Range.init(1, 1, 1, 2)).text == null);
    try std.testing.expectEqualStrings("y", EditOperation.replace(Range.init(1, 1, 1, 2), "y").text.?);
}

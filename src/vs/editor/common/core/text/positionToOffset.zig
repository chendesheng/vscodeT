const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const TextLength = @import("textLength.zig").TextLength;

/// Converts between 1-based positions and byte offsets for a text buffer.
pub const PositionOffsetTransformer = struct {
    allocator: Allocator,
    text: []const u8,
    line_start_offsets: ArrayList(usize),
    line_end_offsets: ArrayList(usize),

    pub fn init(allocator: Allocator, text: []const u8) !PositionOffsetTransformer {
        var self = PositionOffsetTransformer{
            .allocator = allocator,
            .text = text,
            .line_start_offsets = ArrayList(usize).init(allocator),
            .line_end_offsets = ArrayList(usize).init(allocator),
        };
        errdefer self.deinit();
        try self.computeLineOffsets();
        return self;
    }

    pub fn deinit(self: *PositionOffsetTransformer) void {
        self.line_start_offsets.deinit();
        self.line_end_offsets.deinit();
    }

    fn computeLineOffsets(self: *PositionOffsetTransformer) !void {
        try self.line_start_offsets.append(0);
        for (self.text, 0..) |ch, i| {
            if (ch == '\n') {
                try self.line_start_offsets.append(i + 1);
                if (i > 0 and self.text[i - 1] == '\r') {
                    try self.line_end_offsets.append(i - 1);
                } else {
                    try self.line_end_offsets.append(i);
                }
            }
        }
        try self.line_end_offsets.append(self.text.len);
    }

    pub fn getOffset(self: *const PositionOffsetTransformer, position: Position) usize {
        const validated = self.validatePosition(position);
        return self.line_start_offsets.items[validated.lineNumber - 1] + validated.column - 1;
    }

    pub fn getOffsetRange(self: *const PositionOffsetTransformer, range: Range) OffsetRange {
        return OffsetRange.init(self.getOffset(range.getStartPosition()), self.getOffset(range.getEndPosition()));
    }

    pub fn getPosition(self: *const PositionOffsetTransformer, offset: usize) Position {
        var line_index: usize = 0;
        var i = self.line_start_offsets.items.len;
        while (i > 0) {
            i -= 1;
            if (self.line_start_offsets.items[i] <= offset) {
                line_index = i;
                break;
            }
        }
        return Position.init(line_index + 1, offset - self.line_start_offsets.items[line_index] + 1);
    }

    pub fn getRange(self: *const PositionOffsetTransformer, offset_range: OffsetRange) Range {
        const start = self.getPosition(offset_range.start);
        const end = self.getPosition(offset_range.endExclusive);
        return Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
    }

    pub fn getLineLength(self: *const PositionOffsetTransformer, line_number: usize) usize {
        return self.line_end_offsets.items[line_number - 1] - self.line_start_offsets.items[line_number - 1];
    }

    pub fn textLength(self: *const PositionOffsetTransformer) TextLength {
        const line_idx = self.line_start_offsets.items.len - 1;
        return .{
            .lineCount = line_idx,
            .columnCount = self.text.len - self.line_start_offsets.items[line_idx],
        };
    }

    fn validatePosition(self: *const PositionOffsetTransformer, position: Position) Position {
        if (position.lineNumber < 1) return Position.init(1, 1);
        const line_count = self.line_start_offsets.items.len;
        if (position.lineNumber > line_count) {
            const line_length = self.getLineLength(line_count);
            return Position.init(line_count, line_length + 1);
        }
        if (position.column < 1) return Position.init(position.lineNumber, 1);
        const line_length = self.getLineLength(position.lineNumber);
        if (position.column - 1 > line_length) {
            return Position.init(position.lineNumber, line_length + 1);
        }
        return position;
    }
};

test "positionToOffset: offsets, positions, and line lengths" {
    const allocator = std.testing.allocator;
    var transformer = try PositionOffsetTransformer.init(allocator, "ab\ncde\r\nf");
    defer transformer.deinit();

    try std.testing.expectEqual(@as(usize, 0), transformer.getOffset(Position.init(1, 1)));
    try std.testing.expectEqual(@as(usize, 4), transformer.getOffset(Position.init(2, 2)));
    try std.testing.expectEqual(Position.init(2, 2), transformer.getPosition(4));
    try std.testing.expectEqual(@as(usize, 2), transformer.getLineLength(1));
    try std.testing.expectEqual(@as(usize, 3), transformer.getLineLength(2));
    const length = transformer.textLength();
    try std.testing.expectEqual(@as(usize, 2), length.lineCount);
    try std.testing.expectEqual(@as(usize, 1), length.columnCount);

    const range = transformer.getRange(OffsetRange.init(1, 4));
    try std.testing.expectEqual(@as(usize, 1), range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 2), range.startColumn);
    try std.testing.expectEqual(@as(usize, 2), range.endLineNumber);
}

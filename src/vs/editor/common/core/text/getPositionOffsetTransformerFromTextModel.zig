// Port of `src/vs/editor/common/core/text/getPositionOffsetTransformerFromTextModel.ts`.
const std = @import("std");
const Position = @import("../position.zig").Position;
const Range = @import("../range.zig").Range;
const range = @import("../range.zig");
const OffsetRange = @import("../ranges/offsetRange.zig").OffsetRange;
const TextLength = @import("../text/textLength.zig").TextLength;
const TextModel = @import("../../model/textModel.zig").TextModel;

/// A position/offset transformer backed by a `TextModel`.
pub const PositionOffsetTransformerWithTextModel = struct {
    const Self = @This();

    text_model: *TextModel,

    pub fn init(text_model: *TextModel) Self {
        return .{ .text_model = text_model };
    }

    pub fn getOffset(self: *const Self, position: Position) usize {
        return self.text_model.getOffsetAt(position);
    }

    pub fn getPosition(self: *const Self, offset: usize) Position {
        return self.text_model.getPositionAt(offset);
    }

    pub fn getOffsetRange(self: *const Self, text_range: Range) OffsetRange {
        return OffsetRange.init(
            self.getOffset(text_range.getStartPosition()),
            self.getOffset(text_range.getEndPosition()),
        );
    }

    pub fn getRange(self: *const Self, offset_range: OffsetRange) Range {
        return range.fromPositions(
            self.getPosition(offset_range.start),
            self.getPosition(offset_range.endExclusive),
        );
    }

    pub fn getLineLength(self: *const Self, line_number: usize) usize {
        return self.text_model.getLineLength(line_number);
    }

    pub fn textLength(self: *const Self) TextLength {
        const line_count = self.text_model.getLineCount();
        return .{
            .lineCount = line_count - 1,
            .columnCount = self.text_model.getLineLength(line_count),
        };
    }
};

pub fn getPositionOffsetTransformerFromTextModel(text_model: *TextModel) PositionOffsetTransformerWithTextModel {
    return PositionOffsetTransformerWithTextModel.init(text_model);
}

test "PositionOffsetTransformerWithTextModel" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    var test_model = try TestModel.init(allocator, "ab\ncde", "plaintext");
    defer test_model.deinit();

    const transformer = getPositionOffsetTransformerFromTextModel(test_model.model);
    try std.testing.expectEqual(@as(usize, 4), transformer.getOffset(Position.init(2, 2)));
    try std.testing.expectEqualDeep(Position.init(2, 2), transformer.getPosition(4));
    try std.testing.expectEqual(OffsetRange.init(1, 4), transformer.getOffsetRange(Range.init(1, 2, 2, 2)));
    try std.testing.expectEqualDeep(Range.init(1, 2, 2, 2), transformer.getRange(OffsetRange.init(1, 4)));
    try std.testing.expectEqual(@as(usize, 3), transformer.getLineLength(2));
    try std.testing.expectEqualDeep(TextLength{ .lineCount = 1, .columnCount = 3 }, transformer.textLength());
}

const std = @import("std");
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const EndOfLinePreference = @import("../model.zig").EndOfLinePreference;

/// A minimal model interface used by screen readers.
///
/// Returned strings are borrowed from the model implementation and must stay
/// valid for the duration of the call.
pub const ISimpleModel = struct {
    context: *anyopaque,
    getLineContent: *const fn (context: *anyopaque, lineNumber: usize) []const u8,
    getLineCount: *const fn (context: *anyopaque) usize,
    getLineMaxColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    getValueInRange: *const fn (context: *anyopaque, range: Range, eol: EndOfLinePreference) []const u8,
    getValueLengthInRange: *const fn (context: *anyopaque, range: Range, eol: EndOfLinePreference) usize,
    modify_position: *const fn (context: *anyopaque, position: Position, offset: isize) Position,

    pub fn lineContent(self: ISimpleModel, line_number: usize) []const u8 {
        return self.getLineContent(self.context, line_number);
    }

    pub fn lineCount(self: ISimpleModel) usize {
        return self.getLineCount(self.context);
    }

    pub fn lineMaxColumn(self: ISimpleModel, line_number: usize) usize {
        return self.getLineMaxColumn(self.context, line_number);
    }

    pub fn valueInRange(self: ISimpleModel, value_range: Range, eol: EndOfLinePreference) []const u8 {
        return self.getValueInRange(self.context, value_range, eol);
    }

    pub fn valueLengthInRange(self: ISimpleModel, value_range: Range, eol: EndOfLinePreference) usize {
        return self.getValueLengthInRange(self.context, value_range, eol);
    }

    pub fn modifyPosition(self: ISimpleModel, position: Position, offset: isize) Position {
        return self.modify_position(self.context, position, offset);
    }
};

test "ISimpleModel: delegates to implementation" {
    const Model = struct {
        fn getLineContent(_: *anyopaque, line_number: usize) []const u8 {
            return if (line_number == 1) "hello" else "world";
        }

        fn getLineCount(_: *anyopaque) usize {
            return 2;
        }

        fn getLineMaxColumn(_: *anyopaque, line_number: usize) usize {
            return if (line_number == 1) 6 else 6;
        }

        fn getValueInRange(_: *anyopaque, _: Range, _: EndOfLinePreference) []const u8 {
            return "hello\nworld";
        }

        fn getValueLengthInRange(_: *anyopaque, _: Range, _: EndOfLinePreference) usize {
            return 11;
        }

        fn modifyPosition(_: *anyopaque, position: Position, offset: isize) Position {
            return Position.init(position.lineNumber, @intCast(@as(isize, @intCast(position.column)) + offset));
        }
    };

    var context: u8 = 0;
    const model = ISimpleModel{
        .context = &context,
        .getLineContent = &Model.getLineContent,
        .getLineCount = &Model.getLineCount,
        .getLineMaxColumn = &Model.getLineMaxColumn,
        .getValueInRange = &Model.getValueInRange,
        .getValueLengthInRange = &Model.getValueLengthInRange,
        .modify_position = &Model.modifyPosition,
    };

    try std.testing.expectEqual(@as(usize, 2), model.lineCount());
    try std.testing.expectEqualStrings("world", model.lineContent(2));
    try std.testing.expectEqual(@as(usize, 6), model.lineMaxColumn(1));
    try std.testing.expectEqual(@as(usize, 11), model.valueLengthInRange(Range.init(1, 1, 2, 6), .TextDefined));
    try std.testing.expectEqualDeep(Position.init(1, 4), model.modifyPosition(Position.init(1, 2), 2));
}

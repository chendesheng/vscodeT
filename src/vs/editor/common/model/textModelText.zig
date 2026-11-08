const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../core/range.zig").Range;
const TextLength = @import("../core/text/textLength.zig").TextLength;
const TextModel = @import("textModel.zig").TextModel;

/// An `AbstractText`-like view over a `TextModel`.
///
/// The local `AbstractText` is a tagged union rather than a base class, so this
/// type exposes the same useful operations directly. Values returned by
/// `getValueOfRange` are owned by the caller.
pub const TextModelText = struct {
    const Self = @This();

    allocator: Allocator,
    text_model: *TextModel,

    pub fn init(allocator: Allocator, text_model: *TextModel) Self {
        return .{ .allocator = allocator, .text_model = text_model };
    }

    pub fn getValueOfRange(self: *const Self, text_range: Range) ![]u8 {
        var value = try self.text_model.getValueInRange(text_range, null);
        return value.toOwnedSlice();
    }

    pub fn getLineLength(self: *const Self, line_number: usize) usize {
        return self.text_model.getLineLength(line_number);
    }

    pub fn getLineCount(self: *const Self) usize {
        return self.text_model.getLineCount();
    }

    pub fn length(self: *const Self) TextLength {
        const last_line_number = self.text_model.getLineCount();
        const last_line_len = self.text_model.getLineLength(last_line_number);
        return .{ .lineCount = last_line_number - 1, .columnCount = last_line_len };
    }
};

test "TextModelText: length and value of range" {
    const allocator = std.testing.allocator;
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;

    var test_model = try TestModel.init(allocator, "line1\nline2\nline3", "plaintext");
    defer test_model.deinit();

    const text = TextModelText.init(allocator, test_model.model);
    try std.testing.expectEqualDeep(TextLength{ .lineCount = 2, .columnCount = 5 }, text.length());
    try std.testing.expectEqual(@as(usize, 5), text.getLineLength(1));
    try std.testing.expectEqual(@as(usize, 3), text.getLineCount());

    const value = try text.getValueOfRange(Range.init(1, 1, 2, 3));
    defer allocator.free(value);
    try std.testing.expectEqualStrings("line1\nli", value);
}

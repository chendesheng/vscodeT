// Adapts `TextModel` to the `ICursorSimpleModel` interface used by the cursor
// operations. This is the production equivalent of the adapter that used to
// live in the cursor tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const Position = @import("../core/position.zig").Position;
const PositionAffinity = @import("../model.zig").PositionAffinity;
const TextModel = @import("../model/textModel.zig").TextModel;
const cursorCommon = @import("../cursorCommon.zig");
const ICursorSimpleModel = cursorCommon.ICursorSimpleModel;

pub const TextModelCursorSimpleModel = struct {
    model: *TextModel,
    line_buffer: ArrayList(u8),

    pub fn init(allocator: Allocator, model: *TextModel) TextModelCursorSimpleModel {
        return .{
            .model = model,
            .line_buffer = ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *TextModelCursorSimpleModel) void {
        self.line_buffer.deinit();
    }

    fn fromContext(context: *anyopaque) *TextModelCursorSimpleModel {
        return @ptrCast(@alignCast(context));
    }

    fn getLineCount(context: *anyopaque) usize {
        return fromContext(context).model.getLineCount();
    }

    fn getLineContent(context: *anyopaque, lineNumber: usize) []const u8 {
        const self = fromContext(context);
        self.line_buffer.clearRetainingCapacity();
        const line = self.model.getLineContent(lineNumber) catch return "";
        defer line.deinit();
        self.line_buffer.appendSlice(line.items) catch return self.line_buffer.items;
        return self.line_buffer.items;
    }

    fn getLineMinColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }

    fn getLineMaxColumn(context: *anyopaque, lineNumber: usize) usize {
        return fromContext(context).model.getLineMaxColumn(lineNumber);
    }

    fn getLineFirstNonWhitespaceColumn(context: *anyopaque, lineNumber: usize) usize {
        return fromContext(context).model.getLineFirstNonWhitespaceColumn(lineNumber) catch 0;
    }

    fn getLineLastNonWhitespaceColumn(context: *anyopaque, lineNumber: usize) usize {
        return fromContext(context).model.getLineLastNonWhitespaceColumn(lineNumber) catch 0;
    }

    fn normalizePosition(context: *anyopaque, position: Position, _: PositionAffinity) Position {
        return fromContext(context).model.validatePosition(position);
    }

    fn getLineIndentColumn(context: *anyopaque, lineNumber: usize) usize {
        return getLineFirstNonWhitespaceColumn(context, lineNumber);
    }

    pub fn interface(self: *TextModelCursorSimpleModel) ICursorSimpleModel {
        return .{
            .context = self,
            .getLineCount = getLineCount,
            .getLineContent = getLineContent,
            .getLineMinColumn = getLineMinColumn,
            .getLineMaxColumn = getLineMaxColumn,
            .getLineFirstNonWhitespaceColumn = getLineFirstNonWhitespaceColumn,
            .getLineLastNonWhitespaceColumn = getLineLastNonWhitespaceColumn,
            .normalizePosition = normalizePosition,
            .getLineIndentColumn = getLineIndentColumn,
        };
    }
};

test "TextModelCursorSimpleModel adapts TextModel" {
    const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;

    var ctx = try TestModel.init(std.testing.allocator, "abc\ndef", "nullLanguage");
    defer ctx.deinit();

    var adapter = TextModelCursorSimpleModel.init(std.testing.allocator, ctx.model);
    defer adapter.deinit();
    const model = adapter.interface();

    try std.testing.expectEqual(@as(usize, 2), model.getLineCount(model.context));
    try std.testing.expectEqualStrings("abc", model.getLineContent(model.context, 1));
    try std.testing.expectEqual(@as(usize, 1), model.getLineMinColumn(model.context, 1));
    try std.testing.expectEqual(@as(usize, 4), model.getLineMaxColumn(model.context, 1));
    try std.testing.expectEqual(@as(usize, 1), model.getLineFirstNonWhitespaceColumn(model.context, 1));
    try std.testing.expectEqual(@as(usize, 4), model.getLineLastNonWhitespaceColumn(model.context, 1));
    try std.testing.expectEqual(Position.init(2, 4), model.normalizePosition(model.context, Position.init(2, 99), .None));
}

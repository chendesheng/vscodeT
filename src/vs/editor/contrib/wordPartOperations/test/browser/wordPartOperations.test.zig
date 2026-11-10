// Port of representative cases from
// `src/vs/editor/contrib/wordPartOperations/test/browser/wordPartOperations.test.ts`.
const std = @import("std");
const Position = @import("../../../../common/core/position.zig").Position;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const WordCharacterClassifier = @import("../../../../common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const TextModelCursorSimpleModel = @import("../../../../common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const word_part = @import("../../browser/wordPartOperations.zig");

fn setup(allocator: std.mem.Allocator, text: []const u8) !struct { model: TestModel, adapter: TextModelCursorSimpleModel, separators: WordCharacterClassifier } {
    var model = try TestModel.init(allocator, text, "nullLanguage");
    errdefer model.deinit();
    var adapter = TextModelCursorSimpleModel.init(allocator, model.model);
    errdefer adapter.deinit();
    const separators = try WordCharacterClassifier.init(allocator, ",.;");
    return .{ .model = model, .adapter = adapter, .separators = separators };
}

test "cursorWordPartLeft - basic" {
    const allocator = std.testing.allocator;
    var ctx = try setup(allocator, "thisIsACamelCaseVar");
    defer {
        ctx.separators.deinit();
        ctx.adapter.deinit();
        ctx.model.deinit();
    }
    const model = ctx.adapter.interface();
    var position = Position.init(1, 20);
    const expected = [_]usize{ 17, 13, 8, 7, 5, 1, 1, 1 };
    for (expected) |column| {
        const selection = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
        const result = word_part.cursor_word_part_left.apply(&ctx.separators, model, selection, false);
        position = Position.init(result.positionLineNumber, result.positionColumn);
        try std.testing.expectEqual(column, position.column);
    }
}

test "cursorWordPartRight - basic" {
    const allocator = std.testing.allocator;
    var ctx = try setup(allocator, "thisIsACamelCaseVar");
    defer {
        ctx.separators.deinit();
        ctx.adapter.deinit();
        ctx.model.deinit();
    }
    const model = ctx.adapter.interface();
    var position = Position.init(1, 1);
    const expected = [_]usize{ 5, 7, 8, 13, 17, 20, 20, 20 };
    for (expected) |column| {
        const selection = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
        const result = word_part.cursor_word_part_right.apply(&ctx.separators, model, selection);
        position = Position.init(result.positionLineNumber, result.positionColumn);
        try std.testing.expectEqual(column, position.column);
    }
}

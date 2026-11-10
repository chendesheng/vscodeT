// Port of representative cases from
// `src/vs/editor/contrib/wordOperations/test/browser/wordOperations.test.ts`.
const std = @import("std");
const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const WordCharacterClassifier = @import("../../../../common/core/wordCharacterClassifier.zig").WordCharacterClassifier;
const TextModelCursorSimpleModel = @import("../../../../common/cursor/textModelCursorSimpleModel.zig").TextModelCursorSimpleModel;
const cursor_word = @import("../../../../common/cursor/cursorWordOperations.zig");
const DeleteWordContext = cursor_word.DeleteWordContext;
const TestModel = @import("../../../../test/common/port/testSupport.zig").TestModel;
const word_ops = @import("../../browser/wordOperations.zig");

fn setup(allocator: std.mem.Allocator, text: []const u8) !struct { model: TestModel, adapter: TextModelCursorSimpleModel, separators: WordCharacterClassifier } {
    var model = try TestModel.init(allocator, text, "nullLanguage");
    errdefer model.deinit();
    var adapter = TextModelCursorSimpleModel.init(allocator, model.model);
    errdefer adapter.deinit();
    const separators = try WordCharacterClassifier.init(allocator, ",.;");
    return .{ .model = model, .adapter = adapter, .separators = separators };
}

test "cursorWordLeft - simple" {
    const allocator = std.testing.allocator;
    var ctx = try setup(allocator, "one two three");
    defer {
        ctx.separators.deinit();
        ctx.adapter.deinit();
        ctx.model.deinit();
    }
    const model = ctx.adapter.interface();

    var position = Position.init(1, 14);
    const expected = [_]usize{ 9, 5, 1 };
    for (expected) |column| {
        const selection = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
        const result = word_ops.cursor_word_left.apply(&ctx.separators, model, selection, false);
        position = Position.init(result.positionLineNumber, result.positionColumn);
        try std.testing.expectEqual(column, position.column);
    }
}

test "cursorWordRight - simple" {
    const allocator = std.testing.allocator;
    var ctx = try setup(allocator, "one two three");
    defer {
        ctx.separators.deinit();
        ctx.adapter.deinit();
        ctx.model.deinit();
    }
    const model = ctx.adapter.interface();

    var position = Position.init(1, 1);
    const expected = [_]usize{ 4, 8, 14 };
    for (expected) |column| {
        const selection = Selection.init(position.lineNumber, position.column, position.lineNumber, position.column);
        const result = word_ops.cursor_word_right.apply(&ctx.separators, model, selection, false);
        position = Position.init(result.positionLineNumber, result.positionColumn);
        try std.testing.expectEqual(column, position.column);
    }
}

test "deleteWordLeft for cursor inside of a word" {
    const allocator = std.testing.allocator;
    var ctx = try setup(allocator, "    \tMy First Line\t \n\tMy Second Line");
    defer {
        ctx.separators.deinit();
        ctx.adapter.deinit();
        ctx.model.deinit();
    }
    const model = ctx.adapter.interface();
    const selection = Selection.init(1, 12, 1, 12);
    const delete_ctx = DeleteWordContext{
        .wordSeparators = &ctx.separators,
        .model = model,
        .selection = selection,
        .whitespaceHeuristics = true,
    };
    const range = word_ops.delete_word_left.apply(delete_ctx).?;
    try ctx.model.applyEdit(range, "");
    const line = try ctx.model.model.getLineContent(1);
    defer line.deinit();
    try std.testing.expectEqualStrings("    \tMy st Line\t ", line.items);
}

test "deleteInsideWord in words" {
    const allocator = std.testing.allocator;
    var ctx = try setup(allocator, "hello world");
    defer {
        ctx.separators.deinit();
        ctx.adapter.deinit();
        ctx.model.deinit();
    }
    const model = ctx.adapter.interface();
    const selection = Selection.init(1, 8, 1, 8);
    const range = word_ops.deleteInsideWord(&ctx.separators, model, selection, false);
    try ctx.model.applyEdit(range, "");
    const value = try ctx.model.model.getValue(.TextDefined, false);
    defer value.deinit();
    try std.testing.expectEqualStrings("hello", value.items);
}

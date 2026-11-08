const std = @import("std");
const TestModel = @import("../port/testSupport.zig").TestModel;
const Position = @import("../../../common/core/position.zig").Position;

fn expectWord(model: *@import("../../../common/model/textModel.zig").TextModel, line: usize, column: usize, expected: ?[]const u8, startColumn: usize, endColumn: usize) !void {
    var word = model.getWordAtPosition(Position.init(line, column));
    if (expected) |want| {
        try std.testing.expect(word != null);
        defer word.?.deinit();
        try std.testing.expectEqualStrings(want, word.?.word.items);
        try std.testing.expectEqual(startColumn, word.?.startColumn);
        try std.testing.expectEqual(endColumn, word.?.endColumn);
    } else {
        try std.testing.expect(word == null);
    }
}

test "word: get word at position" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "This text has some  words. ", "nullLanguage");
    defer ctx.deinit();

    try expectWord(ctx.model, 1, 1, "This", 1, 5);
    try expectWord(ctx.model, 1, 2, "This", 1, 5);
    try expectWord(ctx.model, 1, 4, "This", 1, 5);
    try expectWord(ctx.model, 1, 5, "This", 1, 5);
    try expectWord(ctx.model, 1, 6, "text", 6, 10);
    try expectWord(ctx.model, 1, 19, "some", 15, 19);
    try expectWord(ctx.model, 1, 20, null, 0, 0);
    try expectWord(ctx.model, 1, 21, "words", 21, 26);
    try expectWord(ctx.model, 1, 26, "words", 21, 26);
    try expectWord(ctx.model, 1, 27, null, 0, 0);
    try expectWord(ctx.model, 1, 28, null, 0, 0);
}

test "word: get word until position" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "This text has some words", "nullLanguage");
    defer ctx.deinit();

    var until = ctx.model.getWordUntilPosition(Position.init(1, 8));
    defer until.deinit();
    try std.testing.expectEqualStrings("te", until.word.items);
    try std.testing.expectEqual(6, until.startColumn);
    try std.testing.expectEqual(8, until.endColumn);
}

const std = @import("std");
const TestModel = @import("testSupport.zig").TestModel;

test "tokenizer: null tokenization smoke" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "Hello\nWorld", "nullLanguage");
    defer ctx.deinit();

    ctx.model.forceTokenization(1);
    var lineTokens = try ctx.model.tokenization().getLineTokens(1);
    defer lineTokens.deinit();

    try std.testing.expectEqual(1, lineTokens.getCount());
    try std.testing.expectEqualStrings("Hello", lineTokens.getLineContent());
    try std.testing.expectEqual(5, lineTokens.getEndOffset(0));
}

// Integration coverage for the terminal adaptation of upstream's threaded
// TextMate background tokenizer. Upstream has no unit test for the worker
// bootstrap, so this test drives a real TextModel through the worker thread.
const std = @import("std");
const time_compat = @import("../../../../../base/common/timeCompat.zig");
const TestModel = @import("../../../../../editor/test/common/port/testSupport.zig").TestModel;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const TokenizationRegistry = @import("../../../../../editor/common/tokenizationRegistry.zig").TokenizationRegistry;
const textMateTokenizer = @import("../../../../../editor/common/model/tokens/textMateTokenizer.zig");
const TextModel = @import("../../../../../editor/common/model/textModel.zig").TextModel;
const Factory = @import("../../browser/backgroundTokenization/threadedBackgroundTokenizerFactory.zig").Factory;

fn waitForWorker(factory: *Factory, model: *TextModel) !void {
    var spins: usize = 0;
    while (factory.hasPendingWork() and spins < 20_000) : (spins += 1) {
        _ = model.drainBackgroundTokenization();
        time_compat.sleepMillis(1);
    }
    try std.testing.expect(spins < 20_000);
    _ = model.drainBackgroundTokenization();
}

fn hasCommentToken(model: *TextModel, line: usize) !bool {
    var tokens = try model.tokenization().getLineTokens(line);
    defer tokens.deinit();
    for (0..tokens.getCount()) |i| {
        if (tokens.getStandardTokenType(i) == .Comment) return true;
    }
    return false;
}

test "threaded textmate tokenizer: initial tokens and edits reach the renderer" {
    const allocator = std.testing.allocator;
    textMateTokenizer.ensureTokenizer("zig");

    var factory = try Factory.init(allocator);
    defer factory.deinit();
    TokenizationRegistry.instance.setBackgroundTokenizerFactory(factory.interface());
    defer TokenizationRegistry.instance.setBackgroundTokenizerFactory(null);

    var ctx = try TestModel.init(allocator, "const x = 1;\nconst y = 2; // hi\n", "zig");
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), factory.controllerCount());
    const view = try ctx.model.onBeforeAttached();
    defer {
        ctx.model.onBeforeDetached(view) catch {};
        ctx.allocator.destroy(view);
    }

    try waitForWorker(factory, ctx.model);
    try std.testing.expect(try hasCommentToken(ctx.model, 2));

    try ctx.applyEdit(Range.init(1, 1, 1, 1), "// exported\n");
    try waitForWorker(factory, ctx.model);
    try std.testing.expect(try hasCommentToken(ctx.model, 1));
    try std.testing.expect(try hasCommentToken(ctx.model, 3));
}

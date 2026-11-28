const std = @import("std");
const Allocator = std.mem.Allocator;
const TestModel = @import("./testSupport.zig").TestModel;
const ITokenizationSupport = @import("../../../common/languages.zig").ITokenizationSupport;
const IState = @import("../../../common/languages.zig").IState;
const EncodedTokenizationResult = @import("../../../common/languages.zig").EncodedTokenizationResult;
const TokenPacked = @import("../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../common/encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../../../common/encodedTokenAttributes.zig").StandardTokenType;
const NullState = @import("../../../common/languages/nullTokenize.zig").NullState;
const TokenizationRegistry = @import("../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const ModelTokensChangedEvent = @import("../../../common/textModelEvents.zig").ModelTokensChangedEvent;
const Range = @import("../../../common/core/range.zig").Range;
const Position = @import("../../../common/core/position.zig").Position;

const SimpleSupport = struct {
    foreground: u9,
    standard_type: StandardTokenType,

    fn getInitialState(_: *anyopaque, _: Allocator) anyerror!IState {
        return NullState;
    }

    fn tokenizeEncoded(ctx: *anyopaque, _: std.Io, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        _ = hasEOL;
        const self: *SimpleSupport = @ptrCast(@alignCast(ctx));
        const tokens = try allocator.alloc(TokenPacked, 1);
        var metadata = TokenMetadata.default;
        metadata.foreground = self.foreground;
        metadata.tokenType = self.standard_type;
        tokens[0] = .{ .endOffset = @intCast(line.len), .metadata = metadata };
        return .{ .tokens = tokens, .endState = state };
    }

    fn interface(self: *SimpleSupport) ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

var token_event_count: usize = 0;

fn onTokens(_: ModelTokensChangedEvent) void {
    token_event_count += 1;
}

test "integration: force tokenization fires token events" {
    const allocator = std.testing.allocator;
    var support = SimpleSupport{ .foreground = 3, .standard_type = .Other };
    try TokenizationRegistry.instance.register("integrationLangA", support.interface());
    defer TokenizationRegistry.instance.unregister("integrationLangA");

    var ctx = try TestModel.init(allocator, "hello world", "integrationLangA");
    defer ctx.deinit();

    token_event_count = 0;
    try ctx.model.onDidChangeTokens(onTokens);
    ctx.model.forceTokenization(1);
    try std.testing.expectEqual(1, token_event_count);

    var lineTokens = try ctx.model.tokenization().getLineTokens(1);
    defer lineTokens.deinit();
    try std.testing.expectEqual(1, lineTokens.getCount());
    try std.testing.expectEqual(3, lineTokens.getForeground(0));
}

test "integration: language switch selects another tokenizer" {
    const allocator = std.testing.allocator;
    var supportA = SimpleSupport{ .foreground = 3, .standard_type = .Other };
    var supportB = SimpleSupport{ .foreground = 7, .standard_type = .String };
    try TokenizationRegistry.instance.register("integrationLangB", supportA.interface());
    defer TokenizationRegistry.instance.unregister("integrationLangB");
    try TokenizationRegistry.instance.register("integrationLangC", supportB.interface());
    defer TokenizationRegistry.instance.unregister("integrationLangC");

    var ctx = try TestModel.init(allocator, "hello", "integrationLangB");
    defer ctx.deinit();

    ctx.model.forceTokenization(1);
    var tokens = try ctx.model.tokenization().getLineTokens(1);
    try std.testing.expectEqual(3, tokens.getForeground(0));
    tokens.deinit();

    ctx.model.setLanguage("integrationLangC");
    ctx.model.forceTokenization(1);
    var tokens2 = try ctx.model.tokenization().getLineTokens(1);
    defer tokens2.deinit();
    try std.testing.expectEqual(7, tokens2.getForeground(0));
    try std.testing.expectEqual(StandardTokenType.String, tokens2.getStandardTokenType(0));
}

test "integration: attach and detach a view" {
    const allocator = std.testing.allocator;
    var support = SimpleSupport{ .foreground = 4, .standard_type = .Other };
    try TokenizationRegistry.instance.register("integrationLangD", support.interface());
    defer TokenizationRegistry.instance.unregister("integrationLangD");

    var ctx = try TestModel.init(allocator, "one\ntwo\nthree", "integrationLangD");
    defer ctx.deinit();

    const view = try ctx.model.onBeforeAttached();
    try std.testing.expect(ctx.model.isAttachedToEditor());
    var lines = [_]@import("../../../common/model/tokens/abstractSyntaxTokenBackend.zig").VisibleLine{
        .{ .startLineNumber = 1, .endLineNumber = 2 },
    };
    try view.setVisibleLines(allocator, &lines, true);
    try ctx.model.onBeforeDetached(view);
    ctx.allocator.destroy(view);
    try std.testing.expect(!ctx.model.isAttachedToEditor());
}

test "integration: tokenizeLinesAt and inserting-character token type" {
    const allocator = std.testing.allocator;
    var support = SimpleSupport{ .foreground = 1, .standard_type = .Comment };
    try TokenizationRegistry.instance.register("integrationLangE", support.interface());
    defer TokenizationRegistry.instance.unregister("integrationLangE");

    var ctx = try TestModel.init(allocator, "abc\ndef", "integrationLangE");
    defer ctx.deinit();

    var lines = [_][]const u8{ "one", "two" };
    var result = (try ctx.model.tokenization().tokenizeLinesAt(1, &lines)) orelse return error.ExpectedTokens;
    defer {
        for (result.items) |*lineTokens| lineTokens.deinit();
        result.deinit();
    }
    try std.testing.expectEqual(2, result.items.len);
    try std.testing.expectEqualStrings("one", result.items[0].getLineContent());
    try std.testing.expectEqual(StandardTokenType.Comment, result.items[0].getStandardTokenType(0));

    const tokenType = try ctx.model.getTokenTypeIfInsertingCharacter(1, 1, "x");
    try std.testing.expectEqual(StandardTokenType.Comment, tokenType);
}

test "integration: semantic token partial update" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "abc def", "nullLanguage");
    defer ctx.deinit();

    const piece = try @import("./testSupport.zig").createSparseTokens(allocator, 1, &[_]u32{
        0, 0, 3, (5 << 15) | (1 << 4),
    });
    var pieces = [_]@import("../../../common/tokens/sparseMultilineTokens.zig").SparseMultilineTokens{piece};
    try ctx.model.tokenization().setPartialSemanticTokens(Range.init(1, 1, 1, 8), &pieces);

    var tokens = try ctx.model.tokenization().getLineTokens(1);
    defer tokens.deinit();
    try std.testing.expectEqual(5, tokens.getForeground(0));
}

test "integration: language change event fires" {
    const allocator = std.testing.allocator;
    var support = SimpleSupport{ .foreground = 4, .standard_type = .Other };
    try TokenizationRegistry.instance.register("integrationLangF", support.interface());
    defer TokenizationRegistry.instance.unregister("integrationLangF");
    try TokenizationRegistry.instance.register("integrationLangG", support.interface());
    defer TokenizationRegistry.instance.unregister("integrationLangG");

    var ctx = try TestModel.init(allocator, "abc", "integrationLangF");
    defer ctx.deinit();

    var changes: usize = 0;
    try ctx.model.onDidChangeLanguage(&changes, struct {
        fn cb(_: @import("../../../common/textModelEvents.zig").ModelLanguageChangedEvent, count: *usize) !void {
            count.* += 1;
        }
    }.cb);
    ctx.model.setLanguage("integrationLangG");
    try std.testing.expectEqual(1, changes);
}

test "integration: tokenization registry notifies on register and unregister" {
    var support = SimpleSupport{ .foreground = 4, .standard_type = .Other };
    const Listener = struct {
        fn cb(e: @import("../../../common/languages.zig").TokenizationSupportChangedEvent, state: *[2]bool) !void {
            if (e.affects("integrationLangH")) {
                if (state[0]) state[1] = true else state[0] = true;
            }
        }
    };

    var state = [2]bool{ false, false };
    const listener = try TokenizationRegistry.instance.onDidChange(&state, Listener.cb);
    defer TokenizationRegistry.instance.unsubscribe(listener);

    try TokenizationRegistry.instance.register("integrationLangH", support.interface());
    try std.testing.expect(state[0]);
    TokenizationRegistry.instance.unregister("integrationLangH");
    try std.testing.expect(state[1]);
}

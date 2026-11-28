const std = @import("std");
const ArrayList = std.array_list.Managed;
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const LineTokens = @import("../../../../common/tokens/lineTokens.zig").LineTokens;
const TokenArray = @import("../../../../common/tokens/lineTokens.zig").TokenArray;
const TokenArrayBuilder = @import("../../../../common/tokens/lineTokens.zig").TokenArrayBuilder;
const TokenWithTextArray = @import("../../../../common/tokens/tokenWithTextArray.zig").TokenWithTextArray;
const LanguageIdCodec = @import("../../../../common/languages.zig").LanguageIdCodec;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const Range = @import("../../../../common/core/range.zig").Range;
const OffsetRange = @import("../../../../common/core/ranges/offsetRange.zig").OffsetRange;
const ContiguousMultilineTokensBuilder = @import("../../../../common/tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const ContiguousTokensStore = @import("../../../../common/tokens/contiguousTokensStore.zig").ContiguousTokensStore;
const ModelTokensChangedRange = @import("../../../../common/textModelEvents.zig").ModelTokensChangedRange;
const TestModel = @import("../../port/testSupport.zig").TestModel;

fn metadata(foreground: u9) TokenMetadata {
    var m = TokenMetadata.default;
    m.foreground = foreground;
    return m;
}

test "token primitives: TokenArray roundtrip" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();

    const data = [_]@import("../../../../common/tokens/lineTokens.zig").TokenTextMetadata{
        .{ .text = "ab", .metadata = metadata(1) },
        .{ .text = "c", .metadata = metadata(2) },
    };
    var lineTokens = try LineTokens.createFromTextAndMetadata(allocator, &data, &codec);
    defer lineTokens.deinit();

    var tokenArray = try TokenArray.fromLineTokens(&lineTokens);
    defer tokenArray.deinit();
    try std.testing.expectEqual(2, tokenArray._tokenInfo.items.len);
    try std.testing.expectEqual(2, tokenArray._tokenInfo.items[0].length);
    try std.testing.expectEqual(1, tokenArray._tokenInfo.items[1].length);

    var rebuilt = try tokenArray.toLineTokens(allocator, "abc", &codec);
    defer rebuilt.deinit();
    try std.testing.expectEqualStrings("abc", rebuilt.getLineContent());
    try std.testing.expectEqual(1, rebuilt.getForeground(0));
    try std.testing.expectEqual(2, rebuilt.getForeground(1));
}

test "token primitives: TokenArrayBuilder and TokenWithTextArray" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();

    var builder = TokenArrayBuilder.init(allocator);
    try builder.add(1, metadata(3));
    try builder.add(2, metadata(4));
    var array = builder.build();
    defer array.deinit();

    var rebuilt = try array.toLineTokens(allocator, "abc", &codec);
    defer rebuilt.deinit();

    var withText = try TokenWithTextArray.fromLineTokens(&rebuilt);
    defer withText.deinit();
    try std.testing.expectEqual(2, withText._tokenInfo.items.len);
    try std.testing.expectEqualStrings("a", withText._tokenInfo.items[0].text);
    try std.testing.expectEqualStrings("bc", withText._tokenInfo.items[1].text);

    var sliced = try withText.slice(OffsetRange.init(1, 2));
    defer sliced.deinit();
    try std.testing.expectEqual(1, sliced._tokenInfo.items.len);
    try std.testing.expectEqualStrings("b", sliced._tokenInfo.items[0].text);

    var lineTokens = try withText.toLineTokens(allocator, &codec);
    defer lineTokens.deinit();
    try std.testing.expectEqualStrings("abc", lineTokens.getLineContent());
}

test "token primitives: contiguous multiline tokens applyEdit" {
    const allocator = std.testing.allocator;
    var builder = ContiguousMultilineTokensBuilder.init(allocator);
    defer builder.deinit();
    var tokens = [_]TokenPacked{.{ .endOffset = 5, .metadata = metadata(0) }};
    try builder.add(1, &tokens);
    var block = builder.finalize()[0];

    try block.applyEdit(Range.init(1, 1, 1, 2), "");
    const line = block.getLineTokens(1).?;
    try std.testing.expectEqual(4, line[0].endOffset);
}

test "token primitives: contiguous store multiline update" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "abc\ndef", "nullLanguage");
    defer ctx.deinit();
    var store = ContiguousTokensStore.init(allocator, ctx.codec);
    defer store.deinit();

    var builder = ContiguousMultilineTokensBuilder.init(allocator);
    defer builder.deinit();
    var line1 = [_]TokenPacked{.{ .endOffset = 3, .metadata = metadata(2) }};
    var line2 = [_]TokenPacked{.{ .endOffset = 3, .metadata = metadata(3) }};
    try builder.add(1, &line1);
    try builder.add(2, &line2);

    var changes = ArrayList(ModelTokensChangedRange).init(allocator);
    defer changes.deinit();
    try store.setMultilineTokens(builder.finalize(), ctx.model, &changes);
    try std.testing.expectEqual(1, changes.items.len);
    try std.testing.expectEqual(1, changes.items[0].fromLineNumber);
    try std.testing.expectEqual(2, changes.items[0].toLineNumber);

    const text = try ctx.model.getLineContent(1);
    var result = try store.getTokens(ctx.model.getLanguageId(), 0, text);
    defer result.deinit();
    try std.testing.expectEqual(2, result.getForeground(0));
}

test "token primitives: lazy tokenization factory" {
    const LazyTokenizationSupport = @import("../../../../common/languages.zig").LazyTokenizationSupport;
    const ITokenizationSupport = @import("../../../../common/languages.zig").ITokenizationSupport;
    const IState = @import("../../../../common/languages.zig").IState;
    const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;
    const EncodedTokenizationResult = @import("../../../../common/languages.zig").EncodedTokenizationResult;
    const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;

    const Factory = struct {
        fn create(_: *anyopaque) ?ITokenizationSupport {
            return .{
                .context = undefined,
                .vtable = &.{
                    .getInitialState = struct {
                        fn f(_: *anyopaque, _: std.mem.Allocator) anyerror!IState {
                            return NullState;
                        }
                    }.f,
                    .tokenizeEncoded = struct {
                        fn f(_: *anyopaque, _: std.Io, alloc: std.mem.Allocator, _: []const u8, _: bool, state: IState) anyerror!EncodedTokenizationResult {
                            return .{ .tokens = try alloc.alloc(TokenPacked, 0), .endState = state };
                        }
                    }.f,
                },
            };
        }
    };

    var lazy = LazyTokenizationSupport.init(undefined, Factory.create);
    try TokenizationRegistry.instance.registerFactory("lazyLang", &lazy);
    defer _ = TokenizationRegistry.instance._factories.remove("lazyLang");
    const support = try TokenizationRegistry.instance.getOrCreate("lazyLang");
    try std.testing.expect(support != null);
    try std.testing.expect(TokenizationRegistry.instance.get("lazyLang") != null);
    TokenizationRegistry.instance.unregister("lazyLang");
}

test "token primitives: line token accessors" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("abc def");
    var tokens = ArrayList(TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 3, .metadata = metadata(1) });
    try tokens.append(.{ .endOffset = 7, .metadata = metadata(2) });
    var line = LineTokens.init(tokens, text, &codec);
    defer line.deinit();

    try std.testing.expectEqualStrings("abc", line.getTokenText(0));
    try std.testing.expectEqualStrings(" def", line.getTokenText(1));
    const presentation = line.getPresentation(1);
    try std.testing.expectEqual(2, presentation.foreground);

    var rangeTokens = try line.getTokensInRange(OffsetRange.init(2, 5));
    defer rangeTokens.deinit();
    try std.testing.expectEqual(2, rangeTokens._tokenInfo.items.len);

    var class_name = try line.getClassName(0);
    defer class_name.deinit();
    try std.testing.expectEqualStrings("mtk1", class_name.items);

    var styles = try line.getInlineStyle(0, &[_][]const u8{ "#000000", "#111111" });
    defer styles.deinit();
    try std.testing.expectEqualStrings("color: #111111;", styles.items);
}

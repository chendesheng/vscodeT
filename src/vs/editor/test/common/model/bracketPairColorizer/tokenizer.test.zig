// Port of the `Basic` case from
// `src/vs/editor/test/common/model/bracketPairColorizer/tokenizer.test.ts`.
//
// The port's Tokenizer precomputes the document tokens and exposes the same
// peek/read/skip stream. The custom document below reproduces upstream's
// TokenizedDocument for the two lines of the test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TestModel = @import("../../port/testSupport.zig").TestModel;
const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const languages = @import("../../../../common/languages.zig");
const ITokenizationSupport = languages.ITokenizationSupport;
const IState = languages.IState;
const EncodedTokenizationResult = languages.EncodedTokenizationResult;
const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../../../../common/encodedTokenAttributes.zig").StandardTokenType;
const LanguageConfiguration = @import("../../../../common/languages/languageConfiguration.zig");
const CharacterPair = LanguageConfiguration.CharacterPair;
const tree = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/bracketPairsTree.zig");
const Tokenizer = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/tokenizer.zig").Tokenizer;
const tokenizer_mod = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsTree/tokenizer.zig");

const language_id = "tokenizerTestMode";

fn makeToken(allocator: Allocator, tokens: *ArrayList(TokenPacked), end: usize, token_type: StandardTokenType) !void {
    var metadata = TokenMetadata.default;
    metadata.languageId = 0;
    metadata.tokenType = token_type;
    metadata.balancedBrackets = true;
    try tokens.append(.{ .endOffset = @intCast(end), .metadata = metadata });
    _ = allocator;
}

const Support = struct {
    fn getInitialState(_: *anyopaque, _: Allocator) anyerror!IState {
        return NullState;
    }

    fn tokenizeEncoded(_: *anyopaque, allocator: Allocator, line: []const u8, _: bool, _: IState) anyerror!EncodedTokenizationResult {
        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();
        if (std.mem.eql(u8, line, " { } begin end")) {
            try makeToken(allocator, &tokens, 0, .Other);
            try makeToken(allocator, &tokens, 5, .Other);
            try makeToken(allocator, &tokens, 7, .Other);
        } else {
            try makeToken(allocator, &tokens, 0, .Other);
            try makeToken(allocator, &tokens, 5, .Comment);
            try makeToken(allocator, &tokens, 6, .Other);
        }
        return .{ .tokens = try tokens.toOwnedSlice(), .endState = NullState };
    }

    fn dispose(_: *anyopaque) void {}
};

test "bracket tokenizer: Basic" {
    const allocator = std.testing.allocator;
    const support = ITokenizationSupport{ .context = undefined, .vtable = &.{
        .getInitialState = Support.getInitialState,
        .tokenizeEncoded = Support.tokenizeEncoded,
        .dispose = Support.dispose,
    } };
    try TokenizationRegistry.instance.register(language_id, support);
    defer TokenizationRegistry.instance.unregister(language_id);

    var ctx = try TestModel.init(allocator, " { } begin end\nhello{}", language_id);
    defer ctx.deinit();

    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" }, .{ "(", ")" }, .{ "begin", "end" } };
    var config = LanguageConfiguration.empty();
    config.brackets = &brackets;
    try ctx.languageService.registerLanguageConfiguration(language_id, config);
    ctx.model.forceTokenization(2);

    var ids = tree.StringIdProvider.init(allocator);
    defer ids.deinit();
    var bracket_map = std.StringHashMap(tree.LanguageBrackets).init(allocator);
    defer {
        var it = bracket_map.valueIterator();
        while (it.next()) |value| {
            value.defs.deinit();
            value.all.deinit();
        }
        bracket_map.deinit();
    }

    var tokenizer = Tokenizer.init(allocator, ctx.model, ctx.languageConfigurationService, &ids, &bracket_map);
    defer tokenizer.deinit();
    try tokenizer.tokenize();

    const Expected = struct {
        text: []const u8,
        bracket_key: ?[]const u8,
        bracket_keys: []const []const u8,
        kind: tokenizer_mod.TokenKind,
    };
    const expected = [_]Expected{
        .{ .text = " ", .bracket_key = null, .bracket_keys = &.{}, .kind = .text },
        .{ .text = "{", .bracket_key = "tokenizerTestMode:::{", .bracket_keys = &.{"tokenizerTestMode:::{"}, .kind = .opening_bracket },
        .{ .text = " ", .bracket_key = null, .bracket_keys = &.{}, .kind = .text },
        .{ .text = "}", .bracket_key = "tokenizerTestMode:::{", .bracket_keys = &.{"tokenizerTestMode:::{"}, .kind = .closing_bracket },
        .{ .text = " ", .bracket_key = null, .bracket_keys = &.{}, .kind = .text },
        .{ .text = "begin", .bracket_key = "tokenizerTestMode:::begin", .bracket_keys = &.{"tokenizerTestMode:::begin"}, .kind = .opening_bracket },
        .{ .text = " ", .bracket_key = null, .bracket_keys = &.{}, .kind = .text },
        .{ .text = "end", .bracket_key = "tokenizerTestMode:::begin", .bracket_keys = &.{"tokenizerTestMode:::begin"}, .kind = .closing_bracket },
        .{ .text = "\nhello{", .bracket_key = null, .bracket_keys = &.{}, .kind = .text },
        .{ .text = "}", .bracket_key = "tokenizerTestMode:::{", .bracket_keys = &.{"tokenizerTestMode:::{"}, .kind = .closing_bracket },
    };

    var offset: tree.Length = 0;
    var index: usize = 0;
    while (tokenizer.read()) |token| : (index += 1) {
        try std.testing.expect(index < expected.len);
        const want = expected[index];
        var text = try ctx.model.getValueInRange(tree.lengthsToRange(offset, tree.lengthAdd(offset, token.length)), .LF);
        defer text.deinit();
        try std.testing.expectEqualStrings(want.text, text.items);
        try std.testing.expectEqual(want.kind, token.kind);

        if (want.bracket_key) |key| {
            const id = try ids.get(key);
            try std.testing.expectEqual(id, token.bracket_id);
        } else {
            try std.testing.expectEqual(@as(usize, 0), token.bracket_id);
        }
        var expected_ids = ArrayList(usize).init(allocator);
        defer expected_ids.deinit();
        for (want.bracket_keys) |key| try expected_ids.append(try ids.get(key));
        try std.testing.expectEqual(expected_ids.items.len, token.bracket_ids.count());
        for (expected_ids.items) |id| try std.testing.expect(token.bracket_ids.has(id));
        offset = tree.lengthAdd(offset, token.length);
    }
    try std.testing.expectEqual(expected.len, index);
}

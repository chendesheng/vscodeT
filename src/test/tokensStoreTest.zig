const std = @import("std");
const ArrayList = std.array_list.Managed;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const SparseMultilineTokens = @import("../tokens/sparseMultilineTokens.zig").SparseMultilineTokens;
const SparseToken = @import("../tokens/sparseMultilineTokens.zig").SparseToken;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const MetadataConsts = @import("../encodedTokenAttributes.zig").MetadataConsts;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const Position = @import("../basics/position.zig").Position;

const TokensStoreTests = struct {
    const allocator = std.testing.allocator;
    const SEMANTIC_COLOR = ColorId.Color5;

    fn parseTokensState(state: []const []const u8) !struct { []const u8, SparseMultilineTokens } {
        var text = ArrayList([]const u8).init(allocator);
        defer {
            for (text.items) |item| {
                allocator.free(item);
            }
            text.deinit();
        }

        var tokens = ArrayList(SparseToken).init(allocator);

        var baseLine: usize = 1;
        for (0..state.len) |i| {
            const line = state[i];

            var startOffset: usize = 0;
            var lineText = ArrayList(u8).init(allocator);
            defer lineText.deinit();
            while (true) {
                const _firstPipeOffset = std.mem.indexOf(u8, line[startOffset..], "|");
                if (_firstPipeOffset == null) {
                    break;
                }
                const firstPipeOffset = _firstPipeOffset.? + startOffset;
                const _secondPipeOffset = std.mem.indexOf(u8, line[firstPipeOffset + 1 ..], "|");
                if (_secondPipeOffset == null) {
                    break;
                }
                const secondPipeOffset = _secondPipeOffset.? + firstPipeOffset + 1;
                if (firstPipeOffset + 1 == secondPipeOffset) {
                    // skip ||
                    try lineText.appendSlice(line[startOffset .. secondPipeOffset + 1]);
                    startOffset = secondPipeOffset + 1;
                    continue;
                }

                try lineText.appendSlice(line[startOffset..firstPipeOffset]);
                const tokenStartCharacter = lineText.items.len;
                const tokenLength = secondPipeOffset - firstPipeOffset - 1;
                const metadata: TokenMetadata = .{
                    .languageId = MetadataConsts.SEMANTIC_USE_FOREGROUND,
                    .foreground = SEMANTIC_COLOR,
                };

                if (tokens.items.len == 0) {
                    baseLine = i + 1;
                }
                try tokens.append(SparseToken.init(
                    @intCast(i + 1 - baseLine),
                    @intCast(tokenStartCharacter),
                    @intCast(tokenStartCharacter + tokenLength),
                    metadata,
                ));

                try lineText.appendSlice(line[firstPipeOffset + 1 .. firstPipeOffset + 1 + tokenLength]);
                startOffset = secondPipeOffset + 1;
            }

            try lineText.appendSlice(line[startOffset..]);

            try text.append(try lineText.toOwnedSlice());
        }

        return .{ try std.mem.join(allocator, "\n", text.items), SparseMultilineTokens.initFromTokens(baseLine, tokens) };
    }

    fn extractState(model: *TextModel) ![]const []const u8 {
        var result = ArrayList([]const u8).init(allocator);
        defer result.deinit();

        for (1..model.getLineCount() + 1) |lineNumber| {
            var lineTokens = try model.tokenization().getLineTokens(lineNumber);
            defer lineTokens.deinit();
            const lineContent = try model.getLineContent(lineNumber);
            defer lineContent.deinit();

            var lineText = ArrayList(u8).init(allocator);
            defer lineText.deinit();

            for (0..lineTokens.getCount()) |i| {
                const tokenStartCharacter = lineTokens.getStartOffset(i);
                const tokenEndCharacter = lineTokens.getEndOffset(i);
                const metadata = lineTokens.getMetadata(i);
                const color = metadata.foreground;
                const tokenText = lineContent.items[tokenStartCharacter..tokenEndCharacter];
                if (color == SEMANTIC_COLOR) {
                    try lineText.append('|');
                    try lineText.appendSlice(tokenText);
                    try lineText.append('|');
                } else {
                    try lineText.appendSlice(tokenText);
                }
            }

            try result.append(try lineText.toOwnedSlice());
        }
        return try result.toOwnedSlice();
    }

    fn testTokensAdjustment(rawInitialState: []const []const u8, edits: []const IdentifiedSingleEditOperation, rawFinalState: []const []const u8) !void {
        const initialState = try parseTokensState(rawInitialState);
        defer allocator.free(initialState.@"0");
        const model = try createTextModel(allocator, initialState.@"0", null, null);
        defer disposeTextModel(model);
        try model.tokenization().setSemanticTokens(&[_]SparseMultilineTokens{initialState.@"1"}, true);
        _ = try model.applyEdits(edits, null);
        const actualState = try extractState(model);
        defer {
            for (actualState) |item| {
                allocator.free(item);
            }
            allocator.free(actualState);
        }
        try std.testing.expectEqualDeep(actualState, rawFinalState);
    }

    test "issue #86303 - color shifting between different tokens" {
        try testTokensAdjustment(
            &[_][]const u8{
                "import { |URI| } from 'vs/base/common/uri';",
                "const foo = |URI|.parse('hey');",
            },
            &[_]IdentifiedSingleEditOperation{
                IdentifiedSingleEditOperation.init(.init(2, 9, 2, 10), .empty),
            },
            &[_][]const u8{
                "import { |URI| } from 'vs/base/common/uri';",
                "const fo = |URI|.parse('hey');",
            },
        );
    }

    test "deleting a newline" {
        try testTokensAdjustment(
            &[_][]const u8{
                "import { |URI| } from 'vs/base/common/uri';",
                "const foo = |URI|.parse('hey');",
            },
            &[_]IdentifiedSingleEditOperation{
                IdentifiedSingleEditOperation.init(.init(1, 42, 2, 1), .empty),
            },
            &[_][]const u8{
                "import { |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
            },
        );
    }

    test "inserting a newline" {
        try testTokensAdjustment(
            &[_][]const u8{
                "import { |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
            },
            &[_]IdentifiedSingleEditOperation{
                IdentifiedSingleEditOperation.init(.init(1, 42, 1, 42), .initBorrowed("\n")),
            },
            &[_][]const u8{
                "import { |URI| } from 'vs/base/common/uri';",
                "const foo = |URI|.parse('hey');",
            },
        );
    }

    test "deleting a newline 2" {
        try testTokensAdjustment(
            &[_][]const u8{
                "import { ",
                "    |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
            },
            &[_]IdentifiedSingleEditOperation{
                IdentifiedSingleEditOperation.init(.init(1, 10, 2, 5), .empty),
            },
            &[_][]const u8{
                "import { |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
            },
        );
    }

    test "issue #179268: a complex edit" {
        try testTokensAdjustment(&[_][]const u8{
            "|export| |'interior_material_selector.dart'|;",
            "|export| |'mileage_selector.dart'|;",
            "|export| |'owners_selector.dart'|;",
            "|export| |'price_selector.dart'|;",
            "|export| |'seat_count_selector.dart'|;",
            "|export| |'year_selector.dart'|;",
            "|export| |'winter_options_selector.dart'|;|export| |'camera_selector.dart'|;",
        }, &[_]IdentifiedSingleEditOperation{
            IdentifiedSingleEditOperation.init(.init(1, 9, 1, 9), .initBorrowed("camera_selector.dart';\nexport '")),
            IdentifiedSingleEditOperation.init(.init(6, 9, 7, 9), .initBorrowed("")),
            IdentifiedSingleEditOperation.init(.init(7, 39, 7, 39), .initBorrowed("\n")),
            IdentifiedSingleEditOperation.init(.init(7, 47, 7, 48), .initBorrowed("ye")),
            IdentifiedSingleEditOperation.init(.init(7, 49, 7, 51), .initBorrowed("")),
            IdentifiedSingleEditOperation.init(.init(7, 52, 7, 53), .initBorrowed("")),
        }, &[_][]const u8{
            "|export| |'|camera_selector.dart';",
            "export 'interior_material_selector.dart';",
            "|export| |'mileage_selector.dart'|;",
            "|export| |'owners_selector.dart'|;",
            "|export| |'price_selector.dart'|;",
            "|export| |'seat_count_selector.dart'|;",
            "|export| |'||winter_options_selector.dart'|;",
            "|export| |'year_selector.dart'|;",
        });
    }

    test "issue #91936: Semantic token color highlighting fails on line with selected text" {
        const model = try createTextModel(allocator, "                    else if ($s = 08) then '\\b'", null, null);
        defer disposeTextModel(model);

        var tokens = ArrayList(SparseToken).init(allocator);
        try tokens.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 20, 24, 0b01111000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 25, 27, 0b01111000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 28, 29, 0b00001000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 29, 31, 0b10000000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 32, 33, 0b00001000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 34, 36, 0b00110000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 36, 37, 0b00001000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 38, 42, 0b01111000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 0, 43, 47, 0b01011000000000010000 })),
        });
        try model.tokenization()
            .setSemanticTokens(&[_]SparseMultilineTokens{.initFromTokens(1, tokens)}, true);

        var lineTokens = try model.tokenization().getLineTokens(1);
        defer lineTokens.deinit();

        try std.testing.expectEqualDeep(&[_]TokenPacked{
            @as(TokenPacked, @bitCast([2]u32{ 20, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 24, 0b10000001111000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 25, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 27, 0b10000001111000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 28, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 29, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 31, 0b10000010000000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 32, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 33, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 34, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 36, 0b10000000110000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 37, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 38, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 42, 0b10000001111000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 43, 0b10000000001000010000000001 })),
            @as(TokenPacked, @bitCast([2]u32{ 47, 0b10000001011000010000000001 })),
        }, lineTokens._tokens.items);
    }

    // test "issue #147944: Language id 'vs.editor.nullLanguage' is not configured nor known" {
    //     // const disposables = new DisposableStore();
    //     // const instantiationService = createModelServices(disposables, [
    //     //[ILanguageConfigurationService, LanguageConfigurationService]
    //     //]);
    //     //const model = disposables.add(instantiateTextModel(instantiationService, '--[[\n\n]]'));
    //     const model = try createTextModel(allocator, "--[[\n\n]]", null, null);
    //     defer disposeTextModel(model);
    //     var tokens = ArrayList(SparseToken).init(allocator);
    //     try tokens.appendSlice(&[_]SparseToken{
    //         @as(SparseToken, @bitCast([4]u32{ 0, 2, 4, 0b100000000000010000 })),
    //         @as(SparseToken, @bitCast([4]u32{ 1, 0, 0, 0b100000000000010000 })),
    //         @as(SparseToken, @bitCast([4]u32{ 2, 0, 2, 0b100000000000010000 })),
    //     });
    //     try model.tokenization().setSemanticTokens(&[_]SparseMultilineTokens{
    //         .initFromTokens(1, tokens),
    //     }, true);
    //     try std.testing.expectEqual(null, model.getWordAtPosition(.init(2, 1)));
    // }
};

test "tokensStore" {
    _ = TokensStoreTests{};
}

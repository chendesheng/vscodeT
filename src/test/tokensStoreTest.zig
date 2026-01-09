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
const LanguageIdCodec = @import("../services/languageRegistry.zig").LanguageIdCodec;
const SparseTokensStore = @import("../tokens/sparseTokensStore.zig").SparseTokensStore;
const Range = @import("../basics/range.zig").Range;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const FontStyle = @import("../encodedTokenAttributes.zig").FontStyle;

const TokensStoreTests = struct {
    const allocator = std.testing.allocator;
    const SEMANTIC_COLOR = 5;

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

        return .{
            try std.mem.join(allocator, "\n", text.items),
            SparseMultilineTokens.initFromTokens(baseLine, tokens),
        };
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

    test "issue #147944: Language id 'vs.editor.nullLanguage' is not configured nor known" {
        // const disposables = new DisposableStore();
        // const instantiationService = createModelServices(disposables, [
        //[ILanguageConfigurationService, LanguageConfigurationService]
        //]);
        //const model = disposables.add(instantiateTextModel(instantiationService, '--[[\n\n]]'));
        const model = try createTextModel(allocator, "--[[\n\n]]", null, null);
        defer disposeTextModel(model);
        var tokens = ArrayList(SparseToken).init(allocator);
        try tokens.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 2, 4, 0b100000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 1, 0, 0, 0b100000000000010000 })),
            @as(SparseToken, @bitCast([4]u32{ 2, 0, 2, 0b100000000000010000 })),
        });
        try model.tokenization().setSemanticTokens(&[_]SparseMultilineTokens{
            .initFromTokens(1, tokens),
        }, true);
        try std.testing.expectEqual(null, model.getWordAtPosition(.init(2, 1)));
    }

    test "partial tokens 1" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        // setPartial: [1,1 -> 31,2], [(5,5-10),(10,5-10),(15,5-10),(20,5-10),(25,5-10),(30,5-10)]
        var arr = ArrayList(SparseToken).init(allocator);
        try arr.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 1 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 2 })),
            @as(SparseToken, @bitCast([4]u32{ 10, 5, 10, 3 })),
            @as(SparseToken, @bitCast([4]u32{ 15, 5, 10, 4 })),
            @as(SparseToken, @bitCast([4]u32{ 20, 5, 10, 5 })),
            @as(SparseToken, @bitCast([4]u32{ 25, 5, 10, 6 })),
        });
        _ = try store.setPartial(.init(1, 1, 31, 2), &[_]SparseMultilineTokens{.initFromTokens(5, arr)});

        // setPartial: [18,1 -> 42,1], [(20,5-10),(25,5-10),(30,5-10),(35,5-10),(40,5-10)]
        var arr2 = ArrayList(SparseToken).init(allocator);
        try arr2.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 4 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 5 })),
            @as(SparseToken, @bitCast([4]u32{ 10, 5, 10, 6 })),
            @as(SparseToken, @bitCast([4]u32{ 15, 5, 10, 7 })),
            @as(SparseToken, @bitCast([4]u32{ 20, 5, 10, 8 })),
        });
        _ = try store.setPartial(.init(18, 1, 42, 1), &[_]SparseMultilineTokens{.initFromTokens(20, arr2)});

        // setPartial: [1,1 -> 31,2], [(5,5-10),(10,5-10),(15,5-10),(20,5-10),(25,5-10),(30,5-10)]
        var arr3 = ArrayList(SparseToken).init(allocator);
        try arr3.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 1 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 2 })),
            @as(SparseToken, @bitCast([4]u32{ 10, 5, 10, 3 })),
            @as(SparseToken, @bitCast([4]u32{ 15, 5, 10, 4 })),
            @as(SparseToken, @bitCast([4]u32{ 20, 5, 10, 5 })),
            @as(SparseToken, @bitCast([4]u32{ 25, 5, 10, 6 })),
        });
        _ = try store.setPartial(.init(1, 1, 31, 2), &[_]SparseMultilineTokens{.initFromTokens(5, arr3)});

        var tokens = ArrayList(TokenPacked).init(allocator);
        defer tokens.deinit();
        try tokens.append(@as(TokenPacked, @bitCast([2]u32{ 12, 1 })));
        var lineTokens = try store.addSparseTokens(10, LineTokens.init(tokens, "enum Enum1 {", codec));
        defer lineTokens.deinit();
        try std.testing.expectEqual(3, lineTokens.getCount());
    }

    test "partial tokens 2" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        // setPartial: [1,1 -> 31,2], [(5,5-10),(10,5-10),(15,5-10),(20,5-10),(25,5-10),(30,5-10)]
        var arr = ArrayList(SparseToken).init(allocator);
        try arr.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 1 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 2 })),
            @as(SparseToken, @bitCast([4]u32{ 10, 5, 10, 3 })),
            @as(SparseToken, @bitCast([4]u32{ 15, 5, 10, 4 })),
            @as(SparseToken, @bitCast([4]u32{ 20, 5, 10, 5 })),
            @as(SparseToken, @bitCast([4]u32{ 25, 5, 10, 6 })),
        });

        _ = try store.setPartial(.init(1, 1, 31, 2), &[_]SparseMultilineTokens{.initFromTokens(5, arr)});

        // setPartial: [6,1 -> 36,2], [(10,5-10),(15,5-10),(20,5-10),(25,5-10),(30,5-10),(35,5-10)]
        var arr2 = ArrayList(SparseToken).init(allocator);
        try arr2.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 2 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 3 })),
            @as(SparseToken, @bitCast([4]u32{ 10, 5, 10, 4 })),
            @as(SparseToken, @bitCast([4]u32{ 15, 5, 10, 5 })),
            @as(SparseToken, @bitCast([4]u32{ 20, 5, 10, 6 })),
        });
        _ = try store.setPartial(.init(6, 1, 36, 2), &[_]SparseMultilineTokens{.initFromTokens(10, arr2)});

        // setPartial: [17,1 -> 42,1], [(20,5-10),(25,5-10),(30,5-10),(35,5-10),(40,5-10)]
        var arr3 = ArrayList(SparseToken).init(allocator);
        try arr3.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 4 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 5 })),
            @as(SparseToken, @bitCast([4]u32{ 10, 5, 10, 6 })),
            @as(SparseToken, @bitCast([4]u32{ 15, 5, 10, 7 })),
            @as(SparseToken, @bitCast([4]u32{ 20, 5, 10, 8 })),
        });
        _ = try store.setPartial(.init(17, 1, 42, 1), &[_]SparseMultilineTokens{.initFromTokens(20, arr3)});

        var tokens = ArrayList(TokenPacked).init(allocator);
        defer tokens.deinit();
        try tokens.append(@as(TokenPacked, @bitCast([2]u32{ 12, 1 })));
        var lineTokens = try store.addSparseTokens(20, LineTokens.init(tokens, "enum Enum1 {", codec));
        defer lineTokens.deinit();
        try std.testing.expectEqual(3, lineTokens.getCount());
    }

    test "partial tokens 3" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        // setPartial: [1,1 -> 31,2], [(5,5-10),(10,5-10),(15,5-10),(20,5-10),(25,5-10),(30,5-10)]
        var arr = ArrayList(SparseToken).init(allocator);
        try arr.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 1 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 2 })),
            @as(SparseToken, @bitCast([4]u32{ 10, 5, 10, 3 })),
            @as(SparseToken, @bitCast([4]u32{ 15, 5, 10, 4 })),
            @as(SparseToken, @bitCast([4]u32{ 20, 5, 10, 5 })),
            @as(SparseToken, @bitCast([4]u32{ 25, 5, 10, 6 })),
        });
        _ = try store.setPartial(.init(1, 1, 31, 2), &[_]SparseMultilineTokens{.initFromTokens(5, arr)});

        // setPartial: [11,1 -> 16,2], [(15,5-10),(20,5-10)]
        var arr2 = ArrayList(SparseToken).init(allocator);
        try arr2.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 5, 10, 3 })),
            @as(SparseToken, @bitCast([4]u32{ 5, 5, 10, 4 })),
        });
        _ = try store.setPartial(.init(11, 1, 16, 2), &[_]SparseMultilineTokens{.initFromTokens(10, arr2)});

        var tokens = ArrayList(TokenPacked).init(allocator);
        defer tokens.deinit();
        try tokens.append(@as(TokenPacked, @bitCast([2]u32{ 12, 1 })));
        var lineTokens = try store.addSparseTokens(5, LineTokens.init(tokens, "enum Enum1 {", codec));
        defer lineTokens.deinit();
        try std.testing.expectEqual(3, lineTokens.getCount());
    }

    test "issue #94133: Semantic colors stick around when using (only) range provider" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        // setPartial: [1,1 -> 1,20] [(1,9-11)]
        var arr = ArrayList(SparseToken).init(allocator);
        try arr.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{ 0, 9, 11, 1 })),
        });
        _ = try store.setPartial(.init(1, 1, 1, 20), &[_]SparseMultilineTokens{.initFromTokens(1, arr)});

        // setPartial: [1,1 -> 1,20], []
        _ = try store.setPartial(.init(1, 1, 1, 20), &[_]SparseMultilineTokens{});

        var tokens = ArrayList(TokenPacked).init(allocator);
        defer tokens.deinit();
        try tokens.append(@as(TokenPacked, @bitCast([2]u32{ 12, 1 })));
        var lineTokens = try store.addSparseTokens(1, LineTokens.init(tokens, "enum Enum1 {", codec));
        try std.testing.expectEqual(1, lineTokens.getCount());
    }

    fn createTokens(_str: []const u8) !SparseMultilineTokens {
        const str = _str[2 .. _str.len - 2];
        var strTokens = std.mem.splitSequence(u8, str, "),(");
        var result = ArrayList(SparseToken).init(allocator);
        var firstLineNumber: u32 = 0;
        while (strTokens.next()) |strToken| {
            var pieces = std.mem.splitAny(u8, strToken, ",-");
            const lineNumber = try std.fmt.parseInt(u32, pieces.next().?, 10);
            const startChar = try std.fmt.parseInt(u32, pieces.next().?, 10);
            const endChar = try std.fmt.parseInt(u32, pieces.next().?, 10);
            if (firstLineNumber == 0) {
                // this is the first line
                firstLineNumber = lineNumber;
            }
            try result.append(@as(SparseToken, @bitCast([4]u32{ lineNumber - firstLineNumber, startChar, endChar, (lineNumber + startChar) % 13 })));
        }
        return SparseMultilineTokens.initFromTokens(firstLineNumber, result);
    }

    test "bug" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();
        // setPartial [36446,1 -> 36475,115] [(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35),(36470,38-46),(36473,25-35),(36473,36-51),(36474,28-33),(36474,36-49),(36474,50-58),(36475,35-53),(36475,54-62)]
        _ = try store.setPartial(.init(36446, 1, 36475, 115), &[_]SparseMultilineTokens{try createTokens("[(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35),(36470,38-46),(36473,25-35),(36473,36-51),(36474,28-33),(36474,36-49),(36474,50-58),(36475,35-53),(36475,54-62)]")});
        // setPartial [36436,1 -> 36464,142] [(36437,33-37),(36437,38-42),(36437,47-57),(36437,58-67),(36438,35-53),(36438,54-62),(36440,24-29),(36440,33-46),(36440,47-53),(36442,25-35),(36442,36-50),(36443,30-39),(36443,42-46),(36443,47-53),(36443,54-58),(36443,63-73),(36443,74-84),(36443,87-91),(36443,92-98),(36443,101-105),(36443,106-112),(36443,113-119),(36444,28-37),(36444,38-42),(36444,47-57),(36444,58-75),(36444,80-95),(36444,96-105),(36445,35-53),(36445,54-62),(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62)]
        _ = try store.setPartial(.init(36436, 1, 36464, 142), &[_]SparseMultilineTokens{try createTokens("[(36437,33-37),(36437,38-42),(36437,47-57),(36437,58-67),(36438,35-53),(36438,54-62),(36440,24-29),(36440,33-46),(36440,47-53),(36442,25-35),(36442,36-50),(36443,30-39),(36443,42-46),(36443,47-53),(36443,54-58),(36443,63-73),(36443,74-84),(36443,87-91),(36443,92-98),(36443,101-105),(36443,106-112),(36443,113-119),(36444,28-37),(36444,38-42),(36444,47-57),(36444,58-75),(36444,80-95),(36444,96-105),(36445,35-53),(36445,54-62),(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62)]")});
        // setPartial [36457,1 -> 36485,140] [(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35),(36470,38-46),(36473,25-35),(36473,36-51),(36474,28-33),(36474,36-49),(36474,50-58),(36475,35-53),(36475,54-62),(36477,28-32),(36477,33-37),(36477,42-52),(36477,53-69),(36478,32-36),(36478,37-41),(36478,46-56),(36478,57-74),(36479,32-36),(36479,37-41),(36479,46-56),(36479,57-76),(36480,32-36),(36480,37-41),(36480,46-56),(36480,57-68),(36481,32-36),(36481,37-41),(36481,46-56),(36481,57-68),(36482,39-57),(36482,58-66),(36484,34-38),(36484,39-45),(36484,46-50),(36484,55-65),(36484,66-82),(36484,86-97),(36484,98-102),(36484,103-109),(36484,111-124),(36484,125-133),(36485,39-57),(36485,58-66)]
        _ = try store.setPartial(.init(36457, 1, 36485, 140), &[_]SparseMultilineTokens{try createTokens("[(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35),(36470,38-46),(36473,25-35),(36473,36-51),(36474,28-33),(36474,36-49),(36474,50-58),(36475,35-53),(36475,54-62),(36477,28-32),(36477,33-37),(36477,42-52),(36477,53-69),(36478,32-36),(36478,37-41),(36478,46-56),(36478,57-74),(36479,32-36),(36479,37-41),(36479,46-56),(36479,57-76),(36480,32-36),(36480,37-41),(36480,46-56),(36480,57-68),(36481,32-36),(36481,37-41),(36481,46-56),(36481,57-68),(36482,39-57),(36482,58-66),(36484,34-38),(36484,39-45),(36484,46-50),(36484,55-65),(36484,66-82),(36484,86-97),(36484,98-102),(36484,103-109),(36484,111-124),(36484,125-133),(36485,39-57),(36485,58-66)]")});
        // setPartial [36441,1 -> 36469,56] [(36442,25-35),(36442,36-50),(36443,30-39),(36443,42-46),(36443,47-53),(36443,54-58),(36443,63-73),(36443,74-84),(36443,87-91),(36443,92-98),(36443,101-105),(36443,106-112),(36443,113-119),(36444,28-37),(36444,38-42),(36444,47-57),(36444,58-75),(36444,80-95),(36444,96-105),(36445,35-53),(36445,54-62),(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35)]
        _ = try store.setPartial(.init(36441, 1, 36469, 56), &[_]SparseMultilineTokens{try createTokens("[(36442,25-35),(36442,36-50),(36443,30-39),(36443,42-46),(36443,47-53),(36443,54-58),(36443,63-73),(36443,74-84),(36443,87-91),(36443,92-98),(36443,101-105),(36443,106-112),(36443,113-119),(36444,28-37),(36444,38-42),(36444,47-57),(36444,58-75),(36444,80-95),(36444,96-105),(36445,35-53),(36445,54-62),(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35)]")});

        var tokens = ArrayList(TokenPacked).init(allocator);
        defer tokens.deinit();
        try tokens.append(@as(TokenPacked, @bitCast([2]u32{ 60, 1 })));
        var lineTokens = try store.addSparseTokens(36451, LineTokens.init(tokens, "                        if (flags & ModifierFlags.Ambient) {", codec));
        defer lineTokens.deinit();
        try std.testing.expectEqual(7, lineTokens.getCount());
    }

    fn createTMMetadata(foreground: u9, fontStyle: FontStyle, languageId: u8) u32 {
        return @bitCast(TokenMetadata{
            .languageId = languageId,
            .fontStyle = fontStyle,
            .foreground = foreground,
        });
    }

    fn toArr(lineTokens: LineTokens) !ArrayList(u32) {
        var r = ArrayList(u32).init(allocator);
        for (0..lineTokens.getCount()) |i| {
            try r.append(lineTokens.getEndOffset(i));
            try r.append(@bitCast(lineTokens.getMetadata(i)));
        }
        return r;
    }

    test "issue #95949: Identifiers are colored in bold when targetting keywords" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        var arrTokens = ArrayList(SparseToken).init(allocator);
        try arrTokens.append(@as(SparseToken, @bitCast([4]u32{
            0,
            6,
            11,
            (1 << MetadataConsts.FOREGROUND_OFFSET) | MetadataConsts.SEMANTIC_USE_FOREGROUND,
        })));
        try store.set(&[_]SparseMultilineTokens{SparseMultilineTokens.initFromTokens(1, arrTokens)}, true, null);

        var arrTokenPakced = ArrayList(TokenPacked).init(allocator);
        defer arrTokenPakced.deinit();
        try arrTokenPakced.appendSlice(&[_]TokenPacked{
            @as(TokenPacked, @bitCast([2]u32{ 5, createTMMetadata(5, FontStyle.Bold, 53) })),
            @as(TokenPacked, @bitCast([2]u32{ 14, createTMMetadata(1, FontStyle.None, 53) })),
            @as(TokenPacked, @bitCast([2]u32{ 17, createTMMetadata(6, FontStyle.None, 53) })),
            @as(TokenPacked, @bitCast([2]u32{ 18, createTMMetadata(1, FontStyle.None, 53) })),
        });
        var lineTokens = try store.addSparseTokens(1, LineTokens.init(arrTokenPakced, "const hello = 123;", codec));
        defer lineTokens.deinit();

        const actual = try toArr(lineTokens);
        defer actual.deinit();
        try std.testing.expectEqualSlices(
            u32,
            &[_]u32{
                5,  createTMMetadata(5, FontStyle.Bold, 53),
                6,  createTMMetadata(1, FontStyle.None, 53),
                11, createTMMetadata(1, FontStyle.None, 53),
                14, createTMMetadata(1, FontStyle.None, 53),
                17, createTMMetadata(6, FontStyle.None, 53),
                18, createTMMetadata(1, FontStyle.None, 53),
            },
            actual.items,
        );
    }

    test "BUG: setPartial with startLineNumber > 1 and token removal creates invalid state" {
        // The bug is the same regardless of the starting line number.
        // If a piece starts at line 5 and all tokens are removed via setPartial:
        // - startLineNumber stays at 5
        // - endLineNumber becomes 5 + (-1) = 4
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        var arrTokens = ArrayList(SparseToken).init(allocator);
        try arrTokens.append(@as(SparseToken, @bitCast([4]u32{
            0,
            5,
            10,
            1,
        })));
        // Set initial tokens on line 5
        try store.set(&[_]SparseMultilineTokens{SparseMultilineTokens.initFromTokens(5, arrTokens)}, false, null);

        try std.testing.expectEqual(false, store.isEmpty());

        // Remove all tokens via setPartial
        _ = try store.setPartial(.init(5, 1, 5, 20), &[_]SparseMultilineTokens{});

        // BUG: During processing, pieces can have invalid line numbers
        // The store should remove empty pieces and remain valid

        std.testing.expectEqual(true, store.isEmpty()) catch |err| {
            std.debug.print("Store should be empty after setPartial removes all tokens\n", .{});
            return err;
        };
    }

    test "BUG: setPartial with split that creates empty first piece with invalid line numbers" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        // Set initial tokens - token is on line 11
        var arrTokens = ArrayList(SparseToken).init(allocator);
        try arrTokens.append(@as(SparseToken, @bitCast([4]u32{
            10, 5, 10, 1, // line 11 (deltaLine=10 from startLineNumber=1), chars 5-10
        })));
        try store.set(&[_]SparseMultilineTokens{SparseMultilineTokens.initFromTokens(1, arrTokens)}, false, null);

        // setPartial with a range [1,1 -> 5,1] that will cause a split where the first piece is empty
        _ = try store.setPartial(.init(1, 1, 5, 1), &[_]SparseMultilineTokens{});

        std.testing.expectEqual(false, store.isEmpty()) catch |err| {
            std.debug.print("Store should still have the token on line 11\n", .{});
            return err;
        };

        // The token at line 11 should be retrievable after the split
        var arrTokenPakced = ArrayList(TokenPacked).init(allocator);
        try arrTokenPakced.appendSlice(&[_]TokenPacked{
            @as(TokenPacked, @bitCast([2]u32{ 22, 1 })),
        });
        defer arrTokenPakced.deinit();
        var lineTokens = try store.addSparseTokens(11, LineTokens.init(arrTokenPakced, "    test line text    ", codec));
        defer lineTokens.deinit();
        std.testing.expectEqual(3, lineTokens.getCount()) catch |err| {
            std.debug.print("Should have 3 tokens: base token start + semantic token from line 11 + base token end\n", .{});
            return err;
        };
        std.testing.expectEqual(5, lineTokens.getStartOffset(1)) catch |err| {
            std.debug.print("Semantic token should start at offset 5\n", .{});
            return err;
        };
        std.testing.expectEqual(10, lineTokens.getEndOffset(1)) catch |err| {
            std.debug.print("Semantic token should end at offset 10\n", .{});
            return err;
        };
    }

    test "piece with startLineNumber 0 and endLineNumber -1 after encompassing deletion" {
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        var store = SparseTokensStore.init(allocator, codec);
        defer store.deinit();

        // Set initial tokens on lines 5-10
        var arrTokens = ArrayList(SparseToken).init(allocator);
        try arrTokens.appendSlice(&[_]SparseToken{
            @as(SparseToken, @bitCast([4]u32{
                0, 0, 5, 1, // line 5, chars 0-5
            })),
            @as(SparseToken, @bitCast([4]u32{
                5, 0, 5, 2, // line 10, chars 0-5
            })),
        });
        var piece = SparseMultilineTokens.initFromTokens(5, arrTokens);
        try store.set(&[_]SparseMultilineTokens{piece}, false, null);

        // Verify initial state
        try std.testing.expectEqual(5, piece.getStartLineNumber());
        try std.testing.expectEqual(10, piece.getEndLineNumber());
        try std.testing.expectEqual(false, piece.isEmpty());

        // Perform an edit that completely encompasses the token range
        // Delete from line 1 to line 20 (encompasses lines 5-10)
        // This triggers the case in _acceptDeleteRange where:
        // if (firstLineIndex < 0 && lastLineIndex >= tokenMaxDeltaLine + 1)
        // Which sets this._startLineNumber = 0 and calls this._tokens.clear()
        store.acceptEdit(
            .initRaw(1, 1, 20, 1),
            0, // eolCount - no new lines inserted
            0, // firstLineLength
            0, // lastLineLength
            0, // firstCharCode
        );

        // After an encompassing deletion, the piece should be empty
        // std.testing.expectEqual(true, piece.isEmpty()) catch |err| {
        //     std.debug.print("Piece should be empty after encompassing deletion\n", .{});
        //     return err;
        // };

        // EXPECTED BEHAVIOR: The store should be empty (no pieces with invalid line numbers)
        // Currently fails because the piece remains with startLineNumber=0, endLineNumber=-1
        std.testing.expectEqual(true, store.isEmpty()) catch |err| {
            std.debug.print("Store should be empty after all tokens are deleted by encompassing edit\n", .{});
            return err;
        };
    }
};

test "tokensStore" {
    _ = TokensStoreTests{};
}

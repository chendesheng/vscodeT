const std = @import("std");
const ArrayList = std.array_list.Managed;
const TestModel = @import("../port/testSupport.zig").TestModel;
const createSparseTokens = @import("../port/testSupport.zig").createSparseTokens;
const SparseMultilineTokens = @import("../../../common/tokens/sparseMultilineTokens.zig").SparseMultilineTokens;
const Range = @import("../../../common/core/range.zig").Range;
const IdentifiedSingleEditOperation = @import("../../../common/model.zig").IdentifiedSingleEditOperation;
const String = @import("../../../../base/common/strings.zig").String;
const LineTokens = @import("../../../common/tokens/lineTokens.zig").LineTokens;
const TokenPacked = @import("../../../common/tokens/lineTokens.zig").TokenPacked;
const SparseTokensStore = @import("../../../common/tokens/sparseTokensStore.zig").SparseTokensStore;
const TokenMetadata = @import("../../../common/encodedTokenAttributes.zig").TokenMetadata;
const FontStyle = @import("../../../common/encodedTokenAttributes.zig").FontStyle;
const Position = @import("../../../common/core/position.zig").Position;
const LanguageIdCodec = @import("../../../common/languages.zig").LanguageIdCodec;

const SEMANTIC_COLOR: u32 = 5;
const SEMANTIC_USE_FOREGROUND: u32 = 1 << 4;
const FOREGROUND_OFFSET: u32 = 15;

const Edit = struct { range: Range, text: []const u8 };

fn metadata() u32 {
    return (SEMANTIC_COLOR << FOREGROUND_OFFSET) | SEMANTIC_USE_FOREGROUND;
}

fn parseTokensState(allocator: std.mem.Allocator, state: []const []const u8) !struct { text: ArrayList(u8), tokens: SparseMultilineTokens } {
    var text = ArrayList(u8).init(allocator);
    errdefer text.deinit();
    var values = ArrayList(u32).init(allocator);
    defer values.deinit();
    var baseLine: usize = 1;

    for (state, 0..) |line, lineIndex| {
        var lineText = ArrayList(u8).init(allocator);
        defer lineText.deinit();
        var startOffset: usize = 0;
        while (true) {
            const firstPipe = std.mem.indexOfPos(u8, line, startOffset, "|") orelse break;
            const secondPipe = std.mem.indexOfPos(u8, line, firstPipe + 1, "|") orelse break;
            if (firstPipe + 1 == secondPipe) {
                try lineText.appendSlice(line[startOffset .. secondPipe + 1]);
                startOffset = secondPipe + 1;
                continue;
            }

            try lineText.appendSlice(line[startOffset..firstPipe]);
            const tokenStart = lineText.items.len;
            try lineText.appendSlice(line[firstPipe + 1 .. secondPipe]);
            const tokenLength = secondPipe - firstPipe - 1;
            if (values.items.len == 0) baseLine = lineIndex + 1;
            try values.appendSlice(&.{ @intCast(lineIndex + 1 - baseLine), @intCast(tokenStart), @intCast(tokenStart + tokenLength), metadata() });
            startOffset = secondPipe + 1;
        }
        try lineText.appendSlice(line[startOffset..]);
        if (lineIndex > 0) try text.append('\n');
        try text.appendSlice(lineText.items);
    }

    return .{ .text = text, .tokens = try createSparseTokens(allocator, baseLine, values.items) };
}

fn extractState(allocator: std.mem.Allocator, model: *@import("../../../common/model/textModel.zig").TextModel) !ArrayList(ArrayList(u8)) {
    var result = ArrayList(ArrayList(u8)).init(allocator);
    errdefer {
        for (result.items) |*line| line.deinit();
        result.deinit();
    }
    var lineNumber: usize = 1;
    while (lineNumber <= model.getLineCount()) : (lineNumber += 1) {
        var lineText = ArrayList(u8).init(allocator);
        errdefer lineText.deinit();
        var content = try model.getLineContent(lineNumber);
        defer content.deinit();
        var lineTokens = try model.tokenization().getLineTokens(lineNumber);
        defer lineTokens.deinit();
        for (0..lineTokens.getCount()) |i| {
            const start = lineTokens.getStartOffset(i);
            const end = lineTokens.getEndOffset(i);
            const tokenText = content.items[start..end];
            if (lineTokens.getForeground(i) == SEMANTIC_COLOR) {
                try lineText.append('|');
                try lineText.appendSlice(tokenText);
                try lineText.append('|');
            } else {
                try lineText.appendSlice(tokenText);
            }
        }
        try result.append(lineText);
    }
    return result;
}

fn applyEdits(model: *@import("../../../common/model/textModel.zig").TextModel, edits: []const Edit) !void {
    var ops = ArrayList(IdentifiedSingleEditOperation).init(model.getAllocator());
    defer ops.deinit();
    for (edits) |edit| {
        try ops.append(IdentifiedSingleEditOperation.init(edit.range, if (edit.text.len == 0) null else String.initBorrowed(edit.text)));
    }
    _ = try model.applyEdits(ops.items, false);
}

fn testTokensAdjustment(
    allocator: std.mem.Allocator,
    initial: []const []const u8,
    edits: []const Edit,
    expected: []const []const u8,
) !void {
    var parsed = try parseTokensState(allocator, initial);
    defer parsed.text.deinit();
    var ctx = try TestModel.init(allocator, parsed.text.items, "nullLanguage");
    defer ctx.deinit();

    var pieces = [_]SparseMultilineTokens{parsed.tokens};
    try ctx.model.tokenization().setSemanticTokens(&pieces, true);
    try applyEdits(ctx.model, edits);

    var actual = try extractState(allocator, ctx.model);
    defer {
        for (actual.items) |*line| line.deinit();
        actual.deinit();
    }
    try std.testing.expectEqual(expected.len, actual.items.len);
    for (expected, actual.items) |want, got| {
        try std.testing.expectEqualStrings(want, got.items);
    }
}

test "tokensStore: issue #86303 - color shifting between different tokens" {
    const allocator = std.testing.allocator;
    try testTokensAdjustment(allocator, &.{
        "import { |URI| } from 'vs/base/common/uri';",
        "const foo = |URI|.parse('hey');",
    }, &.{
        .{ .range = Range.init(2, 9, 2, 10), .text = "" },
    }, &.{
        "import { |URI| } from 'vs/base/common/uri';",
        "const fo = |URI|.parse('hey');",
    });
}

test "tokensStore: deleting a newline" {
    const allocator = std.testing.allocator;
    try testTokensAdjustment(allocator, &.{
        "import { |URI| } from 'vs/base/common/uri';",
        "const foo = |URI|.parse('hey');",
    }, &.{
        .{ .range = Range.init(1, 42, 2, 1), .text = "" },
    }, &.{
        "import { |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
    });
}

test "tokensStore: inserting a newline" {
    const allocator = std.testing.allocator;
    try testTokensAdjustment(allocator, &.{
        "import { |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
    }, &.{
        .{ .range = Range.init(1, 42, 1, 42), .text = "\n" },
    }, &.{
        "import { |URI| } from 'vs/base/common/uri';",
        "const foo = |URI|.parse('hey');",
    });
}

test "tokensStore: deleting a newline 2" {
    const allocator = std.testing.allocator;
    try testTokensAdjustment(allocator, &.{
        "import { ",
        "    |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
    }, &.{
        .{ .range = Range.init(1, 10, 2, 5), .text = "" },
    }, &.{
        "import { |URI| } from 'vs/base/common/uri';const foo = |URI|.parse('hey');",
    });
}

test "tokensStore: partial tokens 1" {
    const allocator = std.testing.allocator;
    var codec = try @import("../../../common/languages.zig").LanguageIdCodec.init(allocator);
    defer codec.deinit();

    var store = @import("../../../common/tokens/sparseTokensStore.zig").SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    var p1 = try createSparseTokens(allocator, 5, &[_]u32{
        0,  5, 10, 1,
        5,  5, 10, 2,
        10, 5, 10, 3,
        15, 5, 10, 4,
        20, 5, 10, 5,
        25, 5, 10, 6,
    });
    var pieces = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(1, 1, 31, 2), &pieces);
    p1 = try createSparseTokens(allocator, 20, &[_]u32{
        0,  5, 10, 4,
        5,  5, 10, 5,
        10, 5, 10, 6,
        15, 5, 10, 7,
        20, 5, 10, 8,
    });
    var pieces2 = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(18, 1, 42, 1), &pieces2);
    p1 = try createSparseTokens(allocator, 5, &[_]u32{
        0,  5, 10, 1,
        5,  5, 10, 2,
        10, 5, 10, 3,
        15, 5, 10, 4,
        20, 5, 10, 5,
        25, 5, 10, 6,
    });
    var pieces3 = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(1, 1, 31, 2), &pieces3);

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("enum Enum1 {");
    var tokens = ArrayList(@import("../../../common/tokens/lineTokens.zig").TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 12, .metadata = .default });
    const aTokens = @import("../../../common/tokens/lineTokens.zig").LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(10, aTokens);
    defer lineTokens.deinit();
    try std.testing.expectEqual(3, lineTokens.getCount());
}

test "tokensStore: addSparseTokens skips overlapping semantic tokens" {
    const allocator = std.testing.allocator;
    var codec = try @import("../../../common/languages.zig").LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = @import("../../../common/tokens/sparseTokensStore.zig").SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const meta1 = (1 << FOREGROUND_OFFSET) | SEMANTIC_USE_FOREGROUND;
    const meta2 = (2 << FOREGROUND_OFFSET) | SEMANTIC_USE_FOREGROUND;
    const piece = try createSparseTokens(allocator, 1, &[_]u32{
        0, 0, 1, meta1,
        0, 1, 2, meta2,
        0, 2, 3, meta1,
        0, 3, 5, meta2,
        0, 4, 5, meta1,
    });
    var pieces = [_]SparseMultilineTokens{piece};
    try store.set(&pieces, true, null);

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("f=1+a2");
    var tokens = ArrayList(@import("../../../common/tokens/lineTokens.zig").TokenPacked).init(allocator);
    var tmMetadata = @import("../../../common/encodedTokenAttributes.zig").TokenMetadata.default;
    tmMetadata.foreground = 3;
    try tokens.append(.{ .endOffset = 6, .metadata = tmMetadata });
    const aTokens = @import("../../../common/tokens/lineTokens.zig").LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(1, aTokens);
    defer lineTokens.deinit();

    var i: usize = 1;
    while (i < lineTokens.getCount()) : (i += 1) {
        try std.testing.expect(lineTokens.getEndOffset(i) > lineTokens.getEndOffset(i - 1));
    }

    try std.testing.expectEqualStrings("f=1+a2", lineTokens.getLineContent());

    var withInjected = try lineTokens.withInserted(&.{
        .{ .offset = 0, .text = "  ", .tokenMetadata = TokenMetadata.default },
    });
    defer withInjected.deinit();
    try std.testing.expectEqualStrings("  f=1+a2", withInjected.getLineContent());
}

test "tokensStore: encompassing deletion makes store empty" {
    const allocator = std.testing.allocator;
    var codec = try @import("../../../common/languages.zig").LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = @import("../../../common/tokens/sparseTokensStore.zig").SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const piece = try createSparseTokens(allocator, 5, &[_]u32{
        0, 0, 5, 1,
        5, 0, 5, 2,
    });
    var pieces = [_]SparseMultilineTokens{piece};
    try store.set(&pieces, false, null);
    try std.testing.expect(!store.isEmpty());

    store.acceptEdit(Range.init(1, 1, 20, 1), 0, 0, 0, 0);
    try std.testing.expect(store.isEmpty());
}

test "tokensStore: partial tokens 2" {
    const allocator = std.testing.allocator;
    var codec = try @import("../../../common/languages.zig").LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = @import("../../../common/tokens/sparseTokensStore.zig").SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    var p1 = try createSparseTokens(allocator, 5, &[_]u32{
        0, 5, 10, 1, 5, 5, 10, 2, 10, 5, 10, 3, 15, 5, 10, 4, 20, 5, 10, 5, 25, 5, 10, 6,
    });
    var pieces = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(1, 1, 31, 2), &pieces);

    p1 = try createSparseTokens(allocator, 10, &[_]u32{
        0, 5, 10, 2, 5, 5, 10, 3, 10, 5, 10, 4, 15, 5, 10, 5, 20, 5, 10, 6,
    });
    var pieces2 = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(6, 1, 36, 2), &pieces2);

    p1 = try createSparseTokens(allocator, 20, &[_]u32{
        0, 5, 10, 4, 5, 5, 10, 5, 10, 5, 10, 6, 15, 5, 10, 7, 20, 5, 10, 8,
    });
    var pieces3 = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(17, 1, 42, 1), &pieces3);

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("enum Enum1 {");
    var tokens = ArrayList(@import("../../../common/tokens/lineTokens.zig").TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 12, .metadata = .default });
    const aTokens = @import("../../../common/tokens/lineTokens.zig").LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(20, aTokens);
    defer lineTokens.deinit();
    try std.testing.expectEqual(3, lineTokens.getCount());
}

test "tokensStore: issue #94133 semantic colors removed by empty partial update" {
    const allocator = std.testing.allocator;
    var codec = try @import("../../../common/languages.zig").LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = @import("../../../common/tokens/sparseTokensStore.zig").SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const piece = try createSparseTokens(allocator, 1, &[_]u32{ 0, 9, 11, 1 });
    var pieces = [_]SparseMultilineTokens{piece};
    _ = try store.setPartial(Range.init(1, 1, 1, 20), &pieces);

    var empty = [_]SparseMultilineTokens{};
    _ = try store.setPartial(Range.init(1, 1, 1, 20), &empty);

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("enum Enum1 {");
    var tokens = ArrayList(@import("../../../common/tokens/lineTokens.zig").TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 12, .metadata = .default });
    const aTokens = @import("../../../common/tokens/lineTokens.zig").LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(1, aTokens);
    defer lineTokens.deinit();
    try std.testing.expectEqual(1, lineTokens.getCount());
}

test "tokensStore: issue #147944 null language word lookup" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "--[[\n\n]]", "nullLanguage");
    defer ctx.deinit();

    const piece = try createSparseTokens(allocator, 1, &[_]u32{
        0, 2, 4, 0b100000000000010000,
        1, 0, 0, 0b100000000000010000,
        2, 0, 2, 0b100000000000010000,
    });
    var pieces = [_]SparseMultilineTokens{piece};
    try ctx.model.tokenization().setSemanticTokens(&pieces, true);

    try std.testing.expect(ctx.model.getWordAtPosition(@import("../../../common/core/position.zig").Position.init(2, 1)) == null);
}

test "tokensStore: issue #179268 complex edit" {
    const allocator = std.testing.allocator;
    try testTokensAdjustment(allocator, &.{
        "|export| |'interior_material_selector.dart'|;",
        "|export| |'mileage_selector.dart'|;",
        "|export| |'owners_selector.dart'|;",
        "|export| |'price_selector.dart'|;",
        "|export| |'seat_count_selector.dart'|;",
        "|export| |'year_selector.dart'|;",
        "|export| |'winter_options_selector.dart'|;|export| |'camera_selector.dart'|;",
    }, &.{
        .{ .range = Range.init(1, 9, 1, 9), .text = "camera_selector.dart';\nexport '" },
        .{ .range = Range.init(6, 9, 7, 9), .text = "" },
        .{ .range = Range.init(7, 39, 7, 39), .text = "\n" },
        .{ .range = Range.init(7, 47, 7, 48), .text = "ye" },
        .{ .range = Range.init(7, 49, 7, 51), .text = "" },
        .{ .range = Range.init(7, 52, 7, 53), .text = "" },
    }, &.{
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

test "tokensStore: issue #91936 semantic colors on a selected line" {
    const allocator = std.testing.allocator;
    var ctx = try TestModel.init(allocator, "                    else if ($s = 08) then '\\b'", "plaintext");
    defer ctx.deinit();

    const piece = try createSparseTokens(allocator, 1, &[_]u32{
        0, 20, 24, 0b01111000000000010000,
        0, 25, 27, 0b01111000000000010000,
        0, 28, 29, 0b00001000000000010000,
        0, 29, 31, 0b10000000000000010000,
        0, 32, 33, 0b00001000000000010000,
        0, 34, 36, 0b00110000000000010000,
        0, 36, 37, 0b00001000000000010000,
        0, 38, 42, 0b01111000000000010000,
        0, 43, 47, 0b01011000000000010000,
    });
    var pieces = [_]SparseMultilineTokens{piece};
    try ctx.model.tokenization().setSemanticTokens(&pieces, true);

    var lineTokens = try ctx.model.tokenization().getLineTokens(1);
    defer lineTokens.deinit();
    const expected = [_]struct { end: usize, metadata: u32 }{
        .{ .end = 20, .metadata = 0b10000000001000010000000001 },
        .{ .end = 24, .metadata = 0b10000001111000010000000001 },
        .{ .end = 25, .metadata = 0b10000000001000010000000001 },
        .{ .end = 27, .metadata = 0b10000001111000010000000001 },
        .{ .end = 28, .metadata = 0b10000000001000010000000001 },
        .{ .end = 29, .metadata = 0b10000000001000010000000001 },
        .{ .end = 31, .metadata = 0b10000010000000010000000001 },
        .{ .end = 32, .metadata = 0b10000000001000010000000001 },
        .{ .end = 33, .metadata = 0b10000000001000010000000001 },
        .{ .end = 34, .metadata = 0b10000000001000010000000001 },
        .{ .end = 36, .metadata = 0b10000000110000010000000001 },
        .{ .end = 37, .metadata = 0b10000000001000010000000001 },
        .{ .end = 38, .metadata = 0b10000000001000010000000001 },
        .{ .end = 42, .metadata = 0b10000001111000010000000001 },
        .{ .end = 43, .metadata = 0b10000000001000010000000001 },
        .{ .end = 47, .metadata = 0b10000001011000010000000001 },
    };
    try std.testing.expectEqual(expected.len, lineTokens.getCount());
    for (expected, 0..) |want, i| {
        try std.testing.expectEqual(want.end, lineTokens.getEndOffset(i));
        try std.testing.expectEqual(want.metadata, @as(u32, @bitCast(lineTokens.getMetadata(i))));
    }
}

test "tokensStore: partial tokens 3" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    var p1 = try createSparseTokens(allocator, 5, &[_]u32{
        0,  5, 10, 1,
        5,  5, 10, 2,
        10, 5, 10, 3,
        15, 5, 10, 4,
        20, 5, 10, 5,
        25, 5, 10, 6,
    });
    var pieces = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(1, 1, 31, 2), &pieces);

    p1 = try createSparseTokens(allocator, 10, &[_]u32{
        0, 5, 10, 3,
        5, 5, 10, 4,
    });
    var pieces2 = [_]SparseMultilineTokens{p1};
    _ = try store.setPartial(Range.init(11, 1, 16, 2), &pieces2);

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("enum Enum1 {");
    var tokens = ArrayList(TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 12, .metadata = .default });
    const aTokens = LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(5, aTokens);
    defer lineTokens.deinit();
    try std.testing.expectEqual(3, lineTokens.getCount());
}

test "tokensStore: issue #95949 identifiers stay non-bold" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const piece = try createSparseTokens(allocator, 1, &[_]u32{
        0, 6, 11, (1 << FOREGROUND_OFFSET) | SEMANTIC_USE_FOREGROUND,
    });
    var pieces = [_]SparseMultilineTokens{piece};
    try store.set(&pieces, true, null);

    const tmMetadata = struct {
        fn create(foreground: u9, fontStyle: FontStyle, languageId: u8) TokenMetadata {
            var m = TokenMetadata.default;
            m.foreground = foreground;
            m.fontStyle = fontStyle;
            m.languageId = languageId;
            return m;
        }
    }.create;

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("const hello = 123;");
    var tokens = ArrayList(TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 5, .metadata = tmMetadata(5, FontStyle.Bold, 53) });
    try tokens.append(.{ .endOffset = 14, .metadata = tmMetadata(1, FontStyle.None, 53) });
    try tokens.append(.{ .endOffset = 17, .metadata = tmMetadata(6, FontStyle.None, 53) });
    try tokens.append(.{ .endOffset = 18, .metadata = tmMetadata(1, FontStyle.None, 53) });
    const aTokens = LineTokens.init(tokens, text, &codec);

    var lineTokens = try store.addSparseTokens(1, aTokens);
    defer lineTokens.deinit();

    const expected = [_]struct { end: usize, metadata: TokenMetadata }{
        .{ .end = 5, .metadata = tmMetadata(5, FontStyle.Bold, 53) },
        .{ .end = 6, .metadata = tmMetadata(1, FontStyle.None, 53) },
        .{ .end = 11, .metadata = tmMetadata(1, FontStyle.None, 53) },
        .{ .end = 14, .metadata = tmMetadata(1, FontStyle.None, 53) },
        .{ .end = 17, .metadata = tmMetadata(6, FontStyle.None, 53) },
        .{ .end = 18, .metadata = tmMetadata(1, FontStyle.None, 53) },
    };
    try std.testing.expectEqual(expected.len, lineTokens.getCount());
    for (expected, 0..) |want, i| {
        try std.testing.expectEqual(want.end, lineTokens.getEndOffset(i));
        try std.testing.expectEqual(want.metadata, lineTokens.getMetadata(i));
    }
}

test "tokensStore: setPartial removes all tokens from a later line" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const piece = try createSparseTokens(allocator, 5, &[_]u32{ 0, 5, 10, 1 });
    var pieces = [_]SparseMultilineTokens{piece};
    try store.set(&pieces, false, null);
    try std.testing.expect(!store.isEmpty());

    var empty = [_]SparseMultilineTokens{};
    _ = try store.setPartial(Range.init(5, 1, 5, 20), &empty);
    try std.testing.expect(store.isEmpty());
}

test "tokensStore: setPartial keeps a piece when the first split half is empty" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const piece = try createSparseTokens(allocator, 1, &[_]u32{ 10, 5, 10, 1 });
    var pieces = [_]SparseMultilineTokens{piece};
    try store.set(&pieces, false, null);

    var empty = [_]SparseMultilineTokens{};
    _ = try store.setPartial(Range.init(1, 1, 5, 1), &empty);
    try std.testing.expect(!store.isEmpty());

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("    test line text    ");
    var tokens = ArrayList(TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 22, .metadata = .default });
    const aTokens = LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(11, aTokens);
    defer lineTokens.deinit();
    try std.testing.expectEqual(3, lineTokens.getCount());
    try std.testing.expectEqual(5, lineTokens.getStartOffset(1));
    try std.testing.expectEqual(10, lineTokens.getEndOffset(1));
}

test "tokensStore: encompassing deletion drops a piece starting at line 5" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const piece = try createSparseTokens(allocator, 5, &[_]u32{
        0, 0, 5, 1,
        5, 0, 5, 2,
    });
    var pieces = [_]SparseMultilineTokens{piece};
    try store.set(&pieces, false, null);
    try std.testing.expect(!store.isEmpty());

    store.acceptEdit(Range.init(1, 1, 20, 1), 0, 0, 0, 0);
    try std.testing.expect(store.isEmpty());
}

fn createTokensFromState(allocator: std.mem.Allocator, str: []const u8) !SparseMultilineTokens {
    const inner = str[2 .. str.len - 2];
    var values = ArrayList(u32).init(allocator);
    defer values.deinit();
    var firstLine: usize = 0;
    var it = std.mem.splitSequence(u8, inner, "),(");
    while (it.next()) |piece| {
        const comma = std.mem.indexOfScalar(u8, piece, ',').?;
        const dash = std.mem.indexOfScalar(u8, piece, '-').?;
        const lineNumber = try std.fmt.parseInt(usize, piece[0..comma], 10);
        const startChar = try std.fmt.parseInt(u32, piece[comma + 1 .. dash], 10);
        const endChar = try std.fmt.parseInt(u32, piece[dash + 1 ..], 10);
        if (firstLine == 0) firstLine = lineNumber;
        try values.appendSlice(&.{ @intCast(lineNumber - firstLine), startChar, endChar, @intCast((lineNumber + startChar) % 13) });
    }
    return createSparseTokens(allocator, firstLine, values.items);
}

test "tokensStore: upstream bug scenario" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var store = SparseTokensStore.init(allocator, &codec);
    defer store.deinit();

    const piece0 = try createTokensFromState(allocator, "[(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35),(36470,38-46),(36473,25-35),(36473,36-51),(36474,28-33),(36474,36-49),(36474,50-58),(36475,35-53),(36475,54-62)]");
    var pieces0 = [_]SparseMultilineTokens{piece0};
    _ = try store.setPartial(Range.init(36446, 1, 36475, 115), &pieces0);

    const piece1 = try createTokensFromState(allocator, "[(36437,33-37),(36437,38-42),(36437,47-57),(36437,58-67),(36438,35-53),(36438,54-62),(36440,24-29),(36440,33-46),(36440,47-53),(36442,25-35),(36442,36-50),(36443,30-39),(36443,42-46),(36443,47-53),(36443,54-58),(36443,63-73),(36443,74-84),(36443,87-91),(36443,92-98),(36443,101-105),(36443,106-112),(36443,113-119),(36444,28-37),(36444,38-42),(36444,47-57),(36444,58-75),(36444,80-95),(36444,96-105),(36445,35-53),(36445,54-62),(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62)]");
    var pieces1 = [_]SparseMultilineTokens{piece1};
    _ = try store.setPartial(Range.init(36436, 1, 36464, 142), &pieces1);

    const piece2 = try createTokensFromState(allocator, "[(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35),(36470,38-46),(36473,25-35),(36473,36-51),(36474,28-33),(36474,36-49),(36474,50-58),(36475,35-53),(36475,54-62),(36477,28-32),(36477,33-37),(36477,42-52),(36477,53-69),(36478,32-36),(36478,37-41),(36478,46-56),(36478,57-74),(36479,32-36),(36479,37-41),(36479,46-56),(36479,57-76),(36480,32-36),(36480,37-41),(36480,46-56),(36480,57-68),(36481,32-36),(36481,37-41),(36481,46-56),(36481,57-68),(36482,39-57),(36482,58-66),(36484,34-38),(36484,39-45),(36484,46-50),(36484,55-65),(36484,66-82),(36484,86-97),(36484,98-102),(36484,103-109),(36484,111-124),(36484,125-133),(36485,39-57),(36485,58-66)]");
    var pieces2 = [_]SparseMultilineTokens{piece2};
    _ = try store.setPartial(Range.init(36457, 1, 36485, 140), &pieces2);

    const piece3 = try createTokensFromState(allocator, "[(36442,25-35),(36442,36-50),(36443,30-39),(36443,42-46),(36443,47-53),(36443,54-58),(36443,63-73),(36443,74-84),(36443,87-91),(36443,92-98),(36443,101-105),(36443,106-112),(36443,113-119),(36444,28-37),(36444,38-42),(36444,47-57),(36444,58-75),(36444,80-95),(36444,96-105),(36445,35-53),(36445,54-62),(36448,24-29),(36448,33-46),(36448,47-54),(36450,25-35),(36450,36-50),(36451,28-33),(36451,36-49),(36451,50-57),(36452,35-53),(36452,54-62),(36454,33-38),(36454,41-54),(36454,55-60),(36455,35-53),(36455,54-62),(36457,33-44),(36457,45-49),(36457,50-56),(36457,62-83),(36457,84-88),(36458,35-53),(36458,54-62),(36460,33-37),(36460,38-42),(36460,47-57),(36460,58-67),(36461,35-53),(36461,54-62),(36463,34-38),(36463,39-45),(36463,46-51),(36463,54-63),(36463,64-71),(36463,76-80),(36463,81-87),(36463,88-92),(36463,97-107),(36463,108-119),(36464,35-53),(36464,54-62),(36466,33-71),(36466,72-76),(36467,35-53),(36467,54-62),(36469,24-29),(36469,33-46),(36469,47-54),(36470,24-35)]");
    var pieces3 = [_]SparseMultilineTokens{piece3};
    _ = try store.setPartial(Range.init(36441, 1, 36469, 56), &pieces3);

    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("                        if (flags & ModifierFlags.Ambient) {");
    var tokens = ArrayList(TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 60, .metadata = .default });
    const aTokens = LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(36451, aTokens);
    defer lineTokens.deinit();
    try std.testing.expectEqual(7, lineTokens.getCount());
}

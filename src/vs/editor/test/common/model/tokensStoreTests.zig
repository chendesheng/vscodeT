const std = @import("std");
const ArrayList = std.array_list.Managed;
const TestModel = @import("../port/testSupport.zig").TestModel;
const createSparseTokens = @import("../port/testSupport.zig").createSparseTokens;
const SparseMultilineTokens = @import("../../../common/tokens/sparseMultilineTokens.zig").SparseMultilineTokens;
const Range = @import("../../../common/core/range.zig").Range;
const IdentifiedSingleEditOperation = @import("../../../common/model.zig").IdentifiedSingleEditOperation;
const String = @import("../../../../base/common/strings.zig").String;

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

    const tmMeta = (3 << FOREGROUND_OFFSET);
    var text = ArrayList(u8).init(allocator);
    try text.appendSlice("f=1+a2");
    var tokens = ArrayList(@import("../../../common/tokens/lineTokens.zig").TokenPacked).init(allocator);
    var tmMetadata = @import("../../../common/encodedTokenAttributes.zig").TokenMetadata.default;
    tmMetadata.foreground = 3;
    try tokens.append(.{ .endOffset = 6, .metadata = tmMetadata });
    const aTokens = @import("../../../common/tokens/lineTokens.zig").LineTokens.init(tokens, text, &codec);
    var lineTokens = try store.addSparseTokens(1, aTokens);
    defer lineTokens.deinit();
    _ = tmMeta;

    var i: usize = 1;
    while (i < lineTokens.getCount()) : (i += 1) {
        try std.testing.expect(lineTokens.getEndOffset(i) > lineTokens.getEndOffset(i - 1));
    }

    try std.testing.expectEqualStrings("f=1+a2", lineTokens.getLineContent());
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

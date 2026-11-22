const std = @import("std");
const ArrayList = std.array_list.Managed;
const LineTokens = @import("../../../common/tokens/lineTokens.zig").LineTokens;
const TokenPacked = @import("../../../common/tokens/lineTokens.zig").TokenPacked;
const LanguageIdCodec = @import("../../../common/languages.zig").LanguageIdCodec;
const TokenMetadata = @import("../../../common/encodedTokenAttributes.zig").TokenMetadata;

const TokenDef = struct { start: usize, foreground: u9 };
const ExpectedToken = struct { end: usize, foreground: u9 };

fn createLineTokens(allocator: std.mem.Allocator, text: []const u8, defs: []const TokenDef, codec: *LanguageIdCodec) !LineTokens {
    var textList = ArrayList(u8).init(allocator);
    errdefer textList.deinit();
    try textList.appendSlice(text);

    var tokens = ArrayList(TokenPacked).init(allocator);
    errdefer tokens.deinit();
    for (defs, 0..) |def, i| {
        const end = if (i + 1 < defs.len) defs[i + 1].start else text.len;
        var metadata = TokenMetadata.default;
        metadata.foreground = def.foreground;
        try tokens.append(TokenPacked.init(@intCast(end), metadata));
    }
    return LineTokens.init(tokens, textList, codec);
}

fn createTestLineTokens(allocator: std.mem.Allocator, codec: *LanguageIdCodec) !LineTokens {
    const defs = [_]TokenDef{
        .{ .start = 0, .foreground = 1 },
        .{ .start = 6, .foreground = 2 },
        .{ .start = 13, .foreground = 3 },
        .{ .start = 18, .foreground = 4 },
        .{ .start = 21, .foreground = 5 },
        .{ .start = 23, .foreground = 6 },
        .{ .start = 30, .foreground = 7 },
    };
    return createLineTokens(allocator, "Hello world, this is a lovely day", &defs, codec);
}

fn expectTokens(lineTokens: *const LineTokens, expected: []const ExpectedToken) !void {
    try std.testing.expectEqual(expected.len, lineTokens.getCount());
    for (expected, 0..) |token, i| {
        try std.testing.expectEqual(token.end, lineTokens.getEndOffset(i));
        try std.testing.expectEqual(token.foreground, lineTokens.getForeground(i));
    }
}

test "lineTokens: basics" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var lineTokens = try createTestLineTokens(allocator, &codec);
    defer lineTokens.deinit();

    try std.testing.expectEqualStrings("Hello world, this is a lovely day", lineTokens.getLineContent());
    try std.testing.expectEqual(33, lineTokens.getTextLength());
    try std.testing.expectEqual(7, lineTokens.getCount());
    try std.testing.expectEqual(0, lineTokens.getStartOffset(0));
    try std.testing.expectEqual(6, lineTokens.getEndOffset(0));
    try std.testing.expectEqual(13, lineTokens.getEndOffset(1));
    try std.testing.expectEqual(33, lineTokens.getEndOffset(6));
}

test "lineTokens: findToken" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var lineTokens = try createTestLineTokens(allocator, &codec);
    defer lineTokens.deinit();

    const cases = [_]struct { offset: usize, index: usize }{
        .{ .offset = 0, .index = 0 },
        .{ .offset = 5, .index = 0 },
        .{ .offset = 6, .index = 1 },
        .{ .offset = 7, .index = 1 },
        .{ .offset = 8, .index = 1 },
        .{ .offset = 9, .index = 1 },
        .{ .offset = 10, .index = 1 },
        .{ .offset = 11, .index = 1 },
        .{ .offset = 12, .index = 1 },
        .{ .offset = 13, .index = 2 },
        .{ .offset = 14, .index = 2 },
        .{ .offset = 15, .index = 2 },
        .{ .offset = 16, .index = 2 },
        .{ .offset = 17, .index = 2 },
        .{ .offset = 18, .index = 3 },
        .{ .offset = 19, .index = 3 },
        .{ .offset = 20, .index = 3 },
        .{ .offset = 21, .index = 4 },
        .{ .offset = 22, .index = 4 },
        .{ .offset = 23, .index = 5 },
        .{ .offset = 24, .index = 5 },
        .{ .offset = 25, .index = 5 },
        .{ .offset = 26, .index = 5 },
        .{ .offset = 27, .index = 5 },
        .{ .offset = 28, .index = 5 },
        .{ .offset = 29, .index = 5 },
        .{ .offset = 30, .index = 6 },
        .{ .offset = 31, .index = 6 },
        .{ .offset = 32, .index = 6 },
        .{ .offset = 33, .index = 6 },
        .{ .offset = 34, .index = 6 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.index, lineTokens.findTokenIndexAtOffset(case.offset));
    }
}

test "lineTokens: inflate" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var lineTokens = try createTestLineTokens(allocator, &codec);
    defer lineTokens.deinit();

    try expectTokens(lineTokens.inflate(), &.{
        .{ .end = 6, .foreground = 1 },
        .{ .end = 13, .foreground = 2 },
        .{ .end = 18, .foreground = 3 },
        .{ .end = 21, .foreground = 4 },
        .{ .end = 23, .foreground = 5 },
        .{ .end = 30, .foreground = 6 },
        .{ .end = 33, .foreground = 7 },
    });
}

test "lineTokens: sliceAndInflate" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var lineTokens = try createTestLineTokens(allocator, &codec);
    defer lineTokens.deinit();

    try expectSlice(&lineTokens, 0, 33, 0, &.{
        .{ .end = 6, .foreground = 1 },
        .{ .end = 13, .foreground = 2 },
        .{ .end = 18, .foreground = 3 },
        .{ .end = 21, .foreground = 4 },
        .{ .end = 23, .foreground = 5 },
        .{ .end = 30, .foreground = 6 },
        .{ .end = 33, .foreground = 7 },
    });
    try expectSlice(&lineTokens, 0, 32, 0, &.{
        .{ .end = 6, .foreground = 1 },
        .{ .end = 13, .foreground = 2 },
        .{ .end = 18, .foreground = 3 },
        .{ .end = 21, .foreground = 4 },
        .{ .end = 23, .foreground = 5 },
        .{ .end = 30, .foreground = 6 },
        .{ .end = 32, .foreground = 7 },
    });
    try expectSlice(&lineTokens, 0, 30, 1, &.{
        .{ .end = 7, .foreground = 1 },
        .{ .end = 14, .foreground = 2 },
        .{ .end = 19, .foreground = 3 },
        .{ .end = 22, .foreground = 4 },
        .{ .end = 24, .foreground = 5 },
        .{ .end = 31, .foreground = 6 },
    });
    try expectSlice(&lineTokens, 6, 18, 0, &.{
        .{ .end = 7, .foreground = 2 },
        .{ .end = 12, .foreground = 3 },
    });
    try expectSlice(&lineTokens, 7, 18, 0, &.{
        .{ .end = 6, .foreground = 2 },
        .{ .end = 11, .foreground = 3 },
    });
    try expectSlice(&lineTokens, 6, 17, 0, &.{
        .{ .end = 7, .foreground = 2 },
        .{ .end = 11, .foreground = 3 },
    });
    try expectSlice(&lineTokens, 6, 19, 0, &.{
        .{ .end = 7, .foreground = 2 },
        .{ .end = 12, .foreground = 3 },
        .{ .end = 13, .foreground = 4 },
    });
}

fn expectSlice(lineTokens: *const LineTokens, start: usize, end: usize, delta: usize, expected: []const ExpectedToken) !void {
    const slice = lineTokens.sliceAndInflate(start, end, delta);
    try std.testing.expectEqual(expected.len, slice.getCount());
    for (expected, 0..) |token, i| {
        try std.testing.expectEqual(token.end, slice.getEndOffset(i));
        try std.testing.expectEqual(token.foreground, slice.getForeground(i));
    }
}

test "lineTokens: withInserted 1" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var lineTokens = try createTestLineTokens(allocator, &codec);
    defer lineTokens.deinit();

    var metadata = TokenMetadata.default;
    metadata.foreground = 0;
    var result = try lineTokens.withInserted(&.{
        .{ .offset = 0, .text = "1", .tokenMetadata = metadata },
        .{ .offset = 6, .text = "2", .tokenMetadata = metadata },
        .{ .offset = 9, .text = "3", .tokenMetadata = metadata },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("1Hello 2wor3ld, this is a lovely day", result.getLineContent());
    try expectTokens(&result, &.{
        .{ .end = 1, .foreground = 0 },
        .{ .end = 7, .foreground = 1 },
        .{ .end = 8, .foreground = 0 },
        .{ .end = 11, .foreground = 2 },
        .{ .end = 12, .foreground = 0 },
        .{ .end = 16, .foreground = 2 },
        .{ .end = 21, .foreground = 3 },
        .{ .end = 24, .foreground = 4 },
        .{ .end = 26, .foreground = 5 },
        .{ .end = 33, .foreground = 6 },
        .{ .end = 36, .foreground = 7 },
    });
}

test "lineTokens: withInserted at end" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var lineTokens = try createTestLineTokens(allocator, &codec);
    defer lineTokens.deinit();

    var metadata = TokenMetadata.default;
    metadata.foreground = 0;
    var result = try lineTokens.withInserted(&.{
        .{ .offset = 32, .text = "1", .tokenMetadata = metadata },
        .{ .offset = 33, .text = "2", .tokenMetadata = metadata },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("Hello world, this is a lovely da1y2", result.getLineContent());
    try expectTokens(&result, &.{
        .{ .end = 6, .foreground = 1 },
        .{ .end = 13, .foreground = 2 },
        .{ .end = 18, .foreground = 3 },
        .{ .end = 21, .foreground = 4 },
        .{ .end = 23, .foreground = 5 },
        .{ .end = 30, .foreground = 6 },
        .{ .end = 32, .foreground = 7 },
        .{ .end = 33, .foreground = 0 },
        .{ .end = 34, .foreground = 7 },
        .{ .end = 35, .foreground = 0 },
    });
}

test "lineTokens: withInserted at same position" {
    const allocator = std.testing.allocator;
    var codec = try LanguageIdCodec.init(allocator);
    defer codec.deinit();
    var lineTokens = try createTestLineTokens(allocator, &codec);
    defer lineTokens.deinit();

    var metadata = TokenMetadata.default;
    metadata.foreground = 0;
    var result = try lineTokens.withInserted(&.{
        .{ .offset = 0, .text = "1", .tokenMetadata = metadata },
        .{ .offset = 0, .text = "2", .tokenMetadata = metadata },
        .{ .offset = 0, .text = "3", .tokenMetadata = metadata },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("123Hello world, this is a lovely day", result.getLineContent());
    try expectTokens(&result, &.{
        .{ .end = 1, .foreground = 0 },
        .{ .end = 2, .foreground = 0 },
        .{ .end = 3, .foreground = 0 },
        .{ .end = 9, .foreground = 1 },
        .{ .end = 16, .foreground = 2 },
        .{ .end = 21, .foreground = 3 },
        .{ .end = 24, .foreground = 4 },
        .{ .end = 26, .foreground = 5 },
        .{ .end = 33, .foreground = 6 },
        .{ .end = 36, .foreground = 7 },
    });
}

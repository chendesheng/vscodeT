const std = @import("std");
const io = std.io;
const ArrayList = std.array_list.Managed;
const TokenPacked = @import("../../tokens/lineTokens.zig").TokenPacked;
const LanguageIdCodec = @import("../../languages.zig").LanguageIdCodec;
const TokenMetadata = @import("../../encodedTokenAttributes.zig").TokenMetadata;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const ColorId = @import("../../encodedTokenAttributes.zig").ColorId;

const LineTokensTests = struct {
    const allocator = std.testing.allocator;

    const ILineToken = struct {
        startIndex: u32,
        foreground: ColorId,
    };

    fn createLineTokens(text: []const u8, tokens: []const ILineToken) !LineTokens {
        var data = ArrayList(TokenPacked).init(allocator);

        // for (let i = 0, len = tokens.length; i < len; i++) {
        // binTokens[(i << 1)] = (i + 1 < len ? tokens[i + 1].startIndex : text.length);
        //binTokens[(i << 1) + 1] = (
        //tokens[i].foreground << MetadataConsts.FOREGROUND_OFFSET
        //) >>> 0;
        // }

        for (tokens, 0..) |token, i| {
            try data.append(.{
                .endOffset = if (i + 1 < tokens.len) tokens[i + 1].startIndex else @intCast(text.len),
                .metadata = .{ .foreground = token.foreground },
            });
        }
        var codec = try LanguageIdCodec.init(allocator);
        defer codec.deinit();
        return LineTokens.init(data, text, codec);
    }

    fn createTestLineTokens() !LineTokens {
        return try createLineTokens(
            "Hello world, this is a lovely day",
            &[_]ILineToken{
                .{ .startIndex = 0, .foreground = .DefaultForeground }, // Hello_
                .{ .startIndex = 6, .foreground = .DefaultBackground }, // world,_
                .{ .startIndex = 13, .foreground = .Color3 }, // this_
                .{ .startIndex = 18, .foreground = .Color4 }, // is_
                .{ .startIndex = 21, .foreground = .Color5 }, // a_
                .{ .startIndex = 23, .foreground = .Color6 }, // lovely_
                .{ .startIndex = 30, .foreground = .Color7 }, // day
            },
        );
    }

    fn renderLineTokens(tokens: LineTokens, result: *io.Writer) !void {
        const str = tokens.getLineContent();
        var lastOffset: u32 = 0;
        for (0..tokens.getCount()) |i| {
            try result.writeAll(str[lastOffset..tokens.getEndOffset(i)]);
            try result.print("({d})", .{@as(u32, @bitCast(tokens.getMetadata(i)))});
            lastOffset = tokens.getEndOffset(i);
        }
    }

    fn assertLineTokens(expected: []const u8, tokens: LineTokens) !void {
        var buf: [1024]u8 = undefined;
        var writer = io.Writer.fixed(&buf);
        try renderLineTokens(tokens, &writer);
        try std.testing.expectEqualStrings(expected, buf[0..writer.end]);
    }

    test "withInserted 1" {
        var lineTokens = try createTestLineTokens();
        defer lineTokens.deinit();

        try assertLineTokens("Hello (32768)world, (65536)this (98304)is (131072)a (163840)lovely (196608)day(229376)", lineTokens);

        var lineTokens2 = try lineTokens.withInserted(&[_]LineTokens.InsertTokenArg{
            .{ .offset = 0, .text = "1", .tokenMetadata = .default },
            .{ .offset = 6, .text = "2", .tokenMetadata = .default },
            .{ .offset = 9, .text = "3", .tokenMetadata = .default },
        });
        defer lineTokens2.deinit();
        defer allocator.free(lineTokens2._text);

        try assertLineTokens("1(0)Hello (32768)2(0)wor(65536)3(0)ld, (65536)this (98304)is (131072)a (163840)lovely (196608)day(229376)", lineTokens2);
    }

    test "withInserted (tokens at the same position)" {
        var lineTokens = try createTestLineTokens();
        defer lineTokens.deinit();
        try assertLineTokens("Hello (32768)world, (65536)this (98304)is (131072)a (163840)lovely (196608)day(229376)", lineTokens);

        var lineTokens2 = try lineTokens.withInserted(&[_]LineTokens.InsertTokenArg{
            .{ .offset = 0, .text = "1", .tokenMetadata = .default },
            .{ .offset = 0, .text = "2", .tokenMetadata = .default },
            .{ .offset = 0, .text = "3", .tokenMetadata = .default },
        });
        defer lineTokens2.deinit();
        defer allocator.free(lineTokens2._text);
        try assertLineTokens("1(0)2(0)3(0)Hello (32768)world, (65536)this (98304)is (131072)a (163840)lovely (196608)day(229376)", lineTokens2);
    }

    test "withInserted (tokens at the end)" {
        var lineTokens = try createTestLineTokens();
        defer lineTokens.deinit();
        try assertLineTokens("Hello (32768)world, (65536)this (98304)is (131072)a (163840)lovely (196608)day(229376)", lineTokens);

        var lineTokens2 = try lineTokens.withInserted(&[_]LineTokens.InsertTokenArg{
            .{ .offset = "Hello world, this is a lovely day".len - 1, .text = "1", .tokenMetadata = .default },
            .{ .offset = "Hello world, this is a lovely day".len, .text = "2", .tokenMetadata = .default },
        });
        defer lineTokens2.deinit();
        defer allocator.free(lineTokens2._text);
        try assertLineTokens("Hello (32768)world, (65536)this (98304)is (131072)a (163840)lovely (196608)da(229376)1(0)y(229376)2(0)", lineTokens2);
    }

    test "basics" {
        var lineTokens = try createTestLineTokens();
        defer lineTokens.deinit();

        try std.testing.expectEqualStrings("Hello world, this is a lovely day", lineTokens.getLineContent());
        try std.testing.expectEqual(33, lineTokens.getLineContent().len);
        try std.testing.expectEqual(7, lineTokens.getCount());

        try std.testing.expectEqual(0, lineTokens.getStartOffset(0));
        try std.testing.expectEqual(6, lineTokens.getEndOffset(0));
        try std.testing.expectEqual(6, lineTokens.getStartOffset(1));
        try std.testing.expectEqual(13, lineTokens.getEndOffset(1));
        try std.testing.expectEqual(13, lineTokens.getStartOffset(2));
        try std.testing.expectEqual(18, lineTokens.getEndOffset(2));
        try std.testing.expectEqual(18, lineTokens.getStartOffset(3));
        try std.testing.expectEqual(21, lineTokens.getEndOffset(3));
        try std.testing.expectEqual(21, lineTokens.getStartOffset(4));
        try std.testing.expectEqual(23, lineTokens.getEndOffset(4));
        try std.testing.expectEqual(23, lineTokens.getStartOffset(5));
        try std.testing.expectEqual(30, lineTokens.getEndOffset(5));
        try std.testing.expectEqual(30, lineTokens.getStartOffset(6));
        try std.testing.expectEqual(33, lineTokens.getEndOffset(6));
    }

    test "findToken" {
        var lineTokens = try createTestLineTokens();
        defer lineTokens.deinit();

        try std.testing.expectEqual(0, lineTokens.findTokenIndexAtOffset(0));
        try std.testing.expectEqual(0, lineTokens.findTokenIndexAtOffset(1));
        try std.testing.expectEqual(0, lineTokens.findTokenIndexAtOffset(2));
        try std.testing.expectEqual(0, lineTokens.findTokenIndexAtOffset(3));
        try std.testing.expectEqual(0, lineTokens.findTokenIndexAtOffset(4));
        try std.testing.expectEqual(0, lineTokens.findTokenIndexAtOffset(5));
        try std.testing.expectEqual(1, lineTokens.findTokenIndexAtOffset(6));
        try std.testing.expectEqual(1, lineTokens.findTokenIndexAtOffset(7));
        try std.testing.expectEqual(1, lineTokens.findTokenIndexAtOffset(8));
        try std.testing.expectEqual(1, lineTokens.findTokenIndexAtOffset(9));
        try std.testing.expectEqual(1, lineTokens.findTokenIndexAtOffset(10));
        try std.testing.expectEqual(1, lineTokens.findTokenIndexAtOffset(11));
        try std.testing.expectEqual(1, lineTokens.findTokenIndexAtOffset(12));
        try std.testing.expectEqual(2, lineTokens.findTokenIndexAtOffset(13));
        try std.testing.expectEqual(2, lineTokens.findTokenIndexAtOffset(14));
        try std.testing.expectEqual(2, lineTokens.findTokenIndexAtOffset(15));
        try std.testing.expectEqual(2, lineTokens.findTokenIndexAtOffset(16));
        try std.testing.expectEqual(2, lineTokens.findTokenIndexAtOffset(17));
        try std.testing.expectEqual(3, lineTokens.findTokenIndexAtOffset(18));
        try std.testing.expectEqual(3, lineTokens.findTokenIndexAtOffset(19));
        try std.testing.expectEqual(3, lineTokens.findTokenIndexAtOffset(20));
        try std.testing.expectEqual(4, lineTokens.findTokenIndexAtOffset(21));
        try std.testing.expectEqual(4, lineTokens.findTokenIndexAtOffset(22));
        try std.testing.expectEqual(5, lineTokens.findTokenIndexAtOffset(23));
        try std.testing.expectEqual(5, lineTokens.findTokenIndexAtOffset(24));
        try std.testing.expectEqual(5, lineTokens.findTokenIndexAtOffset(25));
        try std.testing.expectEqual(5, lineTokens.findTokenIndexAtOffset(26));
        try std.testing.expectEqual(5, lineTokens.findTokenIndexAtOffset(27));
        try std.testing.expectEqual(5, lineTokens.findTokenIndexAtOffset(28));
        try std.testing.expectEqual(5, lineTokens.findTokenIndexAtOffset(29));
        try std.testing.expectEqual(6, lineTokens.findTokenIndexAtOffset(30));
        try std.testing.expectEqual(6, lineTokens.findTokenIndexAtOffset(31));
        try std.testing.expectEqual(6, lineTokens.findTokenIndexAtOffset(32));
        try std.testing.expectEqual(6, lineTokens.findTokenIndexAtOffset(33));
        try std.testing.expectEqual(6, lineTokens.findTokenIndexAtOffset(34));
    }
};

test "lineTokens" {
    _ = LineTokensTests{};
}

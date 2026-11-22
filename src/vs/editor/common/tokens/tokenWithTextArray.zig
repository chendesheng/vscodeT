// Port of `src/vs/editor/common/tokens/tokenWithTextArray.ts`.
//
// Zig adaptation: token texts are borrowed slices instead of owned strings,
// and `toLineTokens` takes the allocator explicitly.
const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const OffsetRange = @import("../core/ranges/offsetRange.zig").OffsetRange;
const LineTokens = @import("./lineTokens.zig").LineTokens;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;

/// This class represents a sequence of tokens, where each token carries its
/// own text. The text slices are borrowed and must outlive this array.
pub const TokenWithTextArray = struct {
    _tokenInfo: ArrayList(TokenWithTextInfo),

    pub fn fromLineTokens(lineTokens: *const LineTokens) !TokenWithTextArray {
        var tokenInfo = ArrayList(TokenWithTextInfo).init(lineTokens._tokens.allocator);
        errdefer tokenInfo.deinit();
        for (0..lineTokens.getCount()) |i| {
            try tokenInfo.append(.{
                .text = lineTokens.getTokenText(i),
                .metadata = lineTokens.getMetadata(i),
            });
        }
        return TokenWithTextArray.init(tokenInfo);
    }

    pub fn init(tokenInfo: ArrayList(TokenWithTextInfo)) TokenWithTextArray {
        return .{ ._tokenInfo = tokenInfo };
    }

    pub fn deinit(self: *TokenWithTextArray) void {
        self._tokenInfo.deinit();
    }

    pub fn toLineTokens(self: *const TokenWithTextArray, allocator: Allocator, decoder: *LanguageIdCodec) !LineTokens {
        return try LineTokens.createFromTextAndMetadata(allocator, self._tokenInfo.items, decoder);
    }

    pub fn forEach(self: *const TokenWithTextArray, context: anytype, cb: fn (range: OffsetRange, tokenInfo: TokenWithTextInfo, ctx: @TypeOf(context)) void) void {
        var lengthSum: usize = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.text.len);
            cb(range, tokenInfo, context);
            lengthSum += tokenInfo.text.len;
        }
    }

    pub fn map(self: *const TokenWithTextArray, comptime T: type, context: anytype, cb: fn (range: OffsetRange, tokenInfo: TokenWithTextInfo, ctx: @TypeOf(context)) T) !ArrayList(T) {
        var result = ArrayList(T).init(self._tokenInfo.allocator);
        errdefer result.deinit();
        var lengthSum: usize = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.text.len);
            try result.append(cb(range, tokenInfo, context));
            lengthSum += tokenInfo.text.len;
        }
        return result;
    }

    pub fn slice(self: *const TokenWithTextArray, range: OffsetRange) !TokenWithTextArray {
        var result = ArrayList(TokenWithTextInfo).init(self._tokenInfo.allocator);
        errdefer result.deinit();
        var lengthSum: usize = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const tokenStart = lengthSum;
            const tokenEndEx = tokenStart + tokenInfo.text.len;
            if (tokenEndEx > range.start) {
                if (tokenStart >= range.endExclusive) break;
                const deltaBefore = range.start -| tokenStart;
                const deltaAfter = tokenEndEx -| range.endExclusive;
                try result.append(.{
                    .text = tokenInfo.text[deltaBefore .. tokenInfo.text.len - deltaAfter],
                    .metadata = tokenInfo.metadata,
                });
            }
            lengthSum = tokenEndEx;
        }
        return TokenWithTextArray.init(result);
    }

    pub fn append(self: *const TokenWithTextArray, other: *const TokenWithTextArray) !TokenWithTextArray {
        var result = ArrayList(TokenWithTextInfo).init(self._tokenInfo.allocator);
        errdefer result.deinit();
        try result.appendSlice(self._tokenInfo.items);
        try result.appendSlice(other._tokenInfo.items);
        return TokenWithTextArray.init(result);
    }
};

pub const TokenWithTextInfo = @import("./lineTokens.zig").TokenTextMetadata;

pub const TokenWithTextArrayBuilder = struct {
    _tokens: ArrayList(TokenWithTextInfo),

    pub fn init(allocator: Allocator) TokenWithTextArrayBuilder {
        return .{ ._tokens = ArrayList(TokenWithTextInfo).init(allocator) };
    }

    pub fn deinit(self: *TokenWithTextArrayBuilder) void {
        self._tokens.deinit();
    }

    pub fn add(self: *TokenWithTextArrayBuilder, text: []const u8, metadata: TokenMetadata) !void {
        try self._tokens.append(.{ .text = text, .metadata = metadata });
    }

    pub fn build(self: *TokenWithTextArrayBuilder) TokenWithTextArray {
        return TokenWithTextArray.init(self._tokens);
    }
};

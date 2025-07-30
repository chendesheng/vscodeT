const std = @import("std");
const ArrayList = std.ArrayList;
const OffsetRange = @import("../basics/offsetRange.zig").OffsetRange;
const LineTokens = @import("lineTokens.zig").LineTokens;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;

// This class represents a sequence of tokens.
// Conceptually, each token has a length and a metadata number.
// A token array might be used to annotate a string with metadata.
// Use {@link TokenWithTextArrayBuilder} to efficiently create a token array.
//
// TODO: Make this class more efficient (e.g. by using a Int32Array).
pub const TokenWithTextArray = struct {
    _tokenInfo: ArrayList(TokenWithTextInfo),

    pub fn fromLineTokens(lineTokens: LineTokens) !TokenWithTextArray {
        var tokenInfo = ArrayList(TokenWithTextInfo).init(lineTokens._tokens.allocator);
        for (0..lineTokens.getCount()) |i| {
            try tokenInfo.append(TokenWithTextInfo{
                .text = lineTokens.getTokenText(i),
                .metadata = lineTokens.getMetadata(i),
            });
        }
        return TokenWithTextArray.init(tokenInfo);
    }

    pub fn init(tokenInfo: ArrayList(TokenWithTextInfo)) TokenWithTextArray {
        return TokenWithTextArray{ ._tokenInfo = tokenInfo };
    }

    pub fn deinit(self: *TokenWithTextArray) void {
        self._tokenInfo.deinit();
    }

    pub fn toLineTokens(self: *TokenWithTextArray, decoder: LanguageIdCodec) LineTokens {
        return LineTokens.createFromTextAndMetadata(self._tokenInfo.allocator, self.map(struct {
            fn cb(_: void, t: TokenWithTextInfo) TokenWithTextInfo {
                return TokenWithTextInfo{ .text = t.text, .metadata = t.metadata };
            }
        }.cb, decoder));
    }

    pub fn forEach(self: *TokenWithTextArray, cb: fn (range: OffsetRange, tokenInfo: TokenWithTextInfo) void) void {
        var lengthSum = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.text.len);
            cb(range, tokenInfo);
            lengthSum += tokenInfo.text.len;
        }
    }

    pub fn map(self: *TokenWithTextArray, comptime T: type, context: anytype, cb: fn (ctx: @TypeOf(context), range: OffsetRange, tokenInfo: TokenWithTextInfo) T) !ArrayList(T) {
        var result = ArrayList(T).init(self._tokenInfo.allocator);
        var lengthSum = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.text.len);
            try result.append(cb(context, range, tokenInfo));
            lengthSum += tokenInfo.text.len;
        }
        return result;
    }

    pub fn slice(self: *TokenWithTextArray, range: OffsetRange) TokenWithTextArray {
        var result = ArrayList(TokenWithTextInfo).init(self._tokenInfo.allocator);
        var lengthSum = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const tokenStart = lengthSum;
            const tokenEndEx = tokenStart + tokenInfo.text.len;
            if (tokenEndEx > range.start) {
                if (tokenStart >= range.endExclusive) {
                    break;
                }

                const deltaBefore = @max(0, range.start - tokenStart);
                const deltaAfter = @max(0, tokenEndEx - range.endExclusive);

                try result.append(TokenWithTextInfo{
                    .text = tokenInfo.text.slice(deltaBefore, tokenInfo.text.len - deltaAfter),
                    .metadata = tokenInfo.metadata,
                });
            }

            lengthSum += tokenInfo.text.len;
        }
        return TokenWithTextArray.init(result);
    }

    pub fn append(self: *TokenWithTextArray, other: TokenWithTextArray) !TokenWithTextArray {
        var result = ArrayList(TokenWithTextInfo).init(self._tokenInfo.allocator);
        try result.appendSlice(self._tokenInfo.items);
        try result.appendSlice(other._tokenInfo.items);
        return TokenWithTextArray.init(result);
    }
};

pub const TokenMetadata = u32;

pub const TokenWithTextInfo = struct {
    text: []u8,
    metadata: TokenMetadata,
};

// TODO: Make this class more efficient (e.g. by using a Int32Array).
pub const TokenWithTextArrayBuilder = struct {
    _tokens: ArrayList(TokenWithTextInfo),

    pub fn add(self: *TokenWithTextArrayBuilder, text: []u8, metadata: TokenMetadata) void {
        try self._tokens.append(TokenWithTextInfo{
            .text = text,
            .metadata = metadata,
        });
    }

    pub fn build(self: *TokenWithTextArrayBuilder) TokenWithTextArray {
        return TokenWithTextArray.init(self._tokens);
    }
};

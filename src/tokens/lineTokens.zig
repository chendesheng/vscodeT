const std = @import("std");
const builtin = @import("builtin");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;

const LanguageIdCodec = @import("../services/languageRegistry.zig").LanguageIdCodec;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const TokenPresentation = @import("../encodedTokenAttributes.zig").TokenPresentation;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const OffsetRange = @import("../basics/offsetRange.zig").OffsetRange;
const Position = @import("../basics/position.zig").Position;
const TextModel = @import("../textModel/textModel.zig").TextModel;

pub const TokenPacked = packed struct(u64) {
    endOffset: u32,
    metadata: TokenMetadata,
    pub fn init(endOffset: u32, metadata: TokenMetadata) TokenPacked {
        return TokenPacked{
            .endOffset = endOffset,
            .metadata = metadata,
        };
    }
};

pub fn implementsIViewLineTokens(comptime T: type) void {
    comptime {
        const methods = [_][]const u8{
            "getLanguageIdCodec",
            "equals",
            "getCount",
            "getStandardTokenType",
            "getForeground",
            "getEndOffset",
            "getClassName",
            "getInlineStyle",
            "getPresentation",
            "findTokenIndexAtOffset",
            "getLineContent",
            "getMetadata",
            "getLanguageId",
            "getTokenText",
            "forEach",
        };
        for (methods) |method| {
            if (!@hasDecl(T, method)) {
                @compileError("Type " ++ @typeName(T) ++ " does not implement method " ++ method);
            }
        }
    }
}

pub const LineTokens = struct {
    _tokens: ArrayList(TokenPacked),
    _text: []const u8,
    languageIdCodec: LanguageIdCodec,

    pub fn initTokenPacked(offset: usize, metadata: TokenMetadata) TokenPacked {
        return TokenPacked{
            .endOffset = @intCast(offset),
            .metadata = metadata,
        };
    }

    pub fn init(tokens: ArrayList(TokenPacked), text: []const u8, decoder: LanguageIdCodec) LineTokens {
        const tokensLength = if (tokens.items.len > 0) tokens.items[tokens.items.len - 1].endOffset else 0;
        // Token length and text length do not match!
        std.debug.assert(tokensLength == text.len);

        return LineTokens{
            ._tokens = tokens,
            ._text = text,
            .languageIdCodec = decoder,
        };
    }

    pub fn deinit(self: *LineTokens) void {
        self._tokens.deinit();
    }

    pub fn createEmpty(allocator: Allocator, lineContent: []const u8, decoder: LanguageIdCodec) !LineTokens {
        const tokens = ArrayList(TokenPacked).init(allocator);
        try tokens.append(initTokenPacked(lineContent.items.len, TokenMetadata.default));
        return LineTokens.init(tokens, lineContent, decoder);
    }

    pub fn createFromTextAndMetadata(allocator: Allocator, data: []const struct { text: []const u8, metadata: TokenMetadata }, decoder: LanguageIdCodec) !LineTokens {
        var offset: usize = 0;
        var fullText = ArrayList(u8).init(allocator);
        var tokens = ArrayList(TokenPacked).init(allocator);
        for (data) |item| {
            const text = item.text;
            const metadata = item.metadata;
            try tokens.append(initTokenPacked(offset + text.len, metadata));
            offset += text.len;
            try fullText.appendSlice(text);
        }
        return LineTokens.init(tokens, fullText, decoder);
    }

    pub fn convertToEndOffset(tokens: []TokenPacked, lineTextLength: u32) void {
        const lastTokenIndex = tokens.len - 1;
        for (0..lastTokenIndex) |tokenIndex| {
            tokens[tokenIndex].endOffset = tokens[tokenIndex + 1].endOffset;
        }
        tokens[lastTokenIndex].endOffset = lineTextLength;
    }

    pub fn findIndexInTokensArray(tokens: []TokenPacked, desiredIndex: usize) usize {
        if (tokens.len <= 2) {
            return 0;
        }

        var low: usize = 0;
        var high: usize = tokens.len - 1;

        while (low < high) {
            const mid = low + @divFloor(high - low, 2);
            const endOffset = tokens[mid].endOffset;

            if (endOffset == desiredIndex) {
                return mid + 1;
            } else if (endOffset < desiredIndex) {
                low = mid + 1;
            } else if (endOffset > desiredIndex) {
                high = mid;
            }
        }

        return low;
    }

    pub fn getLanguageIdCodec(self: *const LineTokens) LanguageIdCodec {
        return self.languageIdCodec;
    }

    pub fn getTextLength(self: *const LineTokens) usize {
        return self._text.len;
    }

    pub fn equals(self: *const LineTokens, other: *const LineTokens) bool {
        return self.slicedEquals(other, 0, self._tokens.items.len);
    }

    pub fn slicedEquals(self: *const LineTokens, other: *const LineTokens, sliceFromTokenIndex: usize, sliceTokenCount: usize) bool {
        if (self._text.len != other._text.len) {
            return false;
        }
        if (self._tokens.items.len != other._tokens.items.len) {
            return false;
        }
        for (sliceFromTokenIndex..sliceFromTokenIndex + sliceTokenCount) |i| {
            if (self._tokens.items[i] != other._tokens.items[i]) {
                return false;
            }
        }
        return true;
    }

    pub fn getLineContent(self: *const LineTokens) []const u8 {
        return self._text;
    }

    pub fn getCount(self: *const LineTokens) usize {
        return self._tokens.items.len;
    }

    pub fn getStartOffset(self: *const LineTokens, tokenIndex: usize) u32 {
        if (tokenIndex > 0) {
            return self._tokens.items[tokenIndex - 1].endOffset;
        }
        return 0;
    }

    pub fn getMetadata(self: *const LineTokens, tokenIndex: usize) TokenMetadata {
        return self._tokens.items[tokenIndex].metadata;
    }

    pub fn getLanguageId(self: *const LineTokens, tokenIndex: usize) []const u8 {
        const languageId = self.getMetadata(tokenIndex).languageId;
        return self.languageIdCodec.decodeLanguageId(languageId);
    }

    pub fn getStandardTokenType(self: *const LineTokens, tokenIndex: usize) StandardTokenType {
        return self.getMetadata(tokenIndex).tokenType;
    }

    pub fn getForeground(self: *const LineTokens, tokenIndex: usize) u9 {
        return self.getMetadata(tokenIndex).foreground;
    }

    pub fn getClassName(self: *const LineTokens, tokenIndex: usize) !ArrayList(u8) {
        return try self.getMetadata(tokenIndex).getClassNameFromMetadata(self._tokens.allocator);
    }

    pub fn getInlineStyle(self: *const LineTokens, tokenIndex: usize, colorMap: []const []const u8) !ArrayList(u8) {
        return try self.getMetadata(tokenIndex).getInlineStyleFromMetadata(self._tokens.allocator, colorMap);
    }

    pub fn getPresentation(self: *const LineTokens, tokenIndex: usize) TokenPresentation {
        return self.getMetadata(tokenIndex).getPresentationFromMetadata();
    }

    pub fn getEndOffset(self: *const LineTokens, tokenIndex: usize) u32 {
        return self._tokens.items[tokenIndex].endOffset;
    }

    // Find the token containing offset `offset`.
    // @param offset The search offset
    // @return The index of the token containing the offset.
    pub fn findTokenIndexAtOffset(self: *const LineTokens, offset: usize) usize {
        return LineTokens.findIndexInTokensArray(self._tokens.items, offset);
    }

    pub fn inflate(self: *const LineTokens) LineTokens {
        return self;
    }

    pub fn sliceAndInflate(self: *const LineTokens, startOffset: usize, endOffset: usize, deltaOffset: usize) SliceLineTokens {
        return SliceLineTokens.init(self, startOffset, endOffset, deltaOffset);
    }

    pub fn sliceZeroCopy(self: *const LineTokens, range: OffsetRange) SliceLineTokens {
        return self.sliceAndInflate(range.start, range.endExclusive, 0);
    }

    pub const InsertTokenArg = struct {
        offset: u32,
        text: []const u8,
        tokenMetadata: TokenMetadata,
    };

    // @pure
    // @param insertTokens Must be sorted by offset.
    pub fn withInserted(self: *const LineTokens, allocator: Allocator, insertTokens: []const InsertTokenArg) !LineTokens {
        if (insertTokens.len == 0) {
            return self.*;
        }

        var nextOriginalTokenIdx: usize = 0;
        var nextInsertTokenIdx: usize = 0;
        var text = ArrayList(u8).init(allocator);
        defer text.deinit();
        var newTokens = ArrayList(TokenPacked).init(allocator);

        var originalEndOffset: usize = 0;
        while (true) {
            const nextOriginalTokenEndOffset = if (nextOriginalTokenIdx < self._tokens.items.len) self._tokens.items[nextOriginalTokenIdx].endOffset else null;
            const nextInsertToken = if (nextInsertTokenIdx < insertTokens.len) insertTokens[nextInsertTokenIdx] else null;

            if (nextOriginalTokenEndOffset != null and (nextInsertToken == null or nextOriginalTokenEndOffset.? <= nextInsertToken.?.offset)) {
                // original token ends before next insert token
                try text.appendSlice(self._text[originalEndOffset..nextOriginalTokenEndOffset.?]);
                const metadata = self.getMetadata(nextOriginalTokenIdx);
                try newTokens.append(initTokenPacked(@intCast(text.items.len), metadata));
                nextOriginalTokenIdx += 1;
                originalEndOffset = nextOriginalTokenEndOffset.?;
            } else if (nextInsertToken) |_nextInsertToken| {
                if (_nextInsertToken.offset > originalEndOffset) {
                    // insert token is in the middle of the next token.
                    try text.appendSlice(self._text[originalEndOffset.._nextInsertToken.offset]);
                    const metadata = self.getMetadata(nextOriginalTokenIdx);
                    try newTokens.append(initTokenPacked(text.items.len, metadata));
                    originalEndOffset = _nextInsertToken.offset;
                }

                try text.appendSlice(_nextInsertToken.text);
                try newTokens.append(initTokenPacked(text.items.len, _nextInsertToken.tokenMetadata));
                nextInsertTokenIdx += 1;
            } else {
                break;
            }
        }

        return LineTokens.init(newTokens, try text.toOwnedSlice(), self.languageIdCodec);
    }

    pub fn getTokensInRange(self: *const LineTokens, allocator: Allocator, range: OffsetRange) TokenArray {
        var builder = TokenArrayBuilder.init(allocator);

        const startTokenIndex = self.findTokenIndexAtOffset(range.start);
        const endTokenIndex = self.findTokenIndexAtOffset(range.endExclusive);

        for (startTokenIndex..endTokenIndex) |tokenIndex| {
            const tokenRange = OffsetRange.init(self.getStartOffset(tokenIndex), self.getEndOffset(tokenIndex));
            const length = tokenRange.intersectionLength(range);
            if (length > 0) {
                try builder.add(length, self.getMetadata(tokenIndex));
            }
        }

        return builder.build();
    }

    pub fn getTokenText(self: *const LineTokens, tokenIndex: usize) []const u8 {
        const startOffset = self.getStartOffset(tokenIndex);
        const endOffset = self.getEndOffset(tokenIndex);
        return self._text[startOffset..endOffset];
    }

    pub fn forEach(self: *const LineTokens, context: anytype, callback: fn (tokenIndex: usize, ctx: @TypeOf(context)) void) void {
        const tokenCount = self.getCount();
        for (0..tokenCount) |tokenIndex| {
            callback(tokenIndex, context);
        }
    }

    pub fn toString(self: *const LineTokens) !ArrayList(u8) {
        var result = ArrayList(u8).init(self._tokens.allocator);
        var writer = result.writer();
        const tokenCount = self.getCount();
        for (0..tokenCount) |tokenIndex| {
            const className = try self.getClassName(tokenIndex);
            defer className.deinit();
            try writer.print("[{s}]{{{s}}}", .{ self.getTokenText(tokenIndex), className.items });
        }
        return result;
    }
};

pub const SliceLineTokens = struct {
    _source: *const LineTokens,
    _startOffset: usize,
    _endOffset: usize,
    _deltaOffset: usize,

    _firstTokenIndex: usize,
    _tokensCount: usize,

    pub fn init(source: *const LineTokens, startOffset: usize, endOffset: usize, deltaOffset: usize) SliceLineTokens {
        const firstTokenIndex = source.findTokenIndexAtOffset(startOffset);

        var tokensCount: usize = 0;
        for (firstTokenIndex..source.getCount()) |i| {
            const tokenStartOffset = source.getStartOffset(i);
            if (tokenStartOffset >= endOffset) {
                break;
            }
            tokensCount += 1;
        }

        return SliceLineTokens{
            ._source = source,
            ._startOffset = startOffset,
            ._endOffset = endOffset,
            ._deltaOffset = deltaOffset,
            ._firstTokenIndex = firstTokenIndex,
            ._tokensCount = tokensCount,
        };
    }

    pub fn getLanguageIdCodec(self: *const SliceLineTokens) LanguageIdCodec {
        return self._source.getLanguageIdCodec();
    }

    pub fn getMetadata(self: *const SliceLineTokens, tokenIndex: usize) TokenMetadata {
        return self._source.getMetadata(self._firstTokenIndex + tokenIndex);
    }

    pub fn getLanguageId(self: *const SliceLineTokens, tokenIndex: usize) []const u8 {
        return self._source.getLanguageId(self._firstTokenIndex + tokenIndex);
    }

    pub fn getLineContent(self: *const SliceLineTokens) []const u8 {
        return self._source.getLineContent()[self._startOffset..self._endOffset];
    }

    pub fn equals(self: *const SliceLineTokens, other: *const SliceLineTokens) bool {
        if (other == SliceLineTokens) {
            return (self._startOffset == other._startOffset and self._endOffset == other._endOffset and self._deltaOffset == other._deltaOffset and self._source.slicedEquals(other._source, self._firstTokenIndex, self._tokensCount));
        }
        return false;
    }

    pub fn getCount(self: *const SliceLineTokens) usize {
        return self._tokensCount;
    }

    pub fn getStandardTokenType(self: *const SliceLineTokens, tokenIndex: usize) StandardTokenType {
        return self._source.getStandardTokenType(self._firstTokenIndex + tokenIndex);
    }

    pub fn getForeground(self: *const SliceLineTokens, tokenIndex: usize) u9 {
        return self._source.getForeground(self._firstTokenIndex + tokenIndex);
    }

    pub fn getEndOffset(self: *const SliceLineTokens, tokenIndex: usize) usize {
        const tokenEndOffset = self._source.getEndOffset(self._firstTokenIndex + tokenIndex);
        return @min(self._endOffset, tokenEndOffset) - self._startOffset + self._deltaOffset;
    }

    pub fn getClassName(self: *const SliceLineTokens, tokenIndex: usize) !ArrayList(u8) {
        return try self._source.getClassName(self._firstTokenIndex + tokenIndex);
    }

    pub fn getInlineStyle(self: *const SliceLineTokens, tokenIndex: usize, colorMap: []const []const u8) !ArrayList(u8) {
        return try self._source.getInlineStyle(self._firstTokenIndex + tokenIndex, colorMap);
    }

    pub fn getPresentation(self: *const SliceLineTokens, tokenIndex: usize) TokenPresentation {
        return self._source.getPresentation(self._firstTokenIndex + tokenIndex);
    }

    pub fn findTokenIndexAtOffset(self: *const SliceLineTokens, offset: usize) usize {
        return self._source.findTokenIndexAtOffset(offset + self._startOffset - self._deltaOffset) - self._firstTokenIndex;
    }

    pub fn getTokenText(self: *const SliceLineTokens, tokenIndex: usize) []const u8 {
        const adjustedTokenIndex = self._firstTokenIndex + tokenIndex;
        const tokenStartOffset = self._source.getStartOffset(adjustedTokenIndex);
        const tokenEndOffset = self._source.getEndOffset(adjustedTokenIndex);
        var text = self._source.getTokenText(adjustedTokenIndex).toOwnedSlice();
        if (tokenStartOffset < self._startOffset) {
            text = text ++ self._text[self._startOffset - tokenStartOffset ..];
        }
        if (tokenEndOffset > self._endOffset) {
            text = text ++ self._text[0 .. text.len - (tokenEndOffset - self._endOffset)];
        }
        return text;
    }

    pub fn forEach(self: *const SliceLineTokens, context: anytype, callback: fn (tokenIndex: usize, ctx: @TypeOf(context)) void) void {
        for (0..self.getCount()) |tokenIndex| {
            callback(tokenIndex, context);
        }
    }
};

pub fn getStandardTokenTypeAtPosition(model: TextModel, position: Position) ?StandardTokenType {
    const lineNumber = position.lineNumber - 1;
    if (!model.tokenization().isCheapToTokenize(lineNumber)) {
        return null;
    }
    model.tokenization().forceTokenization(lineNumber);
    const lineTokens: LineTokens = model.tokenization().getLineTokens(lineNumber);
    const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1) - 1;
    const tokenType = lineTokens.getStandardTokenType(tokenIndex);
    return tokenType;
}

// This class represents a sequence of tokens.
// Conceptually, each token has a length and a metadata number.
// A token array might be used to annotate a string with metadata.
// Use {@link TokenArrayBuilder} to efficiently create a token array.
//
pub const TokenArray = struct {
    _tokenInfo: ArrayList(TokenInfo),

    pub fn init(tokenInfo: ArrayList(TokenInfo)) TokenArray {
        return .{ ._tokenInfo = tokenInfo };
    }

    pub fn deinit(self: *TokenArray) void {
        self._tokenInfo.deinit();
    }

    pub fn fromLineTokens(lineTokens: LineTokens) TokenArray {
        var tokenInfo = ArrayList(TokenInfo).init(lineTokens._tokens.allocator);
        for (0..lineTokens.getCount()) |i| {
            try tokenInfo.append(TokenInfo{
                .length = @intCast(lineTokens.getEndOffset(i) - lineTokens.getStartOffset(i)),
                .metadata = lineTokens.getMetadata(i),
            });
        }
        return TokenArray.init(tokenInfo);
    }

    pub fn toLineTokens(self: *TokenArray, lineContent: []const u8, decoder: LanguageIdCodec) LineTokens {
        return LineTokens.createFromTextAndMetadata(self.map(struct { text: []const u8, metadata: TokenMetadata }, {}, struct {
            fn cb(_: void, r: OffsetRange, t: TokenInfo) struct { text: []const u8, metadata: TokenMetadata } {
                return .{ .text = r.substring(lineContent), .metadata = t.metadata };
            }
        }.cb), decoder);
    }

    pub fn forEach(self: *TokenArray, context: anytype, cb: fn (range: OffsetRange, tokenInfo: TokenPacked, ctx: @TypeOf(context)) void) void {
        var lengthSum = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.length);
            cb(range, tokenInfo, context);
            lengthSum += tokenInfo.length;
        }
    }

    pub fn map(self: *TokenArray, comptime T: type, context: anytype, cb: fn (range: OffsetRange, tokenInfo: TokenPacked, ctx: @TypeOf(context)) T) ArrayList(T) {
        var result = ArrayList(T).init(self._tokenInfo.allocator);
        var lengthSum = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.length);
            try result.append(cb(range, tokenInfo, context));
            lengthSum += tokenInfo.length;
        }
        return result;
    }

    pub fn slice(self: *TokenArray, range: OffsetRange) TokenArray {
        var result = ArrayList(TokenInfo).init(self._tokenInfo.allocator);
        var lengthSum: i32 = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const tokenInfoLen: i32 = @intCast(tokenInfo.length);
            const tokenStart: i32 = lengthSum;
            const tokenEndEx: i32 = tokenStart + tokenInfoLen;
            const rangeStart: i32 = @intCast(range.start);
            const rangeEndExclusive: i32 = @intCast(range.endExclusive);
            if (tokenEndEx > rangeStart) {
                if (tokenStart >= rangeEndExclusive) {
                    break;
                }

                const deltaBefore: i32 = @max(0, rangeStart - tokenStart);
                const deltaAfter: i32 = @max(0, tokenEndEx - rangeEndExclusive);

                try result.append(TokenInfo{
                    .length = @intCast(tokenInfoLen - deltaBefore - deltaAfter),
                    .metadata = tokenInfo.metadata,
                });
            }

            lengthSum += tokenInfoLen;
        }
        return TokenArray.init(result);
    }

    pub fn append(self: *TokenArray, other: TokenArray) TokenArray {
        const result = ArrayList(TokenInfo).init(self._tokenInfo.allocator);
        try result.appendSlice(self._tokenInfo.items);
        try result.appendSlice(other._tokenInfo.items);
        return TokenArray.init(result);
    }
};

const TokenInfoBigEndian = packed struct(u64) {
    length: u32,
    metadata: TokenMetadata,
};

const TokenInfoLittleEndian = packed struct(u64) {
    metadata: TokenMetadata,
    length: u32,
};

const TokenInfo = if (builtin.target.cpu.arch.endian() == .big) TokenInfoBigEndian else TokenInfoLittleEndian;

pub const TokenArrayBuilder = struct {
    _tokens: ArrayList(TokenInfo),

    pub fn init(allocator: Allocator) TokenArrayBuilder {
        return TokenArrayBuilder{
            ._tokens = ArrayList(TokenInfo).init(allocator),
        };
    }

    pub fn add(self: *TokenArrayBuilder, length: usize, metadata: TokenMetadata) !void {
        try self._tokens.append(TokenInfo{
            .length = @intCast(length),
            .metadata = metadata,
        });
    }

    pub fn build(self: *TokenArrayBuilder) TokenArray {
        return TokenArray.init(self._tokens);
    }
};

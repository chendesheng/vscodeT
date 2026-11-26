// Port of `src/vs/editor/common/tokens/lineTokens.ts`.
//
// Zig adaptations: token pairs are stored as packed `TokenPacked` values
// rather than a flat `Uint32Array`; `IViewLineTokens` is a tagged union of
// `LineTokens`/`SliceLineTokens`; and `withInserted` returns a deep copy
// because Zig values do not have reference identity.
const LineContent = @import("../model/pieceTreeTextBuffer/pieceTreeBase.zig").LineContent;
const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const TokenPresentation = @import("../encodedTokenAttributes.zig").TokenPresentation;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const OffsetRange = @import("../core/ranges/offsetRange.zig").OffsetRange;
const Position = @import("../core/position.zig").Position;
const TextModel = @import("../model/textModel.zig").TextModel;

pub const TokenTextMetadata = struct { text: []const u8, metadata: TokenMetadata };

pub const TokenPacked = packed struct(u64) {
    endOffset: u32,
    metadata: TokenMetadata,

    pub fn init(endOffset: u32, metadata: TokenMetadata) TokenPacked {
        return .{ .endOffset = endOffset, .metadata = metadata };
    }
};

pub const LineTokens = struct {
    _tokens: ArrayList(TokenPacked),
    _text: ArrayList(u8),
    shared_text: ?*LineContent = null,
    languageIdCodec: *LanguageIdCodec,

    pub fn initTokenPacked(offset: usize, metadata: TokenMetadata) TokenPacked {
        return .{ .endOffset = @intCast(offset), .metadata = metadata };
    }

    /// Takes ownership of both `tokens` and `text`.
    pub fn init(tokens: ArrayList(TokenPacked), text: ArrayList(u8), decoder: *LanguageIdCodec) LineTokens {
        // Upstream reports this through `onUnexpectedError` and keeps going.
        // There is no global error reporter in the port, so print the same
        // message instead of failing the assertion.
        const matches = if (tokens.items.len > 0)
            tokens.items[tokens.items.len - 1].endOffset == text.items.len
        else
            text.items.len == 0;
        if (!matches) {
            std.debug.print("Token length and text length do not match!\n", .{});
        }
        return .{ ._tokens = tokens, ._text = text, .languageIdCodec = decoder };
    }

    pub fn deinit(self: *LineTokens) void {
        self._tokens.deinit();
        self._text.deinit();
        if (self.shared_text) |line| line.release();
    }

    /// Deep copy of the tokens and the text, allocated with `allocator`.
    pub fn clone(self: *const LineTokens, allocator: Allocator) !LineTokens {
        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();
        try tokens.appendSlice(self._tokens.items);

        var text = ArrayList(u8).init(allocator);
        errdefer text.deinit();
        try text.appendSlice(self.getLineContent());

        return LineTokens.init(tokens, text, self.languageIdCodec);
    }

    /// A retained ViewLine owns a reference to the same immutable model line.
    pub fn retainForView(self: *const LineTokens, allocator: Allocator) !LineTokens {
        const shared = self.shared_text orelse return self.clone(allocator);
        var tokens = ArrayList(TokenPacked).init(allocator);
        try tokens.appendSlice(self._tokens.items);
        return .{ ._text = .init(allocator), .shared_text = shared.retain(), ._tokens = tokens, .languageIdCodec = self.languageIdCodec };
    }

    pub fn createEmpty(allocator: Allocator, lineContent: ArrayList(u8), decoder: *LanguageIdCodec) !LineTokens {
        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();
        try tokens.append(initTokenPacked(lineContent.items.len, TokenMetadata.default));
        return LineTokens.init(tokens, lineContent, decoder);
    }

    pub fn createFromTextAndMetadata(allocator: Allocator, data: []const TokenTextMetadata, decoder: *LanguageIdCodec) !LineTokens {
        var fullText = ArrayList(u8).init(allocator);
        errdefer fullText.deinit();
        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();

        var offset: usize = 0;
        for (data) |item| {
            offset += item.text.len;
            try tokens.append(initTokenPacked(offset, item.metadata));
            try fullText.appendSlice(item.text);
        }
        return LineTokens.init(tokens, fullText, decoder);
    }

    pub fn convertToEndOffset(tokens: []TokenPacked, lineTextLength: usize) void {
        if (tokens.len == 0) return;
        const lastTokenIndex = tokens.len - 1;
        for (0..lastTokenIndex) |tokenIndex| {
            tokens[tokenIndex].endOffset = tokens[tokenIndex + 1].endOffset;
        }
        tokens[lastTokenIndex].endOffset = @intCast(lineTextLength);
    }

    pub fn findIndexInTokensArray(tokens: []const TokenPacked, desiredIndex: usize) usize {
        if (tokens.len <= 1) return 0;

        var low: usize = 0;
        var high: usize = tokens.len - 1;
        while (low < high) {
            const mid = low + @divFloor(high - low, 2);
            const endOffset = tokens[mid].endOffset;
            if (endOffset == desiredIndex) {
                return mid + 1;
            } else if (endOffset < desiredIndex) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    pub fn getTextLength(self: *const LineTokens) usize {
        return self.getLineContent().len;
    }

    pub fn equals(self: *const LineTokens, other: *const LineTokens) bool {
        return self.slicedEquals(other, 0, self._tokens.items.len);
    }

    pub fn slicedEquals(self: *const LineTokens, other: *const LineTokens, sliceFromTokenIndex: usize, sliceTokenCount: usize) bool {
        // Upstream compares the whole text and token count first; `===` on
        // strings is reference identity there, while the port compares the
        // text content.
        if ((self.shared_text == null or self.shared_text != other.shared_text) and !std.mem.eql(u8, self.getLineContent(), other.getLineContent())) return false;
        if (self._tokens.items.len != other._tokens.items.len) return false;
        if (sliceFromTokenIndex > self._tokens.items.len) return false;
        if (sliceTokenCount > self._tokens.items.len - sliceFromTokenIndex) return false;
        for (0..sliceTokenCount) |i| {
            if (self._tokens.items[sliceFromTokenIndex + i] != other._tokens.items[sliceFromTokenIndex + i]) {
                return false;
            }
        }
        return true;
    }

    pub fn getLineContent(self: *const LineTokens) []const u8 {
        return if (self.shared_text) |line| line.text.items else self._text.items;
    }

    pub fn getCount(self: *const LineTokens) usize {
        return self._tokens.items.len;
    }

    pub fn getStartOffset(self: *const LineTokens, tokenIndex: usize) usize {
        if (tokenIndex > 0) return self._tokens.items[tokenIndex - 1].endOffset;
        return 0;
    }

    pub fn getMetadata(self: *const LineTokens, tokenIndex: usize) TokenMetadata {
        return self._tokens.items[tokenIndex].metadata;
    }

    pub fn getLanguageId(self: *const LineTokens, tokenIndex: usize) []const u8 {
        return self.languageIdCodec.decodeLanguageId(self.getMetadata(tokenIndex).languageId);
    }

    pub fn getStandardTokenType(self: *const LineTokens, tokenIndex: usize) StandardTokenType {
        return self.getMetadata(tokenIndex).tokenType;
    }

    pub fn getForeground(self: *const LineTokens, tokenIndex: usize) u9 {
        return self.getMetadata(tokenIndex).foreground;
    }

    pub fn getClassName(self: *const LineTokens, tokenIndex: usize) !ArrayList(u8) {
        return try self.getMetadata(tokenIndex).getClassNameFromMetadata(self._text.allocator);
    }

    pub fn getInlineStyle(self: *const LineTokens, tokenIndex: usize, colorMap: []const []const u8) !ArrayList(u8) {
        return try self.getMetadata(tokenIndex).getInlineStyleFromMetadata(self._text.allocator, colorMap);
    }

    pub fn getPresentation(self: *const LineTokens, tokenIndex: usize) TokenPresentation {
        return self.getMetadata(tokenIndex).getPresentationFromMetadata();
    }

    pub fn getEndOffset(self: *const LineTokens, tokenIndex: usize) usize {
        return self._tokens.items[tokenIndex].endOffset;
    }

    pub fn findTokenIndexAtOffset(self: *const LineTokens, offset: usize) usize {
        return LineTokens.findIndexInTokensArray(self._tokens.items, offset);
    }

    pub fn inflate(self: *const LineTokens) *const LineTokens {
        return self;
    }

    pub fn sliceAndInflate(self: *const LineTokens, startOffset: usize, endOffset: usize, deltaOffset: usize) SliceLineTokens {
        return SliceLineTokens.init(self, startOffset, endOffset, deltaOffset);
    }

    pub fn sliceZeroCopy(self: *const LineTokens, range: OffsetRange) SliceLineTokens {
        return self.sliceAndInflate(range.start, range.endExclusive, 0);
    }

    pub const InsertedToken = struct { offset: usize, text: []const u8, tokenMetadata: TokenMetadata };

    pub fn withInserted(self: *const LineTokens, insertTokens: []const InsertedToken) !LineTokens {
        if (insertTokens.len == 0) {
            return self.clone(self._text.allocator);
        }

        var nextOriginalTokenIdx: usize = 0;
        var nextInsertTokenIdx: usize = 0;
        var text = ArrayList(u8).init(self._text.allocator);
        errdefer text.deinit();
        var newTokens = ArrayList(TokenPacked).init(self._tokens.allocator);
        errdefer newTokens.deinit();

        var originalEndOffset: usize = 0;
        while (true) {
            const nextOriginalTokenEndOffset: ?usize = if (nextOriginalTokenIdx < self._tokens.items.len) self._tokens.items[nextOriginalTokenIdx].endOffset else null;
            const nextInsertToken: ?@TypeOf(insertTokens[0]) = if (nextInsertTokenIdx < insertTokens.len) insertTokens[nextInsertTokenIdx] else null;

            if (nextOriginalTokenEndOffset != null and (nextInsertToken == null or nextOriginalTokenEndOffset.? <= nextInsertToken.?.offset)) {
                try text.appendSlice(self.getLineContent()[originalEndOffset..nextOriginalTokenEndOffset.?]);
                const metadata = self.getMetadata(nextOriginalTokenIdx);
                try newTokens.append(initTokenPacked(text.items.len, metadata));
                nextOriginalTokenIdx += 1;
                originalEndOffset = nextOriginalTokenEndOffset.?;
            } else if (nextInsertToken) |insertToken| {
                if (insertToken.offset > originalEndOffset) {
                    try text.appendSlice(self.getLineContent()[originalEndOffset..insertToken.offset]);
                    const metadata = self.getMetadata(nextOriginalTokenIdx);
                    try newTokens.append(initTokenPacked(text.items.len, metadata));
                    originalEndOffset = insertToken.offset;
                }
                try text.appendSlice(insertToken.text);
                try newTokens.append(initTokenPacked(text.items.len, insertToken.tokenMetadata));
                nextInsertTokenIdx += 1;
            } else {
                break;
            }
        }

        return LineTokens.init(newTokens, text, self.languageIdCodec);
    }

    pub fn getTokensInRange(self: *const LineTokens, range: OffsetRange) !TokenArray {
        var builder = TokenArrayBuilder.init(self._tokens.allocator);

        const startTokenIndex = self.findTokenIndexAtOffset(range.start);
        const endTokenIndex = self.findTokenIndexAtOffset(range.endExclusive);

        var tokenIndex = startTokenIndex;
        while (tokenIndex <= endTokenIndex and tokenIndex < self.getCount()) : (tokenIndex += 1) {
            const tokenRange = OffsetRange.init(self.getStartOffset(tokenIndex), self.getEndOffset(tokenIndex));
            const length = tokenRange.intersectionLength(range);
            if (length > 0) {
                try builder.add(length, self.getMetadata(tokenIndex));
            }
        }

        return builder.build();
    }

    pub fn getTokenText(self: *const LineTokens, tokenIndex: usize) []const u8 {
        return self.getLineContent()[self.getStartOffset(tokenIndex)..self.getEndOffset(tokenIndex)];
    }

    pub fn forEach(self: *const LineTokens, context: anytype, callback: fn (tokenIndex: usize, ctx: @TypeOf(context)) void) void {
        for (0..self.getCount()) |tokenIndex| callback(tokenIndex, context);
    }

    pub fn toString(self: *const LineTokens) !ArrayList(u8) {
        var result: Io.Writer.Allocating = .init(self._text.allocator);
        errdefer result.deinit();
        for (0..self.getCount()) |tokenIndex| {
            const className = try self.getClassName(tokenIndex);
            defer className.deinit();
            try result.writer.print("[{s}]{{{s}}}", .{ self.getTokenText(tokenIndex), className.items });
        }
        return ArrayList(u8).fromOwnedSlice(self._text.allocator, try result.toOwnedSlice());
    }
};

pub const SliceLineTokens = struct {
    _source: *const LineTokens,
    _startOffset: usize,
    _endOffset: usize,
    _deltaOffset: usize,
    _firstTokenIndex: usize,
    _tokensCount: usize,
    languageIdCodec: *LanguageIdCodec,

    pub fn init(source: *const LineTokens, startOffset: usize, endOffset: usize, deltaOffset: usize) SliceLineTokens {
        const firstTokenIndex = source.findTokenIndexAtOffset(startOffset);
        var tokensCount: usize = 0;
        var i = firstTokenIndex;
        while (i < source.getCount()) : (i += 1) {
            if (source.getStartOffset(i) >= endOffset) break;
            tokensCount += 1;
        }
        return .{
            ._source = source,
            ._startOffset = startOffset,
            ._endOffset = endOffset,
            ._deltaOffset = deltaOffset,
            ._firstTokenIndex = firstTokenIndex,
            ._tokensCount = tokensCount,
            .languageIdCodec = source.languageIdCodec,
        };
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
        return self._startOffset == other._startOffset and
            self._endOffset == other._endOffset and
            self._deltaOffset == other._deltaOffset and
            self._source.slicedEquals(other._source, self._firstTokenIndex, self._tokensCount);
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

        var start = tokenStartOffset;
        var end = tokenEndOffset;
        if (start < self._startOffset) start = self._startOffset;
        if (end > self._endOffset) end = self._endOffset;
        return self._source.getLineContent()[start..end];
    }

    pub fn forEach(self: *const SliceLineTokens, context: anytype, callback: fn (tokenIndex: usize, ctx: @TypeOf(context)) void) void {
        for (0..self.getCount()) |tokenIndex| callback(tokenIndex, context);
    }
};

/// A read-only view over a line's tokens. Upstream declares this as the
/// `IViewLineTokens` interface, which both `LineTokens` and `SliceLineTokens`
/// implement; here it is modelled as a tagged union over the two.
pub const IViewLineTokens = union(enum) {
    tokens: *const LineTokens,
    slice: SliceLineTokens,

    pub fn init(tokens: *const LineTokens) IViewLineTokens {
        return .{ .tokens = tokens };
    }

    pub fn initSlice(slice: SliceLineTokens) IViewLineTokens {
        return .{ .slice = slice };
    }

    pub fn equals(self: IViewLineTokens, other: IViewLineTokens) bool {
        return switch (self) {
            .tokens => |a| switch (other) {
                .tokens => |b| a.equals(b),
                .slice => false,
            },
            .slice => |a| switch (other) {
                .slice => |b| a.equals(&b),
                .tokens => false,
            },
        };
    }

    pub fn getCount(self: IViewLineTokens) usize {
        return switch (self) {
            .tokens => |t| t.getCount(),
            .slice => |s| s.getCount(),
        };
    }

    pub fn getStandardTokenType(self: IViewLineTokens, tokenIndex: usize) StandardTokenType {
        return switch (self) {
            .tokens => |t| t.getStandardTokenType(tokenIndex),
            .slice => |s| s.getStandardTokenType(tokenIndex),
        };
    }

    pub fn getForeground(self: IViewLineTokens, tokenIndex: usize) u9 {
        return switch (self) {
            .tokens => |t| t.getForeground(tokenIndex),
            .slice => |s| s.getForeground(tokenIndex),
        };
    }

    pub fn getEndOffset(self: IViewLineTokens, tokenIndex: usize) usize {
        return switch (self) {
            .tokens => |t| t.getEndOffset(tokenIndex),
            .slice => |s| s.getEndOffset(tokenIndex),
        };
    }

    pub fn getClassName(self: IViewLineTokens, tokenIndex: usize) !ArrayList(u8) {
        return switch (self) {
            .tokens => |t| t.getClassName(tokenIndex),
            .slice => |s| s.getClassName(tokenIndex),
        };
    }

    pub fn getInlineStyle(self: IViewLineTokens, tokenIndex: usize, colorMap: []const []const u8) !ArrayList(u8) {
        return switch (self) {
            .tokens => |t| t.getInlineStyle(tokenIndex, colorMap),
            .slice => |s| s.getInlineStyle(tokenIndex, colorMap),
        };
    }

    pub fn getPresentation(self: IViewLineTokens, tokenIndex: usize) TokenPresentation {
        return switch (self) {
            .tokens => |t| t.getPresentation(tokenIndex),
            .slice => |s| s.getPresentation(tokenIndex),
        };
    }

    pub fn getLineContent(self: IViewLineTokens) []const u8 {
        return switch (self) {
            .tokens => |t| t.getLineContent(),
            .slice => |s| s.getLineContent(),
        };
    }

    pub fn getMetadata(self: IViewLineTokens, tokenIndex: usize) TokenMetadata {
        return switch (self) {
            .tokens => |t| t.getMetadata(tokenIndex),
            .slice => |s| s.getMetadata(tokenIndex),
        };
    }

    pub fn getLanguageId(self: IViewLineTokens, tokenIndex: usize) []const u8 {
        return switch (self) {
            .tokens => |t| t.getLanguageId(tokenIndex),
            .slice => |s| s.getLanguageId(tokenIndex),
        };
    }

    pub fn findTokenIndexAtOffset(self: IViewLineTokens, offset: usize) usize {
        return switch (self) {
            .tokens => |t| t.findTokenIndexAtOffset(offset),
            .slice => |s| s.findTokenIndexAtOffset(offset),
        };
    }

    pub fn getTokenText(self: IViewLineTokens, tokenIndex: usize) []const u8 {
        return switch (self) {
            .tokens => |t| t.getTokenText(tokenIndex),
            .slice => |s| s.getTokenText(tokenIndex),
        };
    }

    pub fn forEach(self: IViewLineTokens, context: anytype, callback: fn (tokenIndex: usize, ctx: @TypeOf(context)) void) void {
        switch (self) {
            .tokens => |t| t.forEach(context, callback),
            .slice => |s| s.forEach(context, callback),
        }
    }
};

pub fn getStandardTokenTypeAtPosition(model: *TextModel, position: Position) !?StandardTokenType {
    const lineNumber = position.lineNumber;
    if (!model.tokenization().isCheapToTokenize(lineNumber)) return null;
    model.tokenization().forceTokenization(lineNumber);
    var lineTokens = try model.tokenization().getLineTokens(lineNumber);
    defer lineTokens.deinit();
    const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1);
    return lineTokens.getStandardTokenType(tokenIndex);
}

// This class represents a sequence of tokens.
// Conceptually, each token has a length and a metadata number.
pub const TokenArray = struct {
    _tokenInfo: ArrayList(TokenInfo),

    pub fn init(tokenInfo: ArrayList(TokenInfo)) TokenArray {
        return .{ ._tokenInfo = tokenInfo };
    }

    pub fn deinit(self: *TokenArray) void {
        self._tokenInfo.deinit();
    }

    pub fn fromLineTokens(lineTokens: *const LineTokens) !TokenArray {
        var tokenInfo = ArrayList(TokenInfo).init(lineTokens._tokens.allocator);
        errdefer tokenInfo.deinit();
        for (0..lineTokens.getCount()) |i| {
            try tokenInfo.append(TokenInfo{
                .length = lineTokens.getEndOffset(i) - lineTokens.getStartOffset(i),
                .metadata = lineTokens.getMetadata(i),
            });
        }
        return TokenArray.init(tokenInfo);
    }

    pub fn toLineTokens(self: *const TokenArray, allocator: Allocator, lineContent: []const u8, decoder: *LanguageIdCodec) !LineTokens {
        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();
        var text = ArrayList(u8).init(allocator);
        errdefer text.deinit();

        var offset: usize = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const end = offset + tokenInfo.length;
            try text.appendSlice(lineContent[offset..end]);
            try tokens.append(LineTokens.initTokenPacked(text.items.len, tokenInfo.metadata));
            offset = end;
        }
        return LineTokens.init(tokens, text, decoder);
    }

    pub fn forEach(self: *const TokenArray, context: anytype, cb: fn (range: OffsetRange, tokenInfo: TokenInfo, ctx: @TypeOf(context)) void) void {
        var lengthSum: usize = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.length);
            cb(range, tokenInfo, context);
            lengthSum += tokenInfo.length;
        }
    }

    pub fn map(self: *const TokenArray, comptime T: type, context: anytype, cb: fn (range: OffsetRange, tokenInfo: TokenInfo, ctx: @TypeOf(context)) T) !ArrayList(T) {
        var result = ArrayList(T).init(self._tokenInfo.allocator);
        errdefer result.deinit();
        var lengthSum: usize = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const range = OffsetRange.init(lengthSum, lengthSum + tokenInfo.length);
            try result.append(cb(range, tokenInfo, context));
            lengthSum += tokenInfo.length;
        }
        return result;
    }

    pub fn slice(self: *const TokenArray, range: OffsetRange) !TokenArray {
        var result = ArrayList(TokenInfo).init(self._tokenInfo.allocator);
        errdefer result.deinit();
        var lengthSum: usize = 0;
        for (self._tokenInfo.items) |tokenInfo| {
            const tokenStart = lengthSum;
            const tokenEndEx = tokenStart + tokenInfo.length;
            if (tokenEndEx > range.start) {
                if (tokenStart >= range.endExclusive) break;
                const deltaBefore = range.start -| tokenStart;
                const deltaAfter = tokenEndEx -| range.endExclusive;
                try result.append(TokenInfo{
                    .length = tokenInfo.length - deltaBefore - deltaAfter,
                    .metadata = tokenInfo.metadata,
                });
            }
            lengthSum = tokenEndEx;
        }
        return TokenArray.init(result);
    }

    pub fn append(self: *const TokenArray, other: *const TokenArray) !TokenArray {
        var result = ArrayList(TokenInfo).init(self._tokenInfo.allocator);
        errdefer result.deinit();
        try result.appendSlice(self._tokenInfo.items);
        try result.appendSlice(other._tokenInfo.items);
        return TokenArray.init(result);
    }
};

pub const TokenInfo = struct {
    length: usize,
    metadata: TokenMetadata,
};

pub const TokenArrayBuilder = struct {
    _tokens: ArrayList(TokenInfo),

    pub fn init(allocator: Allocator) TokenArrayBuilder {
        return .{ ._tokens = ArrayList(TokenInfo).init(allocator) };
    }

    pub fn deinit(self: *TokenArrayBuilder) void {
        self._tokens.deinit();
    }

    pub fn add(self: *TokenArrayBuilder, length: usize, metadata: TokenMetadata) !void {
        try self._tokens.append(.{ .length = length, .metadata = metadata });
    }

    pub fn build(self: *TokenArrayBuilder) TokenArray {
        return TokenArray.init(self._tokens);
    }
};

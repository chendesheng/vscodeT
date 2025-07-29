const std = @import("std");

const ILanguageIdCodec = @import("../languages.zig").ILanguageIdCodec;
const FontStyle = @import("../encodedTokenAttributes.zig").FontStyle;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const MetadataConsts = @import("../encodedTokenAttributes.zig").MetadataConsts;
const ITokenPresentation = @import("../encodedTokenAttributes.zig").ITokenPresentation;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;


pub const LineTokens = struct {
	_tokens: std.ArrayList(u32),
	_tokensCount: usize,
	_text: []const u8,
	languageIdCodec: ILanguageIdCodec,

	pub fn createEmpty(lineContent: []const u8, decoder: ILanguageIdCodec) LineTokens {
		const defaultMetadata = LineTokens.defaultTokenMetadata;

		const tokens = std.ArrayList(u32).init(std.heap.page_allocator);
		tokens.append(lineContent.length);
		tokens.append(defaultMetadata);

		return LineTokens{
			.tokens = tokens,
			.lineContent = lineContent,
			.decoder = decoder,
		};
	}

	pub fn createFromTextAndMetadata(data: []struct { text: []const u8, metadata: u32 }, decoder: ILanguageIdCodec) !LineTokens {
		var offset: usize = 0;
		var fullText: string = "";
		var tokens = std.ArrayList(u32).init(std.heap.page_allocator);
		for (data) |item| {
			const text = item.text;
			const metadata = item.metadata;
			try tokens.append(offset + text.len);
			try tokens.append(metadata);
			offset += text.len;
			fullText = fullText ++ text;
		}
		return LineTokens{
			._tokens = tokens,
			.lineContent = fullText,
			.decoder = decoder,
		};
	}

	pub fn convertToEndOffset(tokens: []u32, lineTextLength: usize) void {
		const tokenCount = (tokens.len >>> 1);
		const lastTokenIndex = tokenCount - 1;
		for (0..lastTokenIndex) |tokenIndex| {
			tokens[tokenIndex * 2] = tokens[(tokenIndex + 1) * 2];
		}
		tokens[lastTokenIndex * 2] = lineTextLength;
	}

	pub fn findIndexInTokensArray(tokens: []u32, desiredIndex: usize) usize {
		if (tokens.len <= 2) {
			return 0;
		}

		var low: usize = 0;
		var high: usize = (tokens.len >>> 1) - 1;

		while (low < high) {

			const mid = low + @divFloor(high - low, 2);
			const endOffset = tokens[mid * 2];

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

	pub fn defaultTokenMetadata() u32 {
		return (
		(FontStyle.None << MetadataConsts.FONT_STYLE_OFFSET)
		| (ColorId.DefaultForeground << MetadataConsts.FOREGROUND_OFFSET)
		| (ColorId.DefaultBackground << MetadataConsts.BACKGROUND_OFFSET)
	) >>> 0;
	}

	pub fn init(tokens: []u32, text: []const u8, decoder: ILanguageIdCodec) LineTokens {
		const tokensLength = tokens.len > 1 ? tokens[tokens.len - 2] : 0;
		if (tokensLength != text.len) {
			// onUnexpectedError(new Error('Token length and text length do not match!'));
		}
		return LineTokens{
			._tokens = tokens,
			._tokensCount = (tokens.len >>> 1),
			._text = text,
			.languageIdCodec = decoder,
		};
	}

	pub fn getTextLength(self: *LineTokens) usize {
		return self._text.len;
	}

	pub fn equals(self: *LineTokens, other: *LineTokens) bool {
		return self.slicedEquals(other, 0, self._tokensCount);
	}

	pub fn slicedEquals(self: *LineTokens, other: *LineTokens, sliceFromTokenIndex: usize, sliceTokenCount: usize) bool {
		if (self._text != other._text) {
			return false;
		}
		if (self._tokensCount != other._tokensCount) {
			return false;
		}
		const from = (sliceFromTokenIndex << 1);
		const to = from + (sliceTokenCount << 1);
		for (from..to) |i| {
			if (self._tokens[i] != other._tokens[i]) {
				return false;
			}
		}
		return true;
	}

	pub fn getLineContent(self: *LineTokens) []const u8 {
		return self._text;
	}

	pub fn getCount(self: *LineTokens) usize {
		return self._tokensCount;
	}

	pub fn getStartOffset(self: *LineTokens, tokenIndex: usize) usize {
		if (tokenIndex > 0) {
			return self._tokens[(tokenIndex - 1) * 2];
		}
		return 0;
	}

	pub fn getMetadata(self: *LineTokens, tokenIndex: usize) u32 {
		const metadata = self._tokens[(tokenIndex * 2) + 1];
		return metadata;
	}

	pub fn getLanguageId(self: *LineTokens, tokenIndex: usize) []const u8 {
		const metadata = self._tokens[(tokenIndex * 2) + 1];
		const languageId = TokenMetadata.getLanguageId(metadata);
		return self.languageIdCodec.decodeLanguageId(languageId);
	}

	pub fn getStandardTokenType(self: *LineTokens, tokenIndex: usize) StandardTokenType {
		const metadata = self._tokens[(tokenIndex * 2) + 1];
		return TokenMetadata.getTokenType(metadata);
	}

	pub fn getForeground(self: *LineTokens, tokenIndex: usize) ColorId {
		const metadata = self._tokens[(tokenIndex * 2) + 1];
		return TokenMetadata.getForeground(metadata);
	}

	pub fn getClassName(self: *LineTokens, tokenIndex: usize) []const u8 {
		const metadata = self._tokens[(tokenIndex * 2) + 1];
		return TokenMetadata.getClassNameFromMetadata(metadata);
	}

	pub fn getInlineStyle(self: *LineTokens, tokenIndex: usize, colorMap: []const []const u8) []const u8 {
		const metadata = self._tokens[(tokenIndex * 2) + 1];
		return TokenMetadata.getInlineStyleFromMetadata(metadata, colorMap);
	}

	pub fn getPresentation(self: *LineTokens, tokenIndex: usize) ITokenPresentation {
		const metadata = self._tokens[(tokenIndex * 2) + 1];
		return TokenMetadata.getPresentationFromMetadata(metadata);
	}

	pub fn getEndOffset(self: *LineTokens, tokenIndex: usize) usize {
		return self._tokens[tokenIndex * 2];
	}

	 // Find the token containing offset `offset`.
	 // @param offset The search offset
	 // @return The index of the token containing the offset.
	pub fn findTokenIndexAtOffset(self: *LineTokens, offset: usize) usize {
		return LineTokens.findIndexInTokensArray(self._tokens, offset);
	}

	pub fn inflate(self: *LineTokens) IViewLineTokens {
		return this;
	}

	pub fn sliceAndInflate(self: *LineTokens, startOffset: usize, endOffset: usize, deltaOffset: usize) IViewLineTokens {
		return SliceLineTokens.init(this, startOffset, endOffset, deltaOffset);
	}

	pub fn sliceZeroCopy(self: *LineTokens, range: OffsetRange) IViewLineTokens {
		return self.sliceAndInflate(range.start, range.endExclusive, 0);
	}

	 // @pure
	 // @param insertTokens Must be sorted by offset.
	pub fn withInserted(self: *LineTokens, insertTokens: []const { offset: usize, text: []const u8, tokenMetadata: u32 }) LineTokens {
		if (insertTokens.len == 0) {
			return self;
		}

		var nextOriginalTokenIdx: usize = 0;
		var nextInsertTokenIdx: usize = 0;
		var text: []const u8 = "";
		var newTokens = std.ArrayList(u32).init(std.heap.page_allocator);

		let originalEndOffset = 0;
		while (true) {
			const nextOriginalTokenEndOffset = nextOriginalTokenIdx < self._tokensCount ? self._tokens[nextOriginalTokenIdx * 2] : -1;
			const nextInsertToken = nextInsertTokenIdx < insertTokens.len ? insertTokens[nextInsertTokenIdx] : null;

			if (nextOriginalTokenEndOffset != -1 and (nextInsertToken == null or nextOriginalTokenEndOffset <= nextInsertToken.offset)) {
				// original token ends before next insert token
				text = text ++ self._text[originalEndOffset..nextOriginalTokenEndOffset];
				const metadata = self._tokens[(nextOriginalTokenIdx * 2) + 1];
				newTokens.append(text.length);
				newTokens.append(metadata);
				nextOriginalTokenIdx++;
				originalEndOffset = nextOriginalTokenEndOffset;

			} else if (nextInsertToken) {
				if (nextInsertToken.offset > originalEndOffset) {
					// insert token is in the middle of the next token.
					text = text ++ self._text[originalEndOffset..nextInsertToken.offset];
					const metadata = self._tokens[(nextOriginalTokenIdx * 2) + 1];
					newTokens.append(text.length);
					newTokens.append(metadata);
					originalEndOffset = nextInsertToken.offset;
				}

				text = text ++ nextInsertToken.text;
				newTokens.append(text.length);
				newTokens.append(nextInsertToken.tokenMetadata);
				nextInsertTokenIdx++;
			} else {
				break;
			}
		}

		return LineTokens.init(newTokens.items, text, self.languageIdCodec);
	}

	pub fn getTokensInRange(self: *LineTokens, range: OffsetRange) TokenArray {
		var builder = TokenArrayBuilder.init();

		const startTokenIndex = self.findTokenIndexAtOffset(range.start);
		const endTokenIndex = self.findTokenIndexAtOffset(range.endExclusive);

		for (startTokenIndex..endTokenIndex) |tokenIndex| {
			const tokenRange = OffsetRange{
				.start = self.getStartOffset(tokenIndex),
				.endExclusive = self.getEndOffset(tokenIndex),
			};
			const length = tokenRange.intersectionLength(range);
			if (length > 0) {
				builder.add(length, self.getMetadata(tokenIndex));
			}
		}

		return builder.build();
	}

	pub fn getTokenText(self: *LineTokens, tokenIndex: usize) []const u8 {
		const startOffset = self.getStartOffset(tokenIndex);
		const endOffset = self.getEndOffset(tokenIndex);
		const text = self._text[startOffset..endOffset];
		return text;
	}

	pub fn forEach(self: *LineTokens, callback: (tokenIndex: usize) void {
		const tokenCount = self.getCount();
		for (0..tokenCount) |tokenIndex| {
			callback(tokenIndex);
		}
	}

	pub fn toString(self: *LineTokens) []const u8 {
		var result: []const u8 = "";
		self.forEach((i) => {
			result = result ++ `[${self.getTokenText(i)}]{${self.getClassName(i)}}`;
		});
		return result;
	}
};

pub const SliceLineTokens = struct {

	_source: LineTokens,
	_startOffset: usize,
	_endOffset: usize,
	_deltaOffset: usize,

	_firstTokenIndex: usize,
	_tokensCount: usize,

	languageIdCodec: ILanguageIdCodec,

	pub fn init(source: LineTokens, startOffset: usize, endOffset: usize, deltaOffset: usize) SliceLineTokens {
		var tokensCount: usize = 0;
		for (0..source.getCount()) |i| {
			const tokenStartOffset = source.getStartOffset(i);
			if (tokenStartOffset >= endOffset) {
				break;
			}
			tokensCount += 1;
		}
		return SliceLineTokens{
			.source = source,
			.startOffset = startOffset,
			.endOffset = endOffset,
			.deltaOffset = deltaOffset,
			.firstTokenIndex = source.findTokenIndexAtOffset(startOffset),
			.tokensCount = tokensCount,
			.languageIdCodec = source.languageIdCodec,
		};
	}

	pub fn getMetadata(self: *SliceLineTokens, tokenIndex: usize) u32 {
		return this._source.getMetadata(this._firstTokenIndex + tokenIndex);
	}

	pub fn getLanguageId(self: *SliceLineTokens, tokenIndex: usize) string {
		return this._source.getLanguageId(this._firstTokenIndex + tokenIndex);
	}

	pub fn getLineContent(self: *SliceLineTokens) []const u8 {
		return this._source.getLineContent()[this._startOffset..this._endOffset];
	}

	pub fn equals(self: *SliceLineTokens, other: *SliceLineTokens) bool {
		if (other instanceof SliceLineTokens) {
			return (
				this._startOffset === other._startOffset
				&& this._endOffset === other._endOffset
				&& this._deltaOffset === other._deltaOffset
				&& this._source.slicedEquals(other._source, this._firstTokenIndex, this._tokensCount)
			);
		}
		return false;
	}

	pub fn getCount(self: *SliceLineTokens) usize {
		return this._tokensCount;
	}

	pub fn getStandardTokenType(self: *SliceLineTokens, tokenIndex: usize) StandardTokenType {
		return this._source.getStandardTokenType(this._firstTokenIndex + tokenIndex);
	}

	pub fn getForeground(self: *SliceLineTokens, tokenIndex: usize) ColorId {
		return this._source.getForeground(this._firstTokenIndex + tokenIndex);
	}

	pub fn getEndOffset(self: *SliceLineTokens, tokenIndex: usize) usize {
		const tokenEndOffset = this._source.getEndOffset(this._firstTokenIndex + tokenIndex);
		return Math.min(this._endOffset, tokenEndOffset) - this._startOffset + this._deltaOffset;
	}

	pub fn getClassName(self: *SliceLineTokens, tokenIndex: usize) []const u8 {
		return self._source.getClassName(self._firstTokenIndex + tokenIndex);
	}

	pub fn getInlineStyle(self: *SliceLineTokens, tokenIndex: usize, colorMap: []const []const u8) []const u8 {
		return self._source.getInlineStyle(self._firstTokenIndex + tokenIndex, colorMap);
	}

	pub fn getPresentation(self: *SliceLineTokens, tokenIndex: usize) ITokenPresentation {
		return self._source.getPresentation(self._firstTokenIndex + tokenIndex);
	}

	pub fn findTokenIndexAtOffset(self: *SliceLineTokens, offset: usize) usize {
		return self._source.findTokenIndexAtOffset(offset + self._startOffset - self._deltaOffset) - self._firstTokenIndex;
	}

	pub fn getTokenText(self: *SliceLineTokens, tokenIndex: usize) []const u8 {
		const adjustedTokenIndex = self._firstTokenIndex + tokenIndex;
		const tokenStartOffset = self._source.getStartOffset(adjustedTokenIndex);
		const tokenEndOffset = self._source.getEndOffset(adjustedTokenIndex);
		var text = self._source.getTokenText(adjustedTokenIndex).toOwnedSlice();
		if (tokenStartOffset < self._startOffset) {
			text = text ++ self._text[self._startOffset - tokenStartOffset..];
		}
		if (tokenEndOffset > self._endOffset) {
			text = text ++ self._text[0..text.len - (tokenEndOffset - self._endOffset)];
		}
		return text;
	}

	pub fn forEach(self: *SliceLineTokens, callback: (tokenIndex: usize) void {
		for (0..self.getCount()) |tokenIndex| {
			callback(tokenIndex);
		}
	}
};

pub fn getStandardTokenTypeAtPosition(model: TextModel, position: Position) ?StandardTokenType {
	const lineNumber = position.lineNumber - 1;
	if (!model.tokenization.isCheapToTokenize(lineNumber)) {
		return null;
	}
	model.tokenization.forceTokenization(lineNumber);
	const lineTokens = model.tokenization.getLineTokens(lineNumber);
	const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1) - 1;
	const tokenType = lineTokens.getStandardTokenType(tokenIndex);
	return tokenType;
}



 // This class represents a sequence of tokens.
 // Conceptually, each token has a length and a metadata number.
 // A token array might be used to annotate a string with metadata.
 // Use {@link TokenArrayBuilder} to efficiently create a token array.
 //
 // TODO: Make this class more efficient (e.g. by using a Int32Array).
pub const TokenArray = struct {
	pub fn fromLineTokens(lineTokens: LineTokens) TokenArray {
		var tokenInfo: ArrayList(TokenInfo) = ArrayList(TokenInfo).init(std.heap.page_allocator);
		for (0..lineTokens.getCount()) |i| {
			tokenInfo.append(TokenInfo{
				.length = lineTokens.getEndOffset(i) - lineTokens.getStartOffset(i),
				.metadata = lineTokens.getMetadata(i),
			});
		}
		return TokenArray.create(tokenInfo);
	}

	pub fn create(tokenInfo: ArrayList(TokenInfo)) TokenArray {
		return TokenArray{ ._tokenInfo = tokenInfo };
	}

	pub fn toLineTokens(self: *TokenArray, lineContent: string, decoder: ILanguageIdCodec) LineTokens {
		return createFromTextAndMetadata(this.map((r, t) => ({ text: r.substring(lineContent), metadata: t.metadata })), decoder);
	}

	pub fn forEach(self: *TokenArray, cb: (range: OffsetRange, tokenInfo: TokenInfo) => void) void {
		let lengthSum = 0;
		for (const tokenInfo of this._tokenInfo) {
			const range = new OffsetRange(lengthSum, lengthSum + tokenInfo.length);
			cb(range, tokenInfo);
			lengthSum += tokenInfo.length;
		}
	}

	pub fn map(self: *TokenArray, cb: (range: OffsetRange, tokenInfo: TokenInfo) => T) T[] {
		const result: T[] = [];
		let lengthSum = 0;
		for (const tokenInfo of this._tokenInfo) {
			const range = new OffsetRange(lengthSum, lengthSum + tokenInfo.length);
			result.push(cb(range, tokenInfo));
			lengthSum += tokenInfo.length;
		}
		return result;
	}

	pub fn slice(self: *TokenArray, range: OffsetRange) TokenArray {
		const result: TokenInfo[] = [];
		let lengthSum = 0;
		for (const tokenInfo of this._tokenInfo) {
			const tokenStart = lengthSum;
			const tokenEndEx = tokenStart + tokenInfo.length;
			if (tokenEndEx > range.start) {
				if (tokenStart >= range.endExclusive) {
					break;
				}

				const deltaBefore = Math.max(0, range.start - tokenStart);
				const deltaAfter = Math.max(0, tokenEndEx - range.endExclusive);

				result.push(new TokenInfo(tokenInfo.length - deltaBefore - deltaAfter, tokenInfo.metadata));
			}

			lengthSum += tokenInfo.length;
		}
		return TokenArray.create(result);
	}

	pub fn append(self: *TokenArray, other: TokenArray) TokenArray {
		const result: TokenInfo[] = this._tokenInfo.concat(other._tokenInfo);
		return TokenArray.create(result);
	}
};

pub const TokenInfo = struct {
	length: usize,
	metadata: u32,
};

 // TODO: Make this class more efficient (e.g. by using a Int32Array).
pub const TokenArrayBuilder = struct {
	_tokens: ArrayList(TokenInfo),

	pub fn add(self: *TokenArrayBuilder, length: usize, metadata: u32) void {
		self._tokens.append(TokenInfo{
			.length = length,
			.metadata = metadata,
		});
	}

	pub fn build(self: *TokenArrayBuilder) TokenArray {
		return TokenArray.create(self._tokens);
	}
};

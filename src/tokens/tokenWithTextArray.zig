const std = @import("std");
const ArrayList = std.ArrayList;
const OffsetRange = @import("../basics/offsetRange.zig").OffsetRange;
const LineTokens = @import("lineTokens.zig").LineTokens;

// This class represents a sequence of tokens.
// Conceptually, each token has a length and a metadata number.
// A token array might be used to annotate a string with metadata.
// Use {@link TokenWithTextArrayBuilder} to efficiently create a token array.
//
// TODO: Make this class more efficient (e.g. by using a Int32Array).
pub const TokenWithTextArray = struct {
	_tokenInfo: ArrayList(TokenWithTextInfo),

	pub fn fromLineTokens(lineTokens: LineTokens) !TokenWithTextArray {
		var tokenInfo: ArrayList(TokenWithTextInfo) = ArrayList(TokenWithTextInfo).init(std.heap.page_allocator);
		for (0..lineTokens.getCount()) |i| {
			try tokenInfo.append(TokenWithTextInfo{
				.text = lineTokens.getTokenText(i),
				.metadata = lineTokens.getMetadata(i),
			});
		}
		return TokenWithTextArray.create(tokenInfo.items);
	}

	pub fn create(tokenInfo: ArrayList(TokenWithTextInfo)) TokenWithTextArray {
		return TokenWithTextArray{ ._tokenInfo = tokenInfo };
	}


	pub fn toLineTokens(self: *TokenWithTextArray, decoder: ILanguageIdCodec) LineTokens {
		return LineTokens.createFromTextAndMetadata(self.map((_r, t) => ({ text: t.text, metadata: t.metadata })), decoder);
	}

	pub fn forEach(cb: (range: OffsetRange, tokenInfo: TokenWithTextInfo) => void): void {
		let lengthSum = 0;
		for (const tokenInfo of this._tokenInfo) {
			const range = new OffsetRange(lengthSum, lengthSum + tokenInfo.text.length);
			cb(range, tokenInfo);
			lengthSum += tokenInfo.text.length;
		}
	}

	pub fn map(comptime T: type, cb: (range: OffsetRange, tokenInfo: TokenWithTextInfo) => T): T[] {
		var result: ArrayList(T) = ArrayList(T).init(std.heap.page_allocator);
		let lengthSum = 0;
		for (const tokenInfo of this._tokenInfo) {
			const range = new OffsetRange(lengthSum, lengthSum + tokenInfo.text.length);
			result.append(cb(range, tokenInfo));
			lengthSum += tokenInfo.text.length;
		}
		return result;
	}

	pub fn slice(self: *TokenWithTextArray, range: OffsetRange) TokenWithTextArray {
		var result: ArrayList(TokenWithTextInfo) = ArrayList(TokenWithTextInfo).init(std.heap.page_allocator);
		let lengthSum = 0;
		for (const tokenInfo of this._tokenInfo) {
			const tokenStart = lengthSum;
			const tokenEndEx = tokenStart + tokenInfo.text.length;
			if (tokenEndEx > range.start) {
				if (tokenStart >= range.endExclusive) {
					break;
				}

				const deltaBefore = Math.max(0, range.start - tokenStart);
				const deltaAfter = Math.max(0, tokenEndEx - range.endExclusive);

				result.append(TokenWithTextInfo{
					.text = tokenInfo.text.slice(deltaBefore, tokenInfo.text.length - deltaAfter),
					.metadata = tokenInfo.metadata,
				});
			}

			lengthSum += tokenInfo.text.length;
		}
		return TokenWithTextArray.create(result);
	}

	pub fn append(self: *TokenWithTextArray, other: TokenWithTextArray) TokenWithTextArray {
		var result: ArrayList(TokenWithTextInfo) = ArrayList(TokenWithTextInfo).init(std.heap.page_allocator);
		result.appendSlice(self._tokenInfo);
		result.appendSlice(other._tokenInfo);
		return TokenWithTextArray.create(result);
	}
};

pub const TokenMetadata = u32;

pub const TokenWithTextInfo = struct {
	text: String,
	metadata: TokenMetadata,
}

// TODO: Make this class more efficient (e.g. by using a Int32Array).
pub const TokenWithTextArrayBuilder = struct {
	_tokens: []TokenWithTextInfo,

	pub fn add(self: *TokenWithTextArrayBuilder, text: String, metadata: TokenMetadata) void {
		self._tokens.append(TokenWithTextInfo{
			.text = text,
			.metadata = metadata,
		});
	}

	pub fn build(self: *TokenWithTextArrayBuilder) TokenWithTextArray {
		return TokenWithTextArray.create(self._tokens);
	}
}

const std = @import("std");
const ArrayList = std.ArrayList;
const IRange = @import("../basics/range.zig").IRange;
const Range = @import("../basics/range.zig").Range;
const LineTokens = @import("lineTokens.zig").LineTokens;
const SparseMultilineTokens = @import("sparseMultilineTokens.zig").SparseMultilineTokens;
const ILanguageIdCodec = @import("../languages.zig").ILanguageIdCodec;
const MetadataConsts = @import("../encodedTokenAttributes.zig").MetadataConsts;
const TextModel = @import("../model.zig").TextModel;

// Represents sparse tokens in a text model.
pub const SparseTokensStore = struct {

	_pieces: ArrayList(SparseMultilineTokens),
	_isComplete: bool,
	_languageIdCodec: ILanguageIdCodec,

	pub fn init(languageIdCodec: ILanguageIdCodec) SparseTokensStore {
		return SparseTokensStore{
			._pieces = ArrayList(SparseMultilineTokens).init(std.heap.page_allocator),
			._isComplete = false,
			._languageIdCodec = languageIdCodec,
		};
	}

	pub fn flush(self: *SparseTokensStore) void {
		self._pieces.clearAndFree();
		self._isComplete = false;
	}

	pub fn isEmpty(self: *SparseTokensStore) bool {
		return self._pieces.items.len == 0;
	}

	pub fn set(self: *SparseTokensStore, pieces: ?[]SparseMultilineTokens, isComplete: bool, textModel: ?TextModel) void {
		self._pieces.items = pieces orelse &[];
		self._isComplete = isComplete;

		if (textModel) {
			for (self._pieces.items) |p| {
				p.reportIfInvalid(textModel);
			}
		}
	}

	pub fn setPartial(self: *SparseTokensStore, _range: Range, pieces: []SparseMultilineTokens) Range {
		// console.log(`setPartial ${_range} ${pieces.map(p => p.toString()).join(', ')}`);

		var range = _range;
		if (pieces.len > 0) {
			const _firstRange = pieces[0].getRange();
			const _lastRange = pieces[pieces.len - 1].getRange();
			if (!_firstRange || !_lastRange) {
				return _range;
			}
			range = _range.plusRange(_firstRange).plusRange(_lastRange);
		}

		var insertPosition: ?{ index: usize } = null;
		for (0..self._pieces.items.len) |i| {
			const piece = self._pieces.items[i];
			if (piece.endLineNumber < range.startLineNumber) {
				// this piece is before the range
				continue;
			}

			if (piece.startLineNumber > range.endLineNumber) {
				// this piece is after the range, so mark the spot before this piece
				// as a good insertion position and stop looping
				insertPosition = insertPosition || { index: i };
				break;
			}

			// this piece might intersect with the range
			piece.removeTokens(range);

			if (piece.isEmpty()) {
				// remove the piece if it became empty
				self._pieces.orderedRemove(i);
				i -= 1;
				continue;
			}

			if (piece.endLineNumber < range.startLineNumber) {
				// after removal, this piece is before the range
				continue;
			}

			if (piece.startLineNumber > range.endLineNumber) {
				// after removal, this piece is after the range
				insertPosition = insertPosition || { index: i };
				continue;
			}

			// after removal, this piece contains the range
			const [a, b] = piece.split(range);
			if (a.isEmpty()) {
				// this piece is actually after the range
				insertPosition = insertPosition || { index: i };
				continue;
			}
			if (b.isEmpty()) {
				// this piece is actually before the range
				continue;
			}
			self._pieces.orderedRemove(i);
			self._pieces.append(a);
			self._pieces.append(b);
			i += 1;

			insertPosition = insertPosition || { index: i };
		}

		insertPosition = insertPosition orelse { index: self._pieces.items.len };

		if (pieces.len > 0) {
			self._pieces.insertSlice(insertPosition.index, pieces);
		}

		// console.log(`I HAVE ${this._pieces.length} pieces`);
		// console.log(`${this._pieces.map(p => p.toString()).join('\n')}`);

		return range;
	}

	pub fn isComplete(self: *SparseTokensStore) bool {
		return self._isComplete;
	}

	pub fn addSparseTokens(self: *SparseTokensStore, lineNumber: usize, aTokens: LineTokens) LineTokens {
		if (aTokens.getTextLength() === 0) {
			// Don't do anything for empty lines
			return aTokens;
		}

		const pieces = this._pieces;

		if (pieces.len == 0) {
			return aTokens;
		}

		const pieceIndex = self._findFirstPieceWithLine(pieces, lineNumber);
		const bTokens = pieces[pieceIndex].getLineTokens(lineNumber);

		if (!bTokens) {
			return aTokens;
		}

		const aLen = aTokens.getCount();
		const bLen = bTokens.getCount();

		let aIndex = 0;
		const result: number[] = [];
		let resultLen = 0;
		let lastEndOffset = 0;

		const emitToken = (endOffset: number, metadata: number) => {
			if (endOffset === lastEndOffset) {
				return;
			}
			lastEndOffset = endOffset;
			result[resultLen++] = endOffset;
			result[resultLen++] = metadata;
		};

		for (let bIndex = 0; bIndex < bLen; bIndex++) {
			// bTokens is not validated yet, but aTokens is. We want to make sure that the LineTokens we return
			// are valid, so we clamp the ranges to ensure that.
			const bStartCharacter = Math.min(bTokens.getStartCharacter(bIndex), aTokens.getTextLength());
			const bEndCharacter = Math.min(bTokens.getEndCharacter(bIndex), aTokens.getTextLength());
			const bMetadata = bTokens.getMetadata(bIndex);

			const bMask = (
				((bMetadata & MetadataConsts.SEMANTIC_USE_ITALIC) ? MetadataConsts.ITALIC_MASK : 0)
				| ((bMetadata & MetadataConsts.SEMANTIC_USE_BOLD) ? MetadataConsts.BOLD_MASK : 0)
				| ((bMetadata & MetadataConsts.SEMANTIC_USE_UNDERLINE) ? MetadataConsts.UNDERLINE_MASK : 0)
				| ((bMetadata & MetadataConsts.SEMANTIC_USE_STRIKETHROUGH) ? MetadataConsts.STRIKETHROUGH_MASK : 0)
				| ((bMetadata & MetadataConsts.SEMANTIC_USE_FOREGROUND) ? MetadataConsts.FOREGROUND_MASK : 0)
				| ((bMetadata & MetadataConsts.SEMANTIC_USE_BACKGROUND) ? MetadataConsts.BACKGROUND_MASK : 0)
			) >>> 0;
			const aMask = (~bMask) >>> 0;

			// push any token from `a` that is before `b`
			while (aIndex < aLen && aTokens.getEndOffset(aIndex) <= bStartCharacter) {
				emitToken(aTokens.getEndOffset(aIndex), aTokens.getMetadata(aIndex));
				aIndex++;
			}

			// push the token from `a` if it intersects the token from `b`
			if (aIndex < aLen && aTokens.getStartOffset(aIndex) < bStartCharacter) {
				emitToken(bStartCharacter, aTokens.getMetadata(aIndex));
			}

			// skip any tokens from `a` that are contained inside `b`
			while (aIndex < aLen && aTokens.getEndOffset(aIndex) < bEndCharacter) {
				emitToken(aTokens.getEndOffset(aIndex), (aTokens.getMetadata(aIndex) & aMask) | (bMetadata & bMask));
				aIndex++;
			}

			if (aIndex < aLen) {
				emitToken(bEndCharacter, (aTokens.getMetadata(aIndex) & aMask) | (bMetadata & bMask));
				if (aTokens.getEndOffset(aIndex) === bEndCharacter) {
					// `a` ends exactly at the same spot as `b`!
					aIndex++;
				}
			} else {
				const aMergeIndex = Math.min(Math.max(0, aIndex - 1), aLen - 1);

				// push the token from `b`
				emitToken(bEndCharacter, (aTokens.getMetadata(aMergeIndex) & aMask) | (bMetadata & bMask));
			}
		}

		// push the remaining tokens from `a`
		while (aIndex < aLen) {
			emitToken(aTokens.getEndOffset(aIndex), aTokens.getMetadata(aIndex));
			aIndex++;
		}

		return LineTokens.init(new Uint32Array(result), aTokens.getLineContent(), this._languageIdCodec);
	}

	fn _findFirstPieceWithLine(self: *SparseTokensStore, pieces: []SparseMultilineTokens, lineNumber: usize) usize {
		var low: usize = 0;
		var high: usize = pieces.len - 1;

		while (low < high) {
			const mid = low + @divFloor(high - low, 2);

			if (pieces[mid].endLineNumber < lineNumber) {
				low = mid + 1;
			} else if (pieces[mid].startLineNumber > lineNumber) {
				high = mid - 1;
			} else {
				while (mid > low && pieces[mid - 1].startLineNumber <= lineNumber && lineNumber <= pieces[mid - 1].endLineNumber) {
					mid--;
				}
				return mid;
			}
		}

		return low;
	}

	pub fn acceptEdit(self: *SparseTokensStore, range: IRange, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {
		for (self._pieces.items) |piece| {
			piece.acceptEdit(range, eolCount, firstLineLength, lastLineLength, firstCharCode);
		}
	}
};

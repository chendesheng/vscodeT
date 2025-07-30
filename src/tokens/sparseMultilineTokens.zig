const std = @import("std");
const ArrayList = std.ArrayList;
const Range = @import("../basics/range.zig").Range;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const TextModel = @import("../textModel.zig").TextModel;

// Represents sparse tokens over a contiguous range of lines.
pub const SparseMultilineTokens = struct {
	_startLineNumber: usize,
	_endLineNumber: usize,
	_tokens: SparseMultilineTokensStorage,


	pub fn create(startLineNumber: usize, tokens: []u32) SparseMultilineTokens {
		return SparseMultilineTokens{
			.startLineNumber = startLineNumber,
			.endLineNumber = startLineNumber + tokens.len,
			.tokens = SparseMultilineTokensStorage.init(tokens),
		};
	}

	 // (Inclusive) start line number for these tokens.
	pub fn getStartLineNumber(self: *SparseMultilineTokens) usize {
		return this._startLineNumber;
	}

	 // (Inclusive) end line number for these tokens.
	pub fn endLineNumber(self: *SparseMultilineTokens) usize {
		return this._endLineNumber;
	}

	pub fn init(startLineNumber: usize, tokens: SparseMultilineTokensStorage) SparseMultilineTokens {
		return SparseMultilineTokens{
			.startLineNumber = startLineNumber,
			.tokens = tokens,
			.endLineNumber = startLineNumber + tokens.getMaxDeltaLine(),
		};
	}

	pub fn toString(self: *SparseMultilineTokens) string {
		return self._tokens.toString(self._startLineNumber);
	}

	fn _updateEndLineNumber(self: *SparseMultilineTokens) void {
		self._endLineNumber = self._startLineNumber + self._tokens.getMaxDeltaLine();
	}

	pub fn isEmpty(self: *SparseMultilineTokens) bool {
		return self._tokens.isEmpty();
	}

	pub fn getLineTokens(self: *SparseMultilineTokens, lineNumber: usize) ?SparseLineTokens {
		if (self._startLineNumber <= lineNumber and lineNumber <= self._endLineNumber) {
			return self._tokens.getLineTokens(lineNumber - self._startLineNumber);
		}
		return null;
	}

	pub fn getRange(self: *SparseMultilineTokens) ?Range {
		const deltaRange = self._tokens.getRange();
		if (!deltaRange) {
			return deltaRange;
		}
		return Range{
			.startLineNumber = self._startLineNumber + deltaRange.startLineNumber,
			.startColumn = deltaRange.startColumn,
			.endLineNumber = self._startLineNumber + deltaRange.endLineNumber,
			.endColumn = deltaRange.endColumn,
		};
	}

	pub fn removeTokens(self: *SparseMultilineTokens, range: Range) void {
		const startLineIndex = range.startLineNumber - self._startLineNumber;
		const endLineIndex = range.endLineNumber - self._startLineNumber;

		self._startLineNumber += self._tokens.removeTokens(startLineIndex, range.startColumn - 1, endLineIndex, range.endColumn - 1);
		self._updateEndLineNumber();
	}

	pub fn split(self: *SparseMultilineTokens, range: Range) [2]SparseMultilineTokens {
		// split tokens to two:
		// a) all the tokens before `range`
		// b) all the tokens after `range`
		const startLineIndex = range.startLineNumber - self._startLineNumber;
		const endLineIndex = range.endLineNumber - self._startLineNumber;

		const [a, b, bDeltaLine] = self._tokens.split(startLineIndex, range.startColumn - 1, endLineIndex, range.endColumn - 1);
		return [_]SparseMultilineTokens{
			.startLineNumber = self._startLineNumber,
			.tokens = a,
		}, SparseMultilineTokens{
			.startLineNumber = self._startLineNumber + bDeltaLine,
			.tokens = b,
		};
	}

	pub fn applyEdit(self: *SparseMultilineTokens, range: Range, text: []const u8) void {
		const [eolCount, firstLineLength, lastLineLength] = countEOL(text);
		self.acceptEdit(range, eolCount, firstLineLength, lastLineLength, text.len > 0 ? text.codePointAt(0) : 0);
	}

	pub fn acceptEdit(self: *SparseMultilineTokens, range: Range, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {
		self._acceptDeleteRange(range);
		self._acceptInsertText(Position{
			.lineNumber = range.startLineNumber,
			.column = range.startColumn,
		}, eolCount, firstLineLength, lastLineLength, firstCharCode);
		self._updateEndLineNumber();
	}

	fn _acceptDeleteRange(self: *SparseMultilineTokens, range: Range) void {
		if (range.startLineNumber === range.endLineNumber && range.startColumn === range.endColumn) {
			// Nothing to delete
			return;
		}

		const firstLineIndex = range.startLineNumber - self._startLineNumber;
		const lastLineIndex = range.endLineNumber - self._startLineNumber;

		if (lastLineIndex < 0) {
			// this deletion occurs entirely before this block, so we only need to adjust line numbers
			const deletedLinesCount = lastLineIndex - firstLineIndex;
			self._startLineNumber -= deletedLinesCount;
			return;
		}

		const tokenMaxDeltaLine = self._tokens.getMaxDeltaLine();

		if (firstLineIndex >= tokenMaxDeltaLine + 1) {
			// this deletion occurs entirely after this block, so there is nothing to do
			return;
		}

		if (firstLineIndex < 0 && lastLineIndex >= tokenMaxDeltaLine + 1) {
			// this deletion completely encompasses this block
			self._startLineNumber = 0;
			self._tokens.clear();
			return;
		}

		if (firstLineIndex < 0) {
			const deletedBefore = -firstLineIndex;
			self._startLineNumber -= deletedBefore;

			self._tokens.acceptDeleteRange(range.startColumn - 1, 0, 0, lastLineIndex, range.endColumn - 1);
		} else {
			self._tokens.acceptDeleteRange(0, firstLineIndex, range.startColumn - 1, lastLineIndex, range.endColumn - 1);
		}
	}

	fn _acceptInsertText(self: *SparseMultilineTokens, position: Position, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {

		if (eolCount === 0 && firstLineLength === 0) {
			// Nothing to insert
			return;
		}

		const lineIndex = position.lineNumber - self._startLineNumber;

		if (lineIndex < 0) {
			// this insertion occurs before this block, so we only need to adjust line numbers
			self._startLineNumber += eolCount;
			return;
		}

		const tokenMaxDeltaLine = self._tokens.getMaxDeltaLine();

		if (lineIndex >= tokenMaxDeltaLine + 1) {
			// this insertion occurs after this block, so there is nothing to do
			return;
		}

		self._tokens.acceptInsertText(lineIndex, position.column - 1, eolCount, firstLineLength, lastLineLength, firstCharCode);
	}

	pub fn reportIfInvalid(self: *SparseMultilineTokens, model: TextModel) void {
		self._tokens.reportIfInvalid(model, self._startLineNumber);
	}
};

pub const SparseMultilineTokensStorage = struct {
	 // The encoding of tokens is:
	 //  4*i    deltaLine (from `startLineNumber`)
	 //  4*i+1  startCharacter (from the line start)
	 //  4*i+2  endCharacter (from the line start)
	 //  4*i+3  metadata
	_tokens: ArrayList(u32),
	_tokenCount: usize,

	pub fn init(tokens: ArrayList(u32)) SparseMultilineTokensStorage {
		return SparseMultilineTokensStorage{
			._tokens = tokens,
			._tokenCount = tokens.len / 4,
		};
	}

	pub fn toString(self: *SparseMultilineTokensStorage, startLineNumber: usize) string {
		var pieces: []string = ArrayList(string).init(std.heap.page_allocator);
		for (0..self._tokenCount) |i| {
			pieces.append(fmt.bufPrint(std.ArrayList(u8).init(std.heap.page_allocator), "({d},{d}-{d})", .{ self._getDeltaLine(i) + startLineNumber, self._getStartCharacter(i), self._getEndCharacter(i) }) catch unreachable);
		}
		return fmt.bufPrint(std.ArrayList(u8).init(std.heap.page_allocator), "[{s}]", .{std.mem.join(",", pieces.items) catch unreachable});
	}

	pub fn getMaxDeltaLine(self: *SparseMultilineTokensStorage) usize {
		const tokenCount = self._getTokenCount();
		if (tokenCount == 0) {
			return -1;
		}
		return self._getDeltaLine(tokenCount - 1);
	}

	pub fn getRange(self: *SparseMultilineTokensStorage) ?Range {
		const tokenCount = self._getTokenCount();
		if (tokenCount == 0) {
			return null;
		}
		const startChar = self._getStartCharacter(0);
		const maxDeltaLine = self._getDeltaLine(tokenCount - 1);
		const endChar = self._getEndCharacter(tokenCount - 1);
		return Range{
			.startLineNumber = 0,
			.startColumn = startChar + 1,
			.endLineNumber = maxDeltaLine,
			.endColumn = endChar + 1,
		};
	}

	fn getTokenCount(self: *SparseMultilineTokensStorage) usize {
		return self._tokenCount;
	}
	
	fn getDeltaLine(self: *SparseMultilineTokensStorage, tokenIndex: usize) usize {
		return self._tokens.items[4 * tokenIndex];
	}

	pub fn getStartCharacter(self: *SparseMultilineTokensStorage, tokenIndex: usize) usize {
		return self._tokens.items[4 * tokenIndex + 1];
	}

	fn getEndCharacter(self: *SparseMultilineTokensStorage, tokenIndex: usize) usize {
		return self._tokens.items[4 * tokenIndex + 2];
	}

	pub fn isEmpty(self: *SparseMultilineTokensStorage) bool {
		return (self._getTokenCount() == 0);
	}

	pub fn getLineTokens(self: *SparseMultilineTokensStorage, deltaLine: usize) ?SparseLineTokens {
		var low = 0;
		var high = self._getTokenCount() - 1;

		while (low < high) {
			const mid = low + @divFloor(high - low, 2);
			const midDeltaLine = self._getDeltaLine(mid);

			if (midDeltaLine < deltaLine) {
				low = mid + 1;
			} else if (midDeltaLine > deltaLine) {
				high = mid - 1;
			} else {
				var min = mid;
				while (min > low and self._getDeltaLine(min - 1) == deltaLine) {
					min-=1;
				}
				var max = mid;
				while (max < high and self._getDeltaLine(max + 1) == deltaLine) {
					max += 1;
				}
				return SparseLineTokens.init(self._tokens.items[ 4 * min.. 4 * max + 4 ]);
			}
		}

		if (self._getDeltaLine(low) == deltaLine) {
			return SparseLineTokens.init(self._tokens.items[ 4 * low.. 4 * low + 4 ]);
		}

		return null;
	}

	pub fn clear(self: *SparseMultilineTokensStorage) void {
		self._tokenCount = 0;
	}

	pub fn removeTokens(self: *SparseMultilineTokensStorage, startDeltaLine: usize, startChar: usize, endDeltaLine: usize, endChar: usize) usize {
		const tokens = self._tokens;
		const tokenCount = self._tokenCount;
		var newTokenCount: usize = 0;
		var hasDeletedTokens = false;
		var firstDeltaLine: usize = 0;
		for (0..tokenCount) |i| {
			const srcOffset = 4 * i;
			const tokenDeltaLine = tokens[srcOffset];
			const tokenStartCharacter = tokens[srcOffset + 1];
			const tokenEndCharacter = tokens[srcOffset + 2];
			const tokenMetadata = tokens[srcOffset + 3];

			if (
				(tokenDeltaLine > startDeltaLine or (tokenDeltaLine == startDeltaLine and tokenEndCharacter >= startChar))
				and (tokenDeltaLine < endDeltaLine or (tokenDeltaLine == endDeltaLine and tokenStartCharacter <= endChar))
			) {
				hasDeletedTokens = true;
			} else {
				if (newTokenCount == 0) {
					firstDeltaLine = tokenDeltaLine;
				}
				if (hasDeletedTokens) {
					// must move the token to the left
					const destOffset = 4 * newTokenCount;
					tokens[destOffset] = tokenDeltaLine - firstDeltaLine;
					tokens[destOffset + 1] = tokenStartCharacter;
					tokens[destOffset + 2] = tokenEndCharacter;
					tokens[destOffset + 3] = tokenMetadata;
				}
				newTokenCount++;
			}
		}

		self._tokenCount = newTokenCount;

		return firstDeltaLine;
	}

	pub fn split(self: *SparseMultilineTokensStorage, startDeltaLine: usize, startChar: usize, endDeltaLine: usize, endChar: usize) [SparseMultilineTokensStorage, SparseMultilineTokensStorage, usize] {
		const tokens = self._tokens;
		const tokenCount = self._tokenCount;
		var aTokens: []u32 = &[];
		var bTokens: []u32 = &[];
		var destTokens: []u32 = aTokens;
		var destOffset: usize = 0;
		var destFirstDeltaLine: usize = 0;
		for (0..tokenCount) |i| {
			const srcOffset = 4 * i;
			const tokenDeltaLine = tokens[srcOffset];
			const tokenStartCharacter = tokens[srcOffset + 1]; 
			const tokenEndCharacter = tokens[srcOffset + 2]; 
			const tokenMetadata = tokens[srcOffset + 3]; 

			if ((tokenDeltaLine > startDeltaLine or (tokenDeltaLine === startDeltaLine and tokenEndCharacter >= startChar))) {
				if ((tokenDeltaLine < endDeltaLine or (tokenDeltaLine === endDeltaLine and tokenStartCharacter <= endChar))) {
					// this token is touching the range
					continue;
				} else {
					// this token is after the range
					if (destTokens != bTokens) {
						// this token is the first token after the range
						destTokens = bTokens;
						destOffset = 0;
						destFirstDeltaLine = tokenDeltaLine;
					}
				}
			}

			destTokens[destOffset++] = tokenDeltaLine - destFirstDeltaLine;
			destTokens[destOffset++] = tokenStartCharacter;
			destTokens[destOffset++] = tokenEndCharacter;
			destTokens[destOffset++] = tokenMetadata;
		}

		return [SparseMultilineTokensStorage.init(aTokens), SparseMultilineTokensStorage.init(bTokens), destFirstDeltaLine];
	}

	pub fn acceptDeleteRange(self: *SparseMultilineTokensStorage, horizontalShiftForFirstLineTokens: usize, startDeltaLine: usize, startCharacter: usize, endDeltaLine: usize, endCharacter: usize) void {
		// This is a bit complex, here are the cases I used to think about this:
		//
		// 1. The token starts before the deletion range
		// 1a. The token is completely before the deletion range
		//               -----------
		//                          xxxxxxxxxxx
		// 1b. The token starts before, the deletion range ends after the token
		//               -----------
		//                      xxxxxxxxxxx
		// 1c. The token starts before, the deletion range ends precisely with the token
		//               ---------------
		//                      xxxxxxxx
		// 1d. The token starts before, the deletion range is inside the token
		//               ---------------
		//                    xxxxx
		//
		// 2. The token starts at the same position with the deletion range
		// 2a. The token starts at the same position, and ends inside the deletion range
		//               -------
		//               xxxxxxxxxxx
		// 2b. The token starts at the same position, and ends at the same position as the deletion range
		//               ----------
		//               xxxxxxxxxx
		// 2c. The token starts at the same position, and ends after the deletion range
		//               -------------
		//               xxxxxxx
		//
		// 3. The token starts inside the deletion range
		// 3a. The token is inside the deletion range
		//                -------
		//             xxxxxxxxxxxxx
		// 3b. The token starts inside the deletion range, and ends at the same position as the deletion range
		//                ----------
		//             xxxxxxxxxxxxx
		// 3c. The token starts inside the deletion range, and ends after the deletion range
		//                ------------
		//             xxxxxxxxxxx
		//
		// 4. The token starts after the deletion range
		//                  -----------
		//          xxxxxxxx
		//
		const tokens = self._tokens;
		const tokenCount = self._tokenCount;
		const deletedLineCount = (endDeltaLine - startDeltaLine);
		var newTokenCount: usize = 0;
		var hasDeletedTokens = false;
		for (0..tokenCount) |i| {
			const srcOffset = 4 * i;
			var tokenDeltaLine = tokens[srcOffset];
			var tokenStartCharacter = tokens[srcOffset + 1];
			var tokenEndCharacter = tokens[srcOffset + 2];
			const tokenMetadata = tokens[srcOffset + 3];

			if (tokenDeltaLine < startDeltaLine or (tokenDeltaLine === startDeltaLine and tokenEndCharacter <= startCharacter)) {
				// 1a. The token is completely before the deletion range
				// => nothing to do
				newTokenCount++;
				continue;
			} else if (tokenDeltaLine === startDeltaLine && tokenStartCharacter < startCharacter) {
				// 1b, 1c, 1d
				// => the token survives, but it needs to shrink
				if (tokenDeltaLine === endDeltaLine and tokenEndCharacter > endCharacter) {
					// 1d. The token starts before, the deletion range is inside the token
					// => the token shrinks by the deletion character count
					tokenEndCharacter -= (endCharacter - startCharacter);
				} else {
					// 1b. The token starts before, the deletion range ends after the token
					// 1c. The token starts before, the deletion range ends precisely with the token
					// => the token shrinks its ending to the deletion start
					tokenEndCharacter = startCharacter;
				}
			} else if (tokenDeltaLine === startDeltaLine and tokenStartCharacter === startCharacter) {
				// 2a, 2b, 2c
				if (tokenDeltaLine === endDeltaLine and tokenEndCharacter > endCharacter) {
					// 2c. The token starts at the same position, and ends after the deletion range
					// => the token shrinks by the deletion character count
					tokenEndCharacter -= (endCharacter - startCharacter);
				} else {
					// 2a. The token starts at the same position, and ends inside the deletion range
					// 2b. The token starts at the same position, and ends at the same position as the deletion range
					// => the token is deleted
					hasDeletedTokens = true;
					continue;
				}
			} else if (tokenDeltaLine < endDeltaLine or (tokenDeltaLine === endDeltaLine and tokenStartCharacter < endCharacter)) {
				// 3a, 3b, 3c
				if (tokenDeltaLine === endDeltaLine and tokenEndCharacter > endCharacter) {
					// 3c. The token starts inside the deletion range, and ends after the deletion range
					// => the token moves to continue right after the deletion
					tokenDeltaLine = startDeltaLine;
					tokenStartCharacter = startCharacter;
					tokenEndCharacter = tokenStartCharacter + (tokenEndCharacter - endCharacter);
				} else {
					// 3a. The token is inside the deletion range
					// 3b. The token starts inside the deletion range, and ends at the same position as the deletion range
					// => the token is deleted
					hasDeletedTokens = true;
					continue;
				}
			} else if (tokenDeltaLine > endDeltaLine) {
				// 4. (partial) The token starts after the deletion range, on a line below...
				if (deletedLineCount === 0 && !hasDeletedTokens) {
					// early stop, there is no need to walk all the tokens and do nothing...
					newTokenCount = tokenCount;
					break;
				}
				tokenDeltaLine -= deletedLineCount;
			} else if (tokenDeltaLine === endDeltaLine && tokenStartCharacter >= endCharacter) {
				// 4. (continued) The token starts after the deletion range, on the last line where a deletion occurs
				if (horizontalShiftForFirstLineTokens && tokenDeltaLine === 0) {
					tokenStartCharacter += horizontalShiftForFirstLineTokens;
					tokenEndCharacter += horizontalShiftForFirstLineTokens;
				}
				tokenDeltaLine -= deletedLineCount;
				tokenStartCharacter -= (endCharacter - startCharacter);
				tokenEndCharacter -= (endCharacter - startCharacter);
			} else {
				throw new Error(`Not possible!`);
			}

			const destOffset = 4 * newTokenCount;
			tokens[destOffset] = tokenDeltaLine;
			tokens[destOffset + 1] = tokenStartCharacter;
			tokens[destOffset + 2] = tokenEndCharacter;
			tokens[destOffset + 3] = tokenMetadata;
			newTokenCount++;
		}

		self._tokenCount = newTokenCount;
	}

	pub fn acceptInsertText(self: *SparseMultilineTokensStorage, deltaLine: usize, character: usize, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: usize) void {
		// Here are the cases I used to think about this:
		//
		// 1. The token is completely before the insertion point
		//            -----------   |
		// 2. The token ends precisely at the insertion point
		//            -----------|
		// 3. The token contains the insertion point
		//            -----|------
		// 4. The token starts precisely at the insertion point
		//            |-----------
		// 5. The token is completely after the insertion point
		//            |   -----------
		//
		const isInsertingPreciselyOneWordCharacter = (
			eolCount === 0
			&& firstLineLength === 1
			&& (
				(firstCharCode >= CharCode.Digit0 && firstCharCode <= CharCode.Digit9)
				|| (firstCharCode >= CharCode.A && firstCharCode <= CharCode.Z)
				|| (firstCharCode >= CharCode.a && firstCharCode <= CharCode.z)
			)
		);
		const tokens = self._tokens;
		const tokenCount = self._tokenCount;
		for (0..tokenCount) |i| {
			const offset = 4 * i;
			let tokenDeltaLine = tokens[offset];
			let tokenStartCharacter = tokens[offset + 1];
			let tokenEndCharacter = tokens[offset + 2];

			if (tokenDeltaLine < deltaLine or (tokenDeltaLine === deltaLine and tokenEndCharacter < character)) {
				// 1. The token is completely before the insertion point
				// => nothing to do
				continue;
			} else if (tokenDeltaLine === deltaLine and tokenEndCharacter === character) {
				// 2. The token ends precisely at the insertion point
				// => expand the end character only if inserting precisely one character that is a word character
				if (isInsertingPreciselyOneWordCharacter) {
					tokenEndCharacter += 1;
				} else {
					continue;
				}
			} else if (tokenDeltaLine === deltaLine and tokenStartCharacter < character and character < tokenEndCharacter) {
				// 3. The token contains the insertion point
				if (eolCount === 0) {
					// => just expand the end character
					tokenEndCharacter += firstLineLength;
				} else {
					// => cut off the token
					tokenEndCharacter = character;
				}
			} else {
				// 4. or 5.
				if (tokenDeltaLine == deltaLine and tokenStartCharacter == character) {
					// 4. The token starts precisely at the insertion point
					// => grow the token (by keeping its start constant) only if inserting precisely one character that is a word character
					// => otherwise behave as in case 5.
					if (isInsertingPreciselyOneWordCharacter) {
						continue;
					}
				}
				// => the token must move and keep its size constant
				if (tokenDeltaLine == deltaLine) {
					tokenDeltaLine += eolCount;
					// this token is on the line where the insertion is taking place
					if (eolCount === 0) {
						tokenStartCharacter += firstLineLength;
						tokenEndCharacter += firstLineLength;
					} else {
						const tokenLength = tokenEndCharacter - tokenStartCharacter;
						tokenStartCharacter = lastLineLength + (tokenStartCharacter - character);
						tokenEndCharacter = tokenStartCharacter + tokenLength;
					}
				} else {
					tokenDeltaLine += eolCount;
				}
			}

			tokens[offset] = tokenDeltaLine;
			tokens[offset + 1] = tokenStartCharacter;
			tokens[offset + 2] = tokenEndCharacter;
		}
	}

	pub fn reportIfInvalid(self: *SparseMultilineTokensStorage, model: TextModel, startLineNumber: usize) void {
		for (0..self._tokenCount) |i| {
			const lineNumber = self._getDeltaLine(i) + startLineNumber;

			if (lineNumber > model.getLineCount()) {
				RateLimiter.runIfNotLimited(() => {
					console.error('Invalid Semantic Tokens Data From Extension: lineNumber > model.getLineCount()');
				});
			}

			if (this._getEndCharacter(i) > model.getLineLength(lineNumber)) {
				RateLimiter.runIfNotLimited(() => {
					console.error('Invalid Semantic Tokens Data From Extension: end character > model.getLineLength(lineNumber)');
				});
			}
		}
	}
};

pub const SparseLineTokens = struct {
	_tokens: []u32,

	pub fn init(tokens: []u32) SparseLineTokens {
		return SparseLineTokens{ ._tokens = tokens };
	}

	pub fn getCount(self: *SparseLineTokens) usize {
		return self._tokens.len / 4;
	}

	pub fn getStartCharacter(self: *SparseLineTokens, tokenIndex: usize) usize {
		return self._tokens[4 * tokenIndex + 1];
	}

	pub fn getEndCharacter(self: *SparseLineTokens, tokenIndex: usize) usize {
		return this._tokens[4 * tokenIndex + 2];
	}

	pub fn getMetadata(self: *SparseLineTokens, tokenIndex: usize) usize {
		return this._tokens[4 * tokenIndex + 3];
	}
};

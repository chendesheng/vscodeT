const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const Position = @import("../basics/position.zig").Position;

// Represents contiguous tokens over a contiguous range of lines.
pub const ContiguousMultilineTokens = struct {
	 // The start line number for this block of tokens.
	_startLineNumber: usize,
	 // The tokens are stored in a binary format. There is an element for each line,
	 // so `tokens[index]` contains all tokens on line `startLineNumber + index`.
	 //
	 // On a specific line, each token occupies two array indices. For token i:
	 //  - at offset 2*i => endOffset
	 //  - at offset 2*i + 1 => metadata
	_tokens: ArrayList(u32),

	pub fn deserialize(buff: []const u8, offset: usize, result: []ContiguousMultilineTokens) usize {
		const view32 = std.mem.bytesAsValue(u32, buff);
		const startLineNumber = view32.get(offset); offset += 4;
		const count = view32.get(offset); offset += 4;
		var tokens: ArrayList(u32) = ArrayList(u32).init(std.heap.page_allocator);
		for (0..count) |i| {
			const byteCount = view32.get(offset); offset += 4;
			tokens.append(view32.subarray(offset / 4, offset / 4 + byteCount / 4));
			offset += byteCount;
		}
		result.append(ContiguousMultilineTokens{
			.startLineNumber = startLineNumber,
			.tokens = tokens,
		});
		return offset;
	}



	 // (Inclusive) start line number for these tokens.
	pub fn getStartLineNumber(self: *ContiguousMultilineTokens) usize {
		return this._startLineNumber;
	}

	 // (Inclusive) end line number for these tokens.
	pub fn getEndLineNumber(self: *ContiguousMultilineTokens) usize {
		return this._startLineNumber + this._tokens.length - 1;
	}

	pub fn getLineRange(self: *ContiguousMultilineTokens) LineRange {
		return LineRange.init(this._startLineNumber, this._startLineNumber + this._tokens.length);
	}

	 // @see {@link _tokens}
	pub fn getLineTokens(self: *ContiguousMultilineTokens, lineNumber: usize) ?[]u32 {
		return this._tokens[lineNumber - this._startLineNumber];
	}

	pub fn appendLineTokens(self: *ContiguousMultilineTokens, lineTokens: []u32) !void {
		try self._tokens.append(lineTokens);
	}

	pub fn serializeSize(self: *ContiguousMultilineTokens) !usize {
		var result: usize = 0;
		result += 4; // 4 bytes for the start line number
		result += 4; // 4 bytes for the line count
		for (0..self._tokens.items.len) |i| {
			const lineTokens = self._tokens.items[i];
			if (lineTokens.len == 0) {
				// throw new Error("Not supported!");
				return error.NotSupported;
			}
			result += 4; // 4 bytes for the byte count
			result += lineTokens.byteLength;
		}
		return result;
	}

	pub fn serialize(self: *ContiguousMultilineTokens, destination: []u8, offset: usize) usize {
		writeUInt32BE(destination, this._startLineNumber, offset); offset += 4;
		writeUInt32BE(destination, this._tokens.length, offset); offset += 4;
		for (let i = 0; i < this._tokens.length; i++) {
			const lineTokens = this._tokens[i];
			if (!(lineTokens instanceof Uint32Array)) {
				throw new Error(`Not supported!`);
			}
			writeUInt32BE(destination, lineTokens.byteLength, offset); offset += 4;
			destination.set(new Uint8Array(lineTokens.buffer), offset); offset += lineTokens.byteLength;
		}
		return offset;
	}

	pub fn applyEdit(self: *ContiguousMultilineTokens, range: Range, text: []const u8) void {
		const res = countEOL(text);
		const eolCount = res.eolCount;
		const firstLineLength = res.firstLineLength;
		self._acceptDeleteRange(range);
		self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), eolCount, firstLineLength);
	}

	pub fn _acceptDeleteRange(self: *ContiguousMultilineTokens, range: Range) void {
		if (range.startLineNumber == range.endLineNumber and range.startColumn == range.endColumn) {
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

		if (firstLineIndex >= self._tokens.items.len) {
			// this deletion occurs entirely after this block, so there is nothing to do
			return;
		}

		if (firstLineIndex < 0 and lastLineIndex >= self._tokens.items.len) {
			// this deletion completely encompasses this block
			self._startLineNumber = 0;
			self._tokens.resize(0);
			return;
		}

		if (firstLineIndex == lastLineIndex) {
			// a delete on a single line
			self._tokens[firstLineIndex] = ContiguousTokensEditing.delete(self._tokens[firstLineIndex], range.startColumn - 1, range.endColumn - 1);
			return;
		}

		if (firstLineIndex >= 0) {
			// The first line survives
			self._tokens[firstLineIndex] = ContiguousTokensEditing.deleteEnding(self._tokens[firstLineIndex], range.startColumn - 1);

			if (lastLineIndex < this._tokens.length) {
				// The last line survives
				const lastLineTokens = ContiguousTokensEditing.deleteBeginning(self._tokens[lastLineIndex], range.endColumn - 1);

				// Take remaining text on last line and append it to remaining text on first line
				self._tokens[firstLineIndex] = ContiguousTokensEditing.append(self._tokens[firstLineIndex], lastLineTokens);

				// Delete middle lines
				self._tokens.splice(firstLineIndex + 1, lastLineIndex - firstLineIndex);
			} else {
				// The last line does not survive

				// Take remaining text on last line and append it to remaining text on first line
				self._tokens[firstLineIndex] = ContiguousTokensEditing.append(self._tokens[firstLineIndex], null);

				// Delete lines
				self._tokens = self._tokens.slice(0, firstLineIndex + 1);
			}
		} else {
			// The first line does not survive

			const deletedBefore = -firstLineIndex;
			self._startLineNumber -= deletedBefore;

			// Remove beginning from last line
			self._tokens[lastLineIndex] = ContiguousTokensEditing.deleteBeginning(self._tokens[lastLineIndex], range.endColumn - 1);

			// Delete lines
			self._tokens = self._tokens.slice(lastLineIndex);
		}
	}

	fn _acceptInsertText(self: *ContiguousMultilineTokens, position: Position, eolCount: usize, firstLineLength: usize) void {

		if (eolCount == 0 and firstLineLength == 0) {
			// Nothing to insert
			return;
		}

		const lineIndex = position.lineNumber - self._startLineNumber;

		if (lineIndex < 0) {
			// this insertion occurs before this block, so we only need to adjust line numbers
			self._startLineNumber += eolCount;
			return;
		}

		if (lineIndex >= self._tokens.items.len) {
			// this insertion occurs after this block, so there is nothing to do
			return;
		}

		if (eolCount == 0) {
			// Inserting text on one line
			self._tokens[lineIndex] = ContiguousTokensEditing.insert(self._tokens[lineIndex], position.column - 1, firstLineLength);
			return;
		}

		self._tokens[lineIndex] = ContiguousTokensEditing.deleteEnding(self._tokens[lineIndex], position.column - 1);
		self._tokens[lineIndex] = ContiguousTokensEditing.insert(self._tokens[lineIndex], position.column - 1, firstLineLength);

		self._insertLines(position.lineNumber, eolCount);
	}

	fn _insertLines(self: *ContiguousMultilineTokens, insertIndex: usize, insertCount: usize) void {
		if (insertCount == 0) {
			return;
		}
		const lineTokens: (Uint32Array | ArrayBuffer | null)[] = [];
		for (let i = 0; i < insertCount; i++) {
			lineTokens[i] = null;
		}
		self._tokens = arrays.arrayInsert(self._tokens, insertIndex, lineTokens);
	}
};

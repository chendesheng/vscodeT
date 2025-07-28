const LineTokens = @import("./lineTokens.zig").LineTokens;

pub const EMPTY_LINE_TOKENS = &[_]u32{};

pub const ContiguousTokensEditing = struct {

	pub fn deleteBeginning(lineTokens: []u32, toChIndex: usize) ?[]u32 {
		if (lineTokens == null or lineTokens == EMPTY_LINE_TOKENS) {
			return lineTokens;
		}
		return ContiguousTokensEditing.delete(lineTokens, 0, toChIndex);
	}

	pub fn deleteEnding(lineTokens: []u32, fromChIndex: usize) ?[]u32 {
		if (lineTokens == null or lineTokens == EMPTY_LINE_TOKENS) {
			return lineTokens;
		}

		const tokens = toUint32Array(lineTokens);
		const lineTextLength = tokens[tokens.len - 2];
		return ContiguousTokensEditing.delete(lineTokens, fromChIndex, lineTextLength);
	}

	pub fn delete(lineTokens: []u32, fromChIndex: usize, toChIndex: usize) ?[]u32 {
		if (lineTokens == null or lineTokens == EMPTY_LINE_TOKENS or fromChIndex == toChIndex) {
			return lineTokens;
		}

		const tokens = toUint32Array(lineTokens);
		const tokensCount = (tokens.len >>> 1);

		// special case: deleting everything
		if (fromChIndex == 0 and tokens[tokens.len - 2] == toChIndex) {
			return EMPTY_LINE_TOKENS;
		}

		const fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, fromChIndex);
		const fromTokenStartOffset = (fromTokenIndex > 0 ? tokens[(fromTokenIndex - 1) << 1] : 0);
		const fromTokenEndOffset = tokens[fromTokenIndex << 1];

		if (toChIndex < fromTokenEndOffset) {
			// the delete range is inside a single token
			const delta = (toChIndex - fromChIndex);
			for (fromTokenIndex..tokensCount) |i| {
				tokens[i << 1] -= delta;
			}
			return lineTokens;
		}

		var dest: usize = undefined;
		var lastEnd: usize = undefined;
		if (fromTokenStartOffset != fromChIndex) {
			tokens[fromTokenIndex << 1] = fromChIndex;
			dest = ((fromTokenIndex + 1) << 1);
			lastEnd = fromChIndex;
		} else {
			dest = (fromTokenIndex << 1);
			lastEnd = fromTokenStartOffset;
		}

		const delta = (toChIndex - fromChIndex);
		for (fromTokenIndex + 1..tokensCount) |tokenIndex| {
			const tokenEndOffset = tokens[tokenIndex << 1] - delta;
			if (tokenEndOffset > lastEnd) {
				tokens[dest++] = tokenEndOffset;
				tokens[dest++] = tokens[(tokenIndex << 1) + 1];
				lastEnd = tokenEndOffset;
			}
		}

		if (dest == tokens.len) {
			// nothing to trim
			return lineTokens;
		}

		const tmp = std.ArrayList(u32).init(std.heap.page_allocator);
		tmp.appendSlice(tokens[0..dest]);
		return tmp.items;
	}

	pub fn append(lineTokens: []u32, _otherTokens: []u32) ?[]u32 {
		if (_otherTokens == EMPTY_LINE_TOKENS) {
			return lineTokens;
		}
		if (lineTokens == EMPTY_LINE_TOKENS) {
			return _otherTokens;
		}
		if (lineTokens == null) {
			return lineTokens;
		}
		if (_otherTokens == null) {
			// cannot determine combined line length...
			return null;
		}
		const myTokens = toUint32Array(lineTokens);
		const otherTokens = toUint32Array(_otherTokens);
		const otherTokensCount = (otherTokens.len >>> 1);

		const result = std.ArrayList(u32).init(std.heap.page_allocator);
		result.appendSlice(myTokens);
		var dest = myTokens.len;
		const delta = myTokens[myTokens.len - 2];
		for (0..otherTokensCount) |i| {
			result[dest++] = otherTokens[(i << 1)] + delta;
			result[dest++] = otherTokens[(i << 1) + 1];
		}
		return result.items;
	}

	pub fn insert(lineTokens: []u32, chIndex: usize, textLength: usize) ?[]u32 {
		if (lineTokens == null or lineTokens == EMPTY_LINE_TOKENS) {
			// nothing to do
			return lineTokens;
		}

		const tokens = lineTokens;
		const tokensCount = (tokens.len >>> 1);

		var fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, chIndex);
		if (fromTokenIndex > 0) {
			const fromTokenStartOffset = tokens[(fromTokenIndex - 1) << 1];
			if (fromTokenStartOffset == chIndex) {
				fromTokenIndex--;
			}
		}
		for (fromTokenIndex..tokensCount) |tokenIndex| {
			tokens[tokenIndex << 1] += textLength;
		}
		return lineTokens;
	}
};

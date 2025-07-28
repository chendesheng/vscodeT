const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Pair = @import("./basics/utils.zig").Pair;
const RangePriorityQueue = @import("./basics/rangePriorityQueue.zig").RangePriorityQueue;
const OffsetRange = @import("./basics/offsetRange.zig").OffsetRange;
const countEOL = @import("./basics/eolCounter.zig").countEOL;
const LineRange = @import("./basics/lineRange.zig").LineRange;
const ModelContentChange = @import("model.zig").ModelContentChange;
const FixedArray = @import("./basics/FixedArray.zig").FixedArray;

const CHEAP_TOKENIZATION_LENGTH_LIMIT = 2048;

pub fn TokenizerWithStateStore(comptime TState: type) type {
    return struct {
        const Self = @This();

        initialState: TState,
        store: TrackingTokenizationStateStore(TState),

        pub fn init(lineCount: usize, tokenizationSupport: TokenizationSupport) Self {
            return Self{
                .initialState = tokenizationSupport.getInitialState(),
                .store = TrackingTokenizationStateStore(TState).init(lineCount),
            };
        }

        pub fn getStartState(self: *Self, lineNumber: usize) ?TState {
            return self.store.getStartState(lineNumber, self.initialState);
        }

        pub fn getFirstInvalidLine(self: *Self) ?Pair(usize, TState) {
            return self.store.getFirstInvalidLine(self.initialState);
        }
    };
}

pub fn TokenizerWithStateStoreAndTextModel(comptime TState: type) type {
    return struct {
        const Self = @This();

        lineCount: usize,
        tokenizationSupport: ITokenizationSupport,
        _textModel: ITextModel,
        _languageIdCodec: ILanguageIdCodec,

        pub fn init(lineCount: usize, tokenizationSupport: ITokenizationSupport, textModel: ITextModel, languageIdCodec: ILanguageIdCodec) Self {
            return Self{
                .lineCount = lineCount,
                .tokenizationSupport = tokenizationSupport,
                ._textModel = textModel,
                ._languageIdCodec = languageIdCodec,
            };
        }

        pub fn updateTokensUntilLine(self: *Self, builder: ContiguousMultilineTokensBuilder, lineNumber: usize) void {
            const languageId = self._textModel.getLanguageId();

            while (true) {
                const lineToTokenize = self.getFirstInvalidLine() orelse break;
                if (lineToTokenize.lineNumber > lineNumber) {
                    break;
                }

                const text = self._textModel.getLineContent(lineToTokenize.lineNumber);

                const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, text, true, lineToTokenize.startState);
			builder.add(lineToTokenize.lineNumber, r.tokens);
                self.store.setEndState(lineToTokenize.lineNumber, r.endState);
            }
        }

	// assumes state is up to date 
        pub fn getTokenTypeIfInsertingCharacter(self: *Self, position: Position, character: []const u8) StandardTokenType {
            // TODO@hediet: use tokenizeLineWithEdit
            const lineStartState = self.getStartState(position.lineNumber);
            if (lineStartState == null) {
                return StandardTokenType.Other;
            }

            const languageId = self._textModel.getLanguageId();
            const lineContent = self._textModel.getLineContent(position.lineNumber);

            // Create the text as if `character` was inserted
            const text = (
                lineContent[0..position.column - 1]
                ++ character
                ++ lineContent[position.column - 1..]
            );

            const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, text, true, lineStartState);
            const lineTokens = LineTokens(r.tokens, text, self._languageIdCodec);
            if (lineTokens.getCount() == 0) {
                return StandardTokenType.Other;
            }

            const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1);
            return lineTokens.getStandardTokenType(tokenIndex);
        }

        // assumes state is up to date 
        pub fn tokenizeLinesAt(self: *Self, lineNumber: usize, lines: []const []const u8) ?[]LineTokens {
            const lineStartState = self.getStartState(lineNumber);
            if (!lineStartState) {
                return null;
            }

            const languageId = this._textModel.getLanguageId();
            const result: LineTokens[] = [];

            let state = lineStartState;
            for (const line of lines) {
                const r = safeTokenize(this._languageIdCodec, languageId, this.tokenizationSupport, line, true, state);
                result.push(new LineTokens(r.tokens, line, this._languageIdCodec));
                state = r.endState;
            }

            return result;
        }

        pub fn hasAccurateTokensForLine(self: *Self, lineNumber: usize) bool {
            const firstInvalidLineNumber = self.store.getFirstInvalidEndStateLineNumberOrMax();
            return (lineNumber < firstInvalidLineNumber);
        }

        pub fn isCheapToTokenize(self: *Self, lineNumber: usize) bool {
            const firstInvalidLineNumber = self.store.getFirstInvalidEndStateLineNumberOrMax();
            if (lineNumber < firstInvalidLineNumber) {
                return true;
            }
            if (lineNumber === firstInvalidLineNumber
                && self._textModel.getLineLength(lineNumber) < CHEAP_TOKENIZATION_LENGTH_LIMIT) {
                return true;
            }

            return false;
        }

        // The result is not cached.
        pub fn tokenizeHeuristically(self: *Self, builder: ContiguousMultilineTokensBuilder, startLineNumber: usize, endLineNumber: usize) struct { heuristicTokens: bool } {
            if (endLineNumber <= self.store.getFirstInvalidEndStateLineNumberOrMax()) {
                // nothing to do
                return { heuristicTokens: false };
            }

            if (startLineNumber <= self.store.getFirstInvalidEndStateLineNumberOrMax()) {
                // tokenization has reached the viewport start...
                this.updateTokensUntilLine(builder, endLineNumber);
                return { heuristicTokens: false };
            }

            let state = self.guessStartState(startLineNumber);
            const languageId = self._textModel.getLanguageId();

            for (let lineNumber = startLineNumber; lineNumber <= endLineNumber; lineNumber++) {
                const text = this._textModel.getLineContent(lineNumber);
                const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, text, true, state);
                builder.add(lineNumber, r.tokens);
                state = r.endState;
            }

            return { heuristicTokens: true };
        }

        fn guessStartState(self: *Self, lineNumber: usize) IState {
            let { likelyRelevantLines, initialState } = findLikelyRelevantLines(self._textModel, lineNumber, self);

            if (!initialState) {
                initialState = self.tokenizationSupport.getInitialState();
            }

            const languageId = self._textModel.getLanguageId();
            let state = initialState;
            for (likelyRelevantLines) |line| {
                const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, line, false, state);
                state = r.endState;
            }
            return state;
        }
    }
};

pub fn findLikelyRelevantLines(model: ITextModel, lineNumber: usize, store: *TokenizerWithStateStore) struct { likelyRelevantLines: []const []const u8, initialState: ?IState } {
	var nonWhitespaceColumn = model.getLineFirstNonWhitespaceColumn(lineNumber);
	var likelyRelevantLines = ArrayList([]const u8).init(std.heap.page_allocator);
	var initialState: ?IState = null;
	for (lineNumber - 1, 0..) |i, _| {
		const newNonWhitespaceIndex = model.getLineFirstNonWhitespaceColumn(i);
		// Ignore lines full of whitespace
		if (newNonWhitespaceIndex == 0) {
			continue;
		}
		if (newNonWhitespaceIndex < nonWhitespaceColumn) {
			likelyRelevantLines.append(model.getLineContent(i));
			nonWhitespaceColumn = newNonWhitespaceIndex;
			initialState = store?.getStartState(i);
			if (initialState) {
				break;
			}
		}
	}

	likelyRelevantLines.reverse();
	return .{ .likelyRelevantLines = likelyRelevantLines.items, .initialState = initialState };
}

// **Invariant:**
// If the text model is retokenized from line 1 to {@link getFirstInvalidEndStateLineNumber}() - 1,
// then the recomputed end state for line l will be equal to {@link getEndState}(l).
pub fn TrackingTokenizationStateStore(comptime TState: type) type {
    return struct {
        const Self = @This();

        _tokenizationStateStore: TokenizationStateStore(TState),
        _invalidEndStatesLineNumbers: RangePriorityQueue,

        pub fn init(lineCount: usize) !Self {
            var queue = RangePriorityQueue.init();
            try queue.addRange(OffsetRange.init(1, lineCount + 1));
            return Self{
                ._tokenizationStateStore = TokenizationStateStore(TState).init(),
                ._invalidEndStatesLineNumbers = queue,
            };
        }

        pub fn getEndState(self: *Self, lineNumber: usize) ?TState {
            return self._tokenizationStateStore.getEndState(lineNumber);
        }

        // @returns if the end state has changed.
        pub fn setEndState(self: *Self, lineNumber: usize, state: TState) !bool {
            if (state == null) {
                return false;
            }

            self._invalidEndStatesLineNumbers.delete(lineNumber);
            const r = self._tokenizationStateStore.setEndState(lineNumber, state);
            if (r and lineNumber < self.lineCount) {
                // because the state changed, we cannot trust the next state anymore and have to invalidate it.
                try self._invalidEndStatesLineNumbers.addRange(OffsetRange.init(lineNumber + 1, lineNumber + 2));
            }

            return r;
        }

        pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) !void {
            self.lineCount += newLineCount - range.length;
            self._tokenizationStateStore.acceptChange(range, newLineCount);
            self._invalidEndStatesLineNumbers.addRangeAndResize(OffsetRange.init(range.startLineNumber, range.endLineNumberExclusive), newLineCount);
        }

        pub fn acceptChanges(self: *Self, changes: []ModelContentChange) !void {
            for (changes) |c| {
                const result = countEOL(c.text);
                try self.acceptChange(LineRange.init(c.range.startLineNumber, c.range.endLineNumber + 1), result.eolCount + 1);
            }
        }

        pub fn invalidateEndStateRange(self: *Self, range: LineRange) !void {
            try self._invalidEndStatesLineNumbers.addRange(OffsetRange.init(range.startLineNumber, range.endLineNumberExclusive));
        }

        pub fn getFirstInvalidEndStateLineNumber(self: *Self) ?usize {
            return self._invalidEndStatesLineNumbers.min();
        }

        pub fn getFirstInvalidEndStateLineNumberOrMax(self: *Self) usize {
            return self.getFirstInvalidEndStateLineNumber() orelse std.math.maxInt(usize);
        }

        pub fn allStatesValid(self: *Self) bool {
            return self._invalidEndStatesLineNumbers.min() == null;
        }

        pub fn getStartState(self: *Self, lineNumber: usize, initialState: TState) ?TState {
            if (lineNumber == 1) {
                return initialState;
            }
            return self.getEndState(lineNumber - 1);
        }

        pub fn getFirstInvalidLine(self: *Self, initialState: TState) ?Pair(usize, TState) {
            const lineNumber = self.getFirstInvalidEndStateLineNumber();
            if (lineNumber == null) {
                return null;
            }
            const startState = self.getStartState(lineNumber, initialState);
            if (startState == null) {
                return error.StartStateMustBeDefined;
            }

            return Pair(usize, TState).init(lineNumber, startState);
        }
    };
}

pub fn TokenizationStateStore(comptime TState: type) type {
    return struct {
        const Self = @This();
        _lineEndStates: FixedArray(?TState),

        pub fn init() Self {
            return Self{
                ._lineEndStates = FixedArray(?TState).init(std.heap.page_allocator, null),
            };
        }

        pub fn getEndState(self: *Self, lineNumber: usize) ?TState {
            return self._lineEndStates.get(lineNumber);
        }

        pub fn setEndState(self: *Self, lineNumber: usize, state: TState) bool {
            const oldState = self._lineEndStates.get(lineNumber);
            if (oldState and oldState.equals(state)) {
                return false;
            }

            self._lineEndStates.set(lineNumber, state);
            return true;
        }

        pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) void {
            var len = range.length;
            if (newLineCount > 0 and len > 0) {
                // Keep the last state, even though it is unrelated.
                // But if the new state happens to agree with this last state, then we know we can stop tokenizing.
                len -= 1;
                newLineCount -= 1;
            }

            self._lineEndStates.replace(range.startLineNumber, len, newLineCount);
        }

        pub fn acceptChanges(self: *Self, changes: []ModelContentChange) void {
            for (changes) |c| {
                const result = countEOL(c.text);
                self.acceptChange(LineRange.init(c.range.startLineNumber, c.range.endLineNumber + 1), result.eolCount + 1);
            }
        }
    };
}

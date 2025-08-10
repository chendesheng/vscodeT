const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Pair = @import("./basics/utils.zig").Pair;
const pair = @import("./basics/utils.zig").pair;
const RangePriorityQueue = @import("./basics/rangePriorityQueue.zig");
const OffsetRange = @import("./basics/offsetRange.zig").OffsetRange;
const countEOL = @import("./basics/eolCounter.zig").countEOL;
const LineRange = @import("./basics/lineRange.zig").LineRange;
const ModelContentChange = @import("model.zig").ModelContentChange;
const FixedArray = @import("./basics/FixedArray.zig").FixedArray;
const LineTokens = @import("./tokens/lineTokens.zig").LineTokens;
const TextModel = @import("./textModel.zig").TextModel;
const Position = @import("./basics/position.zig").Position;
const ContiguousMultilineTokensBuilder = @import("./tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const ITokenizationSupport = @import("languages.zig").ITokenizationSupport;
const LanguageIdCodec = @import("./languages.zig").LanguageIdCodec;
const IState = @import("languages.zig").IState;
const EncodedTokenizationResult = @import("languages.zig").EncodedTokenizationResult;
const StandardTokenType = @import("encodedTokenAttributes.zig").StandardTokenType;
const nullTokenizeEncoded = @import("./nullTokenize.zig").nullTokenizeEncoded;
const StopWatch = @import("./basics/stopWatch.zig").StopWatch;
const IBackgroundTokenizationStore = @import("./languages.zig").IBackgroundTokenizationStore;
const IdleDeadline = @import("./basics/utils.zig").IdleDeadline;
const runWhenGlobalIdle = @import("./basics/utils.zig").runWhenGlobalIdle;

const CHEAP_TOKENIZATION_LENGTH_LIMIT = 2048;

pub const TokenizerWithStateStore = struct {
    const Self = @This();

    initialState: IState,
    store: TrackingTokenizationStateStore,

    pub fn init(allocator: Allocator, lineCount: usize, tokenizationSupport: ITokenizationSupport) !Self {
        return Self{
            .initialState = tokenizationSupport.getInitialState(),
            .store = try TrackingTokenizationStateStore.init(allocator, lineCount),
        };
    }

    pub fn getStartState(self: *Self, lineNumber: usize) ?IState {
        return self.store.getStartState(lineNumber, self.initialState);
    }

    pub fn getFirstInvalidLine(self: *Self) !?Pair(usize, IState) {
        return self.store.getFirstInvalidLine(self.initialState);
    }
};

pub const TokenizerWithStateStoreAndTextModel = struct {
    const Self = @This();

    super: TokenizerWithStateStore,

    lineCount: usize,
    tokenizationSupport: ITokenizationSupport,
    _textModel: TextModel,
    _languageIdCodec: LanguageIdCodec,

    pub fn init(lineCount: usize, tokenizationSupport: ITokenizationSupport, textModel: TextModel, languageIdCodec: LanguageIdCodec) !Self {
        return Self{
            .super = try TokenizerWithStateStore.init(textModel.getAllocator(), lineCount, tokenizationSupport),
            .lineCount = lineCount,
            .tokenizationSupport = tokenizationSupport,
            ._textModel = textModel,
            ._languageIdCodec = languageIdCodec,
        };
    }

    pub fn getStartState(self: *Self, lineNumber: usize) ?IState {
        return self.super.getStartState(lineNumber);
    }

    pub fn getFirstInvalidLine(self: *Self) !?Pair(usize, IState) {
        return self.super.getFirstInvalidLine();
    }

    pub fn getStore(self: *Self) TrackingTokenizationStateStore {
        return self.super.store;
    }

    pub fn getInitialState(self: *Self) IState {
        return self.super.initialState;
    }

    pub fn updateTokensUntilLine(self: *Self, builder: ContiguousMultilineTokensBuilder, lineNumber: usize) !void {
        const languageId = self._textModel.getLanguageId();

        while (true) {
            const lineToTokenize = try self.getFirstInvalidLine() orelse break;
            if (lineToTokenize.lineNumber > lineNumber) {
                break;
            }

            const text = try self._textModel.getLineContent(lineToTokenize.lineNumber);
            const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, lineToTokenize.startState);
            try builder.add(lineToTokenize.lineNumber, r.tokens);
            _ = try self.getStore().setEndState(lineToTokenize.lineNumber, r.endState);
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
        const text = (lineContent[0 .. position.column - 1] ++ character ++ lineContent[position.column - 1 ..]);

        const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, text, true, lineStartState);
        const lineTokens = LineTokens.init(r.tokens, text, self._languageIdCodec);
        if (lineTokens.getCount() == 0) {
            return StandardTokenType.Other;
        }

        const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1);
        return lineTokens.getStandardTokenType(tokenIndex);
    }

    // assumes state is up to date
    pub fn tokenizeLinesAt(self: *Self, lineNumber: usize, lines: []const []const u8) !?ArrayList(LineTokens) {
        if (self.getStartState(lineNumber)) |lineStartState| {
            const allocator = self._textModel.getAllocator();
            const languageId = self._textModel.getLanguageId();
            var result = ArrayList(LineTokens).init(allocator);

            var state = lineStartState;
            for (lines) |line| {
                const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, line, true, state);
                try result.append(LineTokens.createFromTextAndMetadata(r.tokens, line, self._languageIdCodec));
                state = r.endState;
            }

            return result;
        } else {
            return null;
        }
    }

    pub fn hasAccurateTokensForLine(self: *Self, lineNumber: usize) bool {
        const firstInvalidLineNumber = self.getStore().getFirstInvalidEndStateLineNumberOrMax();
        return (lineNumber < firstInvalidLineNumber);
    }

    pub fn isCheapToTokenize(self: *Self, lineNumber: usize) bool {
        const firstInvalidLineNumber = self.getStore().getFirstInvalidEndStateLineNumberOrMax();
        if (lineNumber < firstInvalidLineNumber) {
            return true;
        }
        if (lineNumber == firstInvalidLineNumber and self._textModel.getLineLength(lineNumber) < CHEAP_TOKENIZATION_LENGTH_LIMIT) {
            return true;
        }

        return false;
    }

    // The result is not cached.
    pub fn tokenizeHeuristically(self: *Self, builder: ContiguousMultilineTokensBuilder, startLineNumber: usize, endLineNumber: usize) !struct { heuristicTokens: bool } {
        if (endLineNumber <= self.getStore().getFirstInvalidEndStateLineNumberOrMax()) {
            // nothing to do
            return .{ .heuristicTokens = false };
        }

        if (startLineNumber <= self.getStore().getFirstInvalidEndStateLineNumberOrMax()) {
            // tokenization has reached the viewport start...
            try self.updateTokensUntilLine(builder, endLineNumber);
            return .{ .heuristicTokens = false };
        }

        const state = self.guessStartState(startLineNumber);
        const languageId = self._textModel.getLanguageId();

        for (startLineNumber..endLineNumber + 1) |lineNumber| {
            const text = try self._textModel.getLineContent(lineNumber);
            const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, state);
            try builder.add(lineNumber, r.tokens);
            state = r.endState;
        }

        return .{ .heuristicTokens = true };
    }

    fn guessStartState(self: *Self, lineNumber: usize) IState {
        const res = findLikelyRelevantLines(self._textModel, lineNumber, self);
        const likelyRelevantLines = res.likelyRelevantLines;
        const initialState = res.initialState;

        if (!initialState) {
            initialState = self.tokenizationSupport.getInitialState();
        }

        const languageId = self._textModel.getLanguageId();
        var state = initialState;
        for (likelyRelevantLines.items) |line| {
            const r = safeTokenize(self._languageIdCodec, languageId, self.tokenizationSupport, line.items, false, state);
            state = r.endState;
        }
        return state;
    }
};

pub fn findLikelyRelevantLines(model: TextModel, lineNumber: usize, _store: ?TokenizerWithStateStore) struct { likelyRelevantLines: ArrayList(ArrayList(u8)), initialState: ?IState } {
    var nonWhitespaceColumn = model.getLineFirstNonWhitespaceColumn(lineNumber);
    var likelyRelevantLines = ArrayList(ArrayList(u8)).init(model.getAllocator());
    var initialState: ?IState = null;
    var i = lineNumber - 1;
    while (nonWhitespaceColumn > 1 and i >= 1) : (i -= 1) {
        const newNonWhitespaceIndex = model.getLineFirstNonWhitespaceColumn(i);
        // Ignore lines full of whitespace
        if (newNonWhitespaceIndex == 0) {
            continue;
        }
        if (newNonWhitespaceIndex < nonWhitespaceColumn) {
            try likelyRelevantLines.append(try model.getLineContent(i));
            nonWhitespaceColumn = newNonWhitespaceIndex;
            initialState = if (_store) |store| store.getStartState(i) else null;
            if (initialState != null) {
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
pub const TrackingTokenizationStateStore = struct {
    const Self = @This();

    _tokenizationStateStore: TokenizationStateStore,
    _invalidEndStatesLineNumbers: RangePriorityQueue,
    _lineCount: usize,

    pub fn init(allocator: Allocator, lineCount: usize) !Self {
        var queue = RangePriorityQueue.init(allocator);
        try queue.addRange(OffsetRange.init(1, lineCount + 1));
        return Self{
            ._tokenizationStateStore = TokenizationStateStore.init(),
            ._invalidEndStatesLineNumbers = queue,
            ._lineCount = lineCount,
        };
    }

    pub fn getEndState(self: *Self, lineNumber: usize) ?IState {
        return self._tokenizationStateStore.getEndState(lineNumber);
    }

    // @returns if the end state has changed.
    pub fn setEndState(self: *Self, lineNumber: usize, state: IState) !bool {
        self._invalidEndStatesLineNumbers.delete(lineNumber);
        const r = try self._tokenizationStateStore.setEndState(lineNumber, state);
        if (r and lineNumber < self._lineCount) {
            // because the state changed, we cannot trust the next state anymore and have to invalidate it.
            try self._invalidEndStatesLineNumbers.addRange(OffsetRange.init(lineNumber + 1, lineNumber + 2));
        }

        return r;
    }

    pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) !void {
        self._lineCount = self._lineCount + newLineCount - range.length();
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

    pub fn getStartState(self: *Self, lineNumber: usize, initialState: IState) ?IState {
        if (lineNumber == 1) {
            return initialState;
        }
        return self.getEndState(lineNumber - 1);
    }

    pub fn getFirstInvalidLine(self: *Self, initialState: IState) !?Pair(usize, IState) {
        if (self.getFirstInvalidEndStateLineNumber()) |lineNumber| {
            if (self.getStartState(lineNumber, initialState)) |startState| {
                return pair(lineNumber, startState);
            } else {
                return error.StartStateMustBeDefined;
            }
        } else {
            return null;
        }
    }
};

pub const TokenizationStateStore = struct {
    const Self = @This();
    _lineEndStates: FixedArray(?IState),

    pub fn init() Self {
        return Self{
            ._lineEndStates = FixedArray(?IState).init(std.heap.page_allocator, null),
        };
    }

    pub fn getEndState(self: *Self, lineNumber: usize) ?IState {
        return self._lineEndStates.get(lineNumber);
    }

    pub fn setEndState(self: *Self, lineNumber: usize, state: IState) !bool {
        if (self._lineEndStates.get(lineNumber)) |oldState| {
            if (oldState.equals(state)) {
                return false;
            }
        }

        try self._lineEndStates.set(lineNumber, state);
        return true;
    }

    pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) !void {
        var len = range.length();
        if (newLineCount > 0 and len > 0) {
            // Keep the last state, even though it is unrelated.
            // But if the new state happens to agree with this last state, then we know we can stop tokenizing.
            len -= 1;
            newLineCount -= 1;
        }

        try self._lineEndStates.replace(range.startLineNumber, len, newLineCount);
    }

    pub fn acceptChanges(self: *Self, changes: []ModelContentChange) !void {
        for (changes) |c| {
            const result = countEOL(c.text);
            try self.acceptChange(LineRange.init(c.range.startLineNumber, c.range.endLineNumber + 1), result.eolCount + 1);
        }
    }
};

fn safeTokenize(languageIdCodec: LanguageIdCodec, languageId: []u8, _tokenizationSupport: ?ITokenizationSupport, text: []u8, hasEOL: bool, state: IState) EncodedTokenizationResult {
    const r: EncodedTokenizationResult = if (_tokenizationSupport) |tokenizationSupport| {
        tokenizationSupport.tokenizeEncoded(text, hasEOL, state.clone());
    } else {
        nullTokenizeEncoded(languageIdCodec.encodeLanguageId(languageId), state);
    };

    LineTokens.convertToEndOffset(r.tokens, text.len);
    return r;
}

pub const DefaultBackgroundTokenizer = struct {
    _isDisposed: bool = false,
    _isScheduled: bool = false,

    tokenizerWithStateStore: TokenizerWithStateStoreAndTextModel,
    backgroundTokenStore: IBackgroundTokenizationStore,

    const Self = @This();

    pub fn init(tokenizerWithStateStore: TokenizerWithStateStoreAndTextModel, backgroundTokenStore: IBackgroundTokenizationStore) Self {
        return Self{
            .tokenizerWithStateStore = tokenizerWithStateStore,
            .backgroundTokenStore = backgroundTokenStore,
        };
    }

    pub fn dispose(self: *Self) void {
        self._isDisposed = true;
    }

    pub fn handleChanges(self: *Self) void {
        self._beginBackgroundTokenization();
    }

    fn _beginBackgroundTokenization(self: *Self) void {
        if (self._isScheduled or !self.tokenizerWithStateStore._textModel.isAttachedToEditor() or !self._hasLinesToTokenize()) {
            return;
        }

        self._isScheduled = true;
        runWhenGlobalIdle(self, struct {
            fn callback(deadline: IdleDeadline, this: *Self) void {
                this._isScheduled = false;
                this._backgroundTokenizeWithDeadline(deadline);
            }
        }.callback);
    }

    // Tokenize until the deadline occurs, but try to yield every 1-2ms.
    fn _backgroundTokenizeWithDeadline(self: *Self, deadline: IdleDeadline) void {
        // Read the time remaining from the `deadline` immediately because it is unclear
        // if the `deadline` object will be valid after execution leaves this function.
        const now = std.time.timestamp();
        const endTime = now + deadline.timeRemaining();

        if (self._isDisposed or !self.tokenizerWithStateStore._textModel.isAttachedToEditor() or !self._hasLinesToTokenize()) {
            // disposed in the meantime or detached or finished
            return;
        }

        self._backgroundTokenizeForAtLeast1ms();

        if (now < endTime) {
            // There is still time before reaching the deadline, so yield to the browser and then
            // continue execution
            // setTimeout0(execute);
            // self.execute();
        } else {
            // The deadline has been reached, so schedule a new idle callback if necessary
            self._beginBackgroundTokenization();
        }
    }

    // Tokenize for at least 1ms.
    fn _backgroundTokenizeForAtLeast1ms(self: *Self) void {
        const lineCount = self.tokenizerWithStateStore._textModel.getLineCount();
        const builder = ContiguousMultilineTokensBuilder.init();
        const sw = StopWatch.init(false);

        while (true) {
            if (sw.elapsed() > 1) {
                // the comparison is intentionally > 1 and not >= 1 to ensure that
                // a full millisecond has elapsed, given how microseconds are rounded
                // to milliseconds
                break;
            }

            const tokenizedLineNumber = self._tokenizeOneInvalidLine(builder);

            if (tokenizedLineNumber >= lineCount) {
                break;
            }
        }

        self.backgroundTokenStore.setTokens(builder.finalize());
        self.checkFinished();
    }

    fn _hasLinesToTokenize(self: *Self) bool {
        if (!self.tokenizerWithStateStore) {
            return false;
        }
        return !self.tokenizerWithStateStore.store.allStatesValid();
    }

    fn _tokenizeOneInvalidLine(self: *Self, builder: ContiguousMultilineTokensBuilder) usize {
        const firstInvalidLine = self.tokenizerWithStateStore.?.getFirstInvalidLine();
        if (!firstInvalidLine) {
            return self.tokenizerWithStateStore._textModel.getLineCount() + 1;
        }
        self.tokenizerWithStateStore.updateTokensUntilLine(builder, firstInvalidLine.lineNumber);
        return firstInvalidLine.lineNumber;
    }

    pub fn checkFinished(self: *Self) void {
        if (self._isDisposed) {
            return;
        }
        if (self.tokenizerWithStateStore.store.allStatesValid()) {
            self.backgroundTokenStore.backgroundTokenizationFinished();
        }
    }

    pub fn requestTokens(self: *Self, startLineNumber: usize, endLineNumberExclusive: usize) void {
        self.tokenizerWithStateStore.store.invalidateEndStateRange(LineRange.init(startLineNumber, endLineNumberExclusive));
    }
};

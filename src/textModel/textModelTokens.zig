const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Pair = @import("../basics/utils.zig").Pair;
const pair = @import("../basics/utils.zig").pair;
const RangePriorityQueue = @import("../basics/rangePriorityQueue.zig").RangePriorityQueue;
const OffsetRange = @import("../basics/offsetRange.zig").OffsetRange;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const ModelContentChange = @import("../textModel/textModelEvents.zig").ModelContentChange;
const FixedArray = @import("../basics/FixedArray.zig").FixedArray;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const TextModel = @import("./textModel.zig").TextModel;
const Position = @import("../basics/position.zig").Position;
const ContiguousMultilineTokensBuilder = @import("../tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const LanguageIdCodec = @import("../services/languageRegistry.zig").LanguageIdCodec;
const IState = @import("../languages.zig").IState;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const nullTokenizeEncoded = @import("../languages/nullTokenize.zig").nullTokenizeEncoded;
const StopWatch = @import("../basics/stopWatch.zig").StopWatch;
const IBackgroundTokenizationStore = @import("../languages.zig").IBackgroundTokenizationStore;
const IdleDeadline = @import("../basics/utils.zig").IdleDeadline;
const runWhenGlobalIdle = @import("../basics/utils.zig").runWhenGlobalIdle;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const IBackgroundTokenizer = @import("../languages.zig").IBackgroundTokenizer;

const CHEAP_TOKENIZATION_LENGTH_LIMIT = 2048;

pub const TokenizerWithStateStore = struct {
    const Self = @This();

    initialState: IState,
    store: TrackingTokenizationStateStore,

    pub fn init(allocator: Allocator, lineCount: usize, tokenizationSupport: *ITokenizationSupport) !Self {
        return Self{
            .initialState = try tokenizationSupport.getInitialState(),
            .store = try TrackingTokenizationStateStore.init(allocator, lineCount),
        };
    }

    pub fn deinit(self: *Self) void {
        self.store.deinit();
    }

    pub fn getStartState(self: *const Self, lineNumber: usize) ?IState {
        return self.store.getStartState(lineNumber, self.initialState);
    }

    pub fn getFirstInvalidLine(self: *const Self) !?Pair(usize, IState) {
        return self.store.getFirstInvalidLine(self.initialState);
    }
};

pub const TokenizerWithStateStoreAndTextModel = struct {
    const Self = @This();

    super: TokenizerWithStateStore,

    lineCount: usize,
    tokenizationSupport: *ITokenizationSupport,
    _textModel: *TextModel,
    _languageIdCodec: *const LanguageIdCodec,

    pub fn init(lineCount: usize, tokenizationSupport: *ITokenizationSupport, _textModel: *TextModel, languageIdCodec: *const LanguageIdCodec) !Self {
        return Self{
            .super = try TokenizerWithStateStore.init(_textModel.getAllocator(), lineCount, tokenizationSupport),
            .lineCount = lineCount,
            .tokenizationSupport = tokenizationSupport,
            ._textModel = _textModel,
            ._languageIdCodec = languageIdCodec,
        };
    }

    pub fn deinit(self: *Self) void {
        self.super.deinit();
    }

    pub fn getStartState(self: *const Self, lineNumber: usize) ?IState {
        return self.super.getStartState(lineNumber);
    }

    pub fn getFirstInvalidLine(self: *Self) !?Pair(usize, IState) {
        return self.super.getFirstInvalidLine();
    }

    pub fn getStore(self: *Self) *TrackingTokenizationStateStore {
        return &self.super.store;
    }

    pub fn getStoreConst(self: *const Self) *const TrackingTokenizationStateStore {
        return &self.super.store;
    }

    pub fn getInitialState(self: *Self) IState {
        return self.super.initialState;
    }

    pub fn updateTokensUntilLine(self: *Self, builder: *ContiguousMultilineTokensBuilder, lineNumber: usize) !void {
        const allocator = self._textModel.getAllocator();
        const languageId = self._textModel.getLanguageId();

        while (true) {
            const lineToTokenize = try self.getFirstInvalidLine() orelse break;
            if (lineToTokenize.first > lineNumber) {
                break;
            }

            const text = try self._textModel.getLineContent(lineToTokenize.first);
            defer text.deinit();
            const r = try safeTokenize(allocator, self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, lineToTokenize.second);
            try builder.add(lineToTokenize.first, r.tokens);
            var store = self.getStore();
            _ = try store.setEndState(lineToTokenize.first, r.endState);
        }
    }

    // assumes state is up to date
    pub fn getTokenTypeIfInsertingCharacter(self: *const Self, position: Position, character: []const u8) !StandardTokenType {
        const allocator = self._textModel.getAllocator();
        // TODO@hediet: use tokenizeLineWithEdit
        const lineStartState = self.getStartState(position.lineNumber);
        if (lineStartState == null) {
            return StandardTokenType.Other;
        }

        const languageId = self._textModel.getLanguageId();
        const lineContent = try self._textModel.getLineContent(position.lineNumber);

        // Create the text as if `character` was inserted
        // FIXME: text is leaked
        var text = ArrayList(u8).init(allocator);
        try text.appendSlice(lineContent.items[0 .. position.column - 1]);
        try text.appendSlice(character);
        try text.appendSlice(lineContent.items[position.column - 1 ..]);

        const r = try safeTokenize(allocator, self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, lineStartState.?);
        var tokens = ArrayList(TokenPacked).init(allocator);
        try tokens.appendSlice(r.tokens);
        var lineTokens = LineTokens.init(tokens, text.items, self._languageIdCodec);
        defer lineTokens.deinit();
        if (lineTokens.getCount() == 0) {
            return StandardTokenType.Other;
        }

        const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1);
        return lineTokens.getStandardTokenType(tokenIndex);
    }

    // assumes state is up to date
    pub fn tokenizeLinesAt(self: *const Self, lineNumber: usize, lines: []const []const u8) !?ArrayList(LineTokens) {
        if (self.getStartState(lineNumber)) |lineStartState| {
            const allocator = self._textModel.getAllocator();
            const languageId = self._textModel.getLanguageId();
            var result = ArrayList(LineTokens).init(allocator);

            var state = lineStartState;
            for (lines) |line| {
                const r = try safeTokenize(allocator, self._languageIdCodec, languageId, self.tokenizationSupport, line, true, state);
                var tokens = ArrayList(TokenPacked).init(allocator);
                try tokens.appendSlice(r.tokens);
                try result.append(LineTokens.init(tokens, line, self._languageIdCodec));
                state = r.endState;
            }

            return result;
        } else {
            return null;
        }
    }

    pub fn hasAccurateTokensForLine(self: *const Self, lineNumber: usize) bool {
        const firstInvalidLineNumber = self.getStoreConst().getFirstInvalidEndStateLineNumberOrMax();
        return (lineNumber < firstInvalidLineNumber);
    }

    pub fn isCheapToTokenize(self: *const Self, lineNumber: usize) bool {
        const firstInvalidLineNumber = self.getStoreConst().getFirstInvalidEndStateLineNumberOrMax();
        if (lineNumber < firstInvalidLineNumber) {
            return true;
        }
        if (lineNumber == firstInvalidLineNumber and self._textModel.getLineLength(lineNumber) < CHEAP_TOKENIZATION_LENGTH_LIMIT) {
            return true;
        }

        return false;
    }

    // The result is not cached.
    pub fn tokenizeHeuristically(self: *Self, builder: *ContiguousMultilineTokensBuilder, startLineNumber: usize, endLineNumber: usize) !struct { heuristicTokens: bool } {
        if (endLineNumber <= self.getStoreConst().getFirstInvalidEndStateLineNumberOrMax()) {
            // nothing to do
            return .{ .heuristicTokens = false };
        }

        if (startLineNumber <= self.getStoreConst().getFirstInvalidEndStateLineNumberOrMax()) {
            // tokenization has reached the viewport start...
            try self.updateTokensUntilLine(builder, endLineNumber);
            return .{ .heuristicTokens = false };
        }

        const allocator = self._textModel.getAllocator();
        var state = try self.guessStartState(allocator, startLineNumber);
        const languageId = self._textModel.getLanguageId();

        for (startLineNumber..endLineNumber + 1) |lineNumber| {
            const text = try self._textModel.getLineContent(lineNumber);
            const r = try safeTokenize(allocator, self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, state);
            try builder.add(lineNumber, r.tokens);
            state = r.endState;
        }

        return .{ .heuristicTokens = true };
    }

    fn guessStartState(self: *Self, allocator: Allocator, lineNumber: usize) !IState {
        const res = try findLikelyRelevantLines(self._textModel, lineNumber, self.super);
        const likelyRelevantLines = res.likelyRelevantLines;
        defer likelyRelevantLines.deinit();
        var initialState = res.initialState;

        if (initialState == null) {
            initialState = try self.tokenizationSupport.getInitialState();
        }

        const languageId = self._textModel.getLanguageId();
        var state = initialState.?;
        for (likelyRelevantLines.items) |line| {
            defer line.deinit();
            const r = try safeTokenize(allocator, self._languageIdCodec, languageId, self.tokenizationSupport, line.items, false, state);
            state = r.endState;
        }
        return state;
    }
};

pub fn findLikelyRelevantLines(model: *TextModel, lineNumber: usize, _store: ?TokenizerWithStateStore) !struct { likelyRelevantLines: ArrayList(ArrayList(u8)), initialState: ?IState } {
    var nonWhitespaceColumn = try model.getLineFirstNonWhitespaceColumn(lineNumber);
    var likelyRelevantLines = ArrayList(ArrayList(u8)).init(model.getAllocator());
    var initialState: ?IState = null;
    var i = lineNumber - 1;
    while (nonWhitespaceColumn > 1 and i >= 1) : (i -= 1) {
        const newNonWhitespaceIndex = try model.getLineFirstNonWhitespaceColumn(i);
        // Ignore lines full of whitespace
        if (newNonWhitespaceIndex == 0) {
            continue;
        }
        if (newNonWhitespaceIndex < nonWhitespaceColumn) {
            try likelyRelevantLines.append(try model.getLineContent(i));
            nonWhitespaceColumn = newNonWhitespaceIndex;
            initialState = if (_store) |*store| store.getStartState(i) else null;
            if (initialState != null) {
                break;
            }
        }
    }

    std.mem.reverse(ArrayList(u8), likelyRelevantLines.items);
    return .{ .likelyRelevantLines = likelyRelevantLines, .initialState = initialState };
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
        try queue.addRange(OffsetRange.init(1, @as(isize, @intCast(lineCount + 1))));
        return Self{
            ._tokenizationStateStore = TokenizationStateStore.init(allocator),
            ._invalidEndStatesLineNumbers = queue,
            ._lineCount = lineCount,
        };
    }

    pub fn deinit(self: *TrackingTokenizationStateStore) void {
        self._invalidEndStatesLineNumbers.deinit();
        self._tokenizationStateStore.deinit();
    }

    pub fn getEndState(self: *const Self, lineNumber: usize) ?IState {
        return self._tokenizationStateStore.getEndState(lineNumber);
    }

    // @returns if the end state has changed.
    pub fn setEndState(self: *Self, lineNumber: usize, state: IState) !bool {
        try self._invalidEndStatesLineNumbers.delete(@intCast(lineNumber));
        const r = try self._tokenizationStateStore.setEndState(lineNumber, state);
        if (r and lineNumber < self._lineCount) {
            // because the state changed, we cannot trust the next state anymore and have to invalidate it.
            try self._invalidEndStatesLineNumbers.addRange(OffsetRange.init(@intCast(lineNumber + 1), @intCast(lineNumber + 2)));
        }

        return r;
    }

    pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) !void {
        self._lineCount = self._lineCount + newLineCount - range.length();
        try self._tokenizationStateStore.acceptChange(range, newLineCount);
        try self._invalidEndStatesLineNumbers.addRangeAndResize(OffsetRange.init(@intCast(range.startLineNumber), @intCast(range.endLineNumberExclusive)), @intCast(newLineCount));
    }

    pub fn acceptChanges(self: *Self, changes: []ModelContentChange) !void {
        for (changes) |c| {
            var reader = c.text.reader();
            const result = countEOL(&reader);
            try self.acceptChange(LineRange.init(c.range.startLineNumber, c.range.endLineNumber + 1), result.eolCount + 1);
        }
    }

    pub fn invalidateEndStateRange(self: *Self, range: LineRange) !void {
        try self._invalidEndStatesLineNumbers.addRange(OffsetRange.init(@intCast(range.startLineNumber), @intCast(range.endLineNumberExclusive)));
    }

    pub fn getFirstInvalidEndStateLineNumber(self: *const Self) ?usize {
        if (self._invalidEndStatesLineNumbers.min()) |min| {
            return @intCast(min);
        } else {
            return null;
        }
    }

    pub fn getFirstInvalidEndStateLineNumberOrMax(self: *const Self) usize {
        return self.getFirstInvalidEndStateLineNumber() orelse std.math.maxInt(usize);
    }

    pub fn allStatesValid(self: *const Self) bool {
        return self._invalidEndStatesLineNumbers.min() == null;
    }

    pub fn getStartState(self: *const Self, lineNumber: usize, initialState: IState) ?IState {
        if (lineNumber == 1) {
            return initialState;
        }
        return self.getEndState(lineNumber - 1);
    }

    pub fn getFirstInvalidLine(self: *const Self, initialState: IState) !?Pair(usize, IState) {
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

    pub fn init(allocator: Allocator) Self {
        return Self{
            ._lineEndStates = FixedArray(?IState).init(allocator, null),
        };
    }

    pub fn deinit(self: *Self) void {
        self._lineEndStates.deinit();
    }

    pub fn getEndState(self: *const Self, lineNumber: usize) ?IState {
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

    pub fn acceptChange(self: *Self, range: LineRange, _newLineCount: usize) !void {
        var newLineCount = _newLineCount;
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

fn safeTokenize(allocator: Allocator, languageIdCodec: *const LanguageIdCodec, languageId: []const u8, _tokenizationSupport: ?*ITokenizationSupport, text: []const u8, hasEOL: bool, state: IState) !EncodedTokenizationResult {
    const r: EncodedTokenizationResult = if (_tokenizationSupport) |tokenizationSupport|
        try tokenizationSupport.tokenizeEncoded(text, hasEOL, try state.clone(allocator))
    else
        nullTokenizeEncoded(languageIdCodec.encodeLanguageId(languageId), state);

    LineTokens.convertToEndOffset(r.tokens, @intCast(text.len));
    return r;
}

pub const DefaultBackgroundTokenizer = struct {
    interface: IBackgroundTokenizer,

    _isDisposed: bool = false,
    _isScheduled: bool = false,

    tokenizerWithStateStore: ?TokenizerWithStateStoreAndTextModel,
    backgroundTokenStore: *IBackgroundTokenizationStore,

    const Self = @This();

    pub fn init(tokenizerWithStateStore: ?TokenizerWithStateStoreAndTextModel, backgroundTokenStore: *IBackgroundTokenizationStore) Self {
        return .{
            .tokenizerWithStateStore = tokenizerWithStateStore,
            .backgroundTokenStore = backgroundTokenStore,
            .interface = .{
                .vtable = &.{
                    .requestTokens = requestTokens,
                    .reportMismatchingTokens = null,
                    .destroy = destroy,
                },
            },
        };
    }

    fn destroy(b: *IBackgroundTokenizer, allocator: Allocator) void {
        const self = getSelf(b);
        self.backgroundTokenStore.destroy(allocator);
        allocator.destroy(self);
    }

    pub fn dispose(self: *Self) void {
        self._isDisposed = true;
    }

    pub fn handleChanges(self: *Self) void {
        self._beginBackgroundTokenization();
    }

    fn _beginBackgroundTokenization(self: *Self) void {
        if (self._isScheduled or !self.tokenizerWithStateStore.?._textModel.isAttachedToEditor() or !self._hasLinesToTokenize()) {
            return;
        }

        // self._isScheduled = true;
        // runWhenGlobalIdle(self, struct {
        //     fn callback(deadline: IdleDeadline, this: *Self) void {
        //         this._isScheduled = false;
        //         this._backgroundTokenizeWithDeadline(deadline);
        //     }
        // }.callback);
    }

    // Tokenize until the deadline occurs, but try to yield every 1-2ms.
    fn _backgroundTokenizeWithDeadline(self: *Self, deadline: IdleDeadline) void {
        // Read the time remaining from the `deadline` immediately because it is unclear
        // if the `deadline` object will be valid after execution leaves this function.
        const now = std.time.timestamp();
        const endTime = now + deadline.timeRemaining();

        if (self._isDisposed or !self.tokenizerWithStateStore.?.textModel().isAttachedToEditor() or !self._hasLinesToTokenize()) {
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
        const lineCount = self.tokenizerWithStateStore.?.textModel().getLineCount();
        const builder = ContiguousMultilineTokensBuilder.init();
        const sw = StopWatch.init();

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

        self.backgroundTokenStore.setTokens(self.backgroundTokenStore, builder.finalize());
        self.checkFinished();
    }

    fn _hasLinesToTokenize(self: *Self) bool {
        if (self.tokenizerWithStateStore) |tokenizerWithStateStore| {
            return !tokenizerWithStateStore.getStoreConst().allStatesValid();
        }
        return false;
    }

    fn _tokenizeOneInvalidLine(self: *Self, builder: ContiguousMultilineTokensBuilder) usize {
        const firstInvalidLine = self.tokenizerWithStateStore.?.getFirstInvalidLine();
        if (!firstInvalidLine) {
            return self.tokenizerWithStateStore.?.textModel().getLineCount() + 1; // TODO: this is wrong
        }
        self.tokenizerWithStateStore.?.updateTokensUntilLine(builder, firstInvalidLine.lineNumber);
        return firstInvalidLine.lineNumber;
    }

    pub fn checkFinished(self: *Self) void {
        if (self._isDisposed) {
            return;
        }
        if (self.tokenizerWithStateStore.?.getStoreConst().allStatesValid()) {
            self.backgroundTokenStore.backgroundTokenizationFinished();
        }
    }

    fn getSelf(self: *IBackgroundTokenizer) *Self {
        return @alignCast(@fieldParentPtr("interface", self));
    }

    fn requestTokens(b: *IBackgroundTokenizer, startLineNumber: usize, endLineNumberExclusive: usize) !void {
        var self = getSelf(b);
        var store = self.tokenizerWithStateStore.?.getStore();
        try store.invalidateEndStateRange(LineRange.init(startLineNumber, endLineNumberExclusive));
    }
};

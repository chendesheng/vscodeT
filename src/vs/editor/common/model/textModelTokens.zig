const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Pair = @import("../../../base/common/utils.zig").Pair;
const pair = @import("../../../base/common/utils.zig").pair;
const RangePriorityQueue = @import("../core/ranges/rangePriorityQueue.zig");
const OffsetRange = @import("../core/ranges/offsetRange.zig").OffsetRange;
const countEOL = @import("../core/misc/eolCounter.zig").countEOL;
const LineRange = @import("../core/ranges/lineRange.zig").LineRange;
const ModelContentChange = @import("../model.zig").ModelContentChange;
const FixedArray = @import("./fixedArray.zig").FixedArray;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const TextModel = @import("./textModel.zig").TextModel;
const Position = @import("../core/position.zig").Position;
const ContiguousMultilineTokensBuilder = @import("../tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const IState = @import("../languages.zig").IState;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const nullTokenizeEncoded = @import("../languages/nullTokenize.zig").nullTokenizeEncoded;
const StopWatch = @import("../../../base/common/stopwatch.zig").StopWatch;
const IBackgroundTokenizationStore = @import("../languages.zig").IBackgroundTokenizationStore;

const CHEAP_TOKENIZATION_LENGTH_LIMIT = 2048;

pub const TokenizerWithStateStore = struct {
    const Self = @This();

    initialState: IState,
    store: TrackingTokenizationStateStore,
    arena: *std.heap.ArenaAllocator,
    allocator: Allocator,

    pub fn init(allocator: Allocator, lineCount: usize, tokenizationSupport: ITokenizationSupport) !Self {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const initial_state = try tokenizationSupport.getInitialState(arena.allocator());
        return Self{
            .initialState = initial_state,
            .store = try TrackingTokenizationStateStore.init(allocator, lineCount),
            .arena = arena,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.store.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn stateAllocator(self: *Self) Allocator {
        return self.arena.allocator();
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
    _textModel: *anyopaque,
    _languageIdCodec: *LanguageIdCodec,

    pub fn init(lineCount: usize, tokenizationSupport: ITokenizationSupport, textModel_: *TextModel, languageIdCodec: *LanguageIdCodec) !Self {
        return Self{
            .super = try TokenizerWithStateStore.init(textModel_.getAllocator(), lineCount, tokenizationSupport),
            .lineCount = lineCount,
            .tokenizationSupport = tokenizationSupport,
            ._textModel = textModel_,
            ._languageIdCodec = languageIdCodec,
        };
    }

    pub fn deinit(self: *Self) void {
        self.super.deinit();
    }

    pub fn getStartState(self: *Self, lineNumber: usize) ?IState {
        return self.super.getStartState(lineNumber);
    }

    pub fn getFirstInvalidLine(self: *Self) !?Pair(usize, IState) {
        return self.super.getFirstInvalidLine();
    }

    pub fn getStore(self: *Self) *TrackingTokenizationStateStore {
        return &self.super.store;
    }

    pub fn getInitialState(self: *Self) IState {
        return self.super.initialState;
    }

    fn textModel(self: *Self) *TextModel {
        return @ptrCast(@alignCast(self._textModel));
    }

    pub fn updateTokensUntilLine(self: *Self, builder: *ContiguousMultilineTokensBuilder, lineNumber: usize) !void {
        const languageId = self.textModel().getLanguageId();
        const allocator = self.super.stateAllocator();

        while (true) {
            const lineToTokenize = try self.getFirstInvalidLine() orelse break;
            if (lineToTokenize.first > lineNumber) break;

            var text = try self.textModel().getLineContent(lineToTokenize.first);
            defer text.deinit();

            const r = try safeTokenize(allocator, self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, lineToTokenize.second);
            try builder.add(lineToTokenize.first, r.tokens);
            _ = try self.getStore().setEndState(lineToTokenize.first, r.endState);
        }
    }

    /// Assumes the tokenization state is up to date.
    pub fn getTokenTypeIfInsertingCharacter(self: *Self, position: Position, character: []const u8) !StandardTokenType {
        const lineStartState = self.getStartState(position.lineNumber) orelse return StandardTokenType.Other;

        const languageId = self.textModel().getLanguageId();
        var lineContent = try self.textModel().getLineContent(position.lineNumber);
        defer lineContent.deinit();

        var text = ArrayList(u8).init(self.textModel().getAllocator());
        errdefer text.deinit();
        try text.appendSlice(lineContent.items[0 .. position.column - 1]);
        try text.appendSlice(character);
        try text.appendSlice(lineContent.items[position.column - 1 ..]);

        const allocator = self.super.stateAllocator();
        const r = try safeTokenize(allocator, self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, lineStartState);

        var tokens = ArrayList(TokenPacked).init(self.textModel().getAllocator());
        errdefer tokens.deinit();
        try tokens.appendSlice(r.tokens);
        var lineTokens = LineTokens.init(tokens, text, self._languageIdCodec);
        defer lineTokens.deinit();

        if (lineTokens.getCount() == 0) return StandardTokenType.Other;
        const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1);
        return lineTokens.getStandardTokenType(tokenIndex);
    }

    /// Assumes the tokenization state is up to date.
    pub fn tokenizeLinesAt(self: *Self, lineNumber: usize, lines: []const []const u8) !?ArrayList(LineTokens) {
        const lineStartState = self.getStartState(lineNumber) orelse return null;

        const allocator = self.textModel().getAllocator();
        const languageId = self.textModel().getLanguageId();
        var result = ArrayList(LineTokens).init(allocator);
        errdefer {
            for (result.items) |*lineTokens| lineTokens.deinit();
            result.deinit();
        }

        var state = lineStartState;
        for (lines) |line| {
            const r = try safeTokenize(self.super.stateAllocator(), self._languageIdCodec, languageId, self.tokenizationSupport, line, true, state);
            var tokens = ArrayList(TokenPacked).init(allocator);
            errdefer tokens.deinit();
            try tokens.appendSlice(r.tokens);
            var text = ArrayList(u8).init(allocator);
            errdefer text.deinit();
            try text.appendSlice(line);
            try result.append(LineTokens.init(tokens, text, self._languageIdCodec));
            state = r.endState;
        }

        return result;
    }

    pub fn hasAccurateTokensForLine(self: *Self, lineNumber: usize) bool {
        return lineNumber < self.getStore().getFirstInvalidEndStateLineNumberOrMax();
    }

    pub fn isCheapToTokenize(self: *Self, lineNumber: usize) bool {
        const firstInvalidLineNumber = self.getStore().getFirstInvalidEndStateLineNumberOrMax();
        if (lineNumber < firstInvalidLineNumber) return true;
        if (lineNumber == firstInvalidLineNumber and self.textModel().getLineLength(lineNumber) < CHEAP_TOKENIZATION_LENGTH_LIMIT) return true;
        return false;
    }

    pub fn tokenizeHeuristically(self: *Self, builder: *ContiguousMultilineTokensBuilder, startLineNumber: usize, endLineNumber: usize) !struct { heuristicTokens: bool } {
        if (endLineNumber <= self.getStore().getFirstInvalidEndStateLineNumberOrMax()) {
            return .{ .heuristicTokens = false };
        }

        if (startLineNumber <= self.getStore().getFirstInvalidEndStateLineNumberOrMax()) {
            try self.updateTokensUntilLine(builder, endLineNumber);
            return .{ .heuristicTokens = false };
        }

        var state = try self.guessStartState(startLineNumber);
        const languageId = self.textModel().getLanguageId();

        var lineNumber = startLineNumber;
        while (lineNumber <= endLineNumber) : (lineNumber += 1) {
            var text = try self.textModel().getLineContent(lineNumber);
            defer text.deinit();
            const r = try safeTokenize(self.super.stateAllocator(), self._languageIdCodec, languageId, self.tokenizationSupport, text.items, true, state);
            try builder.add(lineNumber, r.tokens);
            state = r.endState;
        }

        return .{ .heuristicTokens = true };
    }

    fn guessStartState(self: *Self, lineNumber: usize) !IState {
        const res = try findLikelyRelevantLines(self.textModel(), lineNumber, &self.super);
        var likelyRelevantLines = res.likelyRelevantLines;
        defer {
            for (likelyRelevantLines.items) |*line| line.deinit();
            likelyRelevantLines.deinit();
        }
        const initialState = res.initialState;

        const languageId = self.textModel().getLanguageId();
        var state = initialState orelse (self.tokenizationSupport.getInitialState(self.super.stateAllocator()) catch return error.StartStateMustBeDefined);
        for (likelyRelevantLines.items) |line| {
            const r = try safeTokenize(self.super.stateAllocator(), self._languageIdCodec, languageId, self.tokenizationSupport, line.items, false, state);
            state = r.endState;
        }
        return state;
    }
};

pub fn findLikelyRelevantLines(model: *TextModel, lineNumber: usize, _store: ?*TokenizerWithStateStore) !struct { likelyRelevantLines: ArrayList(ArrayList(u8)), initialState: ?IState } {
    var nonWhitespaceColumn = try model.getLineFirstNonWhitespaceColumn(lineNumber);
    var likelyRelevantLines = ArrayList(ArrayList(u8)).init(model.getAllocator());
    errdefer {
        for (likelyRelevantLines.items) |*line| line.deinit();
        likelyRelevantLines.deinit();
    }
    var initialState: ?IState = null;
    var i = lineNumber - 1;
    while (nonWhitespaceColumn > 1 and i >= 1) : (i -= 1) {
        const newNonWhitespaceIndex = try model.getLineFirstNonWhitespaceColumn(i);
        if (newNonWhitespaceIndex == 0) continue;
        if (newNonWhitespaceIndex < nonWhitespaceColumn) {
            try likelyRelevantLines.append(try model.getLineContent(i));
            nonWhitespaceColumn = newNonWhitespaceIndex;
            initialState = if (_store) |store| store.getStartState(i) else null;
            if (initialState != null) break;
        }
    }

    std.mem.reverse(ArrayList(u8), likelyRelevantLines.items);
    return .{ .likelyRelevantLines = likelyRelevantLines, .initialState = initialState };
}

pub const TrackingTokenizationStateStore = struct {
    const Self = @This();

    _tokenizationStateStore: TokenizationStateStore,
    _invalidEndStatesLineNumbers: RangePriorityQueue,
    _lineCount: usize,

    pub fn init(allocator: Allocator, lineCount: usize) !Self {
        var queue = RangePriorityQueue.init(allocator);
        errdefer queue.deinit();
        try queue.addRange(OffsetRange.init(1, lineCount + 1));
        return .{
            ._tokenizationStateStore = TokenizationStateStore.init(allocator),
            ._invalidEndStatesLineNumbers = queue,
            ._lineCount = lineCount,
        };
    }

    pub fn deinit(self: *Self) void {
        self._tokenizationStateStore.deinit();
        self._invalidEndStatesLineNumbers.deinit();
    }

    pub fn getEndState(self: *Self, lineNumber: usize) ?IState {
        return self._tokenizationStateStore.getEndState(lineNumber);
    }

    pub fn setEndState(self: *Self, lineNumber: usize, state: IState) !bool {
        try self._invalidEndStatesLineNumbers.delete(lineNumber);
        const changed = try self._tokenizationStateStore.setEndState(lineNumber, state);
        if (changed and lineNumber < self._lineCount) {
            try self._invalidEndStatesLineNumbers.addRange(OffsetRange.init(lineNumber + 1, lineNumber + 2));
        }
        return changed;
    }

    pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) !void {
        self._lineCount = self._lineCount + newLineCount - range.length();
        try self._tokenizationStateStore.acceptChange(range, newLineCount);
        try self._invalidEndStatesLineNumbers.addRangeAndResize(OffsetRange.init(range.startLineNumber, range.endLineNumberExclusive), newLineCount);
    }

    pub fn acceptChanges(self: *Self, changes: []ModelContentChange) !void {
        for (changes) |c| {
            const result = countEOL(c.text.items());
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
        if (lineNumber == 1) return initialState;
        return self.getEndState(lineNumber - 1);
    }

    pub fn getFirstInvalidLine(self: *Self, initialState: IState) !?Pair(usize, IState) {
        if (self.getFirstInvalidEndStateLineNumber()) |lineNumber| {
            const startState = self.getStartState(lineNumber, initialState) orelse return error.StartStateMustBeDefined;
            return pair(lineNumber, startState);
        }
        return null;
    }
};

pub const TokenizationStateStore = struct {
    const Self = @This();
    _lineEndStates: FixedArray(?IState),

    pub fn init(allocator: Allocator) Self {
        return .{ ._lineEndStates = FixedArray(?IState).init(allocator, null) };
    }

    pub fn deinit(self: *Self) void {
        self._lineEndStates.deinit();
    }

    pub fn getEndState(self: *Self, lineNumber: usize) ?IState {
        return self._lineEndStates.get(lineNumber);
    }

    pub fn setEndState(self: *Self, lineNumber: usize, state: IState) !bool {
        if (self._lineEndStates.get(lineNumber)) |oldState| {
            if (oldState.equals(state)) return false;
        }
        try self._lineEndStates.set(lineNumber, state);
        return true;
    }

    pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) !void {
        var len = range.length();
        var new_line_count = newLineCount;
        if (new_line_count > 0 and len > 0) {
            len -= 1;
            new_line_count -= 1;
        }
        try self._lineEndStates.replace(range.startLineNumber, len, new_line_count);
    }

    pub fn acceptChanges(self: *Self, changes: []ModelContentChange) !void {
        for (changes) |c| {
            const result = countEOL(c.text.items());
            try self.acceptChange(LineRange.init(c.range.startLineNumber, c.range.endLineNumber + 1), result.eolCount + 1);
        }
    }
};

fn safeTokenize(allocator: Allocator, languageIdCodec: *LanguageIdCodec, languageId: []const u8, tokenizationSupport: ITokenizationSupport, text: []const u8, hasEOL: bool, state: IState) !EncodedTokenizationResult {
    var r: ?EncodedTokenizationResult = tokenizationSupport.tokenizeEncoded(allocator, text, hasEOL, state) catch null;
    if (r == null) {
        r = try nullTokenizeEncoded(allocator, @fromBackingInt(@intCast(try languageIdCodec.encodeLanguageId(languageId))), state);
    }
    LineTokens.convertToEndOffset(r.?.tokens, text.len);
    return r.?;
}

pub const DefaultBackgroundTokenizer = struct {
    _isDisposed: bool = false,
    _isScheduled: bool = false,
    tokenizerWithStateStore: *TokenizerWithStateStoreAndTextModel,
    backgroundTokenStore: IBackgroundTokenizationStore,

    const BackgroundSelf = @This();

    pub fn init(tokenizerWithStateStore: *TokenizerWithStateStoreAndTextModel, backgroundTokenStore: IBackgroundTokenizationStore) BackgroundSelf {
        return .{ .tokenizerWithStateStore = tokenizerWithStateStore, .backgroundTokenStore = backgroundTokenStore };
    }

    pub fn dispose(self: *BackgroundSelf) void {
        self._isDisposed = true;
    }

    pub fn handleChanges(self: *BackgroundSelf) void {
        self._beginBackgroundTokenization();
    }

    fn _beginBackgroundTokenization(self: *BackgroundSelf) void {
        if (self._isDisposed or self._isScheduled or !self.tokenizerWithStateStore.textModel().isAttachedToEditor() or !self._hasLinesToTokenize()) {
            return;
        }
        self._isScheduled = true;
        defer self._isScheduled = false;
        self._backgroundTokenizeForAtLeast1ms();
        if (self._hasLinesToTokenize()) {
            self._beginBackgroundTokenization();
        }
    }

    fn _backgroundTokenizeForAtLeast1ms(self: *BackgroundSelf) void {
        const lineCount = self.tokenizerWithStateStore.textModel().getLineCount();
        var builder = ContiguousMultilineTokensBuilder.init(self.tokenizerWithStateStore.textModel().getAllocator());
        defer builder.deinit();
        const sw = StopWatch.init();

        while (true) {
            if (sw.elapsed() > 1) break;
            const tokenizedLineNumber = self._tokenizeOneInvalidLine(&builder) catch break;
            if (tokenizedLineNumber >= lineCount) break;
            if (!self._hasLinesToTokenize()) break;
        }

        self.backgroundTokenStore.setTokens(self.backgroundTokenStore.context, builder.finalize());
        self.checkFinished();
    }

    fn _hasLinesToTokenize(self: *BackgroundSelf) bool {
        return !self.tokenizerWithStateStore.getStore().allStatesValid();
    }

    fn _tokenizeOneInvalidLine(self: *BackgroundSelf, builder: *ContiguousMultilineTokensBuilder) !usize {
        const firstInvalidLine = try self.tokenizerWithStateStore.getFirstInvalidLine();
        if (firstInvalidLine == null) {
            return self.tokenizerWithStateStore.textModel().getLineCount() + 1;
        }
        try self.tokenizerWithStateStore.updateTokensUntilLine(builder, firstInvalidLine.?.first);
        return firstInvalidLine.?.first;
    }

    pub fn checkFinished(self: *BackgroundSelf) void {
        if (self._isDisposed) return;
        if (self.tokenizerWithStateStore.getStore().allStatesValid()) {
            self.backgroundTokenStore.backgroundTokenizationFinished(self.backgroundTokenStore.context);
        }
    }

    pub fn requestTokens(self: *BackgroundSelf, startLineNumber: usize, endLineNumberExclusive: usize) void {
        self.tokenizerWithStateStore.getStore().invalidateEndStateRange(LineRange.init(startLineNumber, endLineNumberExclusive)) catch {};
    }
};

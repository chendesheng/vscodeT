const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Pair = @import("./basics/utils.zig").Pair;
const RangePriorityQueue = @import("./basics/rangePriorityQueue.zig").RangePriorityQueue;
const OffsetRange = @import("./basics/offsetRange.zig").OffsetRange;
const countEOL = @import("./basics/eolCounter.zig").countEOL;
const LineRange = @import("./basics/lineRange.zig").LineRange;
const ModelContentChange = @import("model.zig").ModelContentChange;

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

pub fn TokenizationStateStore(comptime TState: type) type {
    return struct {
        const Self = @This();
        _lineEndStates: ArrayList(TState),

        pub fn init() Self {
            return Self{
                ._lineEndStates = ArrayList(TState).init(std.heap.page_allocator),
            };
        }

        pub fn getEndState(self: *Self, lineNumber: usize) ?TState {
            return self._lineEndStates.items[lineNumber];
        }

        pub fn setEndState(self: *Self, lineNumber: usize, state: TState) bool {
            const oldState = self._lineEndStates.items[lineNumber];
            if (oldState and oldState.equals(state)) {
                return false;
            }

            self._lineEndStates.items[lineNumber] = state;
            return true;
        }

        pub fn acceptChange(self: *Self, range: LineRange, newLineCount: usize) void {
            var length = range.length;
            if (newLineCount > 0 and length > 0) {
                // Keep the last state, even though it is unrelated.
                // But if the new state happens to agree with this last state, then we know we can stop tokenizing.
                length -= 1;
                newLineCount -= 1;
            }

            self._lineEndStates.replace(range.startLineNumber, length, newLineCount);
        }

        pub fn acceptChanges(self: *Self, changes: []ModelContentChange) void {
            for (changes) |c| {
                const result = countEOL(c.text);
                self.acceptChange(LineRange.init(c.range.startLineNumber, c.range.endLineNumber + 1), result.eolCount + 1);
            }
        }
    };
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
            return self._invalidEndStatesLineNumbers.min;
        }

        pub fn getFirstInvalidEndStateLineNumberOrMax(self: *Self) usize {
            return self.getFirstInvalidEndStateLineNumber() orelse std.math.maxInt(usize);
        }

        pub fn allStatesValid(self: *Self) bool {
            return self._invalidEndStatesLineNumbers.min == null;
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

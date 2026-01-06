const std = @import("std");
const AutoHashMap = std.AutoHashMap;
const ArrayList = std.array_list.Managed;
const Emitter = @import("../basics/event.zig").Emitter;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const Position = @import("../basics/position.zig").Position;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const IBackgroundTokenizer = @import("../languages.zig").IBackgroundTokenizer;
const IState = @import("../languages.zig").IState;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const IBackgroundTokenizationStore = @import("../languages.zig").IBackgroundTokenizationStore;
const ContiguousMultilineTokens = @import("../tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const ContiguousMultilineTokensBuilder = @import("../tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const ContiguousTokensStore = @import("../tokens/contiguousTokensStore.zig").ContiguousTokensStore;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const TokenizerWithStateStoreAndTextModel = @import("../textModel/textModelTokens.zig").TokenizerWithStateStoreAndTextModel;
const TrackingTokenizationStateStore = @import("../textModel/textModelTokens.zig").TrackingTokenizationStateStore;
const DefaultBackgroundTokenizer = @import("../textModel/textModelTokens.zig").DefaultBackgroundTokenizer;
const AbstractSyntaxTokenBackend = @import("./abstractSyntaxTokenBackend.zig").AbstractSyntaxTokenBackend;
const AttachedViewHandler = @import("./abstractSyntaxTokenBackend.zig").AttachedViewHandler;
const AttachedViews = @import("./abstractSyntaxTokenBackend.zig").AttachedViews;
const BackgroundTokenizationState = @import("./abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const TokenizationRegistry = @import("./tokenizationRegistry.zig").TokenizationRegistry;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const Pair = @import("../basics/utils.zig").Pair;
const AttachedView = @import("./abstractSyntaxTokenBackend.zig").AttachedView;
const AttachedViewState = @import("./abstractSyntaxTokenBackend.zig").AttachedViewState;
const LanguageConfigurationServiceChangeEvent = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationServiceChangeEvent;
const AttachedViewAndState = @import("./abstractSyntaxTokenBackend.zig").AttachedViewAndState;
const ModelTokensChangedRange = @import("../textModel/textModelEvents.zig").ModelTokensChangedRange;
const ModelContentChangedEvent = @import("../textModel/textModelEvents.zig").ModelContentChangedEvent;
const TokenizationSupportChangedEvent = @import("../languages.zig").TokenizationSupportChangedEvent;
const clamp = @import("../basics/utils.zig").clamp;
const LineRangeSet = @import("../basics/lineRange.zig").LineRangeSet;

// For TextMate
pub const TokenizerSyntaxTokenBackend = struct {
    super: AbstractSyntaxTokenBackend,

    _tokenizer: ?TokenizerWithStateStoreAndTextModel = null,
    _tokens: ContiguousTokensStore,
    _debugBackgroundTokens: ?ContiguousTokensStore = null,
    _debugBackgroundStates: ?TrackingTokenizationStateStore = null,
    _debugBackgroundTokenizer: ?IBackgroundTokenizer = null,
    _defaultBackgroundTokenizer: ?DefaultBackgroundTokenizer = null,
    // _backgroundTokenizer: ?IBackgroundTokenizer = null,
    _attachedViewStates: AutoHashMap(AttachedView, AttachedViewHandler),
    _languageId: []const u8,

    pub fn init(
        languageIdCodec: LanguageIdCodec,
        textModel: *TextModel,
        languageId: []const u8,
        attachedViews: *AttachedViews,
    ) !TokenizerSyntaxTokenBackend {
        const allocator = textModel.getAllocator();
        var self: TokenizerSyntaxTokenBackend = .{
            .super = AbstractSyntaxTokenBackend.init(BackgroundTokenizationState.InProgress, languageIdCodec, textModel),
            ._tokens = ContiguousTokensStore.init(allocator, languageIdCodec),
            ._languageId = languageId,
            ._attachedViewStates = AutoHashMap(AttachedView, AttachedViewHandler).init(allocator),
        };

        try TokenizationRegistry.instance.onDidChange(&self, struct {
            fn cb(e: TokenizationSupportChangedEvent, this: *TokenizerSyntaxTokenBackend) void {
                if (std.mem.indexOf(u8, e.changedLanguages, this._languageId) == null) {
                    return;
                }
                this.todo_resetTokenization(false) catch unreachable;
            }
        }.cb);

        try self.todo_resetTokenization(false);

        try attachedViews.onDidChangeVisibleRanges(&self, struct {
            fn cb(p: AttachedViewAndState, this: *TokenizerSyntaxTokenBackend) void {
                const view = p.first;
                const _state = p.second;
                if (_state) |state| {
                    var existing = this._attachedViewStates.get(view);
                    if (existing == null) {
                        existing = AttachedViewHandler.init(struct {
                            fn f(_: *const AttachedViewHandler) void {
                                // this.refreshRanges(handler._lineRanges);
                            }
                        }.f);
                        this._attachedViewStates.put(view, existing.?) catch unreachable;
                    }
                    existing.?.handleStateChange(state);
                } else {
                    _ = this._attachedViewStates.remove(view);
                }
            }
        }.cb);
        return self;
    }

    pub fn deinit(self: *TokenizerSyntaxTokenBackend) void {
        var iter = self._attachedViewStates.keyIterator();
        while (iter.next()) |view| {
            view.deinit();
        }
        self._attachedViewStates.deinit();
        self._tokens.deinit();
        // if (self._debugBackgroundTokens) |*debugBackgroundTokens| {
        //     debugBackgroundTokens.deinit();
        // }
        // if (self._debugBackgroundStates) |debugBackgroundStates| {
        //     debugBackgroundStates.deinit();
        // }
        // if (self._debugBackgroundTokenizer) |debugBackgroundTokenizer| {
        //     debugBackgroundTokenizer.deinit();
        // }
        // if (self._defaultBackgroundTokenizer) |defaultBackgroundTokenizer| {
        //     defaultBackgroundTokenizer.deinit();
        // }
        // if (self._backgroundTokenizer) |backgroundTokenizer| {
        //     backgroundTokenizer.deinit();
        // }
    }

    pub fn todo_resetTokenization(self: *TokenizerSyntaxTokenBackend, fireTokenChangeEvent: bool) !void {
        self._tokens.flush();
        // self._debugBackgroundTokens.?.flush();
        if (self._debugBackgroundStates != null) {
            self._debugBackgroundStates = try TrackingTokenizationStateStore.init(self.super._textModel.getAllocator(), self.super._textModel.getLineCount());
        }
        if (fireTokenChangeEvent) {
            self.super._onDidChangeTokens.fire(.{
                .semanticTokensApplied = false,
                .ranges = &[_]ModelTokensChangedRange{
                    .{
                        .fromLineNumber = 1,
                        .toLineNumber = self.super._textModel.getLineCount(),
                    },
                },
            });
        }

        var tokenizationSupport: ?ITokenizationSupport = null;
        var initialState: ?IState = null;
        if (!self.super._textModel.isTooLargeForTokenization()) {
            tokenizationSupport = TokenizationRegistry.instance.get(self._languageId);
            if (tokenizationSupport != null) {
                initialState = tokenizationSupport.?.getInitialState();
            }
        }

        if (tokenizationSupport != null and initialState != null) {
            self._tokenizer = try TokenizerWithStateStoreAndTextModel.init(
                self.super._textModel.getLineCount(),
                tokenizationSupport.?,
                self.super._textModel,
                self.super._languageIdCodec,
            );
        } else {
            self._tokenizer = null;
        }

        // if (self._backgroundTokenizer) |backgroundTokenizer| {
        //     backgroundTokenizer.clear();
        // }

        self._defaultBackgroundTokenizer = null;
        if (self._tokenizer != null) {
            // const b: IBackgroundTokenizationStore = .{
            //     .setTokens = struct {
            //         fn f(tokens: []ContiguousMultilineTokens) void {
            //             self.setTokens(tokens);
            //         }
            //     }.f,
            //     .backgroundTokenizationFinished = struct {
            //         fn f() void {
            //             if (self.super._backgroundTokenizationState == BackgroundTokenizationState.Completed) {
            //                 // We already did a full tokenization and don't go back to progressing.
            //                 return;
            //             }
            //             const newState = BackgroundTokenizationState.Completed;
            //             self.super._backgroundTokenizationState = newState;
            //             self.super._onDidChangeBackgroundTokenizationState.fire(.{});
            //         }
            //     }.f,
            //     .setEndState = struct {
            //         fn f(lineNumber: usize, state: IState) void {
            //             if (self._tokenizer) |tokenizer| {
            //                 const firstInvalidEndStateLineNumber = tokenizer.store.getFirstInvalidEndStateLineNumber();
            //                 // Don't accept states for definitely valid states, the renderer is ahead of the worker!
            //                 if (firstInvalidEndStateLineNumber != null and lineNumber >= firstInvalidEndStateLineNumber) {
            //                     tokenizer.store.setEndState(lineNumber, state);
            //                 }
            //             }
            //         }
            //     }.f,
            // };

            // if (tokenizationSupport != null and tokenizationSupport.?.createBackgroundTokenizer and !tokenizationSupport.?.backgroundTokenizerShouldOnlyVerifyTokens) {
            // self._backgroundTokenizer = tokenizationSupport.?.createBackgroundTokenizer(self.super.textModel(), b);
            // }
            // if (self._backgroundTokenizer == null and !self.super._textModel.isTooLargeForTokenization()) {
            // self._defaultBackgroundTokenizer = DefaultBackgroundTokenizer.init(self._tokenizer, b);
            // self._backgroundTokenizer = self._defaultBackgroundTokenizer;
            // self._defaultBackgroundTokenizer.?.handleChanges();
            // }

            // if (tokenizationSupport != null and (tokenizationSupport.?.backgroundTokenizerShouldOnlyVerifyTokens orelse false) and tokenizationSupport.?.createBackgroundTokenizer != null) {
            //     self._debugBackgroundTokens = ContiguousTokensStore.init(self.super._textModel.getAllocator(), self._languageIdCodec);
            //     self._debugBackgroundStates = TrackingTokenizationStateStore(IState).init(self.super._textModel.getLineCount());
            //     self._debugBackgroundTokenizer.?.clear();
            //     self._debugBackgroundTokenizer = tokenizationSupport.?.createBackgroundTokenizer(self.super._textModel, .{
            //         .setTokens = struct {
            //             fn f(tokens: []ContiguousMultilineTokens) void {
            //                 self._debugBackgroundTokens.?.setMultilineTokens(tokens, self.super._textModel);
            //             }
            //         }.f,
            //         .backgroundTokenizationFinished = struct {
            //             fn f() void {
            //                 // NO OP
            //             }
            //         }.f,
            //         .setEndState = struct {
            //             fn f(lineNumber: usize, state: IState) void {
            //                 self._debugBackgroundStates.?.setEndState(lineNumber, state);
            //             }
            //         }.f,
            //     });
            // } else {
            //     self._debugBackgroundTokens = null;
            //     self._debugBackgroundStates = null;
            //     self._debugBackgroundTokenizer = null;
            // }
        }

        try self.refreshAllVisibleLineTokens();
    }

    pub fn handleDidChangeAttached(self: *TokenizerSyntaxTokenBackend) void {
        self._defaultBackgroundTokenizer.?.handleChanges();
    }

    pub fn handleDidChangeContent(self: *TokenizerSyntaxTokenBackend, e: ModelContentChangedEvent) !void {
        if (e.isFlush) {
            // Don't fire the event, as the view might not have got the text change event yet
            try self.todo_resetTokenization(false);
        } else if (!e.isEolChange) { // We don't have to do anything on an EOL change
            for (e.changes.items) |c| {
                var reader = c.text.reader();
                const res = countEOL(&reader);
                const eolCount = res.eolCount;
                const firstLineLength = res.firstLineLength;

                try self._tokens.acceptEdit(c.range, eolCount, firstLineLength);
                if (self._debugBackgroundTokens) |*debugBackgroundTokens| {
                    try debugBackgroundTokens.acceptEdit(c.range, eolCount, firstLineLength);
                }
            }

            if (self._debugBackgroundStates) |*debugBackgroundStates| {
                try debugBackgroundStates.acceptChanges(e.changes.items);
            }

            if (self._tokenizer) |tokenizer| {
                var store = tokenizer.getStore();
                try store.acceptChanges(e.changes.items);
            }

            if (self._defaultBackgroundTokenizer) |*defaultBackgroundTokenizer| {
                defaultBackgroundTokenizer.handleChanges();
            }
        }
    }

    pub fn setTokens(self: *TokenizerSyntaxTokenBackend, tokens: []ContiguousMultilineTokens) !struct { changes: []const ModelTokensChangedRange } {
        const res = try self._tokens.setMultilineTokens(tokens, self.super._textModel);
        const changes = res.changes;

        if (changes.len > 0) {
            self.super._onDidChangeTokens.fire(.{
                .semanticTokensApplied = false,
                .ranges = changes,
            });
        }

        return .{ .changes = changes };
    }

    pub fn refreshAllVisibleLineTokens(self: *TokenizerSyntaxTokenBackend) !void {
        var set = LineRangeSet.empty(self.super._textModel.getAllocator());
        defer set.deinit();

        var iter = self._attachedViewStates.valueIterator();
        while (iter.next()) |handler| {
            for (handler._lineRanges) |range| {
                try set.addRange(range);
            }
        }

        try self.refreshRanges(set.ranges());
    }

    pub fn refreshRanges(self: *TokenizerSyntaxTokenBackend, ranges: []const LineRange) !void {
        for (ranges) |range| {
            try self.refreshRange(range.startLineNumber, range.endLineNumberExclusive - 1);
        }
    }

    pub fn refreshRange(self: *TokenizerSyntaxTokenBackend, startLineNumber: usize, endLineNumber: usize) !void {
        if (self._tokenizer) |*tokenizer| {
            const startLineNumber1 = clamp(startLineNumber, 1, self.super._textModel.getLineCount());
            const endLineNumber1 = clamp(endLineNumber, 1, self.super._textModel.getLineCount());

            var builder = ContiguousMultilineTokensBuilder.init(self.super._textModel.getAllocator());
            const res = try tokenizer.tokenizeHeuristically(&builder, startLineNumber1, endLineNumber1);
            const heuristicTokens = res.heuristicTokens;
            const changedTokens = try self.setTokens(builder.finalize().items);

            if (heuristicTokens) {
                // We overrode tokens with heuristically computed ones.
                // Because old states might get reused (thus stopping invalidation),
                // we have to explicitly request the tokens for the changed ranges again.
                for (changedTokens.changes) |c| {
                    _ = c;
                    // if (self._backgroundTokenizer) |backgroundTokenizer| {
                    //     backgroundTokenizer.requestTokens(c.fromLineNumber, c.toLineNumber + 1);
                    // }
                }
            }

            self._defaultBackgroundTokenizer.?.checkFinished();
        }
    }

    pub fn forceTokenization(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) !void {
        var builder = ContiguousMultilineTokensBuilder.init();
        if (self._tokenizer) |tokenizer| {
            try tokenizer.updateTokensUntilLine(&builder, lineNumber);
        }
        try self.setTokens(builder.finalize());
        self._defaultBackgroundTokenizer.?.checkFinished();
    }

    pub fn hasAccurateTokensForLine(self: *const TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
        if (self._tokenizer) |tokenizer| {
            return tokenizer.hasAccurateTokensForLine(lineNumber);
        }
        return true;
    }

    pub fn isCheapToTokenize(self: *const TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
        if (self._tokenizer) |tokenizer| {
            return tokenizer.isCheapToTokenize(lineNumber);
        }
        return true;
    }

    pub fn getLineTokens(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) !LineTokens {
        const lineText = try self.super._textModel.getLineContent(lineNumber);
        defer lineText.deinit();
        const result = try self._tokens.getTokens(self.super._textModel.getLanguageId(), lineNumber - 1, lineText.items);
        if (self._debugBackgroundTokens) |debugBackgroundTokens| {
            if (self._debugBackgroundStates) |debugBackgroundStates| {
                if (self._tokenizer) |tokenizer| {
                    if (debugBackgroundStates.getFirstInvalidEndStateLineNumberOrMax() > lineNumber and tokenizer.getStore().getFirstInvalidEndStateLineNumberOrMax() > lineNumber) {
                        const backgroundResult = try debugBackgroundTokens.getTokens(self.super._textModel.getLanguageId(), lineNumber - 1, lineText.items);
                        if (!result.equals(&backgroundResult)) {
                            if (self._debugBackgroundTokenizer) |debugBackgroundTokenizer| {
                                if (debugBackgroundTokenizer.reportMismatchingTokens) |reportMismatchingTokens| {
                                    reportMismatchingTokens(lineNumber);
                                }
                            }
                        }
                    }
                }
            }
        }
        return result;
    }

    pub fn getTokenTypeIfInsertingCharacter(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, column: usize, character: []const u8) StandardTokenType {
        if (self._tokenizer) |tokenizer| {
            const position = self.super._textModel.validatePosition(Position.init(lineNumber, column));
            try self.forceTokenization(position.lineNumber);
            return tokenizer.getTokenTypeIfInsertingCharacter(position, character);
        } else {
            return StandardTokenType.Other;
        }
    }

    pub fn tokenizeLinesAt(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, lines: []const []const u8) ?[]LineTokens {
        if (self._tokenizer) |tokenizer| {
            try self.forceTokenization(lineNumber);
            if (try tokenizer.tokenizeLinesAt(lineNumber, lines)) |tokens| {
                return tokens.items;
            } else {
                return null;
            }
        } else {
            return null;
        }
    }

    pub fn getHasTokens(self: *const TokenizerSyntaxTokenBackend) bool {
        return self._tokens.hasTokens();
    }
};

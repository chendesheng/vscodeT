const std = @import("std");
const AutoHashMap = std.AutoHashMap;
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
const TextModel = @import("../textModel.zig").TextModel;
const TokenizerWithStateStoreAndTextModel = @import("../textModelTokens.zig").TokenizerWithStateStoreAndTextModel;
const TrackingTokenizationStateStore = @import("../textModelTokens.zig").TrackingTokenizationStateStore;
const AbstractSyntaxTokenBackend = @import("./abstractSyntaxTokenBackend.zig").AbstractSyntaxTokenBackend;
const AttachedViewHandler = @import("./abstractSyntaxTokenBackend.zig").AttachedViewHandler;
const AttachedViews = @import("./abstractSyntaxTokenBackend.zig").AttachedViews;
const BackgroundTokenizationState = @import("./abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const TokenizationRegistry = @import("./tokenizationRegistry.zig").TokenizationRegistry;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const Pair = @import("../basics/utils.zig").Pair;
const AttachedView = @import("./abstractSyntaxTokenBackend.zig").AttachedView;
const AttachedViewState = @import("./abstractSyntaxTokenBackend.zig").AttachedViewState;
const DefaultBackgroundTokenizer = @import("../textModelTokens.zig").DefaultBackgroundTokenizer;
const LanguageConfigurationServiceChangeEvent = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationServiceChangeEvent;
const AttachedViewAndState = @import("./abstractSyntaxTokenBackend.zig").AttachedViewAndState;
const ModelTokensChangedRange = @import("../textModelEvents.zig").ModelTokensChangedRange;
const ModelContentChangedEvent = @import("../textModelEvents.zig").ModelContentChangedEvent;
const TokenizationSupportChangedEvent = @import("../languages.zig").TokenizationSupportChangedEvent;

// For TextMate
pub const TokenizerSyntaxTokenBackend = struct {
    _tokenizer: ?TokenizerWithStateStoreAndTextModel = null,
    _backgroundTokenizationState: BackgroundTokenizationState,
    _onDidChangeBackgroundTokenizationState: Emitter(void),

    _defaultBackgroundTokenizer: ?DefaultBackgroundTokenizer = null,
    _backgroundTokenizer: IBackgroundTokenizer,

    _tokens: ContiguousTokensStore,
    _debugBackgroundTokens: ?ContiguousTokensStore = null,
    _debugBackgroundStates: ?TrackingTokenizationStateStore(IState) = null,

    _debugBackgroundTokenizer: ?IBackgroundTokenizer,

    _attachedViewStates: AutoHashMap(AttachedView, AttachedViewHandler),

    _languageIdCodec: LanguageIdCodec,
    _textModel: TextModel,

    getLanguageId: fn () []const u8,

    pub fn init(
        languageIdCodec: LanguageIdCodec,
        textModel: TextModel,
        getLanguageId: fn () []const u8,
        attachedViews: AttachedViews,
    ) TokenizerSyntaxTokenBackend {
        var self: TokenizerSyntaxTokenBackend = .{
            ._languageIdCodec = languageIdCodec,
            ._textModel = textModel,
            ._tokens = ContiguousTokensStore.init(textModel.getAllocator(), languageIdCodec),
            ._onDidChangeBackgroundTokenizationState = Emitter(void).init(),
            ._backgroundTokenizer = null,
            ._backgroundTokenizationState = BackgroundTokenizationState.InProgress,
            .getLanguageId = getLanguageId,
        };

        TokenizationRegistry.onDidChange(&self, struct {
            fn cb(e: TokenizationSupportChangedEvent, this: *TokenizerSyntaxTokenBackend) void {
                const languageId = this.getLanguageId();
                if (!std.mem.indexOf(u8, e.changedLanguages, languageId)) {
                    return;
                }
                this.todo_resetTokenization();
            }
        }.cb);

        self.todo_resetTokenization();

        attachedViews.onDidChangeVisibleRanges(&self, struct {
            fn cb(p: AttachedViewAndState, this: *TokenizerSyntaxTokenBackend) void {
                const view = p.first;
                const state = p.second;
                if (state) {
                    var existing = this._attachedViewStates.get(view);
                    if (existing == null) {
                        existing = AttachedViewHandler.init(struct {
                            fn f(handler: AttachedViewHandler) void {
                                this.refreshRanges(handler._lineRanges);
                            }
                        }.f);
                        this._attachedViewStates.set(view, existing);
                    }
                    existing.handleStateChange(state);
                } else {
                    this._attachedViewStates.deleteAndDispose(view);
                }
            }
        }.cb);
        return self;
    }

    pub fn todo_resetTokenization(self: *TokenizerSyntaxTokenBackend, fireTokenChangeEvent: bool) void {
        self._tokens.flush();
        self._debugBackgroundTokens.?.flush();
        if (self._debugBackgroundStates) {
            self._debugBackgroundStates = TrackingTokenizationStateStore(IState).init(self._textModel.getLineCount());
        }
        if (fireTokenChangeEvent) {
            self._onDidChangeTokens.fire(.{
                .semanticTokensApplied = false,
                .ranges = &[_]ModelTokensChangedRange{
                    .{
                        .fromLineNumber = 1,
                        .toLineNumber = self._textModel.getLineCount(),
                    },
                },
            });
        }

        var tokenizationSupport: ?ITokenizationSupport = null;
        var initialState: ?IState = null;
        if (!self._textModel.isTooLargeForTokenization()) {
            tokenizationSupport = TokenizationRegistry.get(self.getLanguageId());
            if (tokenizationSupport) {
                initialState = tokenizationSupport.getInitialState();
            }
        }

        if (tokenizationSupport != null and initialState != null) {
            self._tokenizer = TokenizerWithStateStoreAndTextModel.init(self._textModel.getLineCount(), tokenizationSupport.?, self._textModel, self._languageIdCodec);
        } else {
            self._tokenizer = null;
        }

        self._backgroundTokenizer.clear();

        self._defaultBackgroundTokenizer = null;
        if (self._tokenizer != null) {
            const b: IBackgroundTokenizationStore = .{
                .setTokens = struct {
                    fn f(tokens: []ContiguousMultilineTokens) void {
                        self.setTokens(tokens);
                    }
                }.f,
                .backgroundTokenizationFinished = struct {
                    fn f() void {
                        if (self._backgroundTokenizationState == BackgroundTokenizationState.Completed) {
                            // We already did a full tokenization and don't go back to progressing.
                            return;
                        }
                        const newState = BackgroundTokenizationState.Completed;
                        self._backgroundTokenizationState = newState;
                        self._onDidChangeBackgroundTokenizationState.fire(.{});
                    }
                }.f,
                .setEndState = struct {
                    fn f(lineNumber: usize, state: IState) void {
                        if (self._tokenizer) |tokenizer| {
                            const firstInvalidEndStateLineNumber = tokenizer.store.getFirstInvalidEndStateLineNumber();
                            // Don't accept states for definitely valid states, the renderer is ahead of the worker!
                            if (firstInvalidEndStateLineNumber != null and lineNumber >= firstInvalidEndStateLineNumber) {
                                tokenizer.store.setEndState(lineNumber, state);
                            }
                        }
                    }
                }.f,
            };

            if (tokenizationSupport != null and tokenizationSupport.createBackgroundTokenizer and !tokenizationSupport.backgroundTokenizerShouldOnlyVerifyTokens) {
                self._backgroundTokenizer.value = tokenizationSupport.createBackgroundTokenizer(self._textModel, b);
            }
            if (!self._backgroundTokenizer.value and !self._textModel.isTooLargeForTokenization()) {
                // self._backgroundTokenizer.value = self._defaultBackgroundTokenizer = DefaultBackgroundTokenizer.init(self._tokenizer, b);
                self._defaultBackgroundTokenizer.handleChanges();
            }

            if (tokenizationSupport != null and tokenizationSupport.backgroundTokenizerShouldOnlyVerifyTokens and tokenizationSupport.createBackgroundTokenizer) {
                self._debugBackgroundTokens = ContiguousTokensStore.init(self._textModel.getAllocator(), self._languageIdCodec);
                self._debugBackgroundStates = TrackingTokenizationStateStore(IState).init(self._textModel.getLineCount());
                self._debugBackgroundTokenizer.clear();
                self._debugBackgroundTokenizer.value = tokenizationSupport.?.createBackgroundTokenizer(self._textModel, .{
                    .setTokens = struct {
                        fn f(tokens: []ContiguousMultilineTokens) void {
                            self._debugBackgroundTokens.?.setMultilineTokens(tokens, self._textModel);
                        }
                    }.f,
                    .backgroundTokenizationFinished = struct {
                        fn f() void {
                            // NO OP
                        }
                    }.f,
                    .setEndState = struct {
                        fn f(lineNumber: usize, state: IState) void {
                            self._debugBackgroundStates.?.setEndState(lineNumber, state);
                        }
                    }.f,
                });
            } else {
                self._debugBackgroundTokens = null;
                self._debugBackgroundStates = null;
                self._debugBackgroundTokenizer.value = null;
            }
        }

        self.refreshAllVisibleLineTokens();
    }

    pub fn handleDidChangeAttached(self: *TokenizerSyntaxTokenBackend) void {
        self._defaultBackgroundTokenizer.?.handleChanges();
    }

    pub fn handleDidChangeContent(self: *TokenizerSyntaxTokenBackend, e: ModelContentChangedEvent) void {
        if (e.isFlush) {
            // Don't fire the event, as the view might not have got the text change event yet
            self.todo_resetTokenization(false);
        } else if (!e.isEolChange) { // We don't have to do anything on an EOL change
            for (e.changes) |c| {
                const res = countEOL(c.text);
                const eolCount = res.first;
                const firstLineLength = res.second;

                self._tokens.acceptEdit(c.range, eolCount, firstLineLength);
                self._debugBackgroundTokens.?.acceptEdit(c.range, eolCount, firstLineLength);
            }
            self._debugBackgroundStates.?.acceptChanges(e.changes);

            if (self._tokenizer) {
                self._tokenizer.store.acceptChanges(e.changes);
            }
            self._defaultBackgroundTokenizer.?.handleChanges();
        }
    }

    pub fn setTokens(self: *TokenizerSyntaxTokenBackend, tokens: []ContiguousMultilineTokens) struct { changes: []const ModelTokensChangedRange } {
        const res = self._tokens.setMultilineTokens(tokens, self._textModel);
        const changes = res.changes;

        if (changes.len > 0) {
            self._onDidChangeTokens.fire(.{
                .semanticTokensApplied = false,
                .ranges = changes,
            });
        }

        return .{ .changes = changes };
    }

    pub fn refreshAllVisibleLineTokens(self: *TokenizerSyntaxTokenBackend) void {
        const ranges = LineRange.joinMany(self._attachedViewStates.values());
        self.refreshRanges(ranges);
    }

    pub fn refreshRanges(self: *TokenizerSyntaxTokenBackend, ranges: []const LineRange) void {
        for (ranges) |range| {
            self.refreshRange(range.startLineNumber, range.endLineNumberExclusive - 1);
        }
    }

    pub fn refreshRange(self: *TokenizerSyntaxTokenBackend, startLineNumber: usize, endLineNumber: usize) void {
        if (!self._tokenizer) {
            return;
        }

        startLineNumber = @max(1, @min(self._textModel.getLineCount(), startLineNumber));
        endLineNumber = @min(self._textModel.getLineCount(), endLineNumber);

        const builder = ContiguousMultilineTokensBuilder.init();
        const res = self._tokenizer.?.tokenizeHeuristically(builder, startLineNumber, endLineNumber);
        const heuristicTokens = res.heuristicTokens;
        const changedTokens = self.setTokens(builder.finalize());

        if (heuristicTokens) {
            // We overrode tokens with heuristically computed ones.
            // Because old states might get reused (thus stopping invalidation),
            // we have to explicitly request the tokens for the changed ranges again.
            for (changedTokens.changes) |c| {
                self._backgroundTokenizer.value.?.requestTokens(c.fromLineNumber, c.toLineNumber + 1);
            }
        }

        self._defaultBackgroundTokenizer.?.checkFinished();
    }

    pub fn forceTokenization(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) void {
        const builder = ContiguousMultilineTokensBuilder.init();
        if (self._tokenizer) |tokenizer| {
            tokenizer.updateTokensUntilLine(builder, lineNumber);
        }
        self.setTokens(builder.finalize());
        self._defaultBackgroundTokenizer.?.checkFinished();
    }

    pub fn hasAccurateTokensForLine(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
        if (!self._tokenizer) {
            return true;
        }
        return self._tokenizer.?.hasAccurateTokensForLine(lineNumber);
    }

    pub fn isCheapToTokenize(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
        if (!self._tokenizer) {
            return true;
        }
        return self._tokenizer.?.isCheapToTokenize(lineNumber);
    }

    pub fn getLineTokens(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) LineTokens {
        const lineText = self._textModel.getLineContent(lineNumber);
        const result = self._tokens.getTokens(self._textModel.getLanguageId(), lineNumber - 1, lineText);
        if (self._debugBackgroundTokens and self._debugBackgroundStates and self._tokenizer) {
            if (self._debugBackgroundStates.getFirstInvalidEndStateLineNumberOrMax() > lineNumber and self._tokenizer.?.store.getFirstInvalidEndStateLineNumberOrMax() > lineNumber) {
                const backgroundResult = self._debugBackgroundTokens.getTokens(self._textModel.getLanguageId(), lineNumber - 1, lineText);
                if (!result.equals(backgroundResult) and self._debugBackgroundTokenizer.value.?.reportMismatchingTokens) {
                    self._debugBackgroundTokenizer.value.reportMismatchingTokens(lineNumber);
                }
            }
        }
        return result;
    }

    pub fn getTokenTypeIfInsertingCharacter(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, column: usize, character: []const u8) StandardTokenType {
        if (!self._tokenizer) {
            return StandardTokenType.Other;
        }

        const position = self._textModel.validatePosition(Position.init(lineNumber, column));
        self.forceTokenization(position.lineNumber);
        return self._tokenizer.?.getTokenTypeIfInsertingCharacter(position, character);
    }

    pub fn tokenizeLinesAt(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, lines: []const []const u8) ?[]LineTokens {
        if (!self._tokenizer) {
            return null;
        }
        self.forceTokenization(lineNumber);
        return self._tokenizer.?.tokenizeLinesAt(lineNumber, lines);
    }

    pub fn getHasTokens(self: *TokenizerSyntaxTokenBackend) bool {
        return self._tokens.hasTokens;
    }
};

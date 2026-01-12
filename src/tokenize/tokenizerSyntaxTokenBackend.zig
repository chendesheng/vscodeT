const std = @import("std");
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
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
const LanguageIdCodec = @import("../services/languageRegistry.zig").LanguageIdCodec;
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

const BackgroundTokenizationStore = struct {
    interface: IBackgroundTokenizationStore,
    backend: *TokenizerSyntaxTokenBackend,

    pub fn create(backend: *TokenizerSyntaxTokenBackend, allocator: Allocator) !*IBackgroundTokenizationStore {
        var b = try allocator.create(BackgroundTokenizationStore);
        b.* = BackgroundTokenizationStore.init(backend);
        return &b.interface;
    }

    pub fn init(backend: *TokenizerSyntaxTokenBackend) BackgroundTokenizationStore {
        return .{
            .backend = backend,
            .interface = .{
                .vtable = &.{
                    .setTokens = _setTokens,
                    .backgroundTokenizationFinished = _backgroundTokenizationFinished,
                    .setEndState = _setEndState,
                    .destroy = _destroy,
                },
            },
        };
    }

    fn getSelf(b: *IBackgroundTokenizationStore) *BackgroundTokenizationStore {
        return @alignCast(@fieldParentPtr("interface", b));
    }

    fn _setTokens(b: *IBackgroundTokenizationStore, tokens: []ContiguousMultilineTokens) !void {
        const self = getSelf(b);
        const res = try self.backend.setTokens(tokens);
        self.backend.super._textModel.getAllocator().free(res.changes);
    }
    fn _backgroundTokenizationFinished(b: *IBackgroundTokenizationStore) void {
        const self = getSelf(b);
        if (self.backend.super._backgroundTokenizationState == .Completed) {
            return;
        }
        const newState = BackgroundTokenizationState.Completed;
        self.backend.super._backgroundTokenizationState = newState;
        self.backend.super._onDidChangeBackgroundTokenizationState.fire({});
    }
    fn _setEndState(b: *IBackgroundTokenizationStore, lineNumber: usize, state: IState) !void {
        const self = getSelf(b);
        if (self.backend._tokenizer) |*tokenizer| {
            if (tokenizer.super.store.getFirstInvalidEndStateLineNumber()) |firstInvalidEndStateLineNumber| {
                // Don't accept states for definitely valid states, the renderer is ahead of the worker!
                if (lineNumber >= firstInvalidEndStateLineNumber) {
                    _ = try tokenizer.super.store.setEndState(lineNumber, state);
                }
            }
        }
    }
    fn _destroy(b: *IBackgroundTokenizationStore, allocator: Allocator) void {
        const self = getSelf(b);
        allocator.destroy(self);
    }
};

// For TextMate
pub const TokenizerSyntaxTokenBackend = struct {
    _tokenizer: ?TokenizerWithStateStoreAndTextModel = null,
    super: AbstractSyntaxTokenBackend,

    _defaultBackgroundTokenizer: ?DefaultBackgroundTokenizer = null,
    _backgroundTokenizer: ?IBackgroundTokenizer = null,

    // FIXME
    _languageId: []const u8,

    _tokens: ContiguousTokensStore,
    _debugBackgroundTokens: ?ContiguousTokensStore = null,
    _debugBackgroundStates: ?TrackingTokenizationStateStore = null,

    _debugBackgroundTokenizer: ?*IBackgroundTokenizer = null,

    _attachedViewStates: AutoHashMap(AttachedView, AttachedViewHandler),

    pub fn create(
        allocator: Allocator,
        languageIdCodec: *const LanguageIdCodec,
        textModel: *TextModel,
        languageId: []const u8,
        attachedViews: *AttachedViews,
    ) !*AbstractSyntaxTokenBackend {
        const self = try allocator.create(TokenizerSyntaxTokenBackend);
        self.* = .{
            .super = AbstractSyntaxTokenBackend.init(BackgroundTokenizationState.InProgress, languageIdCodec, textModel, &.{
                .handleDidChangeAttached = handleDidChangeAttached,
                .handleDidChangeContent = handleDidChangeContent,
                .forceTokenization = forceTokenization,
                .hasAccurateTokensForLine = hasAccurateTokensForLine,
                .isCheapToTokenize = isCheapToTokenize,
                .getLineTokens = getLineTokens,
                .getTokenTypeIfInsertingCharacter = getTokenTypeIfInsertingCharacter,
                .tokenizeLinesAt = tokenizeLinesAt,
                .hasTokens = getHasTokens,
                .deinit = deinit,
                .destroy = destroy,
            }),
            ._tokens = ContiguousTokensStore.init(allocator, languageIdCodec),
            ._languageId = languageId,
            ._attachedViewStates = AutoHashMap(AttachedView, AttachedViewHandler).init(allocator),
            ._backgroundTokenizer = undefined,
        };

        // Register callbacks with heap-allocated self pointer (not a dangling local pointer)
        try TokenizationRegistry.instance(allocator).onDidChange(self, struct {
            fn cb(e: TokenizationSupportChangedEvent, this: *TokenizerSyntaxTokenBackend) void {
                for (e.changedLanguages) |lang| {
                    if (std.mem.eql(u8, lang, this._languageId)) {
                        this.todo_resetTokenization(false) catch unreachable;
                        return;
                    }
                }
            }
        }.cb);

        try self.todo_resetTokenization(false);

        try attachedViews.onDidChangeVisibleRanges(self, struct {
            fn cb(e: AttachedViewAndState, this: *TokenizerSyntaxTokenBackend) void {
                const view = e.view;
                if (e.state) |state| {
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
        return &self.super;
    }

    pub fn destroy(s: *AbstractSyntaxTokenBackend, allocator: Allocator) void {
        const self = getSelf(s);
        allocator.destroy(self);
    }

    pub fn deinit(s: *AbstractSyntaxTokenBackend) void {
        var self = getSelf(s);
        if (self._tokenizer) |*tokenizer| {
            tokenizer.deinit();
        }
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
        const allocator = self.super._textModel.getAllocator();
        self._tokens.flush();
        // self._debugBackgroundTokens.?.flush();
        if (self._debugBackgroundStates != null) {
            self._debugBackgroundStates = try TrackingTokenizationStateStore.init(allocator, self.super._textModel.getLineCount());
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

        var tokenizationSupport: ?*ITokenizationSupport = null;
        var initialState: ?IState = null;
        initializeTokenization: {
            if (self.super._textModel.isTooLargeForTokenization()) {
                tokenizationSupport = null;
                initialState = null;
                break :initializeTokenization;
            }
            tokenizationSupport = TokenizationRegistry.instance(allocator).get(self._languageId);
            if (tokenizationSupport == null) {
                break :initializeTokenization;
            }
            initialState = try tokenizationSupport.?.getInitialState();
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
            const b = try BackgroundTokenizationStore.create(self, allocator);
            if (tokenizationSupport != null and !tokenizationSupport.?.backgroundTokenizerShouldOnlyVerifyTokens and tokenizationSupport.?.hasCreateBackgroundTokenizer()) {
                self._backgroundTokenizer = try tokenizationSupport.?.createBackgroundTokenizer(self.super._textModel, b);
            }
            if (self._backgroundTokenizer == null and !self.super._textModel.isTooLargeForTokenization()) {
                self._defaultBackgroundTokenizer = DefaultBackgroundTokenizer.init(self._tokenizer, b);
                self._backgroundTokenizer = self._defaultBackgroundTokenizer.?.interface;
                self._defaultBackgroundTokenizer.?.handleChanges();
            }

            if (tokenizationSupport != null and tokenizationSupport.?.backgroundTokenizerShouldOnlyVerifyTokens and self._backgroundTokenizer != null) {
                // self._debugBackgroundTokens = ContiguousTokensStore.init(
                //     self.super._textModel.getAllocator(),
                //     self.super._languageIdCodec,
                // );
                // self._debugBackgroundStates = try TrackingTokenizationStateStore.init(
                //     self.super._textModel.getAllocator(),
                //     self.super._textModel.getLineCount(),
                // );
                // self._debugBackgroundTokenizer.?.clear();
                // self._debugBackgroundTokenizer = tokenizationSupport.?.createBackgroundTokenizer(self.super._textModel, .{
                //     .setTokens = struct {
                //         fn f(tokens: []ContiguousMultilineTokens) void {
                //             self._debugBackgroundTokens.?.setMultilineTokens(tokens, self.super._textModel);
                //         }
                //     }.f,
                //     .backgroundTokenizationFinished = struct {
                //         fn f() void {
                //             // NO OP
                //         }
                //     }.f,
                //     .setEndState = struct {
                //         fn f(lineNumber: usize, state: IState) void {
                //             self._debugBackgroundStates.?.setEndState(lineNumber, state);
                //         }
                //     }.f,
                // });
            } else {
                self._debugBackgroundTokens = null;
                self._debugBackgroundStates = null;
                self._debugBackgroundTokenizer = null;
            }
        }

        try self.refreshAllVisibleLineTokens();
    }

    fn getSelf(s: *AbstractSyntaxTokenBackend) *TokenizerSyntaxTokenBackend {
        return @alignCast(@fieldParentPtr("super", s));
    }

    pub fn handleDidChangeAttached(s: *AbstractSyntaxTokenBackend) void {
        var self = getSelf(s);
        self._defaultBackgroundTokenizer.?.handleChanges();
    }

    pub fn handleDidChangeContent(s: *AbstractSyntaxTokenBackend, e: ModelContentChangedEvent) !void {
        var self = getSelf(s);
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
            const allocator = self.super._textModel.getAllocator();
            const startLineNumber1 = clamp(startLineNumber, 1, self.super._textModel.getLineCount());
            const endLineNumber1 = clamp(endLineNumber, 1, self.super._textModel.getLineCount());

            var builder = ContiguousMultilineTokensBuilder.init(self.super._textModel.getAllocator());
            defer builder.deinit();
            const res = try tokenizer.tokenizeHeuristically(&builder, startLineNumber1, endLineNumber1);
            const heuristicTokens = res.heuristicTokens;
            const changedTokens = try self.setTokens(builder.finalize().items);
            defer allocator.free(changedTokens.changes);

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

    pub fn forceTokenization(s: *AbstractSyntaxTokenBackend, lineNumber: usize) !void {
        var self = getSelf(s);
        const allocator = self.super._textModel.getAllocator();
        var builder = ContiguousMultilineTokensBuilder.init(allocator);
        defer builder.deinit();
        if (self._tokenizer) |*tokenizer| {
            try tokenizer.updateTokensUntilLine(&builder, lineNumber);
        }
        const changedTokens = try self.setTokens(builder.finalize().items);
        defer allocator.free(changedTokens.changes);
        self._defaultBackgroundTokenizer.?.checkFinished();
    }

    pub fn hasAccurateTokensForLine(s: *AbstractSyntaxTokenBackend, lineNumber: usize) bool {
        const self = getSelf(s);
        if (self._tokenizer) |tokenizer| {
            return tokenizer.hasAccurateTokensForLine(lineNumber);
        }
        return true;
    }

    pub fn isCheapToTokenize(s: *AbstractSyntaxTokenBackend, lineNumber: usize) bool {
        const self = getSelf(s);
        if (self._tokenizer) |tokenizer| {
            return tokenizer.isCheapToTokenize(lineNumber);
        }
        return true;
    }

    pub fn getLineTokens(s: *AbstractSyntaxTokenBackend, lineNumber: usize) !LineTokens {
        const self = getSelf(s);
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
                                debugBackgroundTokenizer.reportMismatchingTokens(lineNumber);
                            }
                        }
                    }
                }
            }
        }
        return result;
    }

    pub fn getTokenTypeIfInsertingCharacter(s: *AbstractSyntaxTokenBackend, lineNumber: usize, column: usize, character: []const u8) !StandardTokenType {
        const self = getSelf(s);
        if (self._tokenizer) |tokenizer| {
            const position = self.super._textModel.validatePosition(Position.init(lineNumber, column));
            try self.super.forceTokenization(position.lineNumber);
            return tokenizer.getTokenTypeIfInsertingCharacter(position, character);
        } else {
            return StandardTokenType.Other;
        }
    }

    pub fn tokenizeLinesAt(s: *AbstractSyntaxTokenBackend, lineNumber: usize, lines: []const []const u8) !?[]LineTokens {
        const self = getSelf(s);
        if (self._tokenizer) |tokenizer| {
            try self.super.forceTokenization(lineNumber);
            if (try tokenizer.tokenizeLinesAt(lineNumber, lines)) |tokens| {
                return tokens.items;
            } else {
                return null;
            }
        } else {
            return null;
        }
    }

    pub fn getHasTokens(s: *AbstractSyntaxTokenBackend) bool {
        const self = getSelf(s);
        return self._tokens.hasTokens();
    }
};

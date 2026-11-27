// Port of `src/vs/editor/common/model/tokens/tokenizerSyntaxTokenBackend.ts`.
const std = @import("std");
const AutoHashMap = std.AutoHashMap;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const countEOL = @import("../../core/misc/eolCounter.zig").countEOL;
const Position = @import("../../core/position.zig").Position;
const LineRange = @import("../../core/ranges/lineRange.zig").LineRange;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;
const IBackgroundTokenizer = @import("../../languages.zig").IBackgroundTokenizer;
const IState = @import("../../languages.zig").IState;
const ITokenizationSupport = @import("../../languages.zig").ITokenizationSupport;
const IBackgroundTokenizationStore = @import("../../languages.zig").IBackgroundTokenizationStore;
const ContiguousMultilineTokens = @import("../../tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const ContiguousMultilineTokensBuilder = @import("../../tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const ContiguousTokensStore = @import("../../tokens/contiguousTokensStore.zig").ContiguousTokensStore;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const TextModel = @import("../textModel.zig").TextModel;
const TokenizerWithStateStoreAndTextModel = @import("../textModelTokens.zig").TokenizerWithStateStoreAndTextModel;
const TrackingTokenizationStateStore = @import("../textModelTokens.zig").TrackingTokenizationStateStore;
const AbstractSyntaxTokenBackend = @import("./abstractSyntaxTokenBackend.zig").AbstractSyntaxTokenBackend;
const AttachedViewHandler = @import("./abstractSyntaxTokenBackend.zig").AttachedViewHandler;
const AttachedViews = @import("./abstractSyntaxTokenBackend.zig").AttachedViews;
const AttachedView = @import("./abstractSyntaxTokenBackend.zig").AttachedView;
const AttachedViewState = @import("./abstractSyntaxTokenBackend.zig").AttachedViewState;
const BackgroundTokenizationState = @import("./abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const TokenizationRegistry = @import("../../tokenizationRegistry.zig").TokenizationRegistry;
const LanguageIdCodec = @import("../../languages.zig").LanguageIdCodec;
const DefaultBackgroundTokenizer = @import("../textModelTokens.zig").DefaultBackgroundTokenizer;
const AttachedViewAndState = @import("./abstractSyntaxTokenBackend.zig").AttachedViewAndState;
const ModelTokensChangedRange = @import("../../textModelEvents.zig").ModelTokensChangedRange;
const ModelContentChangedEvent = @import("../../textModelEvents.zig").ModelContentChangedEvent;
const TokenizationSupportChangedEvent = @import("../../languages.zig").TokenizationSupportChangedEvent;
const clamp = @import("../../../../base/common/utils.zig").clamp;
const LineRangeSet = @import("../../core/ranges/lineRange.zig").LineRangeSet;

const line_limit = @import("../../../../workbench/services/textMate/browser/tokenizationSupport/tokenizationSupportWithLineLimit.zig");

pub const TokenizerSyntaxTokenBackend = struct {
    limited_support: line_limit.TokenizationSupportWithLineLimit = undefined,
    super: AbstractSyntaxTokenBackend,

    _tokenizer: ?*TokenizerWithStateStoreAndTextModel = null,
    _tokens: ContiguousTokensStore,
    _debugBackgroundTokens: ?ContiguousTokensStore = null,
    _debugBackgroundStates: ?TrackingTokenizationStateStore = null,
    _debugBackgroundTokenizer: ?IBackgroundTokenizer = null,
    _defaultBackgroundTokenizer: ?DefaultBackgroundTokenizer = null,
    window: ?*@import("../../../../base/common/windowDispatch.zig").Queue = null,
    _backgroundTokenizer: ?IBackgroundTokenizer = null,
    _attachedViewStates: AutoHashMap(*AttachedView, AttachedViewHandler),
    _languageId: []const u8,
    _allocator: Allocator,
    _registryListener: ?usize = null,
    _attachedViewsListener: ?usize = null,
    _attachedViews: ?*AttachedViews = null,
    _callbacks_registered: bool = false,

    pub fn init(languageIdCodec: *LanguageIdCodec, textModel_: *TextModel, languageId: []const u8) TokenizerSyntaxTokenBackend {
        const allocator = textModel_.getAllocator();
        return .{
            .super = AbstractSyntaxTokenBackend.init(.InProgress, languageIdCodec, textModel_),
            ._tokens = ContiguousTokensStore.init(allocator, languageIdCodec),
            ._languageId = languageId,
            ._attachedViewStates = AutoHashMap(*AttachedView, AttachedViewHandler).init(allocator),
            ._allocator = allocator,
        };
    }

    pub fn deinit(self: *TokenizerSyntaxTokenBackend) void {
        if (self._registryListener) |id| TokenizationRegistry.instance.unsubscribe(id);
        self._registryListener = null;
        if (self._attachedViewsListener) |id| {
            if (self._attachedViews) |attachedViews| attachedViews.unsubscribe(id);
        }
        self._attachedViewsListener = null;
        self._attachedViews = null;

        if (self._backgroundTokenizer) |tokenizer| tokenizer.dispose();
        if (self._debugBackgroundTokenizer) |tokenizer| tokenizer.dispose();
        if (self._defaultBackgroundTokenizer) |*tokenizer| tokenizer.dispose();
        if (self._debugBackgroundTokens) |*tokens| tokens.deinit();
        if (self._debugBackgroundStates) |*states| states.deinit();
        if (self._tokenizer) |tokenizer| {
            tokenizer.deinit();
            self._allocator.destroy(tokenizer);
        }
        self._tokens.deinit();
        var view_states = self._attachedViewStates.valueIterator();
        while (view_states.next()) |handler| handler.deinit();
        self._attachedViewStates.deinit();
        self.super.deinit();
    }

    pub fn registerCallbacks(self: *TokenizerSyntaxTokenBackend, attachedViews: *AttachedViews) void {
        if (self._callbacks_registered) return;
        self._callbacks_registered = true;
        self._attachedViews = attachedViews;
        self._registryListener = TokenizationRegistry.instance.onDidChange(self, struct {
            fn cb(e: TokenizationSupportChangedEvent, this: *TokenizerSyntaxTokenBackend) !void {
                if (!e.affects(this._languageId)) return;
                this.todo_resetTokenization(true);
            }
        }.cb) catch null;

        self._attachedViewsListener = attachedViews.onDidChangeVisibleRanges(self, struct {
            fn cb(e: AttachedViewAndState, this: *TokenizerSyntaxTokenBackend) !void {
                const view = e.first;
                const state = e.second;
                if (state) |newState| {
                    const entry = try this._attachedViewStates.getOrPut(view);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = AttachedViewHandler.init(this._allocator, this, struct {
                            fn f(ctx: *anyopaque, handler: *AttachedViewHandler) void {
                                const backend: *TokenizerSyntaxTokenBackend = @ptrCast(@alignCast(ctx));
                                backend.refreshRanges(handler._lineRanges);
                            }
                        }.f);
                    }
                    // Mutate the stored handler, not a by-value copy.
                    entry.value_ptr.handleStateChange(newState);
                } else {
                    if (this._attachedViewStates.fetchRemove(view)) |removed| {
                        var handler = removed.value;
                        handler.deinit();
                    }
                }
            }
        }.cb) catch null;

        // The backend is now in its final storage location, so callbacks that
        // capture `self` are safe.
        self.todo_resetTokenization(false);
    }

    pub fn setLanguageId(self: *TokenizerSyntaxTokenBackend, languageId: []const u8) void {
        self._languageId = languageId;
    }

    pub fn todo_resetTokenization(self: *TokenizerSyntaxTokenBackend, fireTokenChangeEvent: bool) void {
        self._tokens.flush();
        if (self._debugBackgroundTokens) |*tokens| tokens.flush();
        if (self._debugBackgroundStates) |*states| {
            states.deinit();
            self._debugBackgroundStates = null;
        }
        if (fireTokenChangeEvent) {
            var ranges = [_]ModelTokensChangedRange{.{ .fromLineNumber = 1, .toLineNumber = self.textModel().getLineCount() }};
            self.super._onDidChangeTokens.fire(.{ .semanticTokensApplied = false, .ranges = &ranges }) catch {};
        }

        self._disposeBackgroundTokenizers();
        if (self._tokenizer) |tokenizer| {
            tokenizer.deinit();
            self._allocator.destroy(tokenizer);
            self._tokenizer = null;
        }

        var tokenizationSupport: ?ITokenizationSupport = null;
        if (!self.textModel().isTooLargeForTokenization()) {
            tokenizationSupport = TokenizationRegistry.instance.get(self._languageId);
        }

        if (tokenizationSupport) |support| {
            const tokenizer = self._allocator.create(TokenizerWithStateStoreAndTextModel) catch null;
            if (tokenizer) |t| {
                const foreground = if (@import("textMateTokenizer.zig").isTextMate(support)) blk: {
                    self.limited_support = .{
                        .actual = support,
                        .encoded_language_id = @fromBackingInt(@intCast(self.super._languageIdCodec.encodeLanguageId(self._languageId) catch 0)),
                        .limit = self.textModel().max_tokenization_line_length,
                    };
                    break :blk self.limited_support.interface();
                } else support;
                t.* = TokenizerWithStateStoreAndTextModel.init(self.textModel().getLineCount(), foreground, self.textModel(), self.super._languageIdCodec) catch {
                    self._allocator.destroy(t);
                    return;
                };
                self._tokenizer = t;
            }
        }

        if (self._tokenizer) |tokenizer| {
            const store = self._backgroundStore();
            const create = tokenizationSupport != null and tokenizationSupport.?.vtable.createBackgroundTokenizer != null;
            const onlyVerify = if (tokenizationSupport) |support| (support.vtable.backgroundTokenizerShouldOnlyVerifyTokens orelse false) else false;

            if (create and !onlyVerify) {
                self._backgroundTokenizer = tokenizationSupport.?.createBackgroundTokenizer(self.textModel(), store);
            }
            if (self._backgroundTokenizer == null and !self.textModel().isTooLargeForTokenization()) {
                if (TokenizationRegistry.instance.getBackgroundTokenizerFactory()) |factory| {
                    self._backgroundTokenizer = factory.create(factory.context, self.textModel(), store);
                }
            }
            if (self._backgroundTokenizer == null and !self.textModel().isTooLargeForTokenization()) {
                self._defaultBackgroundTokenizer = DefaultBackgroundTokenizer.init(tokenizer, store);
                if (self.window) |window| self._defaultBackgroundTokenizer.?.attachWindow(window);
                self._defaultBackgroundTokenizer.?.handleChanges();
            }

            if (onlyVerify and create) {
                self._debugBackgroundTokens = ContiguousTokensStore.init(self._allocator, self.super._languageIdCodec);
                self._debugBackgroundStates = TrackingTokenizationStateStore.init(self._allocator, self.textModel().getLineCount()) catch null;
                self._debugBackgroundTokenizer = tokenizationSupport.?.createBackgroundTokenizer(self.textModel(), self._debugStore());
            } else {
                self._debugBackgroundTokens = null;
                self._debugBackgroundStates = null;
                self._debugBackgroundTokenizer = null;
            }
        }

        self.refreshAllVisibleLineTokens() catch {};
    }

    fn _disposeBackgroundTokenizers(self: *TokenizerSyntaxTokenBackend) void {
        if (self._backgroundTokenizer) |tokenizer| tokenizer.dispose();
        self._backgroundTokenizer = null;
        if (self._debugBackgroundTokenizer) |tokenizer| tokenizer.dispose();
        self._debugBackgroundTokenizer = null;
        if (self._defaultBackgroundTokenizer) |*tokenizer| tokenizer.dispose();
        self._defaultBackgroundTokenizer = null;
    }

    fn _backgroundStore(self: *TokenizerSyntaxTokenBackend) IBackgroundTokenizationStore {
        return .{
            .context = self,
            .setTokens = struct {
                fn f(ctx: *anyopaque, tokens: []ContiguousMultilineTokens) void {
                    const backend: *TokenizerSyntaxTokenBackend = @ptrCast(@alignCast(ctx));
                    backend.setTokensAndFire(tokens);
                }
            }.f,
            .backgroundTokenizationFinished = struct {
                fn f(ctx: *anyopaque) void {
                    const backend: *TokenizerSyntaxTokenBackend = @ptrCast(@alignCast(ctx));
                    if (backend.super._backgroundTokenizationState == .Completed) return;
                    backend.super._backgroundTokenizationState = .Completed;
                    backend.super._onDidChangeBackgroundTokenizationState.fire({}) catch {};
                }
            }.f,
            .setEndState = struct {
                fn f(ctx: *anyopaque, lineNumber: usize, state: IState) void {
                    const backend: *TokenizerSyntaxTokenBackend = @ptrCast(@alignCast(ctx));
                    if (backend._tokenizer) |tokenizer| {
                        const firstInvalid = tokenizer.getStore().getFirstInvalidEndStateLineNumber();
                        if (firstInvalid != null and lineNumber >= firstInvalid.?) {
                            _ = tokenizer.getStore().setEndState(lineNumber, state) catch {};
                        }
                    }
                }
            }.f,
        };
    }

    fn _debugStore(self: *TokenizerSyntaxTokenBackend) IBackgroundTokenizationStore {
        return .{
            .context = self,
            .setTokens = struct {
                fn f(ctx: *anyopaque, tokens: []ContiguousMultilineTokens) void {
                    const backend: *TokenizerSyntaxTokenBackend = @ptrCast(@alignCast(ctx));
                    if (backend._debugBackgroundTokens) |*store| {
                        var changes = ArrayList(ModelTokensChangedRange).init(backend._allocator);
                        defer changes.deinit();
                        store.setMultilineTokens(tokens, backend.textModel(), &changes) catch {};
                    }
                }
            }.f,
            .backgroundTokenizationFinished = struct {
                fn f(_: *anyopaque) void {}
            }.f,
            .setEndState = struct {
                fn f(ctx: *anyopaque, lineNumber: usize, state: IState) void {
                    const backend: *TokenizerSyntaxTokenBackend = @ptrCast(@alignCast(ctx));
                    if (backend._debugBackgroundStates) |*states| {
                        _ = states.setEndState(lineNumber, state) catch {};
                    }
                }
            }.f,
        };
    }

    pub fn attachWindow(self: *TokenizerSyntaxTokenBackend, window: *@import("../../../../base/common/windowDispatch.zig").Queue) void {
        self.window = window;
        if (self._defaultBackgroundTokenizer) |*tokenizer| tokenizer.attachWindow(window);
    }

    pub fn handleDidChangeAttached(self: *TokenizerSyntaxTokenBackend) void {
        if (self._defaultBackgroundTokenizer) |*tokenizer| tokenizer.handleChanges();
    }

    /// Drives the ported `DefaultBackgroundTokenizer` and any async background
    /// tokenizer from the terminal main loop. Upstream schedules the default
    /// tokenizer through `runWhenGlobalIdle`/`setTimeout0` and delivers worker
    /// results through the browser message queue.
    pub fn pollBackgroundTokenization(self: *TokenizerSyntaxTokenBackend) bool {
        var changed = false;
        if (self._backgroundTokenizer) |tokenizer| {
            if (tokenizer.poll()) changed = true;
        }
        if (self._defaultBackgroundTokenizer) |*tokenizer| {
            if (tokenizer.poll()) changed = true;
        }
        return changed;
    }

    /// Drains completed async worker deltas without advancing the fallback
    /// tokenizer. The TUI calls this on every loop tick (including while input
    /// is pending) so the worker result channel cannot fill up during typing.
    pub fn drainBackgroundTokenization(self: *TokenizerSyntaxTokenBackend) bool {
        if (self._backgroundTokenizer) |tokenizer| return tokenizer.poll();
        return false;
    }

    pub fn backgroundTokenizationPending(self: *TokenizerSyntaxTokenBackend) bool {
        if (self._backgroundTokenizer) |tokenizer| {
            if (tokenizer.isPending()) return true;
        }
        if (self._defaultBackgroundTokenizer) |*tokenizer| return tokenizer.isPending();
        return false;
    }

    pub fn handleDidChangeContent(self: *TokenizerSyntaxTokenBackend, e: ModelContentChangedEvent) void {
        if (e.isFlush) {
            self.todo_resetTokenization(false);
            return;
        }
        if (!e.isEolChange) {
            for (e.changes.items) |c| {
                const res = countEOL(c.text.items());
                self._tokens.acceptEdit(c.range, res.eolCount, res.firstLineLength) catch {};
                if (self._debugBackgroundTokens) |*tokens| tokens.acceptEdit(c.range, res.eolCount, res.firstLineLength) catch {};
            }
            if (self._debugBackgroundStates) |*states| states.acceptChanges(e.changes.items) catch {};
            if (self._tokenizer) |tokenizer| tokenizer.getStore().acceptChanges(e.changes.items) catch {};
            if (self._defaultBackgroundTokenizer) |*tokenizer| tokenizer.handleChanges();
        }
        if (self._backgroundTokenizer) |tokenizer| tokenizer.onDidChangeContent(&e);
    }

    fn setTokensAndFire(self: *TokenizerSyntaxTokenBackend, tokens: []ContiguousMultilineTokens) void {
        var changes = ArrayList(ModelTokensChangedRange).init(self._allocator);
        defer changes.deinit();
        self._tokens.setMultilineTokens(tokens, self.textModel(), &changes) catch return;
        if (changes.items.len > 0) {
            self.super._onDidChangeTokens.fire(.{ .semanticTokensApplied = false, .ranges = changes.items }) catch {};
        }
    }

    pub fn refreshAllVisibleLineTokens(self: *TokenizerSyntaxTokenBackend) !void {
        var set = LineRangeSet.empty(self._allocator);
        defer set.deinit();
        var iter = self._attachedViewStates.valueIterator();
        while (iter.next()) |handler| {
            for (handler._lineRanges) |range| try set.addRange(range);
        }
        self.refreshRanges(set.ranges());
    }

    pub fn refreshRanges(self: *TokenizerSyntaxTokenBackend, ranges: []const LineRange) void {
        for (ranges) |range| self.refreshRange(range.startLineNumber, range.endLineNumberExclusive - 1);
    }

    pub fn forceRefreshRange(self: *TokenizerSyntaxTokenBackend, startLineNumber: usize, endLineNumber: usize) void {
        const tokenizer = self._tokenizer orelse return;
        var builder = ContiguousMultilineTokensBuilder.init(self._allocator);
        defer builder.deinit();
        tokenizer.forceTokenizeRange(&builder, startLineNumber, endLineNumber) catch return;
        self.setTokensAndFire(builder.finalize());
    }

    pub fn refreshRange(self: *TokenizerSyntaxTokenBackend, startLineNumber: usize, endLineNumber: usize) void {
        const tokenizer = self._tokenizer orelse return;

        const start = clamp(startLineNumber, 1, self.textModel().getLineCount());
        const end = clamp(endLineNumber, 1, self.textModel().getLineCount());

        var builder = ContiguousMultilineTokensBuilder.init(self._allocator);
        defer builder.deinit();
        const res = tokenizer.tokenizeHeuristically(&builder, start, end) catch return;

        var changes = ArrayList(ModelTokensChangedRange).init(self._allocator);
        defer changes.deinit();
        self._tokens.setMultilineTokens(builder.finalize(), self.textModel(), &changes) catch return;
        if (changes.items.len > 0) {
            self.super._onDidChangeTokens.fire(.{ .semanticTokensApplied = false, .ranges = changes.items }) catch {};
        }

        if (res.heuristicTokens) {
            for (changes.items) |c| {
                if (self._backgroundTokenizer) |backgroundTokenizer| {
                    backgroundTokenizer.requestTokens(c.fromLineNumber, c.toLineNumber + 1);
                } else if (self._defaultBackgroundTokenizer) |*backgroundTokenizer| {
                    backgroundTokenizer.requestTokens(c.fromLineNumber, c.toLineNumber + 1);
                }
            }
        }

        if (self._defaultBackgroundTokenizer) |*backgroundTokenizer| backgroundTokenizer.checkFinished();
    }

    pub fn forceTokenization(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) void {
        var builder = ContiguousMultilineTokensBuilder.init(self._allocator);
        defer builder.deinit();
        if (self._tokenizer) |tokenizer| tokenizer.updateTokensUntilLine(&builder, lineNumber) catch {};
        self.setTokensAndFire(builder.finalize());
        if (self._defaultBackgroundTokenizer) |*backgroundTokenizer| backgroundTokenizer.checkFinished();
    }

    /// The first line whose tokenization state is not known yet, or null when
    /// the whole prefix is valid. The terminal editor uses this distance to
    /// choose between a sequential walk and a viewport-range guess.
    pub fn firstInvalidTokenLine(self: *TokenizerSyntaxTokenBackend) ?usize {
        const tokenizer = self._tokenizer orelse return null;
        const pair = (tokenizer.getFirstInvalidLine() catch return null) orelse return null;
        return pair.first;
    }

    /// Tokenizes exactly `[startLineNumber, endLineNumber]`, guessing the
    /// start state from the surrounding lines when the state store has no
    /// valid entry. Used for the viewport so a jump does not tokenize every
    /// line between the last valid state and the target synchronously; the
    /// background tokenizer repairs the skipped history.
    pub fn forceTokenizeRange(
        self: *TokenizerSyntaxTokenBackend,
        startLineNumber: usize,
        endLineNumber: usize,
    ) void {
        var builder = ContiguousMultilineTokensBuilder.init(self._allocator);
        defer builder.deinit();
        if (self._tokenizer) |tokenizer| {
            const line_count = self.textModel().getLineCount();
            const start = clamp(startLineNumber, 1, line_count);
            const end = clamp(endLineNumber, start, line_count);
            tokenizer.forceTokenizeRange(&builder, start, end) catch {};
        }
        self.setTokensAndFire(builder.finalize());
        if (self._defaultBackgroundTokenizer) |*backgroundTokenizer| backgroundTokenizer.checkFinished();
    }

    pub fn hasAccurateTokensForLine(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
        if (self._tokenizer) |tokenizer| return tokenizer.hasAccurateTokensForLine(lineNumber);
        return true;
    }

    pub fn isCheapToTokenize(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
        if (self._tokenizer) |tokenizer| return tokenizer.isCheapToTokenize(lineNumber);
        return true;
    }

    pub fn getLineTokens(self: *TokenizerSyntaxTokenBackend, lineNumber: usize) !LineTokens {
        const line = try self.textModel().acquireLineContent(lineNumber);
        defer line.release();
        const result = try self._tokens.getTokensForView(self.textModel().getLanguageId(), lineNumber - 1, line);
        errdefer {
            var owned = result;
            owned.deinit();
        }

        if (self._debugBackgroundTokens != null and self._debugBackgroundStates != null and self._tokenizer != null) {
            const debugStates = &self._debugBackgroundStates.?;
            const tokenizer = self._tokenizer.?;
            if (debugStates.getFirstInvalidEndStateLineNumberOrMax() > lineNumber and tokenizer.getStore().getFirstInvalidEndStateLineNumberOrMax() > lineNumber) {
                var debugText = try self.textModel().getLineContent(lineNumber);
                errdefer debugText.deinit();
                var backgroundResult = try self._debugBackgroundTokens.?.getTokens(self.textModel().getLanguageId(), lineNumber - 1, debugText);
                defer backgroundResult.deinit();
                if (!result.equals(&backgroundResult)) {
                    if (self._debugBackgroundTokenizer) |tokenizerDebug| tokenizerDebug.reportMismatchingTokens(lineNumber);
                }
            }
        }

        return result;
    }

    pub fn getTokenTypeIfInsertingCharacter(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, column: usize, character: []const u8) !StandardTokenType {
        const tokenizer = self._tokenizer orelse return StandardTokenType.Other;
        const position = self.textModel().validatePosition(Position.init(lineNumber, column));
        self.forceTokenization(position.lineNumber);
        return try tokenizer.getTokenTypeIfInsertingCharacter(position, character);
    }

    pub fn tokenizeLinesAt(self: *TokenizerSyntaxTokenBackend, lineNumber: usize, lines: []const []const u8) !?ArrayList(LineTokens) {
        const tokenizer = self._tokenizer orelse return null;
        self.forceTokenization(lineNumber);
        return try tokenizer.tokenizeLinesAt(lineNumber, lines);
    }

    pub fn getHasTokens(self: *TokenizerSyntaxTokenBackend) bool {
        return self._tokens.hasTokens();
    }

    pub fn hasDefaultTokens(self: *const TokenizerSyntaxTokenBackend, lineNumber: usize) bool {
        return self._tokens.hasDefaultTokens(lineNumber - 1);
    }

    pub fn textModel(self: *TokenizerSyntaxTokenBackend) *TextModel {
        return self.super.textModel();
    }
};

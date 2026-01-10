const std = @import("std");
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const Position = @import("../basics/position.zig").Position;
const Range = @import("../basics/range.zig").Range;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const SparseMultilineTokens = @import("../tokens/sparseMultilineTokens.zig").SparseMultilineTokens;
const SparseTokensStore = @import("../tokens/sparseTokensStore.zig").SparseTokensStore;
const ModelLanguageChangedEvent = @import("../textModel/textModelEvents.zig").ModelLanguageChangedEvent;
const ModelLanguageConfigurationChangedEvent = @import("../textModel/textModelEvents.zig").ModelLanguageConfigurationChangedEvent;
const ModelTokensChangedEvent = @import("../textModel/textModelEvents.zig").ModelTokensChangedEvent;
const Emitter = @import("../basics/event.zig").Emitter;
const AbstractSyntaxTokenBackend = @import("./abstractSyntaxTokenBackend.zig").AbstractSyntaxTokenBackend;
const TokenizerSyntaxTokenBackend = @import("./tokenizerSyntaxTokenBackend.zig").TokenizerSyntaxTokenBackend;
const AttachedViews = @import("./abstractSyntaxTokenBackend.zig").AttachedViews;
const ModelContentChangedEvent = @import("../textModel/textModelEvents.zig").ModelContentChangedEvent;
const WordAtPosition = @import("../basics/utils.zig").WordAtPosition;
const LanguageIdCodec = @import("../services/languageRegistry.zig").LanguageIdCodec;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const BackgroundTokenizationState = @import("./abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const getWordAtText = @import("../basics/wordHelper.zig").getWordAtText;
const LanguageConfigurationService = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationService;
const ResolvedLanguageConfiguration = @import("../languages/languageConfigurationRegistry.zig").ResolvedLanguageConfiguration;
const ModelTokensChangedRange = @import("../textModel/textModelEvents.zig").ModelTokensChangedRange;
const LanguageConfigurationServiceChangeEvent = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationServiceChangeEvent;
const LanguageService = @import("../languages/languageService.zig").LanguageService;

// const derived = @import("../common/observable.zig").derived;
// const IObservable = @import("../common/observable.zig").IObservable;
// const ISettableObservable = @import("../common/observable.zig").ISettableObservable;
// const observableValue = @import("../common/observable.zig").observableValue;

pub const TokenizationTextModelPart = struct {
    _semanticTokens: SparseTokensStore,
    _onDidChangeLanguage: Emitter(ModelLanguageChangedEvent),
    _onDidChangeLanguageConfiguration: Emitter(ModelLanguageConfigurationChangedEvent),
    _onDidChangeTokens: Emitter(ModelTokensChangedEvent),
    // public readonly tokens: IObservable<AbstractSyntaxTokenBackend>;
    tokens: *AbstractSyntaxTokenBackend,
    _useTreeSitter: bool,
    _languageId: []const u8,
    _textModel: *TextModel,
    _attachedViews: *AttachedViews,
    // _bracketPairsTextModelPart: BracketPairsTextModelPart,
    _languageService: *LanguageService,
    _languageConfigurationService: *LanguageConfigurationService,
    // _instantiationService: IInstantiationService,
    // _treeSitterLibraryService: ITreeSitterLibraryService,

    pub fn create(
        textModel_: *TextModel,
        languageId: []const u8,
        attachedViews: *AttachedViews,
        languageService: *LanguageService,
        languageConfigurationService: *LanguageConfigurationService,
    ) !*TokenizationTextModelPart {
        const allocator = textModel_.getAllocator();
        const self = try allocator.create(TokenizationTextModelPart);
        self.* = try TokenizationTextModelPart.init(
            textModel_,
            languageId,
            attachedViews,
            languageService,
            languageConfigurationService,
        );
        return self;
    }

    pub fn init(
        textModel_: *TextModel,
        languageId: []const u8,
        attachedViews: *AttachedViews,
        languageService: *LanguageService,
        languageConfigurationService: *LanguageConfigurationService,
    ) !TokenizationTextModelPart {
        //tokens = derived(this, reader => {
        //   let tokens: AbstractSyntaxTokenBackend;
        //   if (this._useTreeSitter.read(reader)) {
        //      tokens = reader.store.add(this._instantiationService.createInstance(
        //         TreeSitterSyntaxTokenBackend,
        //         this._languageIdObs,
        //         this._languageService.languageIdCodec,
        //         this._textModel,
        //         this._attachedViews.visibleLineRanges
        //      ));
        //   } else {
        //      tokens = reader.store.add(new TokenizerSyntaxTokenBackend(this._languageService.languageIdCodec, this._textModel, () => this._languageId, this._attachedViews));
        //   }

        //   // reader.store.add(tokens.onDidChangeTokens(e => {
        //   //    self._emitModelTokensChangedEvent(e);
        //   // }));

        //   // reader.store.add(tokens.onDidChangeBackgroundTokenizationState(e => {
        //   //    self._bracketPairsTextModelPart.handleDidChangeBackgroundTokenizationState();
        //   // }));
        //   return tokens;
        //});

        // var hadTokens = false;
        // self.tokens.recomputeInitiallyAndOnChange(this._store, value => {
        //    if (hadTokens) {
        //       // We need to reset the tokenization, as the new token provider otherwise won't have a chance to provide tokens until some action happens in the editor.
        //       // TODO@hediet: Look into why this is needed.
        //       value.todo_resetTokenization();
        //    }
        //    hadTokens = true;
        // });

        const languageIdCodec = &languageService.languageIdCodec;
        const allocator = textModel_.getAllocator();

        return TokenizationTextModelPart{
            ._useTreeSitter = false,
            ._textModel = textModel_,
            ._languageId = languageId,
            ._attachedViews = attachedViews,
            ._semanticTokens = SparseTokensStore.init(allocator, languageIdCodec),
            ._onDidChangeLanguage = Emitter(ModelLanguageChangedEvent).init(allocator),
            ._onDidChangeLanguageConfiguration = Emitter(ModelLanguageConfigurationChangedEvent).init(allocator),
            ._onDidChangeTokens = Emitter(ModelTokensChangedEvent).init(allocator),
            ._languageService = languageService,
            ._languageConfigurationService = languageConfigurationService,
            .tokens = try TokenizerSyntaxTokenBackend.create(
                allocator,
                languageIdCodec,
                textModel_,
                languageId,
                attachedViews,
            ),
        };
    }

    pub fn deinit(self: *TokenizationTextModelPart) void {
        self._semanticTokens.deinit();
        self._onDidChangeLanguage.deinit();
        self._onDidChangeLanguageConfiguration.deinit();
        self._onDidChangeTokens.deinit();
        self.tokens.destroy(self._textModel.getAllocator());
    }

    pub fn textModel(self: *TokenizationTextModelPart) *TextModel {
        return @ptrCast(self._textModel);
    }

    // @internal, should not be exposed by the text model!
    // pub fn onDidChangeBackgroundTokenizationState(self: *TokenizationTextModelPart, f: fn (void) void) void {
    //     self._onDidChangeBackgroundTokenizationState.event({}, f);
    // }

    // //** @internal, should not be exposed by the text model! */
    pub fn onDidChangeTokens(self: *TokenizationTextModelPart, f: fn (ModelTokensChangedEvent, void) anyerror!void) !void {
        try self._onDidChangeTokens.event({}, f);
    }

    fn _hasListeners(self: *TokenizationTextModelPart) bool {
        return (self._onDidChangeLanguage.hasListeners() or self._onDidChangeLanguageConfiguration.hasListeners() or self._onDidChangeTokens.hasListeners());
    }

    pub fn handleLanguageConfigurationServiceChange(self: *TokenizationTextModelPart, e: LanguageConfigurationServiceChangeEvent) void {
        if (e.affects(self._languageId)) {
            self._onDidChangeLanguageConfiguration.fire(.{});
        }
    }

    pub fn handleDidChangeContent(self: *TokenizationTextModelPart, e: ModelContentChangedEvent) !void {
        if (e.isFlush) {
            self._semanticTokens.flush();
        } else if (!e.isEolChange) { // We don't have to do anything on an EOL change
            for (e.changes.items) |c| {
                var reader = c.text.reader();
                const res = countEOL(&reader);
                const eolCount = res.eolCount;
                const firstLineLength = res.firstLineLength;
                const lastLineLength = res.lastLineLength;

                self._semanticTokens.acceptEdit(
                    c.range,
                    eolCount,
                    firstLineLength,
                    lastLineLength,
                    c.text.getFistCodepoint() orelse 0,
                );
            }
        }

        try self.tokens.handleDidChangeContent(e);
    }

    pub fn handleDidChangeAttached(self: *TokenizationTextModelPart) void {
        self.tokens.handleDidChangeAttached();
    }

    // Includes grammar and semantic tokens.
    pub fn getLineTokens(self: *TokenizationTextModelPart, lineNumber: usize) !LineTokens {
        self.validateLineNumber(lineNumber);
        var syntacticTokens = try self.tokens.getLineTokens(lineNumber);
        const result = try self._semanticTokens.addSparseTokens(lineNumber, syntacticTokens);
        // Only deinit if addSparseTokens created a new LineTokens
        if (result._tokens.items.ptr != syntacticTokens._tokens.items.ptr) {
            syntacticTokens.deinit();
        }
        return result;
    }

    fn _emitModelTokensChangedEvent(self: *TokenizationTextModelPart, e: ModelTokensChangedEvent) void {
        // self._bracketPairsTextModelPart.handleDidChangeTokens(e);
        self._onDidChangeTokens.fire(e);
    }

    // #region Grammar Tokens

    fn validateLineNumber(self: *const TokenizationTextModelPart, lineNumber: usize) void {
        if (lineNumber < 1 or lineNumber > self._textModel.getLineCount()) {
            unreachable();
        }
    }

    pub fn getHasTokens(self: *TokenizationTextModelPart) bool {
        return self.tokens.getHasTokens();
    }

    pub fn resetTokenization(self: *TokenizationTextModelPart) void {
        self.tokens.todo_resetTokenization();
    }

    pub fn getBackgroundTokenizationState(self: *TokenizationTextModelPart) BackgroundTokenizationState {
        return self.tokens.getBackgroundTokenizationState();
    }

    pub fn forceTokenization(self: *TokenizationTextModelPart, lineNumber: usize) !void {
        self.validateLineNumber(lineNumber);
        try self.tokens.forceTokenization(lineNumber);
    }

    pub fn hasAccurateTokensForLine(self: *const TokenizationTextModelPart, lineNumber: usize) bool {
        self.validateLineNumber(lineNumber);
        return self.tokens.hasAccurateTokensForLine(lineNumber);
    }

    pub fn isCheapToTokenize(self: *const TokenizationTextModelPart, lineNumber: usize) bool {
        self.validateLineNumber(lineNumber);
        return self.tokens.isCheapToTokenize(lineNumber);
    }

    pub fn tokenizeIfCheap(self: *TokenizationTextModelPart, lineNumber: usize) void {
        self.validateLineNumber(lineNumber);
        self.tokens.super.tokenizeIfCheap(lineNumber);
    }

    pub fn getTokenTypeIfInsertingCharacter(self: *TokenizationTextModelPart, lineNumber: usize, column: usize, character: []const u8) StandardTokenType {
        return self.tokens.getTokenTypeIfInsertingCharacter(lineNumber, column, character);
    }

    pub fn tokenizeLinesAt(self: *TokenizationTextModelPart, lineNumber: usize, lines: []const []const u8) ?[]LineTokens {
        return self.tokens.tokenizeLinesAt(lineNumber, lines);
    }

    // #endregion

    // #region Semantic Tokens

    pub fn setSemanticTokens(self: *TokenizationTextModelPart, tokens: ?[]const SparseMultilineTokens, isComplete: bool) !void {
        try self._semanticTokens.set(tokens, isComplete, self._textModel);

        var ranges = ArrayList(ModelTokensChangedRange).init(self._textModel.getAllocator());
        defer ranges.deinit();
        try ranges.append(.{ .fromLineNumber = 1, .toLineNumber = self._textModel.getLineCount() });
        self._emitModelTokensChangedEvent(.{
            .semanticTokensApplied = tokens != null,
            .ranges = ranges.items,
        });
    }

    pub fn hasCompleteSemanticTokens(self: *TokenizationTextModelPart) bool {
        return self._semanticTokens.isComplete();
    }

    pub fn hasSomeSemanticTokens(self: *TokenizationTextModelPart) bool {
        return !self._semanticTokens.isEmpty();
    }

    pub fn setPartialSemanticTokens(self: *TokenizationTextModelPart, range: Range, tokens: []SparseMultilineTokens) void {
        if (self.hasCompleteSemanticTokens()) {
            return;
        }
        const changedRange = self._textModel.validateRange(self._semanticTokens.setPartial(range, tokens));

        self._emitModelTokensChangedEvent(.{
            .semanticTokensApplied = true,
            .ranges = &[_]ModelTokensChangedRange{
                .{
                    .fromLineNumber = changedRange.startLineNumber,
                    .toLineNumber = changedRange.endLineNumber,
                },
            },
        });
    }

    // #endregion

    // #region Utility Methods

    pub fn getWordAtPosition(self: *TokenizationTextModelPart, _position: Position) !?WordAtPosition {
        const allocator = self._textModel.getAllocator();
        const position = self._textModel.validatePosition(_position);
        const lineContent = try self._textModel.getLineContent(position.lineNumber);
        defer lineContent.deinit();
        var lineTokens = try self.getLineTokens(position.lineNumber);
        defer lineTokens.deinit();
        const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1);

        // (1). First try checking right biased word
        const res = TokenizationTextModelPart._findLanguageBoundaries(lineTokens, tokenIndex);
        const rbStartOffset = res[0];
        const rbEndOffset = res[1];
        const rightBiasedWord = try getWordAtText(
            allocator,
            position.column,
            try (try self.getLanguageConfiguration(lineTokens.getLanguageId(tokenIndex))).getWordDefinition(),
            lineContent.items[rbStartOffset..rbEndOffset],
            rbStartOffset,
            null,
        );
        // Make sure the result touches the original passed in position
        if (rightBiasedWord != null and
            rightBiasedWord.?.startColumn <= _position.column and
            _position.column <= rightBiasedWord.?.endColumn)
        {
            return rightBiasedWord.?;
        }

        // (2). Else, if we were at a language boundary, check the left biased word
        if (tokenIndex > 0 and rbStartOffset == position.column - 1) {
            // edge case, where `position` sits between two tokens belonging to two different languages
            const b = TokenizationTextModelPart._findLanguageBoundaries(lineTokens, tokenIndex - 1);
            const lbStartOffset = b[0];
            const lbEndOffset = b[1];
            const leftBiasedWord = try getWordAtText(
                allocator,
                position.column,
                try (try self.getLanguageConfiguration(lineTokens.getLanguageId(tokenIndex - 1))).getWordDefinition(),
                lineContent.items[lbStartOffset..lbEndOffset],
                lbStartOffset,
                null,
            );
            // Make sure the result touches the original passed in position
            if (leftBiasedWord != null and
                leftBiasedWord.?.startColumn <= _position.column and
                _position.column <= leftBiasedWord.?.endColumn)
            {
                return leftBiasedWord.?;
            }
        }

        return null;
    }

    fn getLanguageConfiguration(self: *TokenizationTextModelPart, languageId: []const u8) !ResolvedLanguageConfiguration {
        return try self._languageConfigurationService.getLanguageConfiguration(languageId);
    }

    fn _findLanguageBoundaries(lineTokens: LineTokens, tokenIndex: usize) [2]usize {
        const languageId = lineTokens.getLanguageId(tokenIndex);

        // go left until a different language is hit
        var startOffset: u32 = 0;
        var i = tokenIndex;
        while (i >= 0 and std.mem.eql(u8, lineTokens.getLanguageId(i), languageId)) {
            startOffset = lineTokens.getStartOffset(i);
            if (i == 0) break;
            i -= 1;
        }

        // go right until a different language is hit
        var endOffset = @as(u32, @intCast(lineTokens.getLineContent().len));
        i = tokenIndex;
        const tokenCount = lineTokens.getCount();
        while (i < tokenCount and std.mem.eql(u8, lineTokens.getLanguageId(i), languageId)) : (i += 1) {
            endOffset = lineTokens.getEndOffset(i);
        }

        return .{ @intCast(startOffset), @intCast(endOffset) };
    }

    pub fn getWordUntilPosition(self: *TokenizationTextModelPart, position: Position) WordAtPosition {
        if (self.getWordAtPosition(position)) |wordAtPosition| {
            return WordAtPosition{
                .word = wordAtPosition.word[0..(position.column - wordAtPosition.startColumn)],
                .startColumn = wordAtPosition.startColumn,
                .endColumn = position.column,
            };
        }
        return WordAtPosition{ .word = "", .startColumn = position.column, .endColumn = position.column };
    }

    // #endregion

    // #region Language Id handling

    pub fn getLanguageId(self: *const TokenizationTextModelPart) []const u8 {
        return self._languageId;
    }

    pub fn getLanguageIdAtPosition(self: *const TokenizationTextModelPart, lineNumber: usize, column: usize) ![]const u8 {
        const position = self._textModel.validatePosition(Position.init(lineNumber, column));
        const lineTokens = try self.getLineTokens(position.lineNumber);
        return lineTokens.getLanguageId(lineTokens.findTokenIndexAtOffset(position.column - 1));
    }

    pub fn setLanguageId(self: *TokenizationTextModelPart, languageId: []const u8, source: []const u8) void {
        if (self._languageId == languageId) {
            // There's nothing to do
            return;
        }

        const e: ModelLanguageChangedEvent = .{
            .oldLanguage = self._languageId,
            .newLanguage = languageId,
            .source = source,
        };

        self._languageId = languageId;
        // self._languageIdObs.set(languageId, undefined);
        // self._bracketPairsTextModelPart.handleDidChangeLanguage(e);

        self._onDidChangeLanguage.fire(e);
        self._onDidChangeLanguageConfiguration.fire(.{});
    }

    // #endregion
};

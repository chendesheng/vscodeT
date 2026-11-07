const std = @import("std");
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel.zig").TextModel;
const Position = @import("../basics/position.zig").Position;
const Range = @import("../basics/range.zig").Range;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const SparseMultilineTokens = @import("../tokens/sparseMultilineTokens.zig").SparseMultilineTokens;
const SparseTokensStore = @import("../tokens/sparseTokensStore.zig").SparseTokensStore;
const ModelLanguageChangedEvent = @import("../textModelEvents.zig").ModelLanguageChangedEvent;
const ModelLanguageConfigurationChangedEvent = @import("../textModelEvents.zig").ModelLanguageConfigurationChangedEvent;
const ModelTokensChangedEvent = @import("../textModelEvents.zig").ModelTokensChangedEvent;
const Emitter = @import("../basics/event.zig").Emitter;
const TokenizerSyntaxTokenBackend = @import("./tokenizerSyntaxTokenBackend.zig").TokenizerSyntaxTokenBackend;
const AttachedViews = @import("./abstractSyntaxTokenBackend.zig").AttachedViews;
const ModelContentChangedEvent = @import("../textModelEvents.zig").ModelContentChangedEvent;
const WordAtPosition = @import("../basics/utils.zig").WordAtPosition;
const wordHelper = @import("../basics/wordHelper.zig");
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const countEOL = @import("../basics/eolCounter.zig").countEOL;
const BackgroundTokenizationState = @import("./abstractSyntaxTokenBackend.zig").BackgroundTokenizationState;
const ILanguageConfigurationService = @import("../languages/languageConfigurationRegistry.zig").ILanguageConfigurationService;
const ResolvedLanguageConfiguration = @import("../languages/languageConfigurationRegistry.zig").ResolvedLanguageConfiguration;
const ModelTokensChangedRange = @import("../textModelEvents.zig").ModelTokensChangedRange;
const LanguageConfigurationServiceChangeEvent = @import("../languages/languageConfigurationRegistry.zig").LanguageConfigurationServiceChangeEvent;
const LanguageService = @import("../languages/languageService.zig").LanguageService;

pub const TokenizationTextModelPart = struct {
    _semanticTokens: SparseTokensStore,
    _onDidChangeLanguage: Emitter(ModelLanguageChangedEvent),
    _onDidChangeLanguageConfiguration: Emitter(ModelLanguageConfigurationChangedEvent),
    _onDidChangeTokens: Emitter(ModelTokensChangedEvent),
    tokens: TokenizerSyntaxTokenBackend,
    _languageId: []const u8,
    _textModel: *anyopaque,
    _languageService: *LanguageService,
    _languageConfigurationService: ?*ILanguageConfigurationService,

    pub fn init(
        textModel_: *TextModel,
        languageId: []const u8,
        languageService: *LanguageService,
        languageConfigurationService: ?*ILanguageConfigurationService,
    ) TokenizationTextModelPart {
        const allocator = textModel_.getAllocator();
        const codec = languageService.languageIdCodec;

        return .{
            ._textModel = textModel_,
            ._languageId = languageId,
            ._semanticTokens = SparseTokensStore.init(allocator, codec),
            ._onDidChangeLanguage = Emitter(ModelLanguageChangedEvent).init(allocator),
            ._onDidChangeLanguageConfiguration = Emitter(ModelLanguageConfigurationChangedEvent).init(allocator),
            ._onDidChangeTokens = Emitter(ModelTokensChangedEvent).init(allocator),
            ._languageService = languageService,
            ._languageConfigurationService = languageConfigurationService,
            .tokens = TokenizerSyntaxTokenBackend.init(codec, textModel_, languageId),
        };
    }

    pub fn registerCallbacks(self: *TokenizationTextModelPart, attachedViews: *AttachedViews) void {
        self.tokens.registerCallbacks(attachedViews);
        self.tokens.super.onDidChangeTokens(self, struct {
            fn cb(e: ModelTokensChangedEvent, part: *TokenizationTextModelPart) !void {
                part._emitModelTokensChangedEvent(e);
            }
        }.cb) catch {};
    }

    pub fn deinit(self: *TokenizationTextModelPart) void {
        self._semanticTokens.deinit();
        self._onDidChangeLanguage.deinit();
        self._onDidChangeLanguageConfiguration.deinit();
        self._onDidChangeTokens.deinit();
        self.tokens.deinit();
    }

    pub fn textModel(self: *TokenizationTextModelPart) *TextModel {
        return @ptrCast(@alignCast(self._textModel));
    }

    pub fn onDidChangeTokens(self: *TokenizationTextModelPart, f: *const fn (ModelTokensChangedEvent) void) !void {
        try self._onDidChangeTokens.eventVoid(f);
    }

    pub fn onDidChangeLanguage(self: *TokenizationTextModelPart, ctx: anytype, f: fn (ModelLanguageChangedEvent, @TypeOf(ctx)) anyerror!void) !void {
        try self._onDidChangeLanguage.event(ctx, f);
    }

    pub fn onDidChangeLanguageConfiguration(self: *TokenizationTextModelPart, ctx: anytype, f: fn (ModelLanguageConfigurationChangedEvent, @TypeOf(ctx)) anyerror!void) !void {
        try self._onDidChangeLanguageConfiguration.event(ctx, f);
    }

    fn _hasListeners(self: *TokenizationTextModelPart) bool {
        return self._onDidChangeLanguage.hasListeners() or self._onDidChangeLanguageConfiguration.hasListeners() or self._onDidChangeTokens.hasListeners();
    }

    pub fn handleLanguageConfigurationServiceChange(self: *TokenizationTextModelPart, e: LanguageConfigurationServiceChangeEvent) void {
        if (e.affects(self._languageId)) {
            self._onDidChangeLanguageConfiguration.fire(.{}) catch {};
        }
    }

    pub fn handleDidChangeContent(self: *TokenizationTextModelPart, e: ModelContentChangedEvent) void {
        if (e.isFlush) {
            self._semanticTokens.flush();
        } else if (!e.isEolChange) {
            for (e.changes.items) |c| {
                const res = countEOL(c.text.items());
                self._semanticTokens.acceptEdit(c.range, res.eolCount, res.firstLineLength, res.lastLineLength, if (c.text.len() > 0) c.text.items()[0] else 0);
            }
        }
        self.tokens.handleDidChangeContent(e);
    }

    pub fn handleDidChangeAttached(self: *TokenizationTextModelPart) void {
        self.tokens.handleDidChangeAttached();
    }

    pub fn getLineTokens(self: *TokenizationTextModelPart, lineNumber: usize) !LineTokens {
        self.validateLineNumber(lineNumber);
        const syntacticTokens = try self.tokens.getLineTokens(lineNumber);
        return try self._semanticTokens.addSparseTokens(lineNumber, syntacticTokens);
    }

    fn _emitModelTokensChangedEvent(self: *TokenizationTextModelPart, e: ModelTokensChangedEvent) void {
        if (!self.textModel()._isDisposing()) {
            self._onDidChangeTokens.fire(e) catch {};
        }
    }

    fn validateLineNumber(self: *TokenizationTextModelPart, lineNumber: usize) void {
        if (lineNumber < 1 or lineNumber > self.textModel().getLineCount()) {
            unreachable;
        }
    }

    pub fn getHasTokens(self: *TokenizationTextModelPart) bool {
        return self.tokens.getHasTokens();
    }

    pub fn resetTokenization(self: *TokenizationTextModelPart) void {
        self.tokens.todo_resetTokenization(true);
    }

    pub fn getBackgroundTokenizationState(self: *TokenizationTextModelPart) BackgroundTokenizationState {
        return self.tokens.super.getBackgroundTokenizationState();
    }

    pub fn forceTokenization(self: *TokenizationTextModelPart, lineNumber: usize) void {
        self.validateLineNumber(lineNumber);
        self.tokens.forceTokenization(lineNumber);
    }

    pub fn hasAccurateTokensForLine(self: *TokenizationTextModelPart, lineNumber: usize) bool {
        self.validateLineNumber(lineNumber);
        return self.tokens.hasAccurateTokensForLine(lineNumber);
    }

    pub fn isCheapToTokenize(self: *TokenizationTextModelPart, lineNumber: usize) bool {
        self.validateLineNumber(lineNumber);
        return self.tokens.isCheapToTokenize(lineNumber);
    }

    pub fn tokenizeIfCheap(self: *TokenizationTextModelPart, lineNumber: usize) void {
        self.validateLineNumber(lineNumber);
        if (self.tokens.isCheapToTokenize(lineNumber)) self.tokens.forceTokenization(lineNumber);
    }

    pub fn getTokenTypeIfInsertingCharacter(self: *TokenizationTextModelPart, lineNumber: usize, column: usize, character: []const u8) !StandardTokenType {
        return try self.tokens.getTokenTypeIfInsertingCharacter(lineNumber, column, character);
    }

    pub fn tokenizeLinesAt(self: *TokenizationTextModelPart, lineNumber: usize, lines: []const []const u8) !?ArrayList(LineTokens) {
        return try self.tokens.tokenizeLinesAt(lineNumber, lines);
    }

    // #region Semantic Tokens

    pub fn setSemanticTokens(self: *TokenizationTextModelPart, tokens_: ?[]SparseMultilineTokens, isComplete: bool) !void {
        try self._semanticTokens.set(tokens_, isComplete, self.textModel());
        var ranges = [_]ModelTokensChangedRange{.{ .fromLineNumber = 1, .toLineNumber = self.textModel().getLineCount() }};
        self._emitModelTokensChangedEvent(.{ .semanticTokensApplied = tokens_ != null, .ranges = &ranges });
    }

    pub fn hasCompleteSemanticTokens(self: *TokenizationTextModelPart) bool {
        return self._semanticTokens.isComplete();
    }

    pub fn hasSomeSemanticTokens(self: *TokenizationTextModelPart) bool {
        return !self._semanticTokens.isEmpty();
    }

    pub fn setPartialSemanticTokens(self: *TokenizationTextModelPart, range: Range, tokens: []SparseMultilineTokens) !void {
        if (self.hasCompleteSemanticTokens()) return;
        const changedRange = self.textModel().validateRange(try self._semanticTokens.setPartial(range, tokens));
        var ranges = [_]ModelTokensChangedRange{.{ .fromLineNumber = changedRange.startLineNumber, .toLineNumber = changedRange.endLineNumber }};
        self._emitModelTokensChangedEvent(.{ .semanticTokensApplied = true, .ranges = &ranges });
    }

    // #endregion

    pub fn getWordAtPosition(self: *TokenizationTextModelPart, _position: Position) ?WordAtPosition {
        const position = self.textModel().validatePosition(_position);
        var lineContent = self.textModel().getLineContent(position.lineNumber) catch return null;
        defer lineContent.deinit();
        var lineTokens = self.getLineTokens(position.lineNumber) catch return null;
        defer lineTokens.deinit();
        if (lineTokens.getCount() == 0) return null;
        const tokenIndex = lineTokens.findTokenIndexAtOffset(position.column - 1);

        const wordDefinition = self.getWordDefinition(lineTokens.getLanguageId(tokenIndex));

        const rightBoundaries = findLanguageBoundaries(&lineTokens, tokenIndex);
        if (wordHelper.getWordAtText(position.column, wordDefinition, lineContent.items[rightBoundaries[0]..rightBoundaries[1]], rightBoundaries[0])) |match| {
            if (match.startColumn <= _position.column and _position.column <= match.endColumn) {
                return makeOwnedWord(self.textModel().getAllocator(), match);
            }
        }

        if (tokenIndex > 0 and rightBoundaries[0] == position.column - 1) {
            const leftBoundaries = findLanguageBoundaries(&lineTokens, tokenIndex - 1);
            if (wordHelper.getWordAtText(position.column, wordDefinition, lineContent.items[leftBoundaries[0]..leftBoundaries[1]], leftBoundaries[0])) |match| {
                if (match.startColumn <= _position.column and _position.column <= match.endColumn) {
                    return makeOwnedWord(self.textModel().getAllocator(), match);
                }
            }
        }

        return null;
    }

    fn getWordDefinition(self: *TokenizationTextModelPart, languageId: []const u8) ?@import("../basics/RegExp.zig").RegExp {
        if (self._languageConfigurationService) |service| {
            var config = service.getLanguageConfiguration(languageId);
            return config.getWordDefinition();
        }
        return null;
    }

    fn makeOwnedWord(allocator: std.mem.Allocator, match: wordHelper.IWordAtPosition) ?WordAtPosition {
        var word = ArrayList(u8).init(allocator);
        word.appendSlice(match.word) catch {
            word.deinit();
            return null;
        };
        return .{ .word = word, .startColumn = match.startColumn, .endColumn = match.endColumn };
    }

    fn findLanguageBoundaries(lineTokens: *const LineTokens, tokenIndex: usize) [2]usize {
        const languageId = lineTokens.getLanguageId(tokenIndex);
        var startOffset: usize = 0;
        var i = tokenIndex + 1;
        while (i > 0) {
            i -= 1;
            if (!std.mem.eql(u8, lineTokens.getLanguageId(i), languageId)) break;
            startOffset = lineTokens.getStartOffset(i);
        }

        var endOffset = lineTokens.getLineContent().len;
        i = tokenIndex;
        while (i < lineTokens.getCount() and std.mem.eql(u8, lineTokens.getLanguageId(i), languageId)) : (i += 1) {
            endOffset = lineTokens.getEndOffset(i);
        }
        return .{ startOffset, endOffset };
    }

    pub fn getWordUntilPosition(self: *TokenizationTextModelPart, position: Position) WordAtPosition {
        const allocator = self.textModel().getAllocator();
        if (self.getWordAtPosition(position)) |wordAtPosition| {
            var word = wordAtPosition;
            defer word.deinit();
            const len = @min(word.word.items.len, position.column - word.startColumn);
            var result = ArrayList(u8).init(allocator);
            result.appendSlice(word.word.items[0..len]) catch {};
            return .{ .word = result, .startColumn = word.startColumn, .endColumn = position.column };
        }
        return .{
            .word = ArrayList(u8).init(allocator),
            .startColumn = position.column,
            .endColumn = position.column,
        };
    }

    pub fn getLanguageId(self: *TokenizationTextModelPart) []const u8 {
        return self._languageId;
    }

    pub fn getLanguageIdAtPosition(self: *TokenizationTextModelPart, lineNumber: usize, column: usize) []const u8 {
        const position = self.textModel().validatePosition(Position.init(lineNumber, column));
        var lineTokens = self.getLineTokens(position.lineNumber) catch return self._languageId;
        defer lineTokens.deinit();
        return lineTokens.getLanguageId(lineTokens.findTokenIndexAtOffset(position.column - 1));
    }

    pub fn setLanguageId(self: *TokenizationTextModelPart, languageId: []const u8, source: []const u8) void {
        if (std.mem.eql(u8, self._languageId, languageId)) return;

        const e: ModelLanguageChangedEvent = .{
            .oldLanguage = self._languageId,
            .newLanguage = languageId,
            .source = source,
        };

        self._languageId = languageId;
        self.tokens.setLanguageId(languageId);
        self.tokens.todo_resetTokenization(true);
        self._onDidChangeLanguage.fire(e) catch {};
        self._onDidChangeLanguageConfiguration.fire(.{}) catch {};
    }
};

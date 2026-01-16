const std = @import("std");
const findLikelyRelevantLines = @import("../../textModel/textModelTokens.zig").findLikelyRelevantLines;
const TokenMetadata = @import("../../encodedTokenAttributes.zig").TokenMetadata;
const ts = @import("tree-sitter");
const TreeSitterThemeService = @import("../../services/TreeSitterThemeService.zig");
const ModelTokensChangedRange = @import("../../textModel/textModelEvents.zig").ModelTokensChangedRange;
const ArrayList = std.array_list.Managed;
const Emitter = @import("../../basics/event.zig").Emitter;
const Allocator = std.mem.Allocator;
const TextModel = @import("../../textModel/textModel.zig").TextModel;
const TreeSitterTree = @import("treeSitterTree.zig").TreeSitterTree;
const TreeSitterSyntaxTokenBackend = @import("treeSitterSyntaxTokenBackend.zig").TreeSitterSyntaxTokenBackend;
const TokenStore = @import("tokenStore.zig").TokenStore;
const TokenUpdate = @import("tokenStore.zig").TokenUpdate;
const TokenQuality = @import("tokenStore.zig").TokenQuality;
const Token = @import("../../languages.zig").Token;
const TokenizationResult = @import("../../languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("../../languages.zig").EncodedTokenizationResult;
const IState = @import("../../languages.zig").IState;
const LanguageIdCodec = @import("../../services/languageRegistry.zig").LanguageIdCodec;
const LineRange = @import("../../basics/lineRange.zig").LineRange;
const ModelTokensChangedEvent = @import("../../textModel/textModelEvents.zig").ModelTokensChangedEvent;
const Range = @import("../../basics/range.zig").Range;
const TreeChangeEvent = @import("treeSitterTree.zig").TreeChangeEvent;
const ModelContentChangedEvent = @import("../../textModel/textModelEvents.zig").ModelContentChangedEvent;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const TokenPacked = @import("../../tokens/lineTokens.zig").TokenPacked;
const RangeChange = @import("treeSitterTree.zig").RangeChange;
const RangeWithOffsets = @import("treeSitterTree.zig").RangeWithOffsets;
const Position = @import("../../basics/position.zig").Position;
const rangeStartToTSPoint = @import("treeSitterTree.zig").rangeStartToTSPoint;
const rangeEndToTSPoint = @import("treeSitterTree.zig").rangeEndToTSPoint;
const QueryCapture = @import("../../languages.zig").QueryCapture;
const SyntaxNode = @import("../../languages.zig").SyntaxNode;

const Self = @This();

_tokenStore: TokenStore,
_accurateVersion: i64,
_guessVersion: i64,
onDidChangeTokens: Emitter(struct { changes: ModelTokensChangedEvent }),
onDidChangeBackgroundTokenization: Emitter(void),
onDidCompleteBackgroundTokenization: Emitter(void),

_tree: TreeSitterTree,
_encodedLanguageId: u8,
_languageIdCodec: *const LanguageIdCodec,
_treeSitterThemeService: *const TreeSitterThemeService,
_visibleLineRanges: []const LineRange,
_highlightingQueries: *ts.Query,

fn init(
    _tree: TreeSitterTree,
    _languageIdCodec: *const LanguageIdCodec,
    _highlightingQueries: *ts.Query,
    _visibleLineRanges: []const LineRange,
    _treeSitterThemeService: *const TreeSitterThemeService,
) !Self {
    const _textModel = _tree.textModel;
    const allocator = _textModel.getAllocator();
    const encodedLanguageId = try _languageIdCodec.encode(_tree.languageId);

    var self = Self{
        ._tokenStore = try TokenStore.init(_textModel),
        ._accurateVersion = _textModel.getVersionId(),
        ._guessVersion = _textModel.getVersionId(),
        ._tree = _tree,
        ._languageIdCodec = _languageIdCodec,
        .onDidChangeTokens = Emitter(struct { changes: ModelTokensChangedEvent }).init(allocator),
        .onDidChangeBackgroundTokenization = Emitter(void).init(allocator),
        ._encodedLanguageId = encodedLanguageId,
        ._visibleLineRanges = _visibleLineRanges,
        ._treeSitterThemeService = _treeSitterThemeService,
        ._highlightingQueries = _highlightingQueries,
    };

    self._tree.onTreeParseUpdate.event(&self, struct {
        fn cb(e: TreeChangeEvent, this: *Self) void {
            if (e.change == null) {
                this._firstTreeUpdate(this._tree._treeLastParsedVersion);
            } else if (e.change) |changeEvent| {
                if (this.hasTokens(null)) {
                    // Mark the range for refresh immediately

                    for (changeEvent.ranges) |range| {
                        this._markForRefresh(range.newRange);
                    }
                }

                // First time we see a tree we need to build a token store.
                if (!this.hasTokens()) {
                    this._firstTreeUpdate(changeEvent.versionId);
                } else {
                    this._handleTreeUpdate(changeEvent.ranges, changeEvent.versionId);
                }
            }
        }
    }.cb);

    self._tokenStore.buildStore(try self._createEmptyTokens(), .none);

    try _treeSitterThemeService.onChange.event(&self, struct {
        fn cb(_: void, this: *Self) void {
            this._updateTheme();
        }
    }.cb);

    return self;
}

fn textModel(self: *Self) *TextModel {
    return self._tree.textModel;
}

pub fn handleContentChanged(self: *Self, e: ModelContentChangedEvent) !void {
    self._guessVersion = e.versionId;
    for (e.changes.items) |change| {
        if (change.text.len() > change.rangeLength) {
            // If possible, use the token before the change as the starting point for the new token.
            // This is more likely to let the new text be the correct color as typeing is usually at the end of the token.
            const offset = if (change.rangeOffset > 0) change.rangeOffset - 1 else change.rangeOffset;
            var newToken: TokenUpdate = undefined;
            const _oldToken = self._tokenStore.getTokenAt(offset);
            if (_oldToken) |oldToken| {
                // Insert. Just grow the token at this position to include the insert.
                newToken = .{ .startOffsetInclusive = oldToken.startOffsetInclusive, .length = oldToken.length + change.text.length - change.rangeLength, .token = oldToken.token };
                // Also mark tokens that are in the range of the change as needing a refresh.
                self._tokenStore.markForRefresh(offset, change.rangeOffset + (if (change.text.length > change.rangeLength) change.text.length else change.rangeLength));
            } else {
                // The document got larger and the change is at the end of the document.
                newToken = .{ .startOffsetInclusive = offset, .length = change.text.length, .token = 0 };
            }
            self._tokenStore.update(if (_oldToken) |oldToken| oldToken.length else 0, &[_]TokenUpdate{newToken}, .editGuess);
        } else if (change.text.len() < change.rangeLength) {
            // Delete. Delete the tokens at the corresponding range.
            const deletedCharCount = change.rangeLength - change.text.len();
            self._tokenStore.delete(deletedCharCount, change.rangeOffset);
        }
    }
}

pub fn getLineTokens(self: *Self, lineNumber: usize) !LineTokens {
    const content = self.textModel().getLineContent(lineNumber);
    const rawTokens = try self.getTokens(lineNumber);
    return LineTokens.init(rawTokens, content, self._languageIdCodec);
}

fn _createEmptyTokens(self: *Self) ![]const TokenUpdate {
    const allocator = self.textModel().getAllocator();
    const emptyToken = self._emptyToken();
    const modelEndOffset = self.textModel().getValueLength();
    const emptyTokens = [_]TokenUpdate{_emptyTokensForOffsetAndLength(0, modelEndOffset, emptyToken)};
    return try allocator.dupe(TokenUpdate, &emptyTokens);
}

fn _emptyToken(self: *Self) usize {
    return self._treeSitterThemeService.findMetadata(&[_]u8{}, self._encodedLanguageId, false, null);
}

fn _emptyTokensForOffsetAndLength(offset: usize, length: usize, emptyToken: usize) TokenUpdate {
    return .{ .token = emptyToken, .length = offset + length, .startOffsetInclusive = 0 };
}

pub fn tokenizeLinesAt(self: *Self, lineNumber: usize, lines: []const []const u8) ?[]LineTokens {
    if (try self._guessTokensForLinesContent(lineNumber, lines)) |rawLineTokens| {
        const allocator = self.textModel().getAllocator();
        var lineTokens = ArrayList(LineTokens).init(allocator);
        defer rawLineTokens.deinit();
        for (rawLineTokens.items, 0..) |rawLineToken, i| {
            try lineTokens.append(LineTokens.init(rawLineToken, lines[i], self._languageIdCodec));
        }
        return try lineTokens.toOwnedSlice();
    } else {
        return null;
    }
}

fn _rangeHasTokens(self: *Self, range: Range, minimumTokenQuality: TokenQuality) bool {
    return self._tokenStore.rangeHasTokens(
        self.textModel().getOffsetAt(range.getStartPosition()),
        self.textModel().getOffsetAt(range.getEndPosition()),
        minimumTokenQuality,
    );
}

pub fn hasTokens(self: *Self, accurateForRange: ?Range) bool {
    if (accurateForRange == null or (self._guessVersion == self._accurateVersion)) {
        return true;
    }

    return !self._tokenStore.rangeNeedsRefresh(
        self.textModel().getOffsetAt(accurateForRange.?.getStartPosition()),
        self.textModel().getOffsetAt(accurateForRange.?.getEndPosition()),
    );
}

pub fn getTokens(self: *Self, line: usize) !ArrayList(TokenPacked) {
    const allocator = self.textModel().getAllocator();
    const lineStartOffset = self.textModel().getOffsetAt(.{ .lineNumber = line, .column = 1 });
    const lineEndOffset = self.textModel().getOffsetAt(.{ .lineNumber = line, .column = self.textModel().getLineLength(line) + 1 });
    const lineTokens = try self._tokenStore.getTokensInRange(lineStartOffset, lineEndOffset);
    var result = ArrayList(TokenPacked).init(allocator);
    for (lineTokens) |token| {
        try result.append(TokenPacked.init(@intCast(token.startOffsetInclusive - lineStartOffset + token.length), @bitCast(token.token)));
    }
    return result;
}

pub fn getTokensInRange(self: *Self, range: Range, rangeStartOffset: usize, rangeEndOffset: usize, _captures: ?[]QueryCapture) ?[]TokenUpdate {
    const _tokens = blk: {
        if (_captures) |captures| {
            break :blk self._tokenizeCapturesWithMetadata(captures, rangeStartOffset, rangeEndOffset);
        } else {
            if (self._tokenize(range, rangeStartOffset, rangeEndOffset)) |tokens| {
                break :blk tokens.@"0";
            } else {
                break :blk null;
            }
        }
    };

    if (_tokens) |tokens| {
        return self._rangeTokensAsUpdates(rangeStartOffset, tokens);
    }
    return null;
}

fn _updateTokensInStore(self: *Self, version: u32, updates: []const TokensUpdate, tokenQuality: TokenQuality) void {
    self._accurateVersion = version;
    for (updates) |update| {
        const lastToken = if (update.newTokens.len > 0) update.newTokens[update.newTokens.len - 1] else null;
        var oldRangeLength: usize = undefined;
        if (lastToken != null and (self._guessVersion >= version)) {
            oldRangeLength = lastToken.startOffsetInclusive + lastToken.length - update.newTokens[0].startOffsetInclusive;
        } else if (update.oldRangeLength) |len| {
            oldRangeLength = len;
        } else {
            oldRangeLength = 0;
        }
        self._tokenStore.update(oldRangeLength, update.newTokens, tokenQuality);
    }
}

fn _markForRefresh(self: *Self, range: Range) void {
    self._tokenStore.markForRefresh(self.textModel().getOffsetAt(range.getStartPosition()), self.textModel().getOffsetAt(range.getEndPosition()));
}

const NeedsRefreshOffsetRange = struct {
    range: Range,
    startOffset: usize,
    endOffset: usize,
};

fn _getNeedsRefresh(self: *Self) ArrayList(NeedsRefreshOffsetRange) {
    const needsRefreshOffsetRanges = try self._tokenStore.getNeedsRefresh();
    var result = ArrayList(NeedsRefreshOffsetRange).init(self.textModel().getAllocator());
    for (needsRefreshOffsetRanges) |range| {
        try result.append(.{
            .range = Range.fromPositions(self.textModel().getPositionAt(range.startOffset), self.textModel().getPositionAt(range.endOffset)),
            .startOffset = range.startOffset,
            .endOffset = range.endOffset,
        });
    }
    return result;
}

fn _parseAndTokenizeViewPort(self: *Self, lineRanges: []const LineRange) !void {
    const allocator = self.textModel().getAllocator();
    const viewportRanges = ArrayList(Range).init(allocator);
    for (lineRanges) |lineRange| {
        if (lineRange.toInclusiveRange()) |range| {
            try viewportRanges.append(range);
        }
    }
    defer viewportRanges.deinit();

    for (viewportRanges.items) |range| {
        const startOffsetOfRangeInDocument = self.textModel().getOffsetAt(range.getStartPosition());
        const endOffsetOfRangeInDocument = self.textModel().getOffsetAt(range.getEndPosition());
        const version = self.textModel().getVersionId();
        if (self._rangeHasTokens(range, .viewportGuess)) {
            continue;
        }
        const content = self.textModel().getValueInRange(range);
        const tokenUpdates = self._forceParseAndTokenizeContent(range, startOffsetOfRangeInDocument, endOffsetOfRangeInDocument, content, true);
        if (tokenUpdates == null or self._rangeHasTokens(range, .viewportGuess)) {
            continue;
        }
        if (tokenUpdates.len == 0) {
            continue;
        }
        const lastToken = tokenUpdates[tokenUpdates.length - 1];
        const oldRangeLength = lastToken.startOffsetInclusive + lastToken.length - tokenUpdates[0].startOffsetInclusive;
        self._updateTokensInStore(version, &[_]TokensUpdate{.{ .newTokens = tokenUpdates, .oldRangeLength = oldRangeLength }}, .viewportGuess);
        self.onDidChangeTokens.fire(.{
            .changes = .{
                .semanticTokensApplied = false,
                .ranges = &[_]ModelTokensChangedRange{.{
                    .fromLineNumber = range.startLineNumber,
                    .toLineNumber = range.endLineNumber,
                }},
            },
        });
    }
}

fn _guessTokensForLinesContent(self: *Self, lineNumber: usize, lines: []const []const u8) !?ArrayList(ArrayList(TokenPacked)) {
    if (lines.length == 0) {
        return undefined;
    }

    const allocator = self.textModel().getAllocator();
    const lineContent = try std.mem.join(allocator, "\n", lines);
    const range = Range.init(1, 1, lineNumber + lines.length, lines[lines.length - 1].length + 1);
    const startOffset = self.textModel().getOffsetAt(.{ .lineNumber = lineNumber, .column = 1 });
    const tokens = self._forceParseAndTokenizeContent(range, startOffset, startOffset + lineContent.length, lineContent, false);
    if (tokens == null) {
        return null;
    }
    const tokensByLine = try ArrayList(ArrayList(TokenPacked)).initCapacity(allocator, lines.len);
    var tokensIndex: usize = 0;
    var tokenStartOffset: usize = 0;
    var lineStartOffset: usize = 0;
    for (0..lines.len) |i| {
        var tokensForLine = ArrayList(TokenPacked).init(allocator);
        var moveToNextLine = false;
        var j = tokensIndex;
        while (!moveToNextLine and (j < tokens.len)) : (j += 1) {
            const token = tokens[j];
            const lineAdjustedEndOffset = token.endOffset - lineStartOffset;
            const lineAdjustedStartOffset = tokenStartOffset - lineStartOffset;
            if (lineAdjustedEndOffset <= lines[i].length) {
                try tokensForLine.append(TokenPacked.init(lineAdjustedEndOffset, token.metadata));
                tokensIndex += 1;
            } else if (lineAdjustedStartOffset < lines[i].length) {
                const partialToken = TokenPacked.init(lines[i].length, token.metadata);
                try tokensForLine.append(partialToken);
                moveToNextLine = true;
            } else {
                moveToNextLine = true;
            }
            tokenStartOffset = token.endOffset;
        }

        tokensByLine.items[i] = tokensForLine;
        lineStartOffset += lines[i].len + self.textModel().getEOL().length();
    }

    return tokensByLine;
}

fn _forceParseAndTokenizeContentTokens(self: *Self, range: Range, startOffsetOfRangeInDocument: usize, endOffsetOfRangeInDocument: usize, content: []const u8) ?struct { []TokenPacked, usize } {
    const allocator = self.textModel().getAllocator();
    const likelyRelevantLines = (try findLikelyRelevantLines(self.textModel(), range.startLineNumber)).likelyRelevantLines;
    const eol = self.textModel().getEOL().toString();
    const likelyRelevantPrefix = ArrayList(u8).init(allocator);
    defer likelyRelevantPrefix.deinit();
    for (likelyRelevantLines.items, 0..likelyRelevantLines.items.len) |line, i| {
        try likelyRelevantPrefix.appendSlice(line.items);
        if (i < likelyRelevantLines.items.len - 1) {
            try likelyRelevantPrefix.appendSlice(eol);
        }
    }
    const likelyRelevantLinesLength = likelyRelevantPrefix.items.len;

    try likelyRelevantPrefix.appendSlice(content);
    const tree = self._tree.createParsedTreeSync(likelyRelevantPrefix.items);
    if (!tree) {
        return;
    }

    const treeRange = Range.init(1, 1, range.endLineNumber - range.startLineNumber + 1 + likelyRelevantLines.length, range.endColumn);
    const captures = self.captureAtRange(treeRange);
    const tokens = self._tokenizeCapturesWithMetadata(captures, likelyRelevantLinesLength, endOffsetOfRangeInDocument - startOffsetOfRangeInDocument + likelyRelevantLinesLength);
    tree.delete();

    if (!tokens) {
        return null;
    }
    return .{ tokens, likelyRelevantLinesLength };
}

fn _forceParseAndTokenizeContent(
    self: *Self,
    range: Range,
    startOffsetOfRangeInDocument: usize,
    endOffsetOfRangeInDocument: usize,
    content: []const u8,
) ?[]TokenPacked {
    if (self._forceParseAndTokenizeContentTokens(range, startOffsetOfRangeInDocument, endOffsetOfRangeInDocument, content)) |res| {
        return res.@"0";
    }
    return null;
}

fn _forceParseAndTokenizeContentAsUpdate(self: *Self, range: Range, startOffsetOfRangeInDocument: usize, endOffsetOfRangeInDocument: usize, content: []const u8) ?[]TokenUpdate {
    if (self._forceParseAndTokenizeContentTokens(range, startOffsetOfRangeInDocument, endOffsetOfRangeInDocument, content)) |res| {
        return self._rangeTokensAsUpdates(startOffsetOfRangeInDocument, res.@"0", res.@"1");
    }
    return null;
}

fn _firstTreeUpdate(self: *Self, versionId: i32) void {
    self._setViewPortTokens(versionId);
}

fn _setViewPortTokens(self: *Self, versionId: i64) void {
    var rangeChanges = ArrayList(RangeChange).init(self.textModel().getAllocator());
    defer rangeChanges.deinit();
    for (self._visibleLineRanges) |lineRange| {
        if (lineRange.toInclusiveRange()) |range| {
            const newRangeStartOffset = self.textModel().getOffsetAt(range.getStartPosition());
            const newRangeEndOffset = self.textModel().getOffsetAt(range.getEndPosition());
            try rangeChanges.append(.{
                .newRange = range,
                .newRangeEndOffset = newRangeEndOffset,
                .newRangeStartOffset = newRangeStartOffset,
            });
        }
    }
    return self._handleTreeUpdate(rangeChanges.items, versionId);
}

// Do not await in this method, it will cause a race
fn _handleTreeUpdate(self: *Self, ranges: []const RangeChange, versionId: i64) void {
    var rangeChanges = ArrayList(RangeWithOffsets).init(self.textModel().getAllocator());
    defer rangeChanges.deinit();

    const chunkSize = 1000;

    for (0..ranges.len) |i| {
        const rangeLinesLength = ranges[i].newRange.endLineNumber - ranges[i].newRange.startLineNumber;
        if (rangeLinesLength > chunkSize) {
            // Split the range into chunks to avoid long operations
            const fullRangeEndLineNumber = ranges[i].newRange.endLineNumber;
            var chunkLineStart = ranges[i].newRange.startLineNumber;
            var chunkColumnStart = ranges[i].newRange.startColumn;
            var chunkLineEnd = chunkLineStart + chunkSize;
            while (true) {
                const chunkStartingPosition = Position.init(chunkLineStart, chunkColumnStart);
                const chunkEndColumn = if (chunkLineEnd == ranges[i].newRange.endLineNumber)
                    ranges[i].newRange.endColumn
                else
                    self.textModel().getLineMaxColumn(chunkLineEnd);
                const chunkEndPosition = Position.init(chunkLineEnd, chunkEndColumn);
                const chunkRange = Range.fromPositions(chunkStartingPosition, chunkEndPosition);

                rangeChanges.append(.{ .range = chunkRange, .startOffset = self.textModel().getOffsetAt(chunkRange.getStartPosition()), .endOffset = self.textModel().getOffsetAt(chunkRange.getEndPosition()) });

                chunkLineStart = chunkLineEnd + 1;
                chunkColumnStart = 1;
                if (chunkLineEnd < fullRangeEndLineNumber and chunkLineEnd + chunkSize > fullRangeEndLineNumber) {
                    chunkLineEnd = fullRangeEndLineNumber;
                } else {
                    chunkLineEnd = chunkLineEnd + chunkSize;
                }

                if (!(chunkLineEnd <= fullRangeEndLineNumber)) {
                    break;
                }
            }
        } else {
            // Check that the previous range doesn't overlap
            if ((i == 0) or (rangeChanges[i - 1].endOffset < ranges[i].newRangeStartOffset)) {
                rangeChanges.append(.{ .range = ranges[i].newRange, .startOffset = ranges[i].newRangeStartOffset, .endOffset = ranges[i].newRangeEndOffset });
            } else if (rangeChanges[i - 1].endOffset < ranges[i].newRangeEndOffset) {
                // clip the range to the previous range
                const startPosition = self.textModel().getPositionAt(rangeChanges[i - 1].endOffset + 1);
                const range = Range.init(startPosition.lineNumber, startPosition.column, ranges[i].newRange.endLineNumber, ranges[i].newRange.endColumn);
                try rangeChanges.append(.{ .range = range, .startOffset = rangeChanges[i - 1].endOffset + 1, .endOffset = ranges[i].newRangeEndOffset });
            }
        }
    }

    // Get the captures immediately while the text model is correct
    var captures = ArrayList(QueryCapture).init(self.textModel().getAllocator());
    defer captures.deinit();
    for (rangeChanges.items) |range| {
        try captures.append(self._getCaptures(range.range));
    }
    // Don't block
    // return self._updateTreeForRanges(rangeChanges, versionId, captures).then(() => {
    //if (!this._textModel.isDisposed() && (this._tree.treeLastParsedVersion.get() === this._textModel.getVersionId())) {
    //this._refreshNeedsRefresh(versionId);
    //}
    // TODO: start a thread?
    self._updateTreeForRanges(rangeChanges, versionId, captures);
    if (self._tree.treeLastParsedVersion == self.textModel().getVersionId()) {
        self._refreshNeedsRefresh(versionId);
    }
}

fn _updateTreeForRanges(self: *Self, rangeChanges: []RangeWithOffsets, versionId: i64, captures: []const []const QueryCapture) void {
    var tokenUpdate: TokensUpdate = undefined;

    for (0..rangeChanges.len) |i| {
        if (!self.textModel().isDisposed() and versionId != self.textModel().getVersionId()) {
            // Our captures have become invalid and we need to re-capture
            break;
        }
        const capture = captures[i];
        const range = rangeChanges[i];

        const updates = self.getTokensInRange(range.range, range.startOffset, range.endOffset, capture);
        if (updates) {
            tokenUpdate = .{ .newTokens = updates };
        } else {
            tokenUpdate = .{ .newTokens = &[_]TokenUpdate{} };
        }
        self._updateTokensInStore(versionId, &[_]TokensUpdate{tokenUpdate}, .accurate);
        self.onDidChangeTokens.fire(.{
            .changes = .{
                .semanticTokensApplied = false,
                .ranges = &[_]ModelTokensChangedRange{.{
                    .fromLineNumber = range.range.getStartPosition().lineNumber,
                    .toLineNumber = range.range.getEndPosition().lineNumber,
                }},
            },
        });
    }
    self.onDidCompleteBackgroundTokenization.fire();
}

fn _refreshNeedsRefresh(self: *Self, versionId: i64) !void {
    var rangesToRefresh = self._getNeedsRefresh();
    defer rangesToRefresh.deinit();

    if (rangesToRefresh.items.len == 0) {
        return;
    }

    const allocator = rangesToRefresh.allocator;
    const rangeChanges = try allocator.alloc(RangeChange, rangesToRefresh.items.len);
    defer allocator.free(rangeChanges);

    for (rangesToRefresh.items, 0..) |range, i| {
        rangeChanges[i] = .{
            .newRange = range.range,
            .newRangeStartOffset = range.startOffset,
            .newRangeEndOffset = range.endOffset,
        };
    }

    self._handleTreeUpdate(rangeChanges, versionId);
}

fn _rangeTokensAsUpdates(self: *Self, rangeOffset: usize, endOffsetToken: []EndOffsetWithMeta, startingOffsetInArray: ?usize) ![]TokenUpdate {
    var updates = ArrayList(TokenUpdate).init(self.textModel().getAllocator());
    defer updates.deinit();
    var lastEnd = 0;
    for (endOffsetToken) |token| {
        if (token.endOffset <= lastEnd or (startingOffsetInArray and (token.endOffset < startingOffsetInArray))) {
            continue;
        }
        var tokenUpdate: TokenUpdate = undefined;
        if (startingOffsetInArray and (lastEnd < startingOffsetInArray)) {
            tokenUpdate = .{
                .startOffsetInclusive = rangeOffset + startingOffsetInArray,
                .length = token.endOffset - startingOffsetInArray,
                .token = token.metadata,
            };
        } else {
            tokenUpdate = .{
                .startOffsetInclusive = rangeOffset + lastEnd,
                .length = token.endOffset - lastEnd,
                .token = token.metadata,
            };
        }
        try updates.append(tokenUpdate);
        lastEnd = token.endOffset;
    }
    return try updates.toOwnedSlice();
}

fn _updateTheme(self: *Self) void {
    const modelRange = self.textModel().getFullModelRange();
    self._markForRefresh(modelRange);
    self._parseAndTokenizeViewPort(self._visibleLineRanges);
}

// Was used for inspect editor tokens command
pub fn captureAtPosition(self: *Self, lineNumber: usize, column: usize) []QueryCapture {
    const captures = self.captureAtRangeWithInjections(Range.init(lineNumber, column, lineNumber, column + 1));
    return captures;
}

// Was used for the colorization tests
pub fn captureAtRangeTree(self: *Self, range: Range) []QueryCapture {
    const captures = self.captureAtRangeWithInjections(range);
    return captures;
}

fn captureAtRange(self: *Self, range: Range) !ArrayList(QueryCapture) {
    if (self._tree._tree) |tree| {
        // Tree sitter row is 0 based, column is 0 based
        var queryCursor = ts.QueryCursor.create();
        defer queryCursor.destroy();

        queryCursor.exec(self._highlightingQueries, tree.rootNode());
        queryCursor.setPointRange(rangeStartToTSPoint(range), rangeEndToTSPoint(range));

        var result = ArrayList(QueryCapture).init(self.textModel().getAllocator());
        while (true) {
            if (queryCursor.nextCapture()) |c| {
                const i = c.@"0";
                const match = c.@"1";
                const capture = match.captures[i];
                result.append(.{
                    // FIXME: ??
                    .name = "",
                    // FIXME: ??
                    .text = null,
                    .node = .{
                        .startIndex = capture.node.startIndex,
                        .endIndex = capture.node.endIndex,
                        .startPosition = .{ .lineNumber = capture.node.startPoint().row + 1, .column = capture.node.startPoint().column + 1 },
                        .endPosition = .{ .lineNumber = capture.node.endPoint().row + 1, .column = capture.node.endPoint().column + 1 },
                    },
                    .encodedLanguageId = self._encodedLanguageId,
                });
            } else {
                break;
            }
        }

        return result;
    } else {
        return ArrayList(QueryCapture).init(self.textModel().getAllocator());
    }
}

fn captureAtRangeWithInjections(self: *Self, range: Range) ![]QueryCapture {
    const captures = try self.captureAtRange(range);
    for (captures.items, 0..) |capture, i| {
        const capStartLine = capture.node.startPosition.lineNumber;
        const capEndLine = capture.node.endPosition.lineNumber;
        const capStartColumn = capture.node.startPosition.column;
        const capEndColumn = capture.node.endPosition.column;

        const startLine = if ((capStartLine > range.startLineNumber) and (capStartLine < range.endLineNumber)) capStartLine else range.startLineNumber;
        const endLine = if ((capEndLine > range.startLineNumber) and (capEndLine < range.endLineNumber)) capEndLine else range.endLineNumber;
        const startColumn = if (capStartLine == range.startLineNumber)
            (if (capStartColumn < range.startColumn) range.startColumn else capStartColumn)
        else
            (if (capStartLine < range.startLineNumber) range.startColumn else capStartColumn);
        const endColumn = if (capEndLine == range.endLineNumber)
            (if (capEndColumn > range.endColumn) range.endColumn else capEndColumn)
        else
            (if (capEndLine > range.endLineNumber) range.endColumn else capEndColumn);
        const injectionRange = Range.init(startLine, startColumn, endLine, endColumn);

        const injection = self._getInjectionCaptures(capture, injectionRange);
        if (injection and injection.len > 0) {
            try captures.insertSlice(i + 1, injection);
            i += injection.len;
        }
    }
    return captures;
}

// Gets the tokens for a given line.
// Each token takes 2 elements in the array. The first element is the offset of the end of the token *in the line, not in the document*, and the second element is the metadata.
//
// @param lineNumber
// @returns
pub fn tokenizeEncoded(self: *Self, lineNumber: usize) void {
    if (self._tokenizeEncoded(lineNumber)) |res| {
        const tokens = res.@"0";
        const versionId = res.@"1";

        const updates = try self._rangeTokensAsUpdates(self.textModel().getOffsetAt(.{ .lineNumber = lineNumber, .column = 1 }), tokens);
        if (versionId == self.textModel().getVersionId()) {
            self._updateTokensInStore(
                versionId,
                &[_]TokensUpdate{.{
                    .newTokens = updates,
                    .oldRangeLength = self.textModel().getLineLength(lineNumber),
                }},
                .accurate,
            );
        }
    }
}

fn _getCaptures(self: *Self, range: Range) []QueryCapture {
    const captures = self.captureAtRangeWithInjections(range);
    return captures;
}

fn _tokenize(self: *Self, range: Range, rangeStartOffset: usize, rangeEndOffset: usize) ?struct { []TokenPacked, i64 } {
    const captures = self._getCaptures(range);
    if (self._tokenizeCapturesWithMetadata(captures, rangeStartOffset, rangeEndOffset)) |tokens| {
        return .{ tokens, self._tree.treeLastParsedVersion };
    }
    return null;
}

fn _createTokensFromCaptures(_self: *Self, _captures: []QueryCapture, _rangeStartOffset: usize, _rangeEndOffset: usize) ?[]EndOffsetWithMeta {
    const run = struct {
        const Ctx = @This();
        const baseScope = "source.zig";

        tokenIndex: usize,
        allocator: Allocator,
        endOffsetsAndScopes: []EndOffsetAndScopes,
        encodedLanguageId: u32,

        fn run(self: *Self, captures: []QueryCapture, rangeStartOffset: usize, rangeEndOffset: usize) ?[]EndOffsetWithMeta {
            var ctx: Ctx = undefined;

            const allocator = self.textModel().getAllocator();
            ctx.allocator = allocator;
            const tree = self._tree._tree;
            const rangeLength = rangeEndOffset - rangeStartOffset;
            ctx.encodedLanguageId = self._languageIdCodec.encodeLanguageId(self._tree.languageId);

            if (captures.len == 0) {
                if (tree) {
                    return &[_]EndOffsetWithMeta{
                        .{ .endOffset = rangeLength, .scopes = &[_][]const u8{}, .encodedLanguageId = ctx.encodedLanguageId },
                    };
                }
                return null;
            }

            ctx.endOffsetsAndScopes = allocator.alloc(EndOffsetAndScopes, captures.len);
            for (ctx.endOffsetsAndScopes) |*endOffset| {
                endOffset.* = .{ .endOffset = 0, .scopes = &[_][]const u8{baseScope}, .encodedLanguageId = ctx.encodedLanguageId };
            }

            ctx.tokenIndex = 0;

            for (0..captures.len) |captureIndex| {
                const capture = captures[captureIndex];
                const tokenEndIndex = if (capture.node.endIndex < rangeEndOffset)
                    (if (capture.node.endIndex < rangeStartOffset) rangeStartOffset else capture.node.endIndex)
                else
                    rangeEndOffset;
                const tokenStartIndex = if (capture.node.startIndex < rangeStartOffset) rangeStartOffset else capture.node.startIndex;

                const endOffset = tokenEndIndex - rangeStartOffset;

                // Not every character will get captured, so we need to make sure that our current capture doesn't bleed toward the start of the line and cover characters that it doesn't apply to.
                // We do this by creating a new token in the array if the previous token ends before the current token starts.
                var previousEndOffset: usize = 0;
                const currentTokenLength = tokenEndIndex - tokenStartIndex;
                if (captureIndex > 0) {
                    previousEndOffset = ctx.endOffsetsAndScopes[ctx.tokenIndex - 1].endOffset;
                } else {
                    previousEndOffset = tokenStartIndex - rangeStartOffset - 1;
                }
                const startOffset = endOffset - currentTokenLength;
                if ((previousEndOffset >= 0) and (previousEndOffset < startOffset)) {
                    // Add en empty token to cover the space where there were no captures
                    ctx.endOffsetsAndScopes[ctx.tokenIndex] = .{ .endOffset = startOffset, .scopes = &[_][]const u8{baseScope}, .encodedLanguageId = ctx.encodedLanguageId };
                    ctx.tokenIndex += 1;

                    ctx.increaseSizeOfTokensByOneToken();
                }

                if (currentTokenLength < 0) {
                    // This happens when we have a token "gap" right at the end of the capture range. The last capture isn't used because it's start index isn't included in the range.
                    continue;
                }

                if (previousEndOffset >= endOffset) {
                    // walk back through the tokens until we find the one that contains the current token
                    var withinTokenIndex = ctx.tokenIndex - 1;
                    var previousTokenEndOffset = ctx.endOffsetsAndScopes[withinTokenIndex].endOffset;

                    var previousTokenStartOffset = if (withinTokenIndex >= 2) ctx.endOffsetsAndScopes[withinTokenIndex - 1].endOffset else 0;
                    while (true) {
                        // Check that the current token doesn't just replace the last token
                        if ((previousTokenStartOffset + currentTokenLength) == previousTokenEndOffset) {
                            if (previousTokenStartOffset == startOffset) {
                                // Current token and previous token span the exact same characters, add the scopes to the previous token
                                try ctx.endOffsetsAndScopes[withinTokenIndex].scopes.append(capture.name);
                                const oldBracket = ctx.endOffsetsAndScopes[withinTokenIndex].bracket;
                                ctx.endOffsetsAndScopes[withinTokenIndex].bracket = if (oldBracket != null and (oldBracket.?.len > 0)) oldBracket.? else brackets(capture, startOffset);
                            }
                        } else if (previousTokenStartOffset <= startOffset) {
                            ctx.addCurrentTokenToArray(capture, startOffset, endOffset, withinTokenIndex);
                            break;
                        }
                        withinTokenIndex -= 1;
                        previousTokenStartOffset = if (withinTokenIndex >= 1) ctx.endOffsetsAndScopes[withinTokenIndex - 1].endOffset else 0;
                        previousTokenEndOffset = if (withinTokenIndex >= 0) ctx.endOffsetsAndScopes[withinTokenIndex].endOffset else 0;
                        if (!(previousTokenEndOffset > startOffset)) {
                            break;
                        }
                    }
                } else {
                    // Just add the token to the array
                    ctx.addCurrentTokenToArray(capture, startOffset, endOffset);
                }
            }

            // Account for uncaptured characters at the end of the line
            if ((ctx.endOffsetsAndScopes[ctx.tokenIndex - 1].endOffset < rangeLength)) {
                if (rangeLength - ctx.endOffsetsAndScopes[ctx.tokenIndex - 1].endOffset > 0) {
                    ctx.increaseSizeOfTokensByOneToken();
                    ctx.endOffsetsAndScopes[ctx.tokenIndex] = .{ .endOffset = rangeLength, .scopes = ctx.endOffsetsAndScopes[ctx.tokenIndex].scopes, .encodedLanguageId = ctx.encodedLanguageId };
                    ctx.tokenIndex += 1;
                }
            }
            for (0..ctx.endOffsetsAndScopes.len) |i| {
                const token = ctx.endOffsetsAndScopes[i];
                if (token.endOffset == 0 and i != 0) {
                    ctx.endOffsetsAndScopes.splice(i, ctx.endOffsetsAndScopes.len - i);
                    break;
                }
            }
            return ctx.endOffsetsAndScopes;
        }

        fn brackets(ctx: *Ctx, capture: QueryCapture, startOffset: usize) ?[]usize {
            if (std.mem.indexOf(capture.name, "punctuation") != null and capture.text) {
                const bs = ArrayList(usize).init(ctx.allocator);
                _ = startOffset;
                // for (capture.text.matchAll(BRACKETS)) |match| {
                //     try bs.append(startOffset + match.index);
                // }
                return bs;
            } else {
                return null;
            }
        }

        fn increaseSizeOfTokensByOneToken(ctx: *Ctx) void {
            try ctx.endOffsetsAndScopes.append(.{ .endOffset = 0, .scopes = &[_][]const u8{baseScope}, .encodedLanguageId = ctx.encodedLanguageId });
        }

        fn addCurrentTokenToArray(ctx: *Ctx, capture: QueryCapture, startOffset: usize, endOffset: usize, position: ?usize) void {
            if (position != null) {
                const oldScopes = ctx.endOffsetsAndScopes[position].scopes;
                var oldBracket = ctx.endOffsetsAndScopes[position].bracket;
                // Check that the previous token ends at the same point that the current token starts
                const prevEndOffset = if (position > 0) ctx.endOffsetsAndScopes[position - 1].endOffset else 0;
                if (prevEndOffset != startOffset) {
                    var preInsertBracket = ArrayList(usize).init(ctx.allocator);
                    if (oldBracket and oldBracket.len > 0) {
                        var postInsertBracket = ArrayList(usize).init(ctx.allocator);
                        for (oldBracket) |bracket| {
                            if (bracket < startOffset) {
                                try preInsertBracket.append(bracket);
                            } else if (bracket > endOffset) {
                                try postInsertBracket.append(bracket);
                            }
                        }
                        if (preInsertBracket.items.len == 0) {
                            preInsertBracket = undefined;
                        }
                        if (postInsertBracket.items.len == 0) {
                            oldBracket = null;
                        } else {
                            oldBracket = postInsertBracket;
                        }
                    }
                    // We need to add some of the position token to cover the space
                    try ctx.endOffsetsAndScopes.insertSlice(position, &[_]EndOffsetAndScopes{.{ .endOffset = startOffset, .scopes = oldScopes, .bracket = preInsertBracket, .encodedLanguageId = capture.encodedLanguageId }});
                    position += 1;
                    ctx.increaseSizeOfTokensByOneToken();
                    ctx.tokenIndex += 1;
                }

                ctx.endOffsetsAndScopes.splice(position, 0, &[_]EndOffsetAndScopes{.{ .endOffset = endOffset, .scopes = oldScopes, .bracket = brackets(capture, startOffset), .encodedLanguageId = capture.encodedLanguageId }});
                ctx.endOffsetsAndScopes[ctx.tokenIndex].bracket = oldBracket;
            } else {
                ctx.endOffsetsAndScopes[ctx.tokenIndex] = .{ .endOffset = endOffset, .scopes = &[_][]const u8{ baseScope, capture.name }, .bracket = ctx.brackets(capture, startOffset), .encodedLanguageId = capture.encodedLanguageId };
            }
            ctx.tokenIndex += 1;
        }
    }.run;

    return run(_self, _captures, _rangeStartOffset, _rangeEndOffset);
}

fn _getInjectionCaptures(parentCapture: QueryCapture, range: Range) []QueryCapture {
    _ = parentCapture;
    _ = range;
    //
    // const injection = textModelTreeSitter.getInjection(parentCapture.node.startIndex, this._treeSitterModel.languageId);
    // if (!injection?.tree || injection.versionId !== textModelTreeSitter.parseResult?.versionId) {
    // return undefined;
    // }

    // const feature = TreeSitterTokenizationRegistry.get(injection.languageId);
    // if (!feature) {
    // return undefined;
    // }
    // return feature.tokSupport_captureAtRangeTree(range, injection.tree, textModelTreeSitter);
    return &[_]QueryCapture{};
}

fn _tokenizeCapturesWithMetadata(self: *Self, captures: []QueryCapture, rangeStartOffset: usize, rangeEndOffset: usize) ?[]TokenPacked {
    // const stopwatch = StopWatch.create();
    if (self._createTokensFromCaptures(captures, rangeStartOffset, rangeEndOffset)) |endOffsetsAndScopes| {
        for (endOffsetsAndScopes) |token| {
            token.metadata = self._treeSitterThemeService.findMetadata(
                token.scopes,
                token.encodedLanguageId,
                token.bracket != null and (token.bracket.?.len > 0),
                null,
            );
        }
        return endOffsetsAndScopes;
    } else {
        return null;
    }
}

fn _tokenizeEncoded(self: *Self, lineNumber: usize) ?struct { []TokenPacked, i64 } {
    const lineOffset = self.textModel().getOffsetAt(.{ .lineNumber = lineNumber, .column = 1 });
    const maxLine = self.textModel().getLineCount();
    const lineEndOffset = if (lineNumber + 1 <= maxLine)
        self.textModel().getOffsetAt(.{ .lineNumber = lineNumber + 1, .column = 1 })
    else
        self.textModel().getValueLength();

    const lineLength = lineEndOffset - lineOffset;
    return self._tokenize(Range.init(lineNumber, 1, lineNumber, lineLength + 1), lineOffset, lineEndOffset);
}

const TokensUpdate = struct {
    oldRangeLength: ?usize = null,
    newTokens: []const TokenUpdate,
};

const EndOffsetAndScopes = struct {
    endOffset: usize,
    scopes: []const []const u8,
    bracket: ?[]const usize,
    encodedLanguageId: u32,
};

const EndOffsetWithMeta = struct {
    endOffset: usize,
    scopes: []const []const u8,
    bracket: ?[]const usize,
    encodedLanguageId: u32,
    metadata: ?TokenMetadata = null,
};

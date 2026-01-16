const std = @import("std");
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

const Self = @This();

_tokenStore: TokenStore,
_accurateVersion: i64,
_guessVersion: i64,
onDidChangeTokens: Emitter(struct { changes: ModelTokensChangedEvent }),
onDidChangeBackgroundTokenization: Emitter(void),
_tree: TreeSitterTree,
_encodedLanguageId: u8,
_languageIdCodec: *const LanguageIdCodec,
_treeSitterThemeService: *const TreeSitterThemeService,
_visibleLineRanges: []const LineRange,

fn init(
    _tree: TreeSitterTree,
    _languageIdCodec: *const LanguageIdCodec,
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

const TokensUpdate = struct {
    oldRangeLength: ?usize,
    newTokens: []const TokenUpdate,
};

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

fn _updateTheme(self: *Self) void {
    const modelRange = self.textModel().getFullModelRange();
    self._markForRefresh(modelRange);
    self._parseAndTokenizeViewPort(self._visibleLineRanges);
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

fn _rangeHasTokens(self: *Self, range: Range, minimumTokenQuality: TokenQuality) bool {
    return self._tokenStore.rangeHasTokens(self.textModel().getOffsetAt(range.getStartPosition()), self.textModel().getOffsetAt(range.getEndPosition()), minimumTokenQuality);
}

pub fn hasTokens(self: *Self, accurateForRange: ?Range) bool {
    if (accurateForRange == null or (self._guessVersion == self._accurateVersion)) {
        return true;
    }

    return !self._tokenStore.rangeNeedsRefresh(self.textModel().getOffsetAt(accurateForRange.?.getStartPosition()), self.textModel().getOffsetAt(accurateForRange.?.getEndPosition()));
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

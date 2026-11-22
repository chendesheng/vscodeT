// Port of `src/vs/editor/common/tokens/sparseTokensStore.ts`.
//
// Zig adaptation: the store takes ownership of the pieces it receives and
// frees them in `flush`/`deinit`; `addSparseTokens` also takes ownership of
// the syntactic line tokens it merges into.
const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Range = @import("../core/range.zig").Range;
const LineTokens = @import("./lineTokens.zig").LineTokens;
const SparseMultilineTokens = @import("./sparseMultilineTokens.zig").SparseMultilineTokens;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const TextModel = @import("../model/textModel.zig").TextModel;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const SemanticMetadata = @import("../encodedTokenAttributes.zig").SemanticMetadata;
const SparseMultilineTokensStorage = @import("./sparseMultilineTokens.zig").SparseMultilineTokensStorage;
const SparseToken = @import("./sparseMultilineTokens.zig").SparseToken;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const TokenPacked = @import("./lineTokens.zig").TokenPacked;

pub const SparseTokensStore = struct {
    _pieces: ArrayList(SparseMultilineTokens),
    _isComplete: bool,
    _languageIdCodec: *LanguageIdCodec,

    pub fn init(allocator: Allocator, languageIdCodec: *LanguageIdCodec) SparseTokensStore {
        return .{
            ._pieces = ArrayList(SparseMultilineTokens).init(allocator),
            ._isComplete = false,
            ._languageIdCodec = languageIdCodec,
        };
    }

    pub fn deinit(self: *SparseTokensStore) void {
        for (self._pieces.items) |*piece| piece.deinit();
        self._pieces.deinit();
    }

    pub fn flush(self: *SparseTokensStore) void {
        for (self._pieces.items) |*piece| piece.deinit();
        self._pieces.clearRetainingCapacity();
        self._isComplete = false;
    }

    pub fn isEmpty(self: *const SparseTokensStore) bool {
        return self._pieces.items.len == 0;
    }

    pub fn isComplete(self: *const SparseTokensStore) bool {
        return self._isComplete;
    }

    /// Takes ownership of the provided pieces.
    pub fn set(self: *SparseTokensStore, pieces: ?[]SparseMultilineTokens, isComplete_: bool, textModel: ?*const TextModel) !void {
        for (self._pieces.items) |*piece| piece.deinit();
        self._pieces.clearRetainingCapacity();
        if (pieces) |newPieces| {
            try self._pieces.appendSlice(newPieces);
        }
        self._isComplete = isComplete_;

        if (textModel) |model| {
            for (self._pieces.items) |*piece| piece.reportIfInvalid(model);
        }
    }

    /// Takes ownership of the provided pieces and merges them over `_range`.
    pub fn setPartial(self: *SparseTokensStore, _range: Range, pieces: []SparseMultilineTokens) !Range {
        var range = _range;
        if (pieces.len > 0) {
            const firstRange = pieces[0].getRange() orelse return _range;
            const lastRange = pieces[pieces.len - 1].getRange() orelse return _range;
            range = Range.plusRange(&range, &firstRange);
            range = Range.plusRange(&range, &lastRange);
        }

        var insertPosition: ?usize = null;
        var i: usize = 0;
        while (i < self._pieces.items.len) {
            const piece = &self._pieces.items[i];
            if (piece.getEndLineNumber() < range.startLineNumber) {
                i += 1;
                continue;
            }
            if (piece.getStartLineNumber() > range.endLineNumber) {
                insertPosition = insertPosition orelse i;
                break;
            }

            piece.removeTokens(range);

            if (piece.isEmpty()) {
                piece.deinit();
                _ = self._pieces.orderedRemove(i);
                continue;
            }

            if (piece.getEndLineNumber() < range.startLineNumber) {
                i += 1;
                continue;
            }
            if (piece.getStartLineNumber() > range.endLineNumber) {
                insertPosition = insertPosition orelse i;
                i += 1;
                continue;
            }

            var split = try piece.split(range);
            const firstIsEmpty = split[0].isEmpty();
            const secondIsEmpty = split[1].isEmpty();
            if (firstIsEmpty or secondIsEmpty) {
                // Upstream keeps the mutated piece in place when one side of
                // the split is empty; only a real two-sided split replaces it.
                split[0].deinit();
                split[1].deinit();
                if (firstIsEmpty) {
                    insertPosition = insertPosition orelse i;
                }
                i += 1;
                continue;
            }

            // Reserve before dropping the original so a failing allocation
            // cannot leave the store without the piece.
            try self._pieces.ensureUnusedCapacity(2);
            piece.deinit();
            _ = self._pieces.orderedRemove(i);
            try self._pieces.insertSlice(i, split[0..]);
            i += 2;
            // Insert the new pieces between the two split halves.
            insertPosition = insertPosition orelse (i - 1);
        }

        const index = insertPosition orelse self._pieces.items.len;
        if (pieces.len > 0) {
            try self._pieces.ensureUnusedCapacity(pieces.len);
            try self._pieces.insertSlice(index, pieces);
        }
        return range;
    }

    pub fn addSparseTokens(self: *SparseTokensStore, lineNumber: usize, aTokens: LineTokens) !LineTokens {
        errdefer {
            var input = aTokens;
            input.deinit();
        }
        if (aTokens.getTextLength() == 0) return aTokens;
        if (self._pieces.items.len == 0) return aTokens;

        const pieceIndex = SparseTokensStore._findFirstPieceWithLine(self._pieces.items, lineNumber);
        const bTokens = self._pieces.items[pieceIndex].getLineTokens(lineNumber) orelse return aTokens;

        const aLen = aTokens.getCount();
        const bLen = bTokens.getCount();
        var aIndex: usize = 0;
        var result = ArrayList(TokenPacked).init(self._pieces.allocator);
        errdefer result.deinit();
        var lastEndOffset: usize = 0;

        const emitToken = struct {
            fn emit(list: *ArrayList(TokenPacked), last: *usize, endOffset: usize, metadata: TokenMetadata) !void {
                if (endOffset <= last.*) return;
                last.* = endOffset;
                try list.append(.{ .endOffset = @intCast(endOffset), .metadata = metadata });
            }
        }.emit;

        for (0..bLen) |bIndex| {
            const bStartCharacter: usize = @min(bTokens.getStartCharacter(bIndex), aTokens.getTextLength());
            const bEndCharacter: usize = @min(bTokens.getEndCharacter(bIndex), aTokens.getTextLength());
            const bMetadata = bTokens.getMetadata(bIndex);

            var bMask: TokenMetadata = TokenMetadata.default;
            const semanticMask: SemanticMetadata = @bitCast(bMetadata.languageId);
            bMask.fontStyle.italic = semanticMask.useItalic;
            bMask.fontStyle.bold = semanticMask.useBold;
            bMask.fontStyle.underline = semanticMask.useUnderline;
            bMask.fontStyle.strikethrough = semanticMask.useStrikethrough;
            bMask.foreground = if (semanticMask.useForeground) ColorId.Mask else ColorId.None;
            // Upstream's BACKGROUND_MASK covers the 8-bit background field,
            // while ColorId.Mask is the 9-bit foreground mask.
            bMask.background = if (semanticMask.useBackground) 0xFF else 0;
            const aMask: u32 = ~@as(u32, @bitCast(bMask));
            const bMaskBits: u32 = @bitCast(bMask);

            while (aIndex < aLen and aTokens.getEndOffset(aIndex) <= bStartCharacter) {
                try emitToken(&result, &lastEndOffset, aTokens.getEndOffset(aIndex), aTokens.getMetadata(aIndex));
                aIndex += 1;
            }

            if (aIndex < aLen and aTokens.getStartOffset(aIndex) < bStartCharacter) {
                try emitToken(&result, &lastEndOffset, bStartCharacter, aTokens.getMetadata(aIndex));
            }

            while (aIndex < aLen and aTokens.getEndOffset(aIndex) < bEndCharacter) {
                const metadata: TokenMetadata = @bitCast((@as(u32, @bitCast(aTokens.getMetadata(aIndex))) & aMask) | (@as(u32, @bitCast(bMetadata)) & bMaskBits));
                try emitToken(&result, &lastEndOffset, aTokens.getEndOffset(aIndex), metadata);
                aIndex += 1;
            }

            if (aIndex < aLen) {
                const metadata: TokenMetadata = @bitCast((@as(u32, @bitCast(aTokens.getMetadata(aIndex))) & aMask) | (@as(u32, @bitCast(bMetadata)) & bMaskBits));
                try emitToken(&result, &lastEndOffset, bEndCharacter, metadata);
                if (aTokens.getEndOffset(aIndex) == bEndCharacter) aIndex += 1;
            } else {
                const aMergeIndex = @min(if (aIndex == 0) 0 else aIndex - 1, aLen - 1);
                const metadata: TokenMetadata = @bitCast((@as(u32, @bitCast(aTokens.getMetadata(aMergeIndex))) & aMask) | (@as(u32, @bitCast(bMetadata)) & bMaskBits));
                try emitToken(&result, &lastEndOffset, bEndCharacter, metadata);
            }
        }

        while (aIndex < aLen) {
            try emitToken(&result, &lastEndOffset, aTokens.getEndOffset(aIndex), aTokens.getMetadata(aIndex));
            aIndex += 1;
        }

        var input = aTokens;
        const text = input._text;
        input._tokens.deinit();
        return LineTokens.init(result, text, self._languageIdCodec);
    }

    fn _findFirstPieceWithLine(pieces: []const SparseMultilineTokens, lineNumber: usize) usize {
        var low: usize = 0;
        var high: usize = pieces.len - 1;

        while (low < high) {
            var mid = low + @divFloor(high - low, 2);
            if (pieces[mid].getEndLineNumber() < lineNumber) {
                low = mid + 1;
            } else if (pieces[mid].getStartLineNumber() > lineNumber) {
                high = mid - 1;
            } else {
                while (mid > low and pieces[mid - 1].getStartLineNumber() <= lineNumber and lineNumber <= pieces[mid - 1].getEndLineNumber()) {
                    mid -= 1;
                }
                return mid;
            }
        }
        return low;
    }

    pub fn acceptEdit(self: *SparseTokensStore, range: Range, eolCount: usize, firstLineLength: usize, lastLineLength: usize, firstCharCode: u21) void {
        var i: usize = 0;
        while (i < self._pieces.items.len) {
            const piece = &self._pieces.items[i];
            piece.acceptEdit(range, eolCount, firstLineLength, lastLineLength, firstCharCode);
            if (piece.isEmpty()) {
                piece.deinit();
                _ = self._pieces.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

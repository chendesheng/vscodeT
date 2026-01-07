const std = @import("std");
const ArrayList = std.array_list.Managed;
const Range = @import("../basics/range.zig").Range;
const LineTokens = @import("lineTokens.zig").LineTokens;
const SparseMultilineTokens = @import("sparseMultilineTokens.zig").SparseMultilineTokens;
const LanguageIdCodec = @import("../services/languageRegistry.zig").LanguageIdCodec;
const MetadataConsts = @import("../encodedTokenAttributes.zig").MetadataConsts;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const Allocator = std.mem.Allocator;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const SemanticMetadata = @import("../encodedTokenAttributes.zig").SemanticMetadata;
const SparseMultilineTokensStorage = @import("sparseMultilineTokens.zig").SparseMultilineTokensStorage;
const SparseToken = @import("sparseMultilineTokens.zig").SparseToken;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const FontStyle = @import("../encodedTokenAttributes.zig").FontStyle;
const TokenPacked = @import("lineTokens.zig").TokenPacked;

// Represents sparse tokens in a text model.
pub const SparseTokensStore = struct {
    _pieces: ArrayList(SparseMultilineTokens),
    _isComplete: bool,
    _languageIdCodec: LanguageIdCodec,

    pub fn init(allocator: Allocator, languageIdCodec: LanguageIdCodec) SparseTokensStore {
        return SparseTokensStore{
            ._pieces = ArrayList(SparseMultilineTokens).init(allocator),
            ._isComplete = false,
            ._languageIdCodec = languageIdCodec,
        };
    }

    pub fn deinit(self: *SparseTokensStore) void {
        for (self._pieces.items) |*piece| {
            piece.deinit();
        }
        self._pieces.deinit();
    }

    pub fn flush(self: *SparseTokensStore) void {
        self._pieces.clearAndFree();
        self._isComplete = false;
    }

    pub fn isEmpty(self: *const SparseTokensStore) bool {
        return self._pieces.items.len == 0;
    }

    pub fn set(self: *SparseTokensStore, pieces: ?[]const SparseMultilineTokens, _isComplete: bool, textModel: ?*const TextModel) !void {
        const allocator = self._pieces.allocator;
        self._pieces.deinit();
        self._pieces = ArrayList(SparseMultilineTokens).init(allocator);
        if (pieces) |tokens| try self._pieces.appendSlice(tokens);

        self._isComplete = _isComplete;

        if (textModel) |model| {
            for (self._pieces.items) |p| {
                p.reportIfInvalid(model);
            }
        }
    }

    pub fn setPartial(self: *SparseTokensStore, _range: Range, pieces: []const SparseMultilineTokens) !Range {
        // console.log(`setPartial ${_range} ${pieces.map(p => p.toString()).join(', ')}`);

        var range = _range;
        if (pieces.len > 0) {
            const _firstRange = pieces[0].getRange();
            const _lastRange = pieces[pieces.len - 1].getRange();
            if (_firstRange == null or _lastRange == null) {
                return _range;
            }
            range = _range.plusRange(&_firstRange.?).plusRange(&_lastRange.?);
        }

        var insertPosition: ?struct { index: usize } = null;
        var i: usize = 0;
        while (i < self._pieces.items.len) : (i += 1) {
            var piece = self._pieces.items[i];
            if (piece._endLineNumber < range.startLineNumber) {
                // this piece is before the range
                continue;
            }

            if (piece._startLineNumber > range.endLineNumber) {
                // this piece is after the range, so mark the spot before this piece
                // as a good insertion position and stop looping
                insertPosition = insertPosition orelse .{ .index = i };
                break;
            }

            // this piece might intersect with the range
            piece.removeTokens(range);

            if (piece.isEmpty()) {
                // remove the piece if it became empty
                _ = self._pieces.orderedRemove(i);
                i -= 1;
                continue;
            }

            if (piece.getEndLineNumber() < range.startLineNumber) {
                // after removal, this piece is before the range
                continue;
            }

            if (piece.getStartLineNumber() > range.endLineNumber) {
                // after removal, this piece is after the range
                insertPosition = insertPosition orelse .{ .index = i };
                continue;
            }

            // after removal, this piece contains the range
            const res = try piece.split(range);
            const a = res[0];
            const b = res[1];
            if (a.isEmpty()) {
                // this piece is actually after the range
                insertPosition = insertPosition orelse .{ .index = i };
                continue;
            }
            if (b.isEmpty()) {
                // this piece is actually before the range
                continue;
            }
            try self._pieces.replaceRange(i, 1, &[_]SparseMultilineTokens{ a, b });
            i += 1;

            insertPosition = insertPosition orelse .{ .index = i };
        }

        insertPosition = insertPosition orelse .{ .index = self._pieces.items.len };

        if (pieces.len > 0) {
            try self._pieces.insertSlice(insertPosition.?.index, pieces);
        }

        // console.log(`I HAVE ${this._pieces.length} pieces`);
        // console.log(`${this._pieces.map(p => p.toString()).join('\n')}`);

        return range;
    }

    pub fn isComplete(self: *const SparseTokensStore) bool {
        return self._isComplete;
    }

    pub fn addSparseTokens(self: *SparseTokensStore, lineNumber: usize, aTokens: LineTokens) !LineTokens {
        if (aTokens.getTextLength() == 0) {
            // Don't do anything for empty lines
            return aTokens;
        }

        const pieces = self._pieces;

        if (pieces.items.len == 0) {
            return aTokens;
        }

        const pieceIndex = _findFirstPieceWithLine(pieces.items, lineNumber);

        if (pieces.items[pieceIndex].getLineTokens(lineNumber)) |bTokens| {
            const aLen = aTokens.getCount();
            const bLen = bTokens.getCount();

            var aIndex: usize = 0;
            var result = ArrayList(TokenPacked).init(pieces.allocator);
            var lastEndOffset: usize = 0;

            const emitToken = struct {
                fn emit(_result: *ArrayList(TokenPacked), _lastEndOffset: *usize, _endOffset: u32, _metadata: u32) !void {
                    if (_endOffset == _lastEndOffset.*) {
                        return;
                    }
                    _lastEndOffset.* = _endOffset;
                    try _result.append(TokenPacked.init(_endOffset, @bitCast(_metadata)));
                }
            }.emit;

            for (0..bLen) |bIndex| {
                // bTokens is not validated yet, but aTokens is. We want to make sure that the LineTokens we return
                // are valid, so we clamp the ranges to ensure that.
                const bStartCharacter: u32 = @min(bTokens.getStartCharacter(bIndex), @as(u32, @intCast(aTokens.getTextLength())));
                const bEndCharacter: u32 = @min(bTokens.getEndCharacter(bIndex), @as(u32, @intCast(aTokens.getTextLength())));
                const bMetadata = bTokens.getMetadata(bIndex);

                var bMask: TokenMetadata = TokenMetadata.default;
                const semanticMask: SemanticMetadata = @bitCast(bMetadata.languageId);
                bMask.fontStyle.italic = semanticMask.useItalic;
                bMask.fontStyle.bold = semanticMask.useBold;
                bMask.fontStyle.underline = semanticMask.useUnderline;
                bMask.fontStyle.strikethrough = semanticMask.useStrikethrough;
                bMask.foreground = if (semanticMask.useForeground) ColorId.Mask else ColorId.None;
                bMask.background = @intCast(@intFromEnum(if (semanticMask.useBackground) ColorId.Mask else ColorId.None));

                const aMask: u32 = (~@as(u32, @bitCast(bMask))) >> 0;

                // push any token from `a` that is before `b`
                while (aIndex < aLen and aTokens.getEndOffset(aIndex) <= bStartCharacter) {
                    try emitToken(&result, &lastEndOffset, aTokens.getEndOffset(aIndex), @as(u32, @bitCast(aTokens.getMetadata(aIndex))));
                    aIndex += 1;
                }

                // push the token from `a` if it intersects the token from `b`
                if (aIndex < aLen and aTokens.getStartOffset(aIndex) < bStartCharacter) {
                    try emitToken(&result, &lastEndOffset, bStartCharacter, @as(u32, @bitCast(aTokens.getMetadata(aIndex))));
                }

                // skip any tokens from `a` that are contained inside `b`
                while (aIndex < aLen and aTokens.getEndOffset(aIndex) < bEndCharacter) {
                    try emitToken(&result, &lastEndOffset, aTokens.getEndOffset(aIndex), (@as(u32, @bitCast(aTokens.getMetadata(aIndex))) & aMask) | (@as(u32, @bitCast(bMetadata)) & @as(u32, @bitCast(bMask))));
                    aIndex += 1;
                }

                if (aIndex < aLen) {
                    try emitToken(&result, &lastEndOffset, bEndCharacter, (@as(u32, @bitCast(aTokens.getMetadata(aIndex))) & aMask) | (@as(u32, @bitCast(bMetadata)) & @as(u32, @bitCast(bMask))));
                    if (aTokens.getEndOffset(aIndex) == bEndCharacter) {
                        // `a` ends exactly at the same spot as `b`!
                        aIndex += 1;
                    }
                } else {
                    const aMergeIndex: usize = @min(@max(0, aIndex - 1), aLen - 1);

                    // push the token from `b`
                    try emitToken(&result, &lastEndOffset, bEndCharacter, (@as(u32, @bitCast(aTokens.getMetadata(aMergeIndex))) & aMask) | (@as(u32, @bitCast(bMetadata)) & @as(u32, @bitCast(bMask))));
                }
            }

            // push the remaining tokens from `a`
            while (aIndex < aLen) {
                try emitToken(&result, &lastEndOffset, aTokens.getEndOffset(aIndex), @as(u32, @bitCast(aTokens.getMetadata(aIndex))));
                aIndex += 1;
            }

            return LineTokens.init(result, aTokens.getLineContent(), self._languageIdCodec);
        } else {
            return aTokens;
        }
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
        for (self._pieces.items) |*piece| {
            piece.acceptEdit(range, eolCount, firstLineLength, lastLineLength, firstCharCode);
        }
    }
};

fn createTMMetadata(foreground: ColorId, fontStyle: FontStyle, languageId: u8) TokenMetadata {
    var metadata = TokenMetadata.default;
    metadata.languageId = languageId;
    metadata.foreground = foreground;
    metadata.fontStyle = fontStyle;
    return metadata;
}

// test "issue #95949: Identifiers are colored in bold when targetting keywords" {
//     const allocator = std.testing.allocator;
//     var codec = try LanguageIdCodec.init(allocator);
//     defer codec.deinit();

//     var store = SparseTokensStore.init(allocator, codec);
//     defer store.deinit();

//     var sparseTokens = ArrayList(SparseToken).init(allocator);
//     var metadata = TokenMetadata.default;
//     metadata.languageId = @bitCast(SemanticMetadata.UseForeground);
//     metadata.foreground = ColorId.DefaultForeground;
//     try sparseTokens.append(SparseToken.init(0, 6, 11, metadata));

//     const storage = SparseMultilineTokensStorage.init(sparseTokens);

//     var multilineTokens = SparseMultilineTokens.init(1, storage);
//     defer multilineTokens.deinit();

//     var multilineTokensList = ArrayList(SparseMultilineTokens).init(allocator);
//     defer multilineTokensList.deinit();
//     try multilineTokensList.append(multilineTokens);

//     try store.set(multilineTokensList, true, null);

//     var arrTokens = ArrayList(TokenPacked).init(allocator);
//     defer arrTokens.deinit();
//     try arrTokens.appendSlice(&[_]TokenPacked{
//         .init(5, createTMMetadata(.Color5, FontStyle.Bold, 53)),
//         .init(14, createTMMetadata(.DefaultForeground, FontStyle.None, 53)),
//         .init(17, createTMMetadata(.Color6, FontStyle.None, 53)),
//         .init(18, createTMMetadata(.DefaultForeground, FontStyle.None, 53)),
//     });
//     var arrText = ArrayList(u8).init(allocator);
//     defer arrText.deinit();
//     try arrText.appendSlice("const hello = 123;");
//     const lineTokens = try store.addSparseTokens(1, LineTokens.init(arrTokens, arrText.items, codec));

//     var actual = ArrayList(TokenPacked).init(allocator);
//     defer actual.deinit();
//     for (0..lineTokens.getCount()) |i| {
//         try actual.append(TokenPacked.init(lineTokens.getEndOffset(i), lineTokens.getMetadata(i)));
//     }

//     try std.testing.expectEqualSlices(TokenPacked, &[_]TokenPacked{
//         .init(5, createTMMetadata(.Color5, FontStyle.Bold, 53)),
//         .init(6, createTMMetadata(.DefaultForeground, FontStyle.None, 53)),
//         .init(11, createTMMetadata(.DefaultForeground, FontStyle.None, 53)),
//         .init(14, createTMMetadata(.DefaultForeground, FontStyle.None, 53)),
//         .init(17, createTMMetadata(.Color6, FontStyle.None, 53)),
//         .init(18, createTMMetadata(.DefaultForeground, FontStyle.None, 53)),
//     }, actual.items);
// }

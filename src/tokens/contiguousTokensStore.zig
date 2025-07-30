const std = @import("std");
const ArrayList = std.ArrayList;
const Range = @import("../basics/range.zig").Range;
const Position = @import("../basics/position.zig").Position;
const ContiguousTokensEditing = @import("./contiguousTokensEditing.zig").ContiguousTokensEditing;
const EMPTY_LINE_TOKENS = @import("./contiguousTokensEditing.zig").EMPTY_LINE_TOKENS;
const toUint32Array = @import("./contiguousTokensEditing.zig").toUint32Array;
const LineTokens = @import("./lineTokens.zig").LineTokens;
const ILanguageIdCodec = @import("../languages.zig").ILanguageIdCodec;
const LanguageId = @import("../encodedTokenAttributes.zig").LanguageId;
const FontStyle = @import("../encodedTokenAttributes.zig").FontStyle;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const MetadataConsts = @import("../encodedTokenAttributes.zig").MetadataConsts;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const ITextModel = @import("../model.zig").ITextModel;
const ContiguousMultilineTokens = @import("./contiguousMultilineTokens.zig").ContiguousMultilineTokens;

// Represents contiguous tokens in a text model.
pub const ContiguousTokensStore = struct {
    _lineTokens: ArrayList(?u32),
    _len: usize,
    _languageIdCodec: ILanguageIdCodec,

    pub fn init(languageIdCodec: ILanguageIdCodec) ContiguousTokensStore {
        return ContiguousTokensStore{
            ._lineTokens = ArrayList(?u32).init(std.heap.page_allocator),
            ._len = 0,
            .languageIdCodec = languageIdCodec,
        };
    }

    pub fn flush(self: *ContiguousTokensStore) void {
        self._lineTokens.clearAndFree();
        self._len = 0;
    }

    pub fn hasTokens(self: *ContiguousTokensStore) bool {
        return self._lineTokens.items.len > 0;
    }

    pub fn getTokens(self: *ContiguousTokensStore, topLevelLanguageId: []const u8, lineIndex: usize, lineText: []const u8) !LineTokens {
        var rawLineTokens: ?[]u32 = null;
        if (lineIndex < self._len) {
            rawLineTokens = self._lineTokens.items[lineIndex];
        }

        if (rawLineTokens != null and rawLineTokens != EMPTY_LINE_TOKENS) {
            return LineTokens.init(rawLineTokens.?, lineText, self._languageIdCodec);
        }

        var lineTokens = ArrayList(u32).init(self._lineTokens.allocator);
        try lineTokens.append(lineText.length);
        try lineTokens.append(getDefaultMetadata(self._languageIdCodec.encodeLanguageId(topLevelLanguageId)));
        return LineTokens.init(lineTokens, lineText, self._languageIdCodec);
    }

    fn _massageTokens(topLevelLanguageId: LanguageId, lineTextLength: usize, _tokens: ?[]u32) []u32 {
        const tokens = _tokens orelse null;

        if (tokens == null) {
            return EMPTY_LINE_TOKENS;
        }

        if (lineTextLength == 0) {
            var hasDifferentLanguageId = false;
            if (tokens.len > 1) {
                hasDifferentLanguageId = (TokenMetadata.getLanguageId(tokens[1]) != topLevelLanguageId);
            }

            if (!hasDifferentLanguageId) {
                return EMPTY_LINE_TOKENS;
            }
        }

        if (tokens.len == 0) {
            var tokens = ArrayList(u32).init(self._lineTokens.allocator);
            try tokens.append(lineTextLength);
            try tokens.append(getDefaultMetadata(topLevelLanguageId));
            return tokens.items;
        }

        // Ensure the last token covers the end of the text
        tokens[tokens.len - 2] = lineTextLength;

        if (tokens.items.byteOffset == 0 and tokens.items.byteLength == tokens.items.buffer.byteLength) {
            // Store directly the ArrayBuffer pointer to save an object
            return tokens.items.buffer;
        }
        return tokens.items;
    }

    fn _ensureLine(self: *ContiguousTokensStore, lineIndex: usize) !void {
        while (lineIndex >= self._len) {
            try self._lineTokens.append(null);
            self._len += 1;
        }
    }

    fn _deleteLines(self: *ContiguousTokensStore, start: usize, deleteCount: usize) void {
        if (deleteCount == 0) {
            return;
        }
        if (start + deleteCount > self._len) {
            deleteCount = self._len - start;
        }
        self._lineTokens.replaceRange(start, deleteCount, &[_]?u32{});
        self._len -= deleteCount;
    }

    fn _insertLines(self: *ContiguousTokensStore, insertIndex: usize, insertCount: usize) !void {
        if (insertCount == 0) {
            return;
        }
        var lineTokens = ArrayList(?u32).init(self._lineTokens.allocator);
        for (0..insertCount) |_| {
            lineTokens.append(null);
        }
        self._lineTokens = try self._lineTokens.insertSlice(insertIndex, lineTokens);
        self._len += insertCount;
    }

    pub fn setTokens(self: *ContiguousTokensStore, topLevelLanguageId: []const u8, lineIndex: usize, lineTextLength: usize, _tokens: ?[]u32, checkEquality: bool) bool {
        const tokens = ContiguousTokensStore._massageTokens(self._languageIdCodec.encodeLanguageId(topLevelLanguageId), lineTextLength, _tokens);
        self._ensureLine(lineIndex);
        const oldTokens = self._lineTokens[lineIndex];
        self._lineTokens[lineIndex] = tokens;

        if (checkEquality) {
            return !ContiguousTokensStore._equals(oldTokens.?, tokens);
        }
        return false;
    }

    fn _equals(a: ?[]u32, b: ?[]u32) bool {
        if (a == null or b == null) {
            return a == null and b == null;
        }

        if (a.len != b.len) {
            return false;
        }
        for (0..a.len) |i| {
            if (a[i] != b[i]) {
                return false;
            }
        }
        return true;
    }

    //#region Editing

    pub fn acceptEdit(self: *ContiguousTokensStore, range: Range, eolCount: usize, firstLineLength: usize) void {
        self._acceptDeleteRange(range);
        self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), eolCount, firstLineLength);
    }

    fn _acceptDeleteRange(self: *ContiguousTokensStore, range: Range) void {
        const firstLineIndex = range.startLineNumber - 1;
        if (firstLineIndex >= self._len) {
            return;
        }

        if (range.startLineNumber == range.endLineNumber) {
            if (range.startColumn == range.endColumn) {
                // Nothing to delete
                return;
            }

            self._lineTokens[firstLineIndex] = ContiguousTokensEditing.delete(self._lineTokens[firstLineIndex], range.startColumn - 1, range.endColumn - 1);
            return;
        }

        self._lineTokens[firstLineIndex] = ContiguousTokensEditing.deleteEnding(self._lineTokens[firstLineIndex], range.startColumn - 1);

        const lastLineIndex = range.endLineNumber - 1;
        var lastLineTokens: ?[]u32 = null;
        if (lastLineIndex < self._len) {
            lastLineTokens = ContiguousTokensEditing.deleteBeginning(self._lineTokens[lastLineIndex], range.endColumn - 1);
        }

        // Take remaining text on last line and append it to remaining text on first line
        self._lineTokens[firstLineIndex] = ContiguousTokensEditing.append(self._lineTokens[firstLineIndex], lastLineTokens);

        // Delete middle lines
        self._deleteLines(range.startLineNumber, range.endLineNumber - range.startLineNumber);
    }

    fn _acceptInsertText(self: *ContiguousTokensStore, position: Position, eolCount: usize, firstLineLength: usize) void {
        if (eolCount == 0 and firstLineLength == 0) {
            // Nothing to insert
            return;
        }

        const lineIndex = position.lineNumber - 1;
        if (lineIndex >= self._len) {
            return;
        }

        if (eolCount == 0) {
            // Inserting text on one line
            self._lineTokens[lineIndex] = ContiguousTokensEditing.insert(self._lineTokens[lineIndex], position.column - 1, firstLineLength);
            return;
        }

        self._lineTokens[lineIndex] = ContiguousTokensEditing.deleteEnding(self._lineTokens[lineIndex], position.column - 1);
        self._lineTokens[lineIndex] = ContiguousTokensEditing.insert(self._lineTokens[lineIndex], position.column - 1, firstLineLength);

        self._insertLines(position.lineNumber, eolCount);
    }

    //#endregion

    pub fn setMultilineTokens(self: *ContiguousTokensStore, tokens: []ContiguousMultilineTokens, textModel: ITextModel) struct { changes: []struct { fromLineNumber: usize, toLineNumber: usize } } {
        if (tokens.len == 0) {
            return .{ .changes = &.{} };
        }

        var ranges: ArrayList(struct { fromLineNumber: usize, toLineNumber: usize }) = ArrayList(struct { fromLineNumber: usize, toLineNumber: usize }).init(std.heap.page_allocator);

        for (0..tokens.len) |i| {
            const element = tokens[i];
            var minChangedLineNumber = 0;
            var maxChangedLineNumber = 0;
            var hasChange = false;
            for (element.startLineNumber..element.endLineNumber) |lineNumber| {
                if (hasChange) {
                    self.setTokens(textModel.getLanguageId(), lineNumber - 1, textModel.getLineLength(lineNumber), element.getLineTokens(lineNumber), false);
                    maxChangedLineNumber = lineNumber;
                } else {
                    const lineHasChange = self.setTokens(textModel.getLanguageId(), lineNumber - 1, textModel.getLineLength(lineNumber), element.getLineTokens(lineNumber), true);
                    if (lineHasChange) {
                        hasChange = true;
                        minChangedLineNumber = lineNumber;
                        maxChangedLineNumber = lineNumber;
                    }
                }
            }
            if (hasChange) {
                ranges.append(.{ .fromLineNumber = minChangedLineNumber, .toLineNumber = maxChangedLineNumber });
            }
        }

        return .{ .changes = ranges.items };
    }
};

fn getDefaultMetadata(topLevelLanguageId: LanguageId) u32 {
    return ((topLevelLanguageId << MetadataConsts.LANGUAGEID_OFFSET) | (StandardTokenType.Other << MetadataConsts.TOKEN_TYPE_OFFSET) | (FontStyle.None << MetadataConsts.FONT_STYLE_OFFSET) | (ColorId.DefaultForeground << MetadataConsts.FOREGROUND_OFFSET) | (ColorId.DefaultBackground << MetadataConsts.BACKGROUND_OFFSET)
        // If there is no grammar, we just take a guess and try to match brackets.
    | (MetadataConsts.BALANCED_BRACKETS_MASK)) >> 0;
}

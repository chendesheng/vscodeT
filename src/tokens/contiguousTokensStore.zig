const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const Position = @import("../basics/position.zig").Position;
const ContiguousTokensEditing = @import("./contiguousTokensEditing.zig").ContiguousTokensEditing;
const EMPTY_LINE_TOKENS = @import("./contiguousTokensEditing.zig").EMPTY_LINE_TOKENS;
const toUint32Array = @import("./contiguousTokensEditing.zig").toUint32Array;
const LineTokens = @import("./lineTokens.zig").LineTokens;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LanguageId = @import("../encodedTokenAttributes.zig").LanguageId;
const FontStyle = @import("../encodedTokenAttributes.zig").FontStyle;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const MetadataConsts = @import("../encodedTokenAttributes.zig").MetadataConsts;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const TextModel = @import("../textModel.zig").TextModel;
const ContiguousMultilineTokens = @import("./contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const TokenPacked = @import("./lineTokens.zig").TokenPacked;

// Represents contiguous tokens in a text model.
pub const ContiguousTokensStore = struct {
    _lineTokens: ArrayList(?ArrayList(TokenPacked)),
    _len: usize,
    _languageIdCodec: LanguageIdCodec,

    pub fn init(allocator: Allocator, languageIdCodec: LanguageIdCodec) ContiguousTokensStore {
        return ContiguousTokensStore{
            ._lineTokens = ArrayList(?ArrayList(TokenPacked)).init(allocator),
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
        var rawLineTokens: ?ArrayList(TokenPacked) = null;
        if (lineIndex < self._len) {
            rawLineTokens = self._lineTokens.items[lineIndex];
        }

        if (rawLineTokens != null and rawLineTokens.?.items.len > 0) {
            return LineTokens.init(rawLineTokens.?, lineText, self._languageIdCodec);
        }

        var lineTokens = ArrayList(TokenPacked).init(self._lineTokens.allocator);
        try lineTokens.append(TokenPacked{ .endOffset = lineText.len, .metadata = getDefaultMetadata(self._languageIdCodec.encodeLanguageId(topLevelLanguageId)) });
        return LineTokens.init(lineTokens, lineText, self._languageIdCodec);
    }

    fn _massageTokens(allocator: Allocator, topLevelLanguageId: LanguageId, lineTextLength: usize, _tokens: ?[]TokenPacked) []TokenPacked {
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
            var tokens2 = ArrayList(TokenPacked).init(allocator);
            try tokens2.append(TokenPacked{ .endOffset = lineTextLength, .metadata = getDefaultMetadata(topLevelLanguageId) });
            return tokens2.items;
        }

        // Ensure the last token covers the end of the text
        tokens[tokens.len - 2] = TokenPacked{ .endOffset = lineTextLength, .metadata = tokens[tokens.len - 2].metadata };

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
        self._lineTokens.replaceRange(start, deleteCount, &[_]?TokenPacked{});
        self._len -= deleteCount;
    }

    fn _insertLines(self: *ContiguousTokensStore, insertIndex: usize, insertCount: usize) !void {
        if (insertCount == 0) {
            return;
        }
        var lineTokens = ArrayList(?TokenPacked).init(self._lineTokens.allocator);
        for (0..insertCount) |_| {
            try lineTokens.append(null);
        }
        self._lineTokens = try self._lineTokens.insertSlice(insertIndex, lineTokens.items);
        self._len += insertCount;
    }

    pub fn setTokens(self: *ContiguousTokensStore, topLevelLanguageId: []const u8, lineIndex: usize, lineTextLength: usize, _tokens: ?[]TokenPacked, checkEquality: bool) bool {
        const tokens = ContiguousTokensStore._massageTokens(self._lineTokens.allocator, self._languageIdCodec.encodeLanguageId(topLevelLanguageId), lineTextLength, _tokens);
        self._ensureLine(lineIndex);
        const oldTokens = self._lineTokens[lineIndex];
        self._lineTokens[lineIndex] = tokens;

        if (checkEquality) {
            return !ContiguousTokensStore._equals(oldTokens.?, tokens);
        }
        return false;
    }

    fn _equals(a: ?[]TokenPacked, b: ?[]TokenPacked) bool {
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

            ContiguousTokensEditing.delete(&self._lineTokens[firstLineIndex], range.startColumn - 1, range.endColumn - 1);
            return;
        }

        ContiguousTokensEditing.deleteEnding(&self._lineTokens[firstLineIndex], range.startColumn - 1);

        const lastLineIndex = range.endLineNumber - 1;
        const lastLineTokens = &self._lineTokens[lastLineIndex];
        if (lastLineIndex < self._len) {
            ContiguousTokensEditing.deleteBeginning(lastLineTokens, range.endColumn - 1);
        }

        // Take remaining text on last line and append it to remaining text on first line
        ContiguousTokensEditing.append(&self._lineTokens[firstLineIndex], lastLineTokens);

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

        const lineTokens = &self._lineTokens[lineIndex];
        if (eolCount == 0) {
            // Inserting text on one line
            ContiguousTokensEditing.insert(lineTokens, position.column - 1, firstLineLength);
            return;
        }

        ContiguousTokensEditing.deleteEnding(lineTokens, position.column - 1);
        ContiguousTokensEditing.insert(lineTokens, position.column - 1, firstLineLength);

        self._insertLines(position.lineNumber, eolCount);
    }

    //#endregion

    pub fn setMultilineTokens(self: *ContiguousTokensStore, tokens: []ContiguousMultilineTokens, textModel: TextModel) struct { changes: []struct { fromLineNumber: usize, toLineNumber: usize } } {
        if (tokens.len == 0) {
            return .{ .changes = &.{} };
        }

        var ranges: ArrayList(struct { fromLineNumber: usize, toLineNumber: usize }) = ArrayList(struct { fromLineNumber: usize, toLineNumber: usize }).init(std.heap.page_allocator);

        for (tokens) |element| {
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

fn getDefaultMetadata(topLevelLanguageId: u8) TokenMetadata {
    var metadata = TokenMetadata.default;
    metadata.languageId = topLevelLanguageId;
    return metadata;
}

const std = @import("std");
const ArrayList = std.array_list.Managed;
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
const ModelTokensChangedRange = @import("../textModelEvents.zig").ModelTokensChangedRange;

// Represents contiguous tokens in a text model.
pub const ContiguousTokensStore = struct {
    _lineTokens: ArrayList(?ArrayList(TokenPacked)),
    _len: usize,
    _languageIdCodec: LanguageIdCodec,

    pub fn init(allocator: Allocator, languageIdCodec: LanguageIdCodec) ContiguousTokensStore {
        return ContiguousTokensStore{
            ._lineTokens = ArrayList(?ArrayList(TokenPacked)).init(allocator),
            ._len = 0,
            ._languageIdCodec = languageIdCodec,
        };
    }

    pub fn deinit(self: *ContiguousTokensStore) void {
        for (self._lineTokens.items) |*lineTokens| {
            if (lineTokens.*) |*tokens| tokens.deinit();
        }
        self._lineTokens.deinit();
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

    fn _massageTokens(allocator: Allocator, topLevelLanguageId: LanguageId, lineTextLength: usize, _tokens: ?[]TokenPacked) ?ArrayList(TokenPacked) {
        const tokens = _tokens orelse return null;

        if (lineTextLength == 0) {
            var hasDifferentLanguageId = false;
            if (tokens.len > 1) {
                hasDifferentLanguageId = tokens[1].metadata.languageId != @backingInt(topLevelLanguageId);
            }

            if (!hasDifferentLanguageId) {
                return null;
            }
        }

        var result = ArrayList(TokenPacked).init(allocator);
        result.appendSlice(tokens) catch return null;

        if (result.items.len >= 2) {
            // Ensure the last token covers the end of the text.
            result.items[result.items.len - 2] = TokenPacked{
                .endOffset = @intCast(lineTextLength),
                .metadata = result.items[result.items.len - 2].metadata,
            };
        }

        return result;
    }

    fn _ensureLine(self: *ContiguousTokensStore, lineIndex: usize) !void {
        while (lineIndex >= self._len) {
            try self._lineTokens.append(null);
            self._len += 1;
        }
    }

    fn _deleteLines(self: *ContiguousTokensStore, start: usize, deleteCount_: usize) void {
        var deleteCount = deleteCount_;
        if (deleteCount == 0) {
            return;
        }
        if (start + deleteCount > self._len) {
            deleteCount = self._len - start;
        }
        self._lineTokens.replaceRange(start, deleteCount, &[_]?ArrayList(TokenPacked){}) catch {};
        self._len -= deleteCount;
    }

    fn _insertLines(self: *ContiguousTokensStore, insertIndex: usize, insertCount: usize) !void {
        if (insertCount == 0) {
            return;
        }
        var lineTokens = ArrayList(?ArrayList(TokenPacked)).init(self._lineTokens.allocator);
        defer lineTokens.deinit();
        for (0..insertCount) |_| {
            try lineTokens.append(null);
        }
        try self._lineTokens.insertSlice(insertIndex, lineTokens.items);
        self._len += insertCount;
    }

    pub fn setTokens(self: *ContiguousTokensStore, topLevelLanguageId: []const u8, lineIndex: usize, lineTextLength: usize, _tokens: ?[]TokenPacked, checkEquality: bool) bool {
        const tokens = ContiguousTokensStore._massageTokens(self._lineTokens.allocator, @fromBackingInt(@intCast(self._languageIdCodec.encodeLanguageId(topLevelLanguageId) catch 0)), lineTextLength, _tokens);
        self._ensureLine(lineIndex) catch return false;
        const oldTokens = self._lineTokens.items[lineIndex];
        self._lineTokens.items[lineIndex] = tokens;

        if (checkEquality) {
            return !ContiguousTokensStore._equals(if (oldTokens) |t| t.items else null, if (tokens) |t| t.items else null);
        }
        return false;
    }

    fn _equals(a: ?[]TokenPacked, b: ?[]TokenPacked) bool {
        if (a == null or b == null) {
            return a == null and b == null;
        }

        const a_slice = a.?;
        const b_slice = b.?;
        if (a_slice.len != b_slice.len) {
            return false;
        }
        for (0..a_slice.len) |i| {
            if (a_slice[i] != b_slice[i]) {
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

            ContiguousTokensEditing.delete(&self._lineTokens.items[firstLineIndex], range.startColumn - 1, range.endColumn - 1) catch {};
            return;
        }

        ContiguousTokensEditing.deleteEnding(&self._lineTokens.items[firstLineIndex], range.startColumn - 1) catch {};

        const lastLineIndex = range.endLineNumber - 1;
        const lastLineTokens = &self._lineTokens.items[lastLineIndex];
        if (lastLineIndex < self._len) {
            ContiguousTokensEditing.deleteBeginning(lastLineTokens, range.endColumn - 1) catch {};
        }

        // Take remaining text on last line and append it to remaining text on first line
        ContiguousTokensEditing.append(&self._lineTokens.items[firstLineIndex], lastLineTokens) catch {};

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

        const lineTokens = &self._lineTokens.items[lineIndex];
        if (eolCount == 0) {
            // Inserting text on one line
            ContiguousTokensEditing.insert(lineTokens, position.column - 1, firstLineLength);
            return;
        }

        ContiguousTokensEditing.deleteEnding(lineTokens, position.column - 1) catch {};
        ContiguousTokensEditing.insert(lineTokens, position.column - 1, firstLineLength);

        self._insertLines(position.lineNumber, eolCount) catch {};
    }

    //#endregion

    pub fn setMultilineTokens(self: *ContiguousTokensStore, tokens: []ContiguousMultilineTokens, textModel: *TextModel) struct { changes: []ModelTokensChangedRange } {
        if (tokens.len == 0) {
            return .{ .changes = &.{} };
        }

        var ranges: ArrayList(ModelTokensChangedRange) = ArrayList(ModelTokensChangedRange).init(std.heap.page_allocator);

        for (tokens) |element| {
            var minChangedLineNumber: usize = 0;
            var maxChangedLineNumber: usize = 0;
            var hasChange = false;
            for (element.getStartLineNumber()..element.getEndLineNumber()) |lineNumber| {
                if (hasChange) {
                    _ = self.setTokens(textModel.getLanguageId(), lineNumber - 1, textModel.getLineLength(lineNumber), element.getLineTokens(lineNumber), false);
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
                ranges.append(.{ .fromLineNumber = minChangedLineNumber, .toLineNumber = maxChangedLineNumber }) catch {};
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

const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Range = @import("../basics/range.zig").Range;
const Position = @import("../basics/position.zig").Position;
const ContiguousTokensEditing = @import("./contiguousTokensEditing.zig").ContiguousTokensEditing;
const LineTokens = @import("./lineTokens.zig").LineTokens;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const LanguageId = @import("../encodedTokenAttributes.zig").LanguageId;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const TextModel = @import("../textModel.zig").TextModel;
const ContiguousMultilineTokens = @import("./contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const TokenPacked = @import("./lineTokens.zig").TokenPacked;
const ModelTokensChangedRange = @import("../textModelEvents.zig").ModelTokensChangedRange;

pub const ContiguousTokensStore = struct {
    _lineTokens: ArrayList(?ArrayList(TokenPacked)),
    _len: usize,
    _languageIdCodec: *LanguageIdCodec,

    pub fn init(allocator: Allocator, languageIdCodec: *LanguageIdCodec) ContiguousTokensStore {
        return .{
            ._lineTokens = ArrayList(?ArrayList(TokenPacked)).init(allocator),
            ._len = 0,
            ._languageIdCodec = languageIdCodec,
        };
    }

    pub fn deinit(self: *ContiguousTokensStore) void {
        for (self._lineTokens.items) |*entry| deinitEntry(entry);
        self._lineTokens.deinit();
    }

    fn deinitEntry(entry: *?ArrayList(TokenPacked)) void {
        if (entry.*) |*tokens| {
            tokens.deinit();
            entry.* = null;
        }
    }

    pub fn flush(self: *ContiguousTokensStore) void {
        for (self._lineTokens.items) |*entry| deinitEntry(entry);
        self._lineTokens.clearRetainingCapacity();
        self._len = 0;
    }

    pub fn hasTokens(self: *const ContiguousTokensStore) bool {
        return self._lineTokens.items.len > 0;
    }

    /// Takes ownership of `lineText`.
    pub fn getTokens(self: *ContiguousTokensStore, topLevelLanguageId: []const u8, lineIndex: usize, lineText: ArrayList(u8)) !LineTokens {
        var tokens = ArrayList(TokenPacked).init(self._lineTokens.allocator);
        errdefer tokens.deinit();

        if (lineIndex < self._len) {
            if (self._lineTokens.items[lineIndex]) |cached| {
                if (cached.items.len > 0) {
                    try tokens.appendSlice(cached.items);
                    return LineTokens.init(tokens, lineText, self._languageIdCodec);
                }
            }
        }

        const encodedLanguageId = try self._languageIdCodec.encodeLanguageId(topLevelLanguageId);
        try tokens.append(.{
            .endOffset = @intCast(lineText.items.len),
            .metadata = getDefaultMetadata(encodedLanguageId),
        });
        return LineTokens.init(tokens, lineText, self._languageIdCodec);
    }

    fn _massageTokens(allocator: Allocator, topLevelLanguageId: LanguageId, lineTextLength: usize, maybeTokens: ?[]TokenPacked) !?ArrayList(TokenPacked) {
        const source = maybeTokens orelse return null;

        if (lineTextLength == 0) {
            var hasDifferentLanguageId = false;
            if (source.len > 0) {
                hasDifferentLanguageId = source[0].metadata.languageId != @backingInt(topLevelLanguageId);
            }
            if (!hasDifferentLanguageId) return null;
        }

        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();
        try tokens.appendSlice(source);
        if (tokens.items.len > 0) {
            tokens.items[tokens.items.len - 1].endOffset = @intCast(lineTextLength);
        }
        return tokens;
    }

    fn _ensureLine(self: *ContiguousTokensStore, lineIndex: usize) !void {
        while (lineIndex >= self._len) {
            try self._lineTokens.append(null);
            self._len += 1;
        }
    }

    fn _deleteLines(self: *ContiguousTokensStore, start: usize, delete_count_: usize) !void {
        var deleteCount = delete_count_;
        if (deleteCount == 0) return;
        if (start + deleteCount > self._len) deleteCount = self._len - start;

        var i = start;
        while (i < start + deleteCount) : (i += 1) deinitEntry(&self._lineTokens.items[i]);
        try self._lineTokens.replaceRange(start, deleteCount, &[_]?ArrayList(TokenPacked){});
        self._len -= deleteCount;
    }

    fn _insertLines(self: *ContiguousTokensStore, insertIndex: usize, insertCount: usize) !void {
        if (insertCount == 0) return;
        var lineTokens = ArrayList(?ArrayList(TokenPacked)).init(self._lineTokens.allocator);
        defer lineTokens.deinit();
        try lineTokens.resize(insertCount);
        for (lineTokens.items) |*entry| entry.* = null;
        try self._lineTokens.insertSlice(insertIndex, lineTokens.items);
        self._len += insertCount;
    }

    pub fn setTokens(self: *ContiguousTokensStore, topLevelLanguageId: []const u8, lineIndex: usize, lineTextLength: usize, maybeTokens: ?[]TokenPacked, checkEquality: bool) !bool {
        const encodedLanguageId: LanguageId = @fromBackingInt(try self._languageIdCodec.encodeLanguageId(topLevelLanguageId));
        const tokens = try ContiguousTokensStore._massageTokens(self._lineTokens.allocator, encodedLanguageId, lineTextLength, maybeTokens);
        try self._ensureLine(lineIndex);

        const oldTokens = self._lineTokens.items[lineIndex];
        const changed = if (checkEquality)
            !ContiguousTokensStore._equals(if (oldTokens) |old| old.items else null, if (tokens) |new| new.items else null)
        else
            false;

        self._lineTokens.items[lineIndex] = tokens;
        if (oldTokens) |*old| old.deinit();
        return changed;
    }

    fn _equals(a: ?[]const TokenPacked, b: ?[]const TokenPacked) bool {
        if (a == null or b == null) return a == null and b == null;
        const a_slice = a.?;
        const b_slice = b.?;
        if (a_slice.len != b_slice.len) return false;
        for (a_slice, b_slice) |x, y| {
            if (x != y) return false;
        }
        return true;
    }

    pub fn acceptEdit(self: *ContiguousTokensStore, range: Range, eolCount: usize, firstLineLength: usize) !void {
        try self._acceptDeleteRange(range);
        try self._acceptInsertText(Position.init(range.startLineNumber, range.startColumn), eolCount, firstLineLength);
    }

    fn _acceptDeleteRange(self: *ContiguousTokensStore, range: Range) !void {
        const firstLineIndex = range.startLineNumber - 1;
        if (firstLineIndex >= self._len) return;

        if (range.startLineNumber == range.endLineNumber) {
            if (range.startColumn == range.endColumn) return;
            try ContiguousTokensEditing.delete(&self._lineTokens.items[firstLineIndex], range.startColumn - 1, range.endColumn - 1);
            return;
        }

        try ContiguousTokensEditing.deleteEnding(&self._lineTokens.items[firstLineIndex], range.startColumn - 1);

        const lastLineIndex = range.endLineNumber - 1;
        if (lastLineIndex < self._len) {
            try ContiguousTokensEditing.deleteBeginning(&self._lineTokens.items[lastLineIndex], range.endColumn - 1);
            try ContiguousTokensEditing.append(&self._lineTokens.items[firstLineIndex], &self._lineTokens.items[lastLineIndex]);
            deinitEntry(&self._lineTokens.items[lastLineIndex]);
        } else {
            var null_item: ?ArrayList(TokenPacked) = null;
            try ContiguousTokensEditing.append(&self._lineTokens.items[firstLineIndex], &null_item);
        }

        try self._deleteLines(firstLineIndex + 1, range.endLineNumber - range.startLineNumber);
    }

    fn _acceptInsertText(self: *ContiguousTokensStore, position: Position, eolCount: usize, firstLineLength: usize) !void {
        if (eolCount == 0 and firstLineLength == 0) return;

        const lineIndex = position.lineNumber - 1;
        if (lineIndex >= self._len) return;

        if (eolCount == 0) {
            ContiguousTokensEditing.insert(&self._lineTokens.items[lineIndex], position.column - 1, firstLineLength);
            return;
        }

        try ContiguousTokensEditing.deleteEnding(&self._lineTokens.items[lineIndex], position.column - 1);
        ContiguousTokensEditing.insert(&self._lineTokens.items[lineIndex], position.column - 1, firstLineLength);

        try self._insertLines(position.lineNumber, eolCount);
    }

    pub fn setMultilineTokens(self: *ContiguousTokensStore, tokens: []ContiguousMultilineTokens, textModel: *TextModel, changes: *ArrayList(ModelTokensChangedRange)) !void {
        if (tokens.len == 0) return;

        for (tokens) |*element| {
            var minChangedLineNumber: usize = 0;
            var maxChangedLineNumber: usize = 0;
            var hasChange = false;

            var lineNumber = element.getStartLineNumber();
            const endLineNumber = element.getEndLineNumber();
            while (lineNumber <= endLineNumber) : (lineNumber += 1) {
                const lineTokens = element.getLineTokens(lineNumber);
                if (hasChange) {
                    _ = try self.setTokens(textModel.getLanguageId(), lineNumber - 1, textModel.getLineLength(lineNumber), lineTokens, false);
                    maxChangedLineNumber = lineNumber;
                } else {
                    const lineHasChange = try self.setTokens(textModel.getLanguageId(), lineNumber - 1, textModel.getLineLength(lineNumber), lineTokens, true);
                    if (lineHasChange) {
                        hasChange = true;
                        minChangedLineNumber = lineNumber;
                        maxChangedLineNumber = lineNumber;
                    }
                }
            }

            if (hasChange) {
                try changes.append(.{ .fromLineNumber = minChangedLineNumber, .toLineNumber = maxChangedLineNumber });
            }
        }
    }
};

fn getDefaultMetadata(topLevelLanguageId: u8) TokenMetadata {
    var metadata = TokenMetadata.default;
    metadata.languageId = topLevelLanguageId;
    return metadata;
}

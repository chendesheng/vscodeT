const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const LineTokens = @import("lineTokens.zig").LineTokens;
const usizeSub = @import("../basics/utils.zig").usizeSub;
const TokenPacked = @import("lineTokens.zig").TokenPacked;

pub const EMPTY_LINE_TOKENS: []TokenPacked = &[_]TokenPacked{};
pub const ContiguousTokensEditing = struct {
    pub fn deleteBeginning(_lineTokens: ?ArrayList(TokenPacked), toChIndex: usize) !?ArrayList(TokenPacked) {
        if (_lineTokens == null or _lineTokens.?.items.len == 0) {
            return _lineTokens;
        }

        return try ContiguousTokensEditing.delete(_lineTokens, 0, toChIndex);
    }

    pub fn deleteEnding(_lineTokens: ?ArrayList(TokenPacked), fromChIndex: usize) !?ArrayList(TokenPacked) {
        if (_lineTokens == null or _lineTokens.?.items.len == 0) {
            return _lineTokens;
        }

        const lineTextLength = _lineTokens.?.getLast().endOffset;
        return try ContiguousTokensEditing.delete(_lineTokens, fromChIndex, lineTextLength);
    }

    pub fn delete(_lineTokens: ?ArrayList(TokenPacked), fromChIndex: usize, toChIndex: usize) !?ArrayList(TokenPacked) {
        if (_lineTokens == null or _lineTokens.?.items.len == 0 or fromChIndex == toChIndex) {
            return _lineTokens;
        }

        var lineTokens = _lineTokens.?;
        var tokens: []TokenPacked = _lineTokens.?.items;
        const tokensCount = tokens.len;

        // special case: deleting everything
        if (fromChIndex == 0 and lineTokens.getLast().endOffset == toChIndex) {
            try lineTokens.resize(0);
            return lineTokens;
        }

        const fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, fromChIndex);
        const fromTokenStartOffset = if (fromTokenIndex > 0) tokens[(fromTokenIndex - 1)].endOffset else 0;
        const fromTokenEndOffset = tokens[fromTokenIndex].endOffset;

        if (toChIndex < fromTokenEndOffset) {
            // the delete range is inside a single token
            const delta = usizeSub(toChIndex, fromChIndex);
            for (fromTokenIndex..tokensCount) |i| {
                tokens[i].endOffset = @intCast(@as(isize, @intCast(tokens[i].endOffset)) - delta);
            }
            return lineTokens;
        }

        var dest: usize = undefined;
        var lastEnd: usize = undefined;
        if (fromTokenStartOffset != fromChIndex) {
            tokens[fromTokenIndex].endOffset = @intCast(fromChIndex);
            dest = fromTokenIndex + 1;
            lastEnd = fromChIndex;
        } else {
            dest = fromTokenIndex;
            lastEnd = fromTokenStartOffset;
        }

        const delta: u32 = @intCast(usizeSub(toChIndex, fromChIndex));
        for (fromTokenIndex + 1..tokensCount) |tokenIndex| {
            const tokenEndOffset = tokens[tokenIndex].endOffset - delta;
            if (tokenEndOffset > lastEnd) {
                tokens[dest].endOffset = tokenEndOffset;
                tokens[dest].metadata = tokens[tokenIndex].metadata;
                dest += 1;
                lastEnd = tokenEndOffset;
            }
        }

        if (dest == tokens.len) {
            // nothing to trim
            return lineTokens;
        }

        try lineTokens.resize(dest);
        return lineTokens;
    }

    pub fn append(_lineTokens: ?ArrayList(TokenPacked), _otherTokens: ?ArrayList(TokenPacked)) !?ArrayList(TokenPacked) {
        if (_otherTokens != null and _otherTokens.?.items.len == 0) {
            return _lineTokens;
        }
        if (_lineTokens != null and _lineTokens.?.items.len == 0) {
            return _otherTokens;
        }
        if (_lineTokens == null) {
            return null;
        }
        if (_otherTokens == null) {
            // cannot determine combined line length...
            return null;
        }

        const myTokens = _lineTokens.?;

        var result = try myTokens.clone();
        const delta = result.getLast().endOffset;
        for (_otherTokens.?.items) |token| {
            try result.append(TokenPacked{
                .endOffset = token.endOffset + delta,
                .metadata = token.metadata,
            });
        }
        return result;
    }

    pub fn insert(_lineTokens: ?ArrayList(TokenPacked), chIndex: usize, textLength: usize) !?ArrayList(TokenPacked) {
        if (_lineTokens == null or _lineTokens.?.items.len == 0) {
            // nothing to do
            return _lineTokens;
        }

        const lineTokens = _lineTokens.?;
        const tokens = _lineTokens.?.items;

        var fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, chIndex);
        if (fromTokenIndex > 0) {
            const fromTokenStartOffset = tokens[fromTokenIndex - 1].endOffset;
            if (fromTokenStartOffset == chIndex) {
                fromTokenIndex -= 1;
            }
        }
        for (tokens[fromTokenIndex..]) |*token| {
            token.endOffset += @intCast(textLength);
        }
        return lineTokens;
    }
};

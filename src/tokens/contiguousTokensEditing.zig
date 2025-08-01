const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const LineTokens = @import("lineTokens.zig").LineTokens;
const usizeSub = @import("../basics/utils.zig").usizeSub;
const TokenPacked = @import("lineTokens.zig").TokenPacked;

pub const EMPTY_LINE_TOKENS = &[_]TokenPacked{};
pub const ContiguousTokensEditing = struct {
    pub fn deleteBeginning(_lineTokens: ?ArrayList(TokenPacked), toChIndex: usize) ?ArrayList(TokenPacked) {
        if (_lineTokens) |lineTokens| {
            if (lineTokens.len > 0) {
                return ContiguousTokensEditing.delete(lineTokens, 0, toChIndex);
            }
        }

        return null;
    }

    pub fn deleteEnding(_lineTokens: ?ArrayList(TokenPacked), fromChIndex: usize) ?ArrayList(TokenPacked) {
        if (_lineTokens) |lineTokens| {
            if (lineTokens.len > 0) {
                const lineTextLength = lineTokens.items[lineTokens.len - 2];
                return ContiguousTokensEditing.delete(lineTokens, fromChIndex, lineTextLength);
            }
        }
        return null;
    }

    pub fn delete(_lineTokens: ?ArrayList(TokenPacked), fromChIndex: usize, toChIndex: usize) ?ArrayList(TokenPacked) {
        if (_lineTokens == null or _lineTokens.?.items.len == 0 or fromChIndex == toChIndex) {
            return _lineTokens;
        }

        const lineTokens = _lineTokens.?;
        const tokens: []TokenPacked = lineTokens.items;
        const tokensCount = tokens.len;

        // special case: deleting everything
        if (fromChIndex == 0 and lineTokens.getLast().offset == toChIndex) {
            return ArrayList(TokenPacked).init(lineTokens.allocator);
        }

        const fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, fromChIndex);
        const fromTokenStartOffset = if (fromTokenIndex > 0) tokens[(fromTokenIndex - 1)].offset else 0;
        const fromTokenEndOffset = tokens[fromTokenIndex].offset;

        if (toChIndex < fromTokenEndOffset) {
            // the delete range is inside a single token
            const delta: u32 = @intCast(-usizeSub(toChIndex, fromChIndex));
            for (fromTokenIndex..tokensCount) |i| {
                tokens[i].offset += delta;
            }
            return lineTokens;
        }

        var dest: usize = undefined;
        var lastEnd: usize = undefined;
        if (fromTokenStartOffset != fromChIndex) {
            tokens[fromTokenIndex].offset = fromChIndex;
            dest = fromTokenIndex + 1;
            lastEnd = fromChIndex;
        } else {
            dest = fromTokenIndex;
            lastEnd = fromTokenStartOffset;
        }

        const delta: u32 = @intCast(usizeSub(toChIndex, fromChIndex));
        for (fromTokenIndex + 1..tokensCount) |tokenIndex| {
            const tokenEndOffset = tokens[tokenIndex].offset - delta;
            if (tokenEndOffset > lastEnd) {
                tokens[dest].offset = tokenEndOffset;
                tokens[dest].metadata = tokens[tokenIndex].metadata;
                dest += 1;
                lastEnd = tokenEndOffset;
            }
        }

        if (dest == tokens.len) {
            // nothing to trim
            return lineTokens;
        }

        var tmp = try ArrayList(TokenPacked).initCapacity(lineTokens.allocator, dest);
        try tmp.appendSlice(tokens[0..dest]);
        return tmp;
    }

    pub fn append(allocator: Allocator, lineTokens: ArrayList(TokenPacked), _otherTokens: ArrayList(TokenPacked)) !?ArrayList(TokenPacked) {
        if (_otherTokens.len == 0) {
            return lineTokens;
        }
        if (lineTokens.len == 0) {
            return _otherTokens;
        }
        if (lineTokens == null) {
            return lineTokens;
        }
        if (_otherTokens == null) {
            // cannot determine combined line length...
            return null;
        }
        const myTokens = lineTokens.items;

        var result = try ArrayList(TokenPacked).initCapacity(allocator, myTokens.len + _otherTokens.items.len);
        try result.appendSlice(myTokens);
        const delta = myTokens.getLast().offset;
        for (_otherTokens.items) |token| {
            try result.append(TokenPacked{
                .offset = token.offset + delta,
                .metadata = token.metadata,
            });
        }
        return result;
    }

    pub fn insert(_lineTokens: ?ArrayList(TokenPacked), chIndex: usize, textLength: usize) ?ArrayList(TokenPacked) {
        if (_lineTokens == null or _lineTokens.?.items.len == 0) {
            // nothing to do
            return _lineTokens;
        }

        const lineTokens = _lineTokens.?;
        const tokens = lineTokens.items;

        var fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, chIndex);
        if (fromTokenIndex > 0) {
            const fromTokenStartOffset = tokens[fromTokenIndex - 1].offset;
            if (fromTokenStartOffset == chIndex) {
                fromTokenIndex -= 1;
            }
        }
        for (tokens[fromTokenIndex..]) |*token| {
            token.offset += textLength;
        }
        return lineTokens;
    }
};

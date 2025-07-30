const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const LineTokens = @import("lineTokens.zig").LineTokens;
const usizeSub = @import("../basics/utils.zig").usizeSub;

pub const EMPTY_LINE_TOKENS = &[_]u32{};

pub const ContiguousTokensEditing = struct {
    pub fn deleteBeginning(lineTokens: []u32, toChIndex: usize) ?[]u32 {
        if (lineTokens == null or lineTokens.len == 0) {
            return lineTokens;
        }
        return ContiguousTokensEditing.delete(lineTokens, 0, toChIndex);
    }

    pub fn deleteEnding(lineTokens: []u32, fromChIndex: usize) ?[]u32 {
        if (lineTokens == null or lineTokens.len == 0) {
            return lineTokens;
        }

        const tokens = lineTokens.items;
        const lineTextLength = tokens[tokens.len - 2];
        return ContiguousTokensEditing.delete(lineTokens, fromChIndex, lineTextLength);
    }

    pub fn delete(lineTokens: ArrayList(u32), fromChIndex: usize, toChIndex: usize) ?ArrayList(u32) {
        if (lineTokens == null or lineTokens.items.len == 0 or fromChIndex == toChIndex) {
            return lineTokens;
        }

        const tokens = lineTokens.items;
        const tokensCount = (tokens.len >> 1);

        // special case: deleting everything
        if (fromChIndex == 0 and tokens[tokens.len - 2] == toChIndex) {
            return EMPTY_LINE_TOKENS;
        }

        const fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, fromChIndex);
        const fromTokenStartOffset = if (fromTokenIndex > 0) tokens[(fromTokenIndex - 1) << 1] else 0;
        const fromTokenEndOffset = tokens[fromTokenIndex << 1];

        if (toChIndex < fromTokenEndOffset) {
            // the delete range is inside a single token
            const delta: u32 = @intCast(usizeSub(toChIndex, fromChIndex));
            for (fromTokenIndex..tokensCount) |i| {
                tokens[i << 1] -= delta;
            }
            return lineTokens;
        }

        var dest: usize = undefined;
        var lastEnd: usize = undefined;
        if (fromTokenStartOffset != fromChIndex) {
            tokens[fromTokenIndex << 1] = fromChIndex;
            dest = ((fromTokenIndex + 1) << 1);
            lastEnd = fromChIndex;
        } else {
            dest = (fromTokenIndex << 1);
            lastEnd = fromTokenStartOffset;
        }

        const delta: u32 = @intCast(usizeSub(toChIndex, fromChIndex));
        for (fromTokenIndex + 1..tokensCount) |tokenIndex| {
            const tokenEndOffset = tokens[tokenIndex << 1] - delta;
            if (tokenEndOffset > lastEnd) {
                tokens[dest] = tokenEndOffset;
                dest += 1;
                tokens[dest] = tokens[(tokenIndex << 1) + 1];
                dest += 1;
                lastEnd = tokenEndOffset;
            }
        }

        if (dest == tokens.len) {
            // nothing to trim
            return lineTokens;
        }

        var tmp = ArrayList(u32).init(lineTokens.allocator);
        try tmp.appendSlice(tokens[0..dest]);
        return tmp;
    }

    pub fn append(allocator: Allocator, lineTokens: []u32, _otherTokens: []u32) !ArrayList(u32) {
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
        const otherTokens = _otherTokens;
        const otherTokensCount = (otherTokens.len >> 1);

        var result = ArrayList(u32).init(allocator);
        try result.appendSlice(myTokens);
        const delta = myTokens[myTokens.len - 2];
        for (0..otherTokensCount) |i| {
            try result.append(otherTokens[(i << 1)] + delta);
            try result.append(otherTokens[(i << 1) + 1]);
        }
        return result;
    }

    pub fn insert(lineTokens: ?ArrayList(u32), chIndex: usize, textLength: usize) ?ArrayList(u32) {
        if (lineTokens == null or lineTokens.items.len == 0) {
            // nothing to do
            return lineTokens;
        }

        const tokens = lineTokens.?.items;
        const tokensCount = (tokens.len >> 1);

        var fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, chIndex);
        if (fromTokenIndex > 0) {
            const fromTokenStartOffset = tokens[(fromTokenIndex - 1) << 1];
            if (fromTokenStartOffset == chIndex) {
                fromTokenIndex -= 1;
            }
        }
        for (fromTokenIndex..tokensCount) |tokenIndex| {
            tokens[tokenIndex << 1] += textLength;
        }
        return lineTokens;
    }
};

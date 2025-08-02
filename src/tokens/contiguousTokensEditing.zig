const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const LineTokens = @import("lineTokens.zig").LineTokens;
const usizeSub = @import("../basics/utils.zig").usizeSub;
const TokenPacked = @import("lineTokens.zig").TokenPacked;

pub const EMPTY_LINE_TOKENS = &[_]TokenPacked{};
pub const ContiguousTokensEditing = struct {
    pub fn deleteBeginning(_lineTokens: *?ArrayList(TokenPacked), toChIndex: usize) !void {
        if (_lineTokens.* == null or _lineTokens.*.?.items.len == 0) {
            return;
        }

        try ContiguousTokensEditing.delete(_lineTokens, 0, toChIndex);
    }

    pub fn deleteEnding(_lineTokens: *?ArrayList(TokenPacked), fromChIndex: usize) !void {
        if (_lineTokens.* == null or _lineTokens.*.?.items.len == 0) {
            return;
        }

        const lineTextLength = _lineTokens.*.?.getLast().endOffset;
        try ContiguousTokensEditing.delete(_lineTokens, fromChIndex, lineTextLength);
    }

    pub fn delete(_lineTokens: *?ArrayList(TokenPacked), fromChIndex: usize, toChIndex: usize) !void {
        if (_lineTokens.* == null or _lineTokens.*.?.items.len == 0 or fromChIndex == toChIndex) {
            return;
        }

        const lineTokens = &_lineTokens.*.?;
        var tokens: []TokenPacked = lineTokens.items;
        const tokensCount = tokens.len;

        // special case: deleting everything
        if (fromChIndex == 0 and lineTokens.getLast().endOffset == toChIndex) {
            try lineTokens.resize(0);
            return;
        }

        const fromTokenIndex = LineTokens.findIndexInTokensArray(tokens, fromChIndex);
        const fromTokenStartOffset = if (fromTokenIndex > 0) tokens[(fromTokenIndex - 1)].endOffset else 0;
        const fromTokenEndOffset = tokens[fromTokenIndex].endOffset;

        if (toChIndex < fromTokenEndOffset) {
            // the delete range is inside a single token
            const delta: u32 = @intCast(-usizeSub(toChIndex, fromChIndex));
            for (fromTokenIndex..tokensCount) |i| {
                tokens[i].endOffset += delta;
            }
            return;
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
            return;
        }

        try lineTokens.resize(dest);
    }

    pub fn append(_lineTokens: *?ArrayList(TokenPacked), _otherTokens: *?ArrayList(TokenPacked)) !void {
        if (_otherTokens.* != null and _otherTokens.*.?.items.len == 0) {
            return;
        }
        if (_lineTokens.* != null and _lineTokens.*.?.items.len == 0) {
            _lineTokens.* = _otherTokens.*;
            return;
        }
        if (_lineTokens.* == null) {
            return;
        }
        if (_otherTokens.* == null) {
            // cannot determine combined line length...
            _lineTokens.* = null;
            return;
        }

        var lineTokens = &_lineTokens.*.?;
        const myTokens: []TokenPacked = lineTokens.items;

        try lineTokens.appendSlice(myTokens);
        const delta = lineTokens.getLast().endOffset;
        for (_otherTokens.*.?.items) |token| {
            try lineTokens.append(TokenPacked{
                .endOffset = token.endOffset + delta,
                .metadata = token.metadata,
            });
        }
    }

    pub fn insert(_lineTokens: *?ArrayList(TokenPacked), chIndex: usize, textLength: usize) void {
        if (_lineTokens.* == null or _lineTokens.*.?.items.len == 0) {
            // nothing to do
            return;
        }

        const lineTokens = &_lineTokens.*.?;
        const tokens = lineTokens.items;

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
    }
};

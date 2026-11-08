const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const LineTokens = @import("./lineTokens.zig").LineTokens;
const usizeSub = @import("../../../base/common/utils.zig").usizeSub;
const TokenPacked = @import("./lineTokens.zig").TokenPacked;

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
        if (fromChIndex >= lineTextLength) return;
        try ContiguousTokensEditing.delete(_lineTokens, fromChIndex, lineTextLength);
    }

    pub fn delete(_lineTokens: *?ArrayList(TokenPacked), fromChIndex: usize, toChIndex: usize) !void {
        if (_lineTokens.* == null or _lineTokens.*.?.items.len == 0 or fromChIndex >= toChIndex) {
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
            const delta: u32 = @intCast(toChIndex - fromChIndex);
            for (fromTokenIndex..tokensCount) |i| {
                tokens[i].endOffset -= delta;
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
            // Upstream uses JS numbers here and may produce a negative
            // intermediate value. Only the tokens that end after the deleted
            // range are kept.
            const tokenEndOffset = @as(isize, @intCast(tokens[tokenIndex].endOffset)) - @as(isize, @intCast(delta));
            if (tokenEndOffset > @as(isize, @intCast(lastEnd))) {
                const end: usize = @intCast(tokenEndOffset);
                tokens[dest].endOffset = @intCast(end);
                tokens[dest].metadata = tokens[tokenIndex].metadata;
                dest += 1;
                lastEnd = end;
            }
        }

        if (dest == tokens.len) {
            // nothing to trim
            return;
        }

        try lineTokens.resize(dest);
    }

    pub fn append(_lineTokens: *?ArrayList(TokenPacked), _otherTokens: *?ArrayList(TokenPacked)) !void {
        const other = _otherTokens.* orelse {
            // cannot determine combined line length...
            if (_lineTokens.*) |*tokens| tokens.deinit();
            _lineTokens.* = null;
            return;
        };
        if (other.items.len == 0) return;

        if (_lineTokens.* == null) return;
        const lineTokens = &_lineTokens.*.?;
        if (lineTokens.items.len == 0) {
            // Move the other list into this slot when possible; otherwise copy.
            if (lineTokens.allocator.ptr == other.allocator.ptr) {
                lineTokens.deinit();
                _lineTokens.* = other;
                _otherTokens.* = null;
                return;
            }
            try lineTokens.appendSlice(other.items);
            return;
        }

        const delta = lineTokens.items[lineTokens.items.len - 1].endOffset;
        // Copy first because appending may reallocate `lineTokens`.
        const copied = try other.allocator.dupe(TokenPacked, other.items);
        defer other.allocator.free(copied);
        for (copied) |*token| {
            token.endOffset += delta;
        }
        try lineTokens.appendSlice(copied);
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


test "ContiguousTokensEditing.delete skips tokens before the deleted range" {
    const allocator = std.testing.allocator;
    var tokens = ArrayList(TokenPacked).init(allocator);
    try tokens.append(.{ .endOffset = 2, .metadata = .default });
    try tokens.append(.{ .endOffset = 4, .metadata = .default });
    try tokens.append(.{ .endOffset = 10, .metadata = .default });

    var optional: ?ArrayList(TokenPacked) = tokens;
    defer if (optional) |*value| value.deinit();
    try ContiguousTokensEditing.delete(&optional, 0, 8);
    const result = optional.?;
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqual(@as(u32, 2), result.items[0].endOffset);
}


test "ContiguousTokensEditing.append releases an empty destination buffer" {
    const allocator = std.testing.allocator;
    var first: ?ArrayList(TokenPacked) = ArrayList(TokenPacked).init(allocator);
    try first.?.append(.{ .endOffset = 4, .metadata = .default });
    try ContiguousTokensEditing.delete(&first, 0, 4);
    try std.testing.expectEqual(@as(usize, 0), first.?.items.len);

    var second: ?ArrayList(TokenPacked) = ArrayList(TokenPacked).init(allocator);
    try second.?.append(.{ .endOffset = 4, .metadata = .default });

    try ContiguousTokensEditing.append(&first, &second);
    var result = first.?;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
}


test "ContiguousTokensEditing.append frees the destination when other is null" {
    const allocator = std.testing.allocator;
    var first: ?ArrayList(TokenPacked) = ArrayList(TokenPacked).init(allocator);
    try first.?.append(.{ .endOffset = 4, .metadata = .default });

    var none: ?ArrayList(TokenPacked) = null;
    try ContiguousTokensEditing.append(&first, &none);
    try std.testing.expect(first == null);
}

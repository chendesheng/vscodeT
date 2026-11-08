const std = @import("std");
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const SliceLineTokens = @import("../tokens/lineTokens.zig").SliceLineTokens;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;

/// A contiguous run of tokens belonging to one language inside a line.
/// Borrows the underlying `LineTokens`; the caller keeps it alive.
pub const ScopedLineTokens = struct {
    _actual: *const LineTokens,
    languageId: []const u8,
    _firstTokenIndex: usize,
    _lastTokenIndex: usize,
    firstCharOffset: usize,
    _lastCharOffset: usize,

    pub fn init(
        actual: *const LineTokens,
        languageId: []const u8,
        firstTokenIndex: usize,
        lastTokenIndex: usize,
        firstCharOffset: usize,
        lastCharOffset: usize,
    ) ScopedLineTokens {
        return .{
            ._actual = actual,
            .languageId = languageId,
            ._firstTokenIndex = firstTokenIndex,
            ._lastTokenIndex = lastTokenIndex,
            .firstCharOffset = firstCharOffset,
            ._lastCharOffset = lastCharOffset,
        };
    }

    pub fn getLineContent(self: *const ScopedLineTokens) []const u8 {
        const actualLineContent = self._actual.getLineContent();
        return actualLineContent[self.firstCharOffset..self._lastCharOffset];
    }

    pub fn getLineLength(self: *const ScopedLineTokens) usize {
        return self._lastCharOffset - self.firstCharOffset;
    }

    pub fn getActualLineContentBefore(self: *const ScopedLineTokens, offset: usize) []const u8 {
        const actualLineContent = self._actual.getLineContent();
        return actualLineContent[0 .. self.firstCharOffset + offset];
    }

    pub fn getTokenCount(self: *const ScopedLineTokens) usize {
        return self._lastTokenIndex - self._firstTokenIndex;
    }

    pub fn findTokenIndexAtOffset(self: *const ScopedLineTokens, offset: usize) usize {
        return self._actual.findTokenIndexAtOffset(offset + self.firstCharOffset) - self._firstTokenIndex;
    }

    pub fn getStandardTokenType(self: *const ScopedLineTokens, tokenIndex: usize) StandardTokenType {
        return self._actual.getStandardTokenType(tokenIndex + self._firstTokenIndex);
    }

    pub fn toSliceLineTokens(self: *const ScopedLineTokens) SliceLineTokens {
        return self._actual.sliceAndInflate(self.firstCharOffset, self._lastCharOffset, 0);
    }
};

pub fn createScopedLineTokens(context: *const LineTokens, offset: usize) ScopedLineTokens {
    const tokenCount = context.getCount();
    const tokenIndex = context.findTokenIndexAtOffset(offset);
    const desiredLanguageId = context.getLanguageId(tokenIndex);

    var lastTokenIndex = tokenIndex;
    while (lastTokenIndex + 1 < tokenCount and
        std.mem.eql(u8, context.getLanguageId(lastTokenIndex + 1), desiredLanguageId))
    {
        lastTokenIndex += 1;
    }

    var firstTokenIndex = tokenIndex;
    while (firstTokenIndex > 0 and
        std.mem.eql(u8, context.getLanguageId(firstTokenIndex - 1), desiredLanguageId))
    {
        firstTokenIndex -= 1;
    }

    return ScopedLineTokens.init(
        context,
        desiredLanguageId,
        firstTokenIndex,
        lastTokenIndex + 1,
        context.getStartOffset(firstTokenIndex),
        context.getEndOffset(lastTokenIndex),
    );
}

pub fn ignoreBracketsInToken(standardTokenType: StandardTokenType) bool {
    return switch (standardTokenType) {
        .Comment, .String, .RegEx => true,
        .Other => false,
    };
}

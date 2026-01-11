const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TokenMetadata = @import("../../encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;
const TokenPacked = @import("../../tokens/lineTokens.zig").TokenPacked;
const TokenPresentation = @import("../../encodedTokenAttributes.zig").TokenPresentation;
const LanguageIdCodec = @import("../../services/languageRegistry.zig").LanguageIdCodec;

// A token on a line.
pub const TestLineToken = struct {
    // last char index of this token (not inclusive).
    endIndex: usize,
    _metadata: TokenMetadata,
    _allocator: Allocator,

    pub fn init(allocator: Allocator, endIndex: usize, metadata: TokenMetadata) TestLineToken {
        return TestLineToken{
            .endIndex = endIndex,
            ._metadata = metadata,
            ._allocator = allocator,
        };
    }

    pub fn getStandardTokenType(self: TestLineToken) StandardTokenType {
        return self._metadata.tokenType;
    }

    pub fn getForeground(self: *const TestLineToken) u9 {
        return self._metadata.foreground;
    }

    pub fn getType(self: *const TestLineToken) !ArrayList(u8) {
        return try self._metadata.getClassNameFromMetadata(self._allocator);
    }

    pub fn getInlineStyle(self: *const TestLineToken, colorMap: []const []const u8) !ArrayList(u8) {
        return try self._metadata.getInlineStyleFromMetadata(self._allocator, colorMap);
    }

    pub fn getPresentation(self: *const TestLineToken) TokenPresentation {
        return self._metadata.getPresentationFromMetadata();
    }

    fn equals(a: TestLineToken, b: TestLineToken) bool {
        return (a.endIndex == b.endIndex and a._metadata == b._metadata);
    }

    pub fn equalsArr(a: []const TestLineToken, b: []const TestLineToken) bool {
        return std.mem.eql(TestLineToken, a, b);
    }
};

pub const TestLineTokens = struct {
    _actual: []TestLineToken,

    pub fn init(actual: []TestLineToken) TestLineTokens {
        return TestLineTokens{
            ._actual = actual,
        };
    }

    pub fn equals(self: *const TestLineTokens, other: *const TestLineTokens) bool {
        return TestLineToken.equalsArr(self._actual, other._actual);
    }

    pub fn getCount(self: *const TestLineTokens) usize {
        return self._actual.len;
    }

    pub fn getStandardTokenType(self: *const TestLineTokens, tokenIndex: usize) StandardTokenType {
        return self._actual[tokenIndex].getStandardTokenType();
    }

    pub fn getForeground(self: *const TestLineTokens, tokenIndex: usize) u9 {
        return self._actual[tokenIndex].getForeground();
    }

    pub fn getEndOffset(self: *const TestLineTokens, tokenIndex: usize) usize {
        return self._actual[tokenIndex].endIndex;
    }

    pub fn getClassName(self: *const TestLineTokens, tokenIndex: usize) !ArrayList(u8) {
        return try self._actual[tokenIndex].getType();
    }

    pub fn getInlineStyle(self: *const TestLineTokens, tokenIndex: usize, colorMap: []const []const u8) !ArrayList(u8) {
        return try self._actual[tokenIndex].getInlineStyle(colorMap);
    }

    pub fn getPresentation(self: *const TestLineTokens, tokenIndex: usize) TokenPresentation {
        return self._actual[tokenIndex].getPresentation();
    }

    pub fn findTokenIndexAtOffset(self: *const TestLineTokens, offset: usize) usize {
        _ = self;
        _ = offset;
        unreachable;
    }

    pub fn getLineContent(self: *const TestLineTokens) []const u8 {
        _ = self;
        unreachable;
    }

    pub fn getMetadata(self: *const TestLineTokens, tokenIndex: usize) TokenMetadata {
        _ = self;
        _ = tokenIndex;
        unreachable;
    }

    pub fn getLanguageId(self: *const TestLineTokens, tokenIndex: usize) []const u8 {
        _ = self;
        _ = tokenIndex;
        unreachable;
    }

    pub fn getTokenText(self: *const TestLineTokens, tokenIndex: usize) []const u8 {
        _ = self;
        _ = tokenIndex;
        unreachable;
    }

    pub fn forEach(self: *const TestLineTokens, context: anytype, callback: fn (tokenIndex: usize, ctx: @TypeOf(context)) void) void {
        _ = self;
        _ = callback;
        unreachable;
    }

    pub fn getLanguageIdCodec(self: *const TestLineTokens) *LanguageIdCodec {
        _ = self;
        unreachable;
    }
};

pub const TestLineTokenFactory = struct {
    pub fn inflateArr(allocator: Allocator, tokens: []const TokenPacked) ![]TestLineToken {
        var result = ArrayList(TestLineToken).init(allocator);
        defer result.deinit();
        for (tokens) |token| {
            const endOffset = token.endOffset;
            const metadata = token.metadata;

            try result.append(TestLineToken.init(allocator, endOffset, metadata));
        }

        return try result.toOwnedSlice();
    }
};

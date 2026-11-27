// Port of `src/vs/workbench/services/textMate/browser/tokenizationSupport/tokenizationSupportWithLineLimit.ts`.
// The terminal model supplies the current configuration value at the UTF-8
// boundary. VS Code's line.length counts UTF-16 code units.
const std = @import("std");
const languages = @import("../../../../../editor/common/languages.zig");
const encoded = @import("../../../../../editor/common/encodedTokenAttributes.zig");
const nullTokenizeEncoded = @import("../../../../../editor/common/languages/nullTokenize.zig").nullTokenizeEncoded;
const position = @import("../../../../api/common/positionConverter.zig");

pub const default_limit: usize = 20_000;

pub fn atLimit(line: []const u8, limit: usize) bool {
    if (line.len < limit) return false;
    // Each UTF-16 unit occupies at most three UTF-8 bytes.
    if (line.len / 3 >= limit) return true;
    return position.utf16OffsetForColumn(line, line.len + 1) - 1 >= limit;
}

pub const TokenizationSupportWithLineLimit = struct {
    actual: languages.ITokenizationSupport,
    encoded_language_id: encoded.LanguageId,
    limit: usize,

    pub fn interface(self: *TokenizationSupportWithLineLimit) languages.ITokenizationSupport {
        return .{ .context = self, .vtable = &.{ .getInitialState = getInitialState, .tokenizeEncoded = tokenizeEncoded, .tokenizeEncodedWithStateAllocator = tokenizeEncodedWithStateAllocator } };
    }

    fn getInitialState(context: *anyopaque, allocator: std.mem.Allocator) !languages.IState {
        const self: *TokenizationSupportWithLineLimit = @ptrCast(@alignCast(context));
        return self.actual.getInitialState(allocator);
    }

    fn tokenizeEncoded(context: *anyopaque, allocator: std.mem.Allocator, line: []const u8, has_eol: bool, state: languages.IState) !languages.EncodedTokenizationResult {
        const self: *TokenizationSupportWithLineLimit = @ptrCast(@alignCast(context));
        if (atLimit(line, self.limit)) return nullTokenizeEncoded(allocator, self.encoded_language_id, state);
        return self.actual.tokenizeEncoded(allocator, line, has_eol, state);
    }

    fn tokenizeEncodedWithStateAllocator(context: *anyopaque, scratch: std.mem.Allocator, state_allocator: std.mem.Allocator, line: []const u8, has_eol: bool, state: languages.IState) !languages.EncodedTokenizationResult {
        const self: *TokenizationSupportWithLineLimit = @ptrCast(@alignCast(context));
        if (atLimit(line, self.limit)) return nullTokenizeEncoded(scratch, self.encoded_language_id, state);
        return self.actual.tokenizeEncodedWithStateAllocator(scratch, state_allocator, line, has_eol, state);
    }
};

test "TextMate line limit compares UTF-16 length including the threshold" {
    try std.testing.expect(atLimit("", 0));
    try std.testing.expect(!atLimit("x😀", 4));
    try std.testing.expect(atLimit("x😀", 3));
    try std.testing.expect(!atLimit("☼", 2));
    var line: [default_limit]u8 = undefined;
    @memset(&line, 97);
    try std.testing.expect(atLimit(&line, default_limit));
}

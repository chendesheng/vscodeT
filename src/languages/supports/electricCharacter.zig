const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const ScopedLineTokens = @import("../supports.zig").ScopedLineTokens;
const ignoreBracketsInToken = @import("../supports.zig").ignoreBracketsInToken;
const RichEditBrackets = @import("richEditBrackets.zig").RichEditBrackets;
const BracketsUtils = @import("richEditBrackets.zig").BracketsUtils;

pub const IElectricAction = struct {
    /// The opening bracket whose line indentation should be matched.
    /// Borrowed from the `RichEditBrackets` owner.
    matchOpenBracket: []const u8,
};

/// Interface used to support electric characters.
pub const BracketElectricCharacterSupport = struct {
    _richEditBrackets: ?*const RichEditBrackets,

    pub fn init(richEditBrackets: ?*const RichEditBrackets) BracketElectricCharacterSupport {
        return .{ ._richEditBrackets = richEditBrackets };
    }

    pub fn getElectricCharacters(
        self: *const BracketElectricCharacterSupport,
        out: *ArrayList([]const u8),
    ) !void {
        const rich = self._richEditBrackets orelse return;
        for (rich.brackets) |bracket| {
            for (bracket.close) |close| {
                if (close.len == 0) continue;
                const last_char = close[close.len - 1 ..];
                var found = false;
                for (out.items) |existing| {
                    if (std.mem.eql(u8, existing, last_char)) {
                        found = true;
                        break;
                    }
                }
                if (!found) try out.append(last_char);
            }
        }
    }

    pub fn onElectricCharacter(
        self: *const BracketElectricCharacterSupport,
        allocator: Allocator,
        character: []const u8,
        context: ScopedLineTokens,
        column: usize,
    ) !?IElectricAction {
        const rich = self._richEditBrackets orelse return null;
        if (rich.brackets.len == 0) return null;
        if (column == 0) return null;

        const ctx = &context;
        const tokenIndex = ctx.findTokenIndexAtOffset(column - 1);
        if (ignoreBracketsInToken(ctx.getStandardTokenType(tokenIndex))) return null;

        const line = ctx.getLineContent();
        const before_len = @min(column - 1, line.len);

        var text = ArrayList(u8).init(allocator);
        defer text.deinit();
        try text.appendSlice(line[0..before_len]);
        try text.appendSlice(character);

        const range = try BracketsUtils.findPrevBracketInRange(
            allocator,
            &rich.reversedRegex,
            1,
            text.items,
            0,
            text.items.len,
        ) orelse return null;

        if (range.startColumn == 0 or range.endColumn < range.startColumn) return null;
        const bracket_text_raw = text.items[range.startColumn - 1 .. range.endColumn - 1];
        const bracket_text = try lowercaseAlloc(allocator, bracket_text_raw);
        defer allocator.free(bracket_text);

        const entry = rich.textIsOpenBracket.getEntry(bracket_text) orelse return null;
        if (entry.value_ptr.*) return null;

        const text_before_bracket = ctx.getActualLineContentBefore(range.startColumn - 1);
        if (!isWhitespace(text_before_bracket)) return null;

        return .{ .matchOpenBracket = entry.key_ptr.* };
    }
};

fn lowercaseAlloc(allocator: Allocator, text: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, text.len);
    for (text, 0..) |ch, i| result[i] = std.ascii.toLower(ch);
    return result;
}

fn isWhitespace(text: []const u8) bool {
    for (text) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') return false;
    }
    return true;
}

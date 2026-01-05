const std = @import("std");
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const SparseMultilineTokens = @import("../tokens/sparseMultilineTokens.zig").SparseMultilineTokens;
const SparseToken = @import("../tokens/sparseMultilineTokens.zig").SparseToken;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const MetadataConsts = @import("../encodedTokenAttributes.zig").MetadataConsts;

const TokensStoreTests = struct {
    const allocator = std.testing.allocator;

    fn parseTokensState(state: []const []const u8) !struct { []const u8, SparseMultilineTokens } {
        var text = ArrayList([]const u8).init(allocator);
        defer text.deinit();

        var tokens = ArrayList(SparseToken).init(allocator);
        defer tokens.deinit();

        var baseLine = 1;
        for (0..state.len) |i| {
            const line = state[i];

            var startOffset: usize = 0;
            var lineText = ArrayList(u8).init(allocator);
            while (true) {
                const firstPipeOffset = std.mem.indexOf(u8, line[startOffset..], '|');
                if (firstPipeOffset == null) {
                    break;
                }
                const secondPipeOffset = std.mem.indexOf(u8, line[firstPipeOffset + 1 ..], '|');
                if (secondPipeOffset == null) {
                    break;
                }
                if (firstPipeOffset.? + 1 == secondPipeOffset) {
                    // skip ||
                    try lineText.appendSlice(line[startOffset .. secondPipeOffset + 1]);
                    startOffset = secondPipeOffset + 1;
                    continue;
                }

                try lineText.appendSlice(line[startOffset..firstPipeOffset]);
                const tokenStartCharacter = lineText.items.len;
                const tokenLength = secondPipeOffset - firstPipeOffset - 1;
                const metadata: TokenMetadata = .{
                    .languageId = MetadataConsts.SEMANTIC_USE_FOREGROUND,
                    .foreground = .DefaultForeground,
                };

                if (tokens.items.length == 0) {
                    baseLine = i + 1;
                }
                try tokens.append(i + 1 - baseLine);
                try tokens.append(tokenStartCharacter);
                try tokens.append(tokenStartCharacter + tokenLength);
                try tokens.append(metadata);

                try lineText.appendSlice(line[firstPipeOffset + 1 .. firstPipeOffset + 1 + tokenLength]);
                startOffset = secondPipeOffset + 1;
            }

            try lineText.appendSlice(line[startOffset..]);

            try text.append(lineText.items);
        }

        return .{ try std.mem.join(allocator, '\n', text.items), SparseMultilineTokens.create(baseLine, tokens) };
    }

    fn extractState(model: *TextModel) ![]const []const u8 {
        const result = ArrayList([]const u8).init(allocator);
        defer result.deinit();

        for (1..model.getLineCount() + 1) |lineNumber| {
            const lineTokens = try model.tokenization().getLineTokens(lineNumber);
            const lineContent = try model.getLineContent(lineNumber);

            var lineText = ArrayList(u8).init(allocator);
            defer lineText.deinit();

            for (0..lineTokens.getCount()) |i| {
                const tokenStartCharacter = lineTokens.getStartOffset(i);
                const tokenEndCharacter = lineTokens.getEndOffset(i);
                const metadata = lineTokens.getMetadata(i);
                const color = metadata.foreground;
                const tokenText = lineContent.substring(tokenStartCharacter, tokenEndCharacter);
                if (color == .Color5) { // SEMANTIC_COLOR
                    try lineText.append('|');
                    try lineText.appendSlice(tokenText);
                    try lineText.append('|');
                } else {
                    try lineText.appendSlice(tokenText);
                }
            }

            result.append(try lineText.toOwnedSlice());
        }
        return try result.toOwnedSlice();
    }
};

test "tokensStore" {
    _ = TokensStoreTests{};
}

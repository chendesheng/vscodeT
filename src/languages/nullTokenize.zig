const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Token = @import("../languages.zig").Token;
const TokenizationResult = @import("../languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const IState = @import("../languages.zig").IState;
const LanguageId = @import("../encodedTokenAttributes.zig").LanguageId;
const FontStyle = @import("../encodedTokenAttributes.zig").FontStyle;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;

const nullState = IState{ .data = &[_]u8{} };

pub fn nullTokenize(languageId: []u8, state: IState) TokenizationResult {
    return TokenizationResult.init(ArrayList(Token).init(Token.init(0, languageId, 0)), state);
}

pub fn nullTokenizeEncoded(languageId: u8, state: ?IState) EncodedTokenizationResult {
    var tokens = [_]TokenPacked{.{
        .endOffset = 0,
        .metadata = .{
            .languageId = languageId,
            .background = ColorId.DefaultBackground,
            .foreground = ColorId.DefaultForeground,
        },
    }};
    return EncodedTokenizationResult.init(&tokens, state orelse nullState);
}

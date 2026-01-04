const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Token = @import("./languages.zig").Token;
const TokenizationResult = @import("./languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("./languages.zig").EncodedTokenizationResult;
const IState = @import("./languages.zig").IState;
const LanguageId = @import("./encodedTokenAttributes.zig").LanguageId;
const FontStyle = @import("./encodedTokenAttributes.zig").FontStyle;
const ColorId = @import("./encodedTokenAttributes.zig").ColorId;
const StandardTokenType = @import("./encodedTokenAttributes.zig").StandardTokenType;
const TokenMetadata = @import("./encodedTokenAttributes.zig").TokenMetadata;

const NullState = IState{
    .clone = nullStateClone,
    .equals = nullStateEquals,
};

fn nullStateClone() IState {
    return NullState;
}

fn nullStateEquals(self: IState) bool {
    return self == NullState;
}

pub fn nullTokenize(languageId: []u8, state: IState) TokenizationResult {
    return TokenizationResult.init(ArrayList(Token).init(Token.init(0, languageId, 0)), state);
}

pub fn nullTokenizeEncoded(languageId: LanguageId, state: ?IState) EncodedTokenizationResult {
    _ = languageId;
    const tokens = [_]u32{ 0, @intCast(TokenMetadata.default) };
    return EncodedTokenizationResult.init(tokens, if (state == null) NullState else state.?);
}

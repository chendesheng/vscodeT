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
const TokenPacked = @import("./tokens/lineTokens.zig").TokenPacked;

const NullState = IState{
    .clone = nullStateClone,
    .equals = nullStateEquals,
};

fn nullStateClone() IState {
    return NullState;
}

fn nullStateEquals(self: IState) bool {
    return self.clone == NullState.clone;
}

pub fn nullTokenize(languageId: []u8, state: IState) TokenizationResult {
    return TokenizationResult.init(ArrayList(Token).init(Token.init(0, languageId, 0)), state);
}

var null_tokens = [_]TokenPacked{.{ .endOffset = 0, .metadata = TokenMetadata.default }};

pub fn nullTokenizeEncoded(languageId: LanguageId, state: ?IState) EncodedTokenizationResult {
    _ = languageId;
    return EncodedTokenizationResult.init(&null_tokens, if (state == null) NullState else state.?);
}

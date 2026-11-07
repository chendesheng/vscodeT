const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("./languages.zig").Token;
const TokenizationResult = @import("./languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("./languages.zig").EncodedTokenizationResult;
const IState = @import("./languages.zig").IState;
const LanguageId = @import("./encodedTokenAttributes.zig").LanguageId;
const TokenMetadata = @import("./encodedTokenAttributes.zig").TokenMetadata;
const TokenPacked = @import("./tokens/lineTokens.zig").TokenPacked;

var null_context: u8 = 0;

fn nullStateClone(_: *anyopaque, _: Allocator) anyerror!IState {
    return NullState;
}

fn nullStateEquals(_: *anyopaque, other: IState) bool {
    return other.vtable == &null_state_vtable;
}

const null_state_vtable: IState.VTable = .{
    .clone = nullStateClone,
    .equals = nullStateEquals,
};

pub const NullState = IState{
    .context = @ptrCast(&null_context),
    .vtable = &null_state_vtable,
};

pub fn nullTokenize(languageId: []const u8, state: IState) TokenizationResult {
    _ = languageId;
    return TokenizationResult.init(&[_]Token{}, state);
}

pub fn nullTokenizeEncoded(allocator: Allocator, languageId: LanguageId, state: ?IState) !EncodedTokenizationResult {
    _ = languageId;
    const tokens = try allocator.alloc(TokenPacked, 1);
    tokens[0] = .{ .endOffset = 0, .metadata = TokenMetadata.default };
    return EncodedTokenizationResult.init(tokens, if (state) |s| s else NullState);
}

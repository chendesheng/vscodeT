// Port of `src/vs/editor/common/languages/nullTokenize.ts`.
//
// Zig adaptation: allocating a non-encoded token array needs an allocator, so
// `nullTokenize` takes one and returns an error union (like
// `nullTokenizeEncoded`); upstream relies on the JS garbage collector.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("../languages.zig").Token;
const TokenizationResult = @import("../languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const IState = @import("../languages.zig").IState;
const LanguageId = @import("../encodedTokenAttributes.zig").LanguageId;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const FontStyle = @import("../encodedTokenAttributes.zig").FontStyle;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;

var null_context: u8 = 0;

fn nullStateClone(_: *anyopaque, _: Allocator) anyerror!IState {
    // Upstream returns the singleton state itself.
    return NullState;
}

fn nullStateEquals(_: *anyopaque, other: IState) bool {
    // Upstream compares object identity (`this === other`); the port models
    // the singleton as this context/vtable pair.
    return other.context == @as(*anyopaque, @ptrCast(&null_context)) and
        other.vtable == &null_state_vtable;
}

const null_state_vtable: IState.VTable = .{
    .clone = nullStateClone,
    .equals = nullStateEquals,
};

pub const NullState = IState{
    .context = @ptrCast(&null_context),
    .vtable = &null_state_vtable,
};

pub fn nullTokenize(allocator: Allocator, languageId: []const u8, state: IState) !TokenizationResult {
    const tokens = try allocator.alloc(Token, 1);
    errdefer allocator.free(tokens);
    tokens[0] = Token.init(0, "", languageId);
    return TokenizationResult.init(tokens, state);
}

pub fn nullTokenizeEncoded(allocator: Allocator, languageId: LanguageId, state: ?IState) !EncodedTokenizationResult {
    var metadata = TokenMetadata.default;
    metadata.languageId = @backingInt(languageId);

    const tokens = try allocator.alloc(TokenPacked, 1);
    errdefer allocator.free(tokens);
    tokens[0] = .{ .endOffset = 0, .metadata = metadata };
    return EncodedTokenizationResult.init(tokens, if (state) |s| s else NullState);
}

test "nullTokenize: NullState identity" {
    const cloned = try NullState.clone(std.testing.allocator);
    try std.testing.expect(cloned.equals(NullState));
    try std.testing.expect(NullState.equals(cloned));

    var other_context: u8 = 0;
    const OtherState = struct {
        fn clone(_: *anyopaque, _: Allocator) anyerror!IState {
            return error.NotSupported;
        }

        fn equals(_: *anyopaque, _: IState) bool {
            return false;
        }
    };
    const other_vtable: IState.VTable = .{
        .clone = OtherState.clone,
        .equals = OtherState.equals,
    };
    const other = IState{
        .context = @ptrCast(&other_context),
        .vtable = &other_vtable,
    };
    try std.testing.expect(!NullState.equals(other));
    try std.testing.expect(!other.equals(NullState));
}

test "nullTokenize: encoded default metadata" {
    const encoded_language_id: LanguageId = @fromBackingInt(1);
    const result = try nullTokenizeEncoded(std.testing.allocator, encoded_language_id, null);
    defer std.testing.allocator.free(result.tokens);

    try std.testing.expectEqual(@as(usize, 1), result.tokens.len);
    try std.testing.expectEqual(@as(u32, 0), result.tokens[0].endOffset);

    const metadata = result.tokens[0].metadata;
    try std.testing.expectEqual(@as(u8, 1), metadata.languageId);
    try std.testing.expectEqual(StandardTokenType.Other, metadata.tokenType);
    try std.testing.expectEqual(FontStyle.None, metadata.fontStyle);
    try std.testing.expectEqual(ColorId.DefaultForeground, metadata.foreground);
    try std.testing.expectEqual(@as(u8, @intCast(ColorId.DefaultBackground)), metadata.background);
    try std.testing.expect(!metadata.balancedBrackets);

    try std.testing.expect(result.endState.equals(NullState));
}

test "nullTokenize: explicit end state and single token" {
    const result = try nullTokenize(std.testing.allocator, "zig", NullState);
    defer std.testing.allocator.free(result.tokens);

    try std.testing.expectEqual(@as(usize, 1), result.tokens.len);
    try std.testing.expectEqual(@as(usize, 0), result.tokens[0].offset);
    try std.testing.expectEqualStrings("", result.tokens[0].type_);
    try std.testing.expectEqualStrings("zig", result.tokens[0].language);
    try std.testing.expect(result.endState.equals(NullState));

    const encoded = try nullTokenizeEncoded(std.testing.allocator, @fromBackingInt(0), NullState);
    defer std.testing.allocator.free(encoded.tokens);
    try std.testing.expect(encoded.endState.equals(NullState));
}

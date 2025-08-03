const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Position = @import("./basics/position.zig").Position;
const ContiguousMultilineTokens = @import("./tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const TextModel = @import("./textModel.zig").TextModel;
const TokenPacked = @import("./tokens/lineTokens.zig").TokenPacked;

// @internal
pub const LanguageIdCodec = struct {
    pub fn encodeLanguageId(languageId: []const u8) u8 {
        _ = languageId;
        return 0;
    }

    pub fn decodeLanguageId(languageId: u8) []const u8 {
        _ = languageId;
        return "unknown";
    }
};

pub const Token = struct {
    offset: usize,
    type_: []const u8,
    language: u8,

    pub fn init(
        offset: usize,
        type_: []const u8,
        language: u8,
    ) Token {
        return Token{
            .offset = offset,
            .type_ = type_,
            .language = language,
        };
    }

    pub fn toString(self: *Token, allocator: Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "({d}, {s})", .{ self.offset, self.type_ });
    }
};

// @internal
pub const TokenizationSupportChangedEvent = struct {
    changedLanguages: []const u8,
    changedColorMap: bool,
};

// @internal
pub const TokenizationResult = struct {
    tokens: ArrayList(Token),
    endState: IState,

    pub fn init(tokens: ArrayList(Token), endState: IState) TokenizationResult {
        return TokenizationResult{
            .tokens = tokens,
            .endState = endState,
        };
    }
};

// @internal
pub const EncodedTokenizationResult = struct {
    tokens: []TokenPacked,
    endState: IState,

    // The tokens in binary format. Each token occupies two array indices. For token i:
    //  - at offset 2*i => startIndex
    //  - at offset 2*i + 1 => metadata
    pub fn init(tokens: []TokenPacked, endState: IState) EncodedTokenizationResult {
        return EncodedTokenizationResult{
            .tokens = tokens,
            .endState = endState,
        };
    }
};

pub const SyntaxNode = struct {
    startIndex: usize,
    endIndex: usize,
    startPosition: Position,
    endPosition: Position,
};

pub const QueryCapture = struct {
    name: []u8,
    text: ?[]u8,
    node: SyntaxNode,
    encodedLanguageId: u32,
};

// @internal
pub const ITokenizationSupport = struct {
    // If true, the background tokenizer will only be used to verify tokens against the default background tokenizer.
    // Used for debugging.
    backgroundTokenizerShouldOnlyVerifyTokens: ?bool,

    getInitialState: fn () IState,

    tokenize: fn (line: []u8, hasEOL: bool, state: IState) TokenizationResult,

    tokenizeEncoded: fn (line: []u8, hasEOL: bool, state: IState) EncodedTokenizationResult,

    // Can be/return undefined if default background tokenization should be used.
    createBackgroundTokenizer: ?fn (textModel: TextModel, store: IBackgroundTokenizationStore) IBackgroundTokenizer,
};

// @internal
pub const IBackgroundTokenizer = struct {
    // Instructs the background tokenizer to set the tokens for the given range again.
    // This might be necessary if the renderer overwrote those tokens with heuristically computed ones for some viewport,
    // when the change does not even propagate to that viewport.
    requestTokens: fn (startLineNumber: usize, endLineNumberExclusive: usize) void,

    reportMismatchingTokens: ?fn (lineNumber: usize) void,
};

// @internal
pub const IBackgroundTokenizationStore = struct {
    setTokens: fn (tokens: []ContiguousMultilineTokens) void,

    setEndState: fn (lineNumber: usize, state: IState) void,

    // Should be called to indicate that the background tokenization has finished for now.
    // (This triggers bracket pair colorization to re-parse the bracket pairs with token information)
    backgroundTokenizationFinished: fn () void,
};

// The state of the tokenizer between two lines.
// It is useful to store flags such as in multiline comment, etc.
// The model will clone the previous line's state and pass it in to tokenize the next line.
pub const IState = struct {
    clone: fn () IState,
    equals: fn (other: IState) bool,
};

const std = @import("std");
const io = std.io;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Position = @import("./basics/position.zig").Position;
const ContiguousMultilineTokens = @import("./tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const TextModel = @import("./textModel/textModel.zig").TextModel;
const TokenPacked = @import("./tokens/lineTokens.zig").TokenPacked;
const LanguageId = @import("./encodedTokenAttributes.zig").LanguageId;
const LanguageIdCodec = @import("./services/languageRegistry.zig").LanguageIdCodec;
const Emitter = @import("./basics/event.zig").Emitter;

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

    pub fn toString(self: *const Token, writer: *io.Writer) !void {
        try writer.print("({d}, {s})", .{ self.offset, self.type_ });
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

    getInitialState: *const fn () IState,

    tokenize: *const fn (line: []const u8, hasEOL: bool, state: IState) TokenizationResult,

    tokenizeEncoded: *const fn (line: []const u8, hasEOL: bool, state: IState) EncodedTokenizationResult,

    // Can be/return undefined if default background tokenization should be used.
    createBackgroundTokenizer: ?*const fn (textModel: *TextModel, store: IBackgroundTokenizationStore) IBackgroundTokenizer,
};

// @internal
pub const IBackgroundTokenizer = struct {
    // Instructs the background tokenizer to set the tokens for the given range again.
    // This might be necessary if the renderer overwrote those tokens with heuristically computed ones for some viewport,
    // when the change does not even propagate to that viewport.
    requestTokens: *const fn (startLineNumber: usize, endLineNumberExclusive: usize) void,

    reportMismatchingTokens: ?*const fn (lineNumber: usize) void,
};

// @internal
pub const IBackgroundTokenizationStore = struct {
    setTokens: *const fn (tokens: []ContiguousMultilineTokens) void,

    setEndState: *const fn (lineNumber: usize, state: IState) void,

    // Should be called to indicate that the background tokenization has finished for now.
    // (This triggers bracket pair colorization to re-parse the bracket pairs with token information)
    backgroundTokenizationFinished: *const fn () void,
};

// The state of the tokenizer between two lines.
// It is useful to store flags such as in multiline comment, etc.
// The model will clone the previous line's state and pass it in to tokenize the next line.
pub const IState = struct {
    clone: *const fn () IState,
    equals: *const fn (other: IState) bool,
};

// @internal
pub const LazyTokenizationSupport = struct {
    _tokenizationSupport: ?ITokenizationSupport,

    createSupport: *const fn () ?ITokenizationSupport,

    pub fn init(createSupport: *const fn () ?ITokenizationSupport) LazyTokenizationSupport {
        return LazyTokenizationSupport{
            ._tokenizationSupport = null,
            .createSupport = createSupport,
        };
    }

    // pub fn dispose(self: *LazyTokenizationSupport) void {
    //     if (self._tokenizationSupport) |tokenizationSupport| {
    //         tokenizationSupport.dispose();
    //     }
    // }

    pub fn getTokenizationSupport(self: *LazyTokenizationSupport) ?ITokenizationSupport {
        if (self._tokenizationSupport) |tokenizationSupport| {
            return tokenizationSupport;
        }
        self._tokenizationSupport = self.createSupport();
        return self._tokenizationSupport;
    }
};

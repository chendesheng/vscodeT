const std = @import("std");
const io = std.io;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Position = @import("./basics/position.zig").Position;
const ContiguousMultilineTokens = @import("./tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const TextModel = @import("./textModel/textModel.zig").TextModel;
const TokenPacked = @import("./tokens/lineTokens.zig").TokenPacked;
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
    changedLanguages: []const []const u8,
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
    vtable: *const VTable,
    // If true, the background tokenizer will only be used to verify tokens against the default background tokenizer.
    // Used for debugging.
    backgroundTokenizerShouldOnlyVerifyTokens: bool = false,

    pub const VTable = struct {
        getInitialState: *const fn (t: *ITokenizationSupport) anyerror!IState,
        tokenize: *const fn (t: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) anyerror!TokenizationResult,
        tokenizeEncoded: *const fn (t: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult,
        // Can be/return undefined if default background tokenization should be used.
        createBackgroundTokenizer: ?*const fn (t: *ITokenizationSupport, textModel: *TextModel, store: *IBackgroundTokenizationStore) anyerror!?IBackgroundTokenizer,
    };

    pub fn getInitialState(self: *ITokenizationSupport) !IState {
        return try self.vtable.getInitialState(self);
    }
    pub fn tokenize(self: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !TokenizationResult {
        return try self.vtable.tokenize(self, line, hasEOL, state);
    }
    pub fn tokenizeEncoded(self: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !EncodedTokenizationResult {
        return try self.vtable.tokenizeEncoded(self, line, hasEOL, state);
    }
    pub fn createBackgroundTokenizer(self: *ITokenizationSupport, textModel: *TextModel, store: *IBackgroundTokenizationStore) !?IBackgroundTokenizer {
        if (self.vtable.createBackgroundTokenizer) |f| {
            return try f(self, textModel, store);
        }
        return null;
    }
};

// @internal
pub const IBackgroundTokenizer = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        // Instructs the background tokenizer to set the tokens for the given range again.
        // This might be necessary if the renderer overwrote those tokens with heuristically computed ones for some viewport,
        // when the change does not even propagate to that viewport.
        requestTokens: *const fn (b: *IBackgroundTokenizer, startLineNumber: usize, endLineNumberExclusive: usize) anyerror!void,
        reportMismatchingTokens: ?*const fn (b: *IBackgroundTokenizer, lineNumber: usize) void,
    };

    pub fn requestTokens(self: *IBackgroundTokenizer, startLineNumber: usize, endLineNumberExclusive: usize) !void {
        return try self.vtable.requestTokens(self, startLineNumber, endLineNumberExclusive);
    }
    pub fn reportMismatchingTokens(self: *IBackgroundTokenizer, lineNumber: usize) void {
        if (self.vtable.reportMismatchingTokens) |r| {
            return r(self, lineNumber);
        }
    }
};

// @internal
pub const IBackgroundTokenizationStore = struct {
    vtable: *const VTable,
    pub const VTable = struct {
        setTokens: *const fn (b: *IBackgroundTokenizationStore, tokens: []ContiguousMultilineTokens) anyerror!void,
        setEndState: *const fn (b: *IBackgroundTokenizationStore, lineNumber: usize, state: IState) anyerror!void,
        // Should be called to indicate that the background tokenization has finished for now.
        // (This triggers bracket pair colorization to re-parse the bracket pairs with token information)
        backgroundTokenizationFinished: *const fn (b: *IBackgroundTokenizationStore) void,
    };

    pub fn setTokens(self: *IBackgroundTokenizationStore, tokens: []ContiguousMultilineTokens) !void {
        return try self.vtable.setTokens(self, tokens);
    }
    pub fn setEndState(self: *IBackgroundTokenizationStore, lineNumber: usize, state: IState) !void {
        return try self.vtable.setEndState(self, lineNumber, state);
    }
    pub fn backgroundTokenizationFinished(self: *IBackgroundTokenizationStore) void {
        return self.vtable.backgroundTokenizationFinished(self);
    }
};

// The state of the tokenizer between two lines.
// It is useful to store flags such as in multiline comment, etc.
// The model will clone the previous line's state and pass it in to tokenize the next line.
pub const IState = struct {
    data: []u8,

    pub fn init(comptime T: type, data: *const T) IState {
        return .{
            .data = @as([*]u8, @ptrCast(@constCast(data)))[0..@sizeOf(T)],
        };
    }

    pub fn getPtr(self: IState, comptime T: type) *T {
        return @ptrCast(@alignCast(self.data.ptr));
    }

    pub fn clone(self: IState, allocator: Allocator) !IState {
        return .{ .data = try allocator.dupe(u8, self.data) };
    }

    pub fn equals(self: IState, other: IState) bool {
        return std.mem.eql(u8, self.data, other.data);
    }
};

// @internal
pub const LazyTokenizationSupport = struct {
    _tokenizationSupport: ?*ITokenizationSupport,

    createSupport: *const fn (l: *LazyTokenizationSupport) ?*ITokenizationSupport,

    pub fn init(createSupport: *const fn (l: *LazyTokenizationSupport) ?*ITokenizationSupport) LazyTokenizationSupport {
        return LazyTokenizationSupport{
            ._tokenizationSupport = null,
            .createSupport = createSupport,
        };
    }

    pub fn deinit(self: *LazyTokenizationSupport) void {
        _ = self;
        // if (self._tokenizationSupport) |tokenizationSupport| {
        //     tokenizationSupport.deinit();
        // }
    }

    pub fn getTokenizationSupport(self: *LazyTokenizationSupport) ?*ITokenizationSupport {
        if (self._tokenizationSupport) |tokenizationSupport| {
            return tokenizationSupport;
        }
        self._tokenizationSupport = self.createSupport();
        return self._tokenizationSupport;
    }
};

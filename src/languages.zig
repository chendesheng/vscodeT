const std = @import("std");
const Io = std.Io;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const Position = @import("./basics/position.zig").Position;
const ContiguousMultilineTokens = @import("./tokens/contiguousMultilineTokens.zig").ContiguousMultilineTokens;
const TextModel = @import("./textModel.zig").TextModel;
const TokenPacked = @import("./tokens/lineTokens.zig").TokenPacked;
const LanguageId = @import("./encodedTokenAttributes.zig").LanguageId;

pub const NULL_LANGUAGE_ID = "nullLanguage";

// @internal
pub const LanguageIdCodec = struct {
    _languageIdToLanguage: ArrayList([]const u8),
    _languageToLanguageId: std.StringHashMap(u8),

    pub fn init(allocator: Allocator) !LanguageIdCodec {
        var codec = LanguageIdCodec{
            ._languageIdToLanguage = ArrayList([]const u8).init(allocator),
            ._languageToLanguageId = std.StringHashMap(u8).init(allocator),
        };
        try codec._languageIdToLanguage.append(NULL_LANGUAGE_ID);
        try codec._languageToLanguageId.put(NULL_LANGUAGE_ID, 0);
        return codec;
    }

    pub fn deinit(self: *LanguageIdCodec) void {
        self._languageIdToLanguage.deinit();
        self._languageToLanguageId.deinit();
    }

    fn _register(self: *LanguageIdCodec, language: []const u8, languageId: u8) !void {
        try self._languageIdToLanguage.append(language);
        try self._languageToLanguageId.put(language, languageId);
    }

    pub fn register(self: *LanguageIdCodec, language: []const u8) !void {
        if (self._languageToLanguageId.get(language)) |_| {
            return;
        }
        if (self._languageIdToLanguage.items.len > std.math.maxInt(u8)) return error.TooManyLanguages;
        const languageId: u8 = @intCast(self._languageIdToLanguage.items.len);
        try self._register(language, languageId);
    }

    pub fn encodeLanguageId(self: *const LanguageIdCodec, language: []const u8) !u8 {
        if (self._languageToLanguageId.get(language)) |languageId| {
            return languageId;
        }
        return @backingInt(LanguageId.Null);
    }

    pub fn decodeLanguageId(self: *LanguageIdCodec, languageId: u8) []const u8 {
        if (languageId < self._languageIdToLanguage.items.len) {
            return self._languageIdToLanguage.items[languageId];
        }
        return NULL_LANGUAGE_ID;
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

    pub fn toString(self: *Token, writer: *Io.Writer) !void {
        try writer.print("({d}, {s})", .{ self.offset, self.type_ });
    }
};

// @internal
pub const TokenizationSupportChangedEvent = struct {
    changedLanguages: []const []const u8,
    changedColorMap: bool,

    pub fn affects(self: *const TokenizationSupportChangedEvent, languageId: []const u8) bool {
        for (self.changedLanguages) |changedLanguage| {
            if (std.mem.eql(u8, changedLanguage, languageId)) {
                return true;
            }
        }
        return false;
    }
};

// @internal
pub const TokenizationResult = struct {
    tokens: []Token,
    endState: IState,

    pub fn init(tokens: []Token, endState: IState) TokenizationResult {
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

// The state of a tokenizer between two lines.
//
// States are interface objects: `context` points at the concrete state data and
// `vtable` provides the operations. Clones must be allocated with the supplied
// allocator.
pub const IState = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        clone: *const fn (context: *anyopaque, allocator: Allocator) anyerror!IState,
        equals: *const fn (context: *anyopaque, other: IState) bool,
    };

    pub fn clone(self: IState, allocator: Allocator) anyerror!IState {
        return self.vtable.clone(self.context, allocator);
    }

    pub fn equals(self: IState, other: IState) bool {
        return self.vtable.equals(self.context, other);
    }
};

// @internal
pub const ITokenizationSupport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // If true, the background tokenizer will only be used to verify tokens
        // against the default background tokenizer. Used for debugging.
        backgroundTokenizerShouldOnlyVerifyTokens: ?bool = null,
        getInitialState: *const fn (context: *anyopaque, allocator: Allocator) anyerror!IState,
        tokenize: ?*const fn (context: *anyopaque, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!TokenizationResult = null,
        tokenizeEncoded: *const fn (context: *anyopaque, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult,
        // Can be null if default background tokenization should be used.
        createBackgroundTokenizer: ?*const fn (context: *anyopaque, textModel: *TextModel, store: IBackgroundTokenizationStore) IBackgroundTokenizer = null,
        dispose: ?*const fn (context: *anyopaque) void = null,
    };

    pub fn getInitialState(self: ITokenizationSupport, allocator: Allocator) anyerror!IState {
        return self.vtable.getInitialState(self.context, allocator);
    }

    pub fn tokenizeEncoded(self: ITokenizationSupport, allocator: Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        return self.vtable.tokenizeEncoded(self.context, allocator, line, hasEOL, state);
    }

    pub fn createBackgroundTokenizer(self: ITokenizationSupport, textModel: *TextModel, store: IBackgroundTokenizationStore) ?IBackgroundTokenizer {
        const create = self.vtable.createBackgroundTokenizer orelse return null;
        return create(self.context, textModel, store);
    }

    pub fn dispose(self: ITokenizationSupport) void {
        if (self.vtable.dispose) |disposeFn| disposeFn(self.context);
    }
};

// @internal
pub const IBackgroundTokenizer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Instructs the background tokenizer to set the tokens for the given
        // range again. This might be necessary if the renderer overwrote those
        // tokens with heuristically computed ones for some viewport, when the
        // change does not even propagate to that viewport.
        requestTokens: *const fn (context: *anyopaque, startLineNumber: usize, endLineNumberExclusive: usize) void,
        reportMismatchingTokens: ?*const fn (context: *anyopaque, lineNumber: usize) void = null,
        dispose: ?*const fn (context: *anyopaque) void = null,
    };

    pub fn requestTokens(self: IBackgroundTokenizer, startLineNumber: usize, endLineNumberExclusive: usize) void {
        self.vtable.requestTokens(self.context, startLineNumber, endLineNumberExclusive);
    }

    pub fn reportMismatchingTokens(self: IBackgroundTokenizer, lineNumber: usize) void {
        if (self.vtable.reportMismatchingTokens) |report| report(self.context, lineNumber);
    }

    pub fn dispose(self: IBackgroundTokenizer) void {
        if (self.vtable.dispose) |disposeFn| disposeFn(self.context);
    }
};

// @internal
pub const IBackgroundTokenizationStore = struct {
    context: *anyopaque,
    setTokens: *const fn (context: *anyopaque, tokens: []ContiguousMultilineTokens) void,

    setEndState: *const fn (context: *anyopaque, lineNumber: usize, state: IState) void,

    // Should be called to indicate that the background tokenization has finished for now.
    backgroundTokenizationFinished: *const fn (context: *anyopaque) void,
};

// @internal
pub const LazyTokenizationSupport = struct {
    context: *anyopaque,
    createSupport: *const fn (context: *anyopaque) ?ITokenizationSupport,
    _tokenizationSupport: ?ITokenizationSupport = null,

    pub fn init(context: *anyopaque, createSupport: *const fn (context: *anyopaque) ?ITokenizationSupport) LazyTokenizationSupport {
        return LazyTokenizationSupport{
            .context = context,
            .createSupport = createSupport,
            ._tokenizationSupport = null,
        };
    }

    pub fn getTokenizationSupport(self: *LazyTokenizationSupport) ?ITokenizationSupport {
        if (self._tokenizationSupport) |tokenizationSupport| {
            return tokenizationSupport;
        }
        self._tokenizationSupport = self.createSupport(self.context);
        return self._tokenizationSupport;
    }
};

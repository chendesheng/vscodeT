const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const Set = @import("../basics/Set.zig").Set;
const IBackgroundTokenizationStore = @import("../languages.zig").IBackgroundTokenizationStore;
const IState = @import("../languages.zig").IState;
const TokenizationResult = @import("../languages.zig").TokenizationResult;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const ContiguousMultilineTokensBuilder = @import("../tokens/contiguousMultilineTokensBuilder.zig").ContiguousMultilineTokensBuilder;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const IBackgroundTokenizer = @import("../languages.zig").IBackgroundTokenizer;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;

const ManualTokenizationSupport = struct {
    interface: *ITokenizationSupport,
    allocator: Allocator,
    tokens: AutoHashMap(usize, []u32),
    stores: Set(IBackgroundTokenizationStore),

    pub fn init(allocator: Allocator) ManualTokenizationSupport {
        return ManualTokenizationSupport{
            .interface = &.{
                .vtable = &.{
                    .getInitialState = getInitialState,
                    .tokenize = tokenize,
                    .tokenizeEncoded = tokenizeEncoded,
                    .createBackgroundTokenizer = createBackgroundTokenizer,
                },
            },
            .allocator = allocator,
            .tokens = AutoHashMap(usize, []u32).init(allocator),
            .stores = Set(IBackgroundTokenizationStore).init(allocator),
        };
    }

    pub fn setLineTokens(self: *ManualTokenizationSupport, lineNumber: usize, tokens: []u32) void {
        const b = ContiguousMultilineTokensBuilder.init(self.allocator);
        b.add(lineNumber, tokens);
        for (self.stores.items) |s| {
            s.setTokens(b.finalize());
        }
    }

    pub fn getInitialState(_: *ITokenizationSupport) !IState {
        return .init(LineState, &.{ .lineNumber = 1 });
    }

    pub fn tokenize(self: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !TokenizationResult {
        _ = self;
        _ = line;
        _ = hasEOL;
        _ = state;
        return error.NotImplemented;
    }

    pub fn tokenizeEncoded(t: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !EncodedTokenizationResult {
        const self = getSelf(t);
        const allocator = self.allocator;
        _ = line;
        _ = hasEOL;
        const s = state.getPtr(LineState);

        var nextState = try allocator.create(LineState);
        nextState.lineNumber = s.lineNumber + 1;
        const endState = IState.init(LineState, nextState);

        return EncodedTokenizationResult.init(self.tokens.get(s.lineNumber).?, &[_]TokenPacked{}, endState);
    }

    // Can be/return undefined if default background tokenization should be used.
    pub fn createBackgroundTokenizer(t: *ITokenizationSupport, textModel: *TextModel, store: IBackgroundTokenizationStore) !?IBackgroundTokenizer {
        _ = textModel;
        try getSelf(t).stores.add(store);
        return null;
    }

    fn getSelf(s: *ITokenizationSupport) *ManualTokenizationSupport {
        return @alignCast(@fieldParentPtr("interface", s));
    }
};

const LineState = struct {
    lineNumber: usize,

    pub fn init(lineNumber: usize) LineState {
        return LineState{
            .lineNumber = lineNumber,
        };
    }
};

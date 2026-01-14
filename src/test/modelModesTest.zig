const std = @import("std");
const Allocator = std.mem.Allocator;
const IState = @import("../languages.zig").IState;
const TokenizationResult = @import("../languages.zig").TokenizationResult;
const nullState = @import("../languages/nullTokenize.zig").nullState;
const ArrayList = std.array_list.Managed;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const IBackgroundTokenizationStore = @import("../languages.zig").IBackgroundTokenizationStore;
const IBackgroundTokenizer = @import("../languages.zig").IBackgroundTokenizer;
const createTextModel = @import("../textModel/testTextModel.zig").createTextModel;
const disposeTextModel = @import("../textModel/testTextModel.zig").disposeTextModel;
const TokenizationRegistry = @import("../tokenize/tokenizationRegistry.zig").TokenizationRegistry;

const ModelModes1Tests = struct {
    const allocator = std.testing.allocator;
    var callFor: ArrayList(u8) = ArrayList(u8).init(allocator);

    fn getAndClear() ![]const u8 {
        const result = try callFor.toOwnedSlice();
        callFor.clearAndFree();
        return result;
    }

    const TokenizationSupport = struct {
        fn init() ITokenizationSupport {
            return .{
                .vtable = &.{
                    .getInitialState = getInitialState,
                    .tokenize = tokenize,
                    .tokenizeEncoded = tokenizeEncoded,
                    .createBackgroundTokenizer = null,
                    .destroy = destroy,
                },
            };
        }

        fn getInitialState(_: *ITokenizationSupport) !IState {
            return nullState;
        }

        fn tokenize(_: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !TokenizationResult {
            _ = line;
            _ = hasEOL;
            _ = state;
            return error.NotImplemented;
        }

        fn tokenizeEncoded(_: *ITokenizationSupport, line: []const u8, hasEOL: bool, state: IState) !EncodedTokenizationResult {
            _ = hasEOL;
            try callFor.append(line[0]);
            return EncodedTokenizationResult.init(&[_]TokenPacked{}, state);
        }

        fn destroy(self: *ITokenizationSupport, _allocator: Allocator) void {
            _allocator.destroy(self);
        }
    };

    fn setup() !*TextModel {
        const text = "1\r\n" ++
            "2\n" ++
            "3\n" ++
            "4\r\n" ++
            "5";
        const languageId = "modelModeTest1";
        callFor.clearAndFree();
        const tokenizationSupport = try allocator.create(ITokenizationSupport);
        tokenizationSupport.* = TokenizationSupport.init();
        try TokenizationRegistry.instance(allocator).register(languageId, tokenizationSupport);
        return try createTextModel(allocator, text, languageId, null);
    }

    fn teardown(textModel: *TextModel) void {
        callFor.clearAndFree();
        disposeTextModel(textModel);
    }

    test "model calls syntax highlighter 1" {
        const thisModel = try setup();
        defer teardown(thisModel);
        try thisModel.tokenization().forceTokenization(1);
        const result = try getAndClear();
        defer allocator.free(result);
        try std.testing.expectEqualDeep(&[_]u8{'1'}, result);
    }
};

test "Editor Model" {
    _ = ModelModes1Tests;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const IdentifiedSingleEditOperation = @import("../textModel/model.zig").IdentifiedSingleEditOperation;
const EditOperation = @import("../textModel/model.zig").EditOperation;
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

    fn assertResult(expected: []const u8) !void {
        const result = try getAndClear();
        defer allocator.free(result);
        try std.testing.expectEqualDeep(expected, result);
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
        try assertResult(&[_]u8{'1'});
    }

    test "model calls syntax highlighter 2" {
        const thisModel = try setup();
        defer teardown(thisModel);
        try thisModel.tokenization().forceTokenization(2);
        try assertResult(&[_]u8{ '1', '2' });

        try thisModel.tokenization().forceTokenization(2);
        try assertResult(&[_]u8{});
    }

    test "model caches states" {
        const thisModel = try setup();
        defer teardown(thisModel);

        try thisModel.tokenization().forceTokenization(1);
        try assertResult(&[_]u8{'1'});

        try thisModel.tokenization().forceTokenization(2);
        try assertResult(&[_]u8{'2'});

        try thisModel.tokenization().forceTokenization(3);
        try assertResult(&[_]u8{'3'});

        try thisModel.tokenization().forceTokenization(4);
        try assertResult(&[_]u8{'4'});

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{'5'});

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{});
    }

    test "model invalidates states for one line insert" {
        const thisModel = try setup();
        defer teardown(thisModel);

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{ '1', '2', '3', '4', '5' });

        _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = .init(1, 1, 1, 1),
            .text = .initBorrowed("-"),
        }}, null);
        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{'-'});

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{});
    }

    test "model invalidates states for many lines insert" {
        const thisModel = try setup();
        defer teardown(thisModel);

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{ '1', '2', '3', '4', '5' });

        _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = .init(1, 1, 1, 1),
            .text = .initBorrowed("0\n-\n+"),
        }}, null);
        try std.testing.expectEqual(7, thisModel.getLineCount());
        try thisModel.tokenization().forceTokenization(7);
        try assertResult(&[_]u8{ '0', '-', '+' });

        try thisModel.tokenization().forceTokenization(7);
        try assertResult(&[_]u8{});
    }

    test "model invalidates states for one new line" {
        const thisModel = try setup();
        defer teardown(thisModel);

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{ '1', '2', '3', '4', '5' });

        _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = .init(1, 2, 1, 2),
            .text = .initBorrowed("\n"),
        }}, null);
        _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = .init(2, 1, 2, 1),
            .text = .initBorrowed("a"),
        }}, null);
        try thisModel.tokenization().forceTokenization(6);
        try assertResult(&[_]u8{ '1', 'a' });
    }

    test "model invalidates states for one line delete" {
        const thisModel = try setup();
        defer teardown(thisModel);

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{ '1', '2', '3', '4', '5' });

        _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = .init(1, 2, 1, 2),
            .text = .initBorrowed("-"),
        }}, null);
        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{'1'});

        _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = .init(1, 1, 1, 2),
        }}, null);
        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{'-'});

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{});
    }

    test "model invalidates states for many lines delete" {
        const thisModel = try setup();
        defer teardown(thisModel);

        try thisModel.tokenization().forceTokenization(5);
        try assertResult(&[_]u8{ '1', '2', '3', '4', '5' });

        _ = try thisModel.applyEdits(&[_]IdentifiedSingleEditOperation{.{
            .range = .init(1, 1, 3, 1),
        }}, null);
        try thisModel.tokenization().forceTokenization(3);
        try assertResult(&[_]u8{'3'});

        try thisModel.tokenization().forceTokenization(3);
        try assertResult(&[_]u8{});
    }
};

test "Editor Model" {
    _ = ModelModes1Tests;
}

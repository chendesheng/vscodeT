// Port of
// `src/vs/editor/test/common/model/bracketPairColorizer/getBracketPairsInRange.test.ts`.
//
// Marker characters ¹/² are stripped from the source and their byte offsets
// become the query range, like upstream's AnnotatedDocument.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TestModel = @import("../../port/testSupport.zig").TestModel;
const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const ITokenizationSupport = @import("../../../../common/languages.zig").ITokenizationSupport;
const IState = @import("../../../../common/languages.zig").IState;
const EncodedTokenizationResult = @import("../../../../common/languages.zig").EncodedTokenizationResult;
const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const LanguageConfiguration = @import("../../../../common/languages/languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../../../../common/languages/languageConfiguration.zig").CharacterPair;
const Range = @import("../../../../common/core/range.zig").Range;
const BracketPairInfo = @import("../../../../common/model/bracketPairsTextModelPart/bracketPairsImpl.zig").BracketPairInfo;

const language_id = "getBracketPairsLanguage";

const Support = struct {
    fn getInitialState(_: *anyopaque, _: Allocator) anyerror!IState {
        return NullState;
    }

    fn tokenizeEncoded(_: *anyopaque, allocator: Allocator, line: []const u8, _: bool, state: IState) anyerror!EncodedTokenizationResult {
        const tokens = try allocator.alloc(TokenPacked, 1);
        var metadata = TokenMetadata.default;
        metadata.balancedBrackets = true;
        tokens[0] = .{ .endOffset = @intCast(line.len), .metadata = metadata };
        return .{ .tokens = tokens, .endState = state };
    }

    fn interface(self: *Support) ITokenizationSupport {
        return .{ .context = self, .vtable = &.{
            .getInitialState = getInitialState,
            .tokenizeEncoded = tokenizeEncoded,
        } };
    }
};

const Annotated = struct {
    text: []u8,
    first: usize,
    second: usize,
};

fn parseAnnotated(allocator: Allocator, src: []const u8) !Annotated {
    var text = ArrayList(u8).init(allocator);
    errdefer text.deinit();
    var first: ?usize = null;
    var second: ?usize = null;
    var i: usize = 0;
    while (i < src.len) {
        if (i + 1 < src.len and src[i] == 0xC2) {
            if (src[i + 1] == 0xB9) {
                first = text.items.len;
                i += 2;
                continue;
            }
            if (src[i + 1] == 0xB2) {
                second = text.items.len;
                i += 2;
                continue;
            }
        }
        try text.append(src[i]);
        i += 1;
    }
    return .{ .text = try text.toOwnedSlice(), .first = first.?, .second = second.? };
}

const Fixture = struct {
    support: Support = .{},
    model: TestModel,
    annotated: Annotated,

    fn init(allocator: Allocator, src: []const u8) !Fixture {
        const annotated = try parseAnnotated(allocator, src);
        errdefer allocator.free(annotated.text);
        const support = ITokenizationSupport{ .context = undefined, .vtable = &.{
            .getInitialState = Support.getInitialState,
            .tokenizeEncoded = Support.tokenizeEncoded,
        } };
        try TokenizationRegistry.instance.register(language_id, support);
        errdefer TokenizationRegistry.instance.unregister(language_id);
        var ctx = try TestModel.init(allocator, annotated.text, language_id);
        errdefer {
            allocator.free(annotated.text);
            ctx.deinit();
        }
        var brackets = [_]CharacterPair{.{ "<", ">" }};
        var colorized = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" }, .{ "(", ")" } };
        var config = @import("../../../../common/languages/languageConfiguration.zig").empty();
        config.brackets = &brackets;
        config.colorizedBracketPairs = &colorized;
        try ctx.languageService.registerLanguageConfiguration(language_id, config);
        ctx.model.forceTokenization(1);
        try ctx.model.bracketPairs().updateNow();
        return .{ .model = ctx, .annotated = annotated };
    }

    fn deinit(self: *Fixture) void {
        TokenizationRegistry.instance.unregister(language_id);
        self.model.deinit();
        self.model.allocator.free(self.annotated.text);
    }

    fn queryRange(self: *Fixture) Range {
        const start = self.model.model.getPositionAt(self.annotated.first);
        const end = self.model.model.getPositionAt(self.annotated.second);
        return Range.init(start.lineNumber, start.column, end.lineNumber, end.column);
    }
};

const ExpectedPair = struct {
    level: usize,
    range: Range,
    open: Range,
    close: ?Range,
};

fn expectPairs(pairs: []const BracketPairInfo, expected: []const ExpectedPair) !void {
    try std.testing.expectEqual(expected.len, pairs.len);
    for (expected, pairs) |want, got| {
        try std.testing.expectEqual(want.level, got.nestingLevel);
        try std.testing.expectEqualDeep(want.range, got.range);
        try std.testing.expectEqualDeep(want.open, got.openingBracketRange);
        if (want.close) |close| {
            try std.testing.expect(got.closingBracketRange != null);
            try std.testing.expectEqualDeep(close, got.closingBracketRange.?);
        } else {
            try std.testing.expect(got.closingBracketRange == null);
        }
    }
}

test "getBracketPairsInRange: Basic 1" {
    var fixture = try Fixture.init(std.testing.allocator, "{ ( [] ¹ ) [ ² { } ] () } []");
    defer fixture.deinit();

    var pairs = try fixture.model.model.getBracketPairsInRange(fixture.queryRange());
    defer pairs.deinit();
    try expectPairs(pairs.items, &.{
        .{ .level = 0, .range = Range.init(1, 1, 1, 24), .open = Range.init(1, 1, 1, 2), .close = Range.init(1, 23, 1, 24) },
        .{ .level = 1, .range = Range.init(1, 3, 1, 10), .open = Range.init(1, 3, 1, 4), .close = Range.init(1, 9, 1, 10) },
        .{ .level = 1, .range = Range.init(1, 11, 1, 19), .open = Range.init(1, 11, 1, 12), .close = Range.init(1, 18, 1, 19) },
    });
}

test "getBracketPairsInRange: Basic 2" {
    var fixture = try Fixture.init(std.testing.allocator, "{ ( [] ¹ ²) [  { } ] () } []");
    defer fixture.deinit();

    var pairs = try fixture.model.model.getBracketPairsInRange(fixture.queryRange());
    defer pairs.deinit();
    try expectPairs(pairs.items, &.{
        .{ .level = 0, .range = Range.init(1, 1, 1, 24), .open = Range.init(1, 1, 1, 2), .close = Range.init(1, 23, 1, 24) },
        .{ .level = 1, .range = Range.init(1, 3, 1, 10), .open = Range.init(1, 3, 1, 4), .close = Range.init(1, 9, 1, 10) },
    });
}

test "getBracketPairsInRange: Basic Empty" {
    var fixture = try Fixture.init(std.testing.allocator, "¹ ² { ( [] ) [  { } ] () } []");
    defer fixture.deinit();

    var pairs = try fixture.model.model.getBracketPairsInRange(fixture.queryRange());
    defer pairs.deinit();
    try std.testing.expectEqual(@as(usize, 0), pairs.items.len);
}

test "getBracketPairsInRange: Basic All" {
    var fixture = try Fixture.init(std.testing.allocator, "¹ { ( [] ) [  { } ] () } [] ²");
    defer fixture.deinit();

    var pairs = try fixture.model.model.getBracketPairsInRange(fixture.queryRange());
    defer pairs.deinit();
    try expectPairs(pairs.items, &.{
        .{ .level = 0, .range = Range.init(1, 2, 1, 24), .open = Range.init(1, 2, 1, 3), .close = Range.init(1, 23, 1, 24) },
        .{ .level = 1, .range = Range.init(1, 4, 1, 10), .open = Range.init(1, 4, 1, 5), .close = Range.init(1, 9, 1, 10) },
        .{ .level = 2, .range = Range.init(1, 6, 1, 8), .open = Range.init(1, 6, 1, 7), .close = Range.init(1, 7, 1, 8) },
        .{ .level = 1, .range = Range.init(1, 11, 1, 19), .open = Range.init(1, 11, 1, 12), .close = Range.init(1, 18, 1, 19) },
        .{ .level = 2, .range = Range.init(1, 14, 1, 17), .open = Range.init(1, 14, 1, 15), .close = Range.init(1, 16, 1, 17) },
        .{ .level = 1, .range = Range.init(1, 20, 1, 22), .open = Range.init(1, 20, 1, 21), .close = Range.init(1, 21, 1, 22) },
        .{ .level = 0, .range = Range.init(1, 25, 1, 27), .open = Range.init(1, 25, 1, 26), .close = Range.init(1, 26, 1, 27) },
    });
}

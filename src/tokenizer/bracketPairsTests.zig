const std = @import("std");
const ArrayList = std.array_list.Managed;
const TestModel = @import("testSupport.zig").TestModel;
const TokenizationRegistry = @import("../tokenize/tokenizationRegistry.zig").TokenizationRegistry;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const IState = @import("../languages.zig").IState;
const EncodedTokenizationResult = @import("../languages.zig").EncodedTokenizationResult;
const NullState = @import("../nullTokenize.zig").NullState;
const TokenPacked = @import("../tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const LanguageConfiguration = @import("../languages/languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../languages/languageConfiguration.zig").CharacterPair;
const Range = @import("../basics/range.zig").Range;
const Position = @import("../basics/position.zig").Position;
const ModelDecoration = @import("../model.zig").ModelDecoration;

const BracketSupport = struct {
    fn getInitialState(_: *anyopaque, _: std.mem.Allocator) anyerror!IState {
        return NullState;
    }

    fn tokenizeEncoded(_: *anyopaque, allocator: std.mem.Allocator, line: []const u8, hasEOL: bool, state: IState) anyerror!EncodedTokenizationResult {
        _ = hasEOL;
        var tokens = ArrayList(TokenPacked).init(allocator);
        errdefer tokens.deinit();
        var start: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '"' or line[i] == '\'') {
                const quote = line[i];
                if (i > start) try appendToken(&tokens, line[start..i], .Other);
                var end = i + 1;
                while (end < line.len and line[end] != quote) end += 1;
                if (end < line.len) end += 1;
                try appendToken(&tokens, line[i..end], .String);
                i = end;
                start = end;
            } else {
                i += 1;
            }
        }
        if (start < line.len) try appendToken(&tokens, line[start..], .Other);
        return .{ .tokens = try tokens.toOwnedSlice(), .endState = state };
    }

    fn interface(self: *BracketSupport) ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

fn appendToken(tokens: *ArrayList(TokenPacked), text: []const u8, tokenType: StandardTokenType) !void {
    var metadata = TokenMetadata.default;
    metadata.tokenType = tokenType;
    metadata.balancedBrackets = true;
    try tokens.append(.{ .endOffset = @intCast((if (tokens.items.len > 0) tokens.items[tokens.items.len - 1].endOffset else 0) + text.len), .metadata = metadata });
}

const languageId = "bracketTestLanguage";

const Fixture = struct {
    ctx: TestModel,
    support: *BracketSupport,

    fn init(allocator: std.mem.Allocator, text: []const u8, config: ?LanguageConfiguration) !Fixture {
        const support = try allocator.create(BracketSupport);
        support.* = .{};
        errdefer allocator.destroy(support);
        try TokenizationRegistry.instance.register(languageId, support.interface());
        errdefer TokenizationRegistry.instance.unregister(languageId);
        var ctx = try TestModel.init(allocator, text, languageId);
        errdefer ctx.deinit();
        if (config) |c| try ctx.languageService.registerLanguageConfiguration(languageId, c);
        return .{ .ctx = ctx, .support = support };
    }

    fn deinit(self: *Fixture) void {
        TokenizationRegistry.instance.unregister(languageId);
        self.ctx.deinit();
        self.ctx.allocator.destroy(self.support);
    }
};

fn makeConfig(brackets: []CharacterPair, colorized: ?[]CharacterPair) LanguageConfiguration {
    var config = @import("../languages/languageConfiguration.zig").empty();
    config.brackets = brackets;
    config.colorizedBracketPairs = colorized;
    return config;
}

fn bracketClasses(allocator: std.mem.Allocator, model: *@import("../textModel.zig").TextModel) !ArrayList([]const u8) {
    const decorations = try model.getDecorationsInRange(model.getFullModelRange(), 0, false, false, false);
    defer allocator.free(decorations);
    var classes = ArrayList([]const u8).init(allocator);
    errdefer classes.deinit();
    for (decorations) |decoration| {
        if (decoration.options.inlineClassName) |name| {
            if (std.mem.startsWith(u8, name, "bracket-highlighting-") or std.mem.eql(u8, name, "unexpected-closing-bracket")) {
                try classes.append(name);
            }
        }
    }
    return classes;
}

test "bracket pairs: basic pairs and nesting levels" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{
        .{ "{", "}" }, .{ "[", "]" }, .{ "(", ")" }, .{ "<", ">" },
    };
    var colorized = [_]CharacterPair{
        .{ "{", "}" }, .{ "[", "]" }, .{ "(", ")" },
    };
    var fixture = try Fixture.init(allocator, "{ ( [] ) [ { } ] () } []", makeConfig(&brackets, &colorized));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    var pairs = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer pairs.deinit();
    try std.testing.expectEqual(7, pairs.items.len);

    const expectedStarts = [_]usize{ 1, 3, 5, 10, 12, 18, 23 };
    const expectedLevels = [_]usize{ 0, 1, 2, 1, 2, 1, 0 };
    for (pairs.items, 0..) |pair, i| {
        try std.testing.expectEqual(expectedStarts[i], pair.openingBracketRange.startColumn);
        try std.testing.expectEqual(expectedLevels[i], pair.nestingLevel);
    }
    try std.testing.expectEqualStrings("{", pairs.items[0].openingBracket);
    try std.testing.expectEqualStrings("}", pairs.items[0].closingBracket.?);
    try std.testing.expect(pairs.items[6].range.endColumn == 25);
}

test "bracket pairs: colorization decorations" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" } };
    var fixture = try Fixture.init(allocator, "{ [ ] }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    var classes = try bracketClasses(allocator, fixture.ctx.model);
    defer classes.deinit();
    try std.testing.expectEqual(4, classes.items.len);
    try std.testing.expectEqualStrings("bracket-highlighting-0", classes.items[0]);
    try std.testing.expectEqualStrings("bracket-highlighting-1", classes.items[1]);
    try std.testing.expectEqualStrings("bracket-highlighting-1", classes.items[2]);
    try std.testing.expectEqualStrings("bracket-highlighting-0", classes.items[3]);
}

test "bracket pairs: angle brackets are parsed but not colorized by default" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "<", ">" }};
    var fixture = try Fixture.init(allocator, "< >", makeConfig(&brackets, null));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    var all = try fixture.ctx.model.getBracketsInRange(fixture.ctx.model.getFullModelRange(), false);
    defer all.deinit();
    try std.testing.expectEqual(2, all.items.len);

    var colorized = try fixture.ctx.model.getBracketsInRange(fixture.ctx.model.getFullModelRange(), true);
    defer colorized.deinit();
    try std.testing.expectEqual(0, colorized.items.len);

    var classes = try bracketClasses(allocator, fixture.ctx.model);
    defer classes.deinit();
    try std.testing.expectEqual(0, classes.items.len);
}

test "bracket pairs: strings are ignored and unmatched closings are invalid" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "\"}\"\n}", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(2);

    var bracketsInRange = try fixture.ctx.model.getBracketsInRange(fixture.ctx.model.getFullModelRange(), true);
    defer bracketsInRange.deinit();
    try std.testing.expectEqual(1, bracketsInRange.items.len);
    try std.testing.expect(bracketsInRange.items[0].isInvalid);
    try std.testing.expectEqual(2, bracketsInRange.items[0].range.startLineNumber);

    var classes = try bracketClasses(allocator, fixture.ctx.model);
    defer classes.deinit();
    try std.testing.expectEqual(1, classes.items.len);
    try std.testing.expectEqualStrings("unexpected-closing-bracket", classes.items[0]);

    try std.testing.expect(fixture.ctx.model.hasUnmatchedClosingBracketAfter(Position.init(1, 1), "{"));
    try std.testing.expect(!fixture.ctx.model.hasUnmatchedClosingBracketAfter(Position.init(2, 2), "{"));
}

test "bracket pairs: multi-character brackets" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "begin", "end" }};
    var fixture = try Fixture.init(allocator, "begin x end", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    var pairs = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer pairs.deinit();
    try std.testing.expectEqual(1, pairs.items.len);
    try std.testing.expectEqualStrings("begin", pairs.items[0].openingBracket);
    try std.testing.expectEqualStrings("end", pairs.items[0].closingBracket.?);
    try std.testing.expectEqual(1, pairs.items[0].openingBracketRange.startColumn);
    try std.testing.expectEqual(9, pairs.items[0].closingBracketRange.?.startColumn);
}

test "bracket pairs: decorations can be disabled" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "{ }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    var classes = try bracketClasses(allocator, fixture.ctx.model);
    defer classes.deinit();
    try std.testing.expectEqual(2, classes.items.len);

    fixture.ctx.model.updateOptions(.{
        .tabSize = null,
        .indentSize = null,
        .insertSpaces = null,
        .trimAutoWhitespace = null,
        .bracketColorizationOptions = .{
            .enabled = false,
            .independentColorPoolPerBracketType = false,
        },
    });
    var disabled = try bracketClasses(allocator, fixture.ctx.model);
    defer disabled.deinit();
    try std.testing.expectEqual(0, disabled.items.len);
}

test "bracket pairs: independent color pool uses equal bracket type level" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "(", ")" } };
    var fixture = try Fixture.init(allocator, "{ ( { } ) }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.updateOptions(.{
        .tabSize = null,
        .indentSize = null,
        .insertSpaces = null,
        .trimAutoWhitespace = null,
        .bracketColorizationOptions = .{
            .enabled = true,
            .independentColorPoolPerBracketType = true,
        },
    });
    fixture.ctx.model.forceTokenization(1);

    var classes = try bracketClasses(allocator, fixture.ctx.model);
    defer classes.deinit();
    try std.testing.expectEqual(6, classes.items.len);
    // The inner `{` is the second `{` at the same bracket type, so it gets level 1,
    // even though it is the third bracket pair in the document.
    try std.testing.expectEqualStrings("bracket-highlighting-1", classes.items[2]);
}

test "bracket pairs: unmatched closing query waits for tokenization" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "\"}\"\n}", makeConfig(&brackets, &brackets));
    defer fixture.deinit();

    var all = try fixture.ctx.model.getBracketsInRange(fixture.ctx.model.getFullModelRange(), true);
    all.deinit();
    try std.testing.expect(!fixture.ctx.model.hasUnmatchedClosingBracketAfter(Position.init(1, 1), "{"));

    fixture.ctx.model.forceTokenization(2);
    try std.testing.expect(fixture.ctx.model.hasUnmatchedClosingBracketAfter(Position.init(1, 1), "{"));

    try fixture.ctx.applyEdit(Range.init(1, 1, 1, 1), "x");
    try std.testing.expect(!fixture.ctx.model.hasUnmatchedClosingBracketAfter(Position.init(1, 1), "{"));
}

test "bracket pairs: bracket navigation" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" } };
    var fixture = try Fixture.init(allocator, "{ [ ] }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    const matched = fixture.ctx.model.bracketPairs().matchBracket(Position.init(1, 3), null);
    try std.testing.expect(matched != null);
    try std.testing.expectEqual(3, matched.?[0].startColumn);
    try std.testing.expectEqual(5, matched.?[1].startColumn);

    const enclosing = fixture.ctx.model.bracketPairs().findEnclosingBrackets(Position.init(1, 4), null);
    try std.testing.expect(enclosing != null);
    try std.testing.expectEqual(3, enclosing.?[0].startColumn);

    const previous = fixture.ctx.model.bracketPairs().findPrevBracket(Position.init(1, 4));
    try std.testing.expect(previous != null);
    try std.testing.expectEqualStrings("[", previous.?.bracketText);

    const next = fixture.ctx.model.bracketPairs().findNextBracket(Position.init(1, 2));
    try std.testing.expect(next != null);
    try std.testing.expectEqualStrings("[", next.?.bracketText);

    const matchingUp = fixture.ctx.model.bracketPairs().findMatchingBracketUp("]", Position.init(1, 5), null);
    try std.testing.expect(matchingUp != null);
    try std.testing.expectEqual(3, matchingUp.?.startColumn);
}

test "bracket pairs: range query returns enclosing pairs" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "(", ")" } };
    var fixture = try Fixture.init(allocator, "{ ( ) }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    var pairs = try fixture.ctx.model.getBracketPairsInRange(Range.init(1, 3, 1, 4));
    defer pairs.deinit();
    try std.testing.expectEqual(2, pairs.items.len);
    try std.testing.expectEqual(1, pairs.items[0].openingBracketRange.startColumn);
    try std.testing.expectEqual(3, pairs.items[1].openingBracketRange.startColumn);
}

test "bracket pairs: model edits reuse incremental AST" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" } };
    var fixture = try Fixture.init(allocator, "{[]}", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    var first = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer first.deinit();
    try std.testing.expectEqual(2, first.items.len);

    try fixture.ctx.applyEdit(Range.init(1, 5, 1, 5), "x");

    var second = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer second.deinit();
    try std.testing.expectEqual(2, second.items.len);
    try std.testing.expectEqual(5, second.items[0].closingBracketRange.?.endColumn);

    try fixture.ctx.applyEdit(Range.init(1, 5, 1, 5), "y");
    var combined = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer combined.deinit();
    try std.testing.expectEqual(2, combined.items.len);

    try fixture.ctx.applyEdit(Range.init(1, 2, 1, 4), "");
    var third = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer third.deinit();
    try std.testing.expectEqual(1, third.items.len);
}

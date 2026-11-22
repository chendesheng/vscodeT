const std = @import("std");
const ArrayList = std.array_list.Managed;
const TestModel = @import("../../port/testSupport.zig").TestModel;
const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const ITokenizationSupport = @import("../../../../common/languages.zig").ITokenizationSupport;
const IState = @import("../../../../common/languages.zig").IState;
const EncodedTokenizationResult = @import("../../../../common/languages.zig").EncodedTokenizationResult;
const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../../../../common/encodedTokenAttributes.zig").StandardTokenType;
const LanguageConfiguration = @import("../../../../common/languages/languageConfiguration.zig").LanguageConfiguration;
const CharacterPair = @import("../../../../common/languages/languageConfiguration.zig").CharacterPair;
const Range = @import("../../../../common/core/range.zig").Range;
const Position = @import("../../../../common/core/position.zig").Position;
const ModelDecoration = @import("../../../../common/model.zig").ModelDecoration;

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
    var config = @import("../../../../common/languages/languageConfiguration.zig").empty();
    config.brackets = brackets;
    config.colorizedBracketPairs = colorized;
    return config;
}

fn bracketClasses(allocator: std.mem.Allocator, model: *@import("../../../../common/model/textModel.zig").TextModel) !ArrayList([]const u8) {
    // The provider only reads an up-to-date AST; the view normally prepares
    // it before resolving decorations.
    try model.bracketPairs().updateNow();
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

test "bracket pairs: colorization decorations ignore the decoration owner" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "{ }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);
    try fixture.ctx.model.bracketPairs().updateNow();

    const decorations = try fixture.ctx.model.getDecorationsInRange(
        fixture.ctx.model.getFullModelRange(),
        42,
        false,
        false,
        false,
    );
    defer allocator.free(decorations);
    var count: usize = 0;
    for (decorations) |decoration| {
        if (decoration.options.inlineClassName) |name| {
            if (std.mem.startsWith(u8, name, "bracket-highlighting-")) count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "bracket pairs: tokenization completion replaces the fast initial tree" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var text = ArrayList(u8).init(allocator);
    defer text.deinit();
    // 501 lines: a brace inside a string, then a real pair spanning the
    // document. Above 500 lines the first tree is the fast, token-agnostic one.
    try text.appendSlice("\"{\"\n{\n");
    for (0..498) |_| try text.appendSlice("x\n");
    try text.appendSlice("}\n");
    var fixture = try Fixture.init(allocator, text.items, makeConfig(&brackets, &brackets));
    defer fixture.deinit();

    var fast = try bracketClasses(allocator, fixture.ctx.model);
    defer fast.deinit();
    // The fast tokenizer does not know the first brace is inside a string.
    try std.testing.expectEqual(@as(usize, 3), fast.items.len);

    // Tokenizing every line completes background tokenization, which rebuilds
    // the tree token-aware and invalidates the colorization decorations.
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    var token_aware = try bracketClasses(allocator, fixture.ctx.model);
    defer token_aware.deinit();
    try std.testing.expectEqual(@as(usize, 2), token_aware.items.len);
    try std.testing.expectEqualStrings("bracket-highlighting-0", token_aware.items[0]);
    try std.testing.expectEqualStrings("bracket-highlighting-0", token_aware.items[1]);
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

    // The query must not act on lines whose tokens are still unknown. (Small
    // documents are eagerly tokenized when the AST is built, so query before
    // building it here.)
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

test "bracket pairs: cached ranges follow edits before them" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" } };
    var fixture = try Fixture.init(allocator, "{\n}\nplain\n[ ]", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    var first = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.items.len);
    try std.testing.expectEqual(@as(usize, 1), first.items[1].openingBracketRange.startColumn);

    // Insert a line before it; the `[ ]` pair moves from line 4 to line 5.
    try fixture.ctx.applyEdit(Range.init(3, 1, 3, 1), "\n");
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    var second = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 2), second.items.len);
    try std.testing.expectEqual(@as(usize, 5), second.items[1].openingBracketRange.startLineNumber);
    try std.testing.expectEqual(@as(usize, 1), second.items[1].openingBracketRange.startColumn);
    try std.testing.expectEqual(@as(usize, 5), second.items[1].closingBracketRange.?.startLineNumber);
}

test "bracket pairs: min indentation query" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "{\n    a\n        b\n}", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    var pairs = try fixture.ctx.model.getBracketPairsInRangeWithMinIndentation(fixture.ctx.model.getFullModelRange());
    defer pairs.deinit();
    try std.testing.expectEqual(@as(usize, 1), pairs.items.len);
    // Upstream's text-node calculation includes the closing-bracket line, so
    // the unindented `}` contributes visible column 0.
    try std.testing.expectEqual(@as(i64, 0), pairs.items[0].minVisibleColumnIndentation);
    try std.testing.expectEqual(@as(usize, 1), pairs.items[0].pair.range.startLineNumber);
    try std.testing.expectEqual(@as(usize, 4), pairs.items[0].pair.range.endLineNumber);
}

test "bracket pairs: guides carry class names and wrapping columns" {
    const allocator = std.testing.allocator;
    const GuidesTextModelPart = @import("../../../../common/model/guidesTextModelPart.zig").GuidesTextModelPart;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "fn main() {\n    x\n}", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    var guides = GuidesTextModelPart.init(fixture.ctx.model, fixture.ctx.languageService);
    defer guides.dispose();
    const lines = try guides.getLinesBracketGuides(
        allocator,
        1,
        3,
        null,
        .{ .includeInactive = true, .horizontalGuides = .Disabled, .highlightActive = false },
    );
    defer {
        for (lines) |*line| line.deinit();
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    // The pair starts at column 11 and ends at column 1; the closing line
    // contributes visible column 0, so the guide sits at visible column 1.
    // Without horizontal guides the closing line has no vertical segment.
    try std.testing.expectEqual(@as(usize, 1), lines[0].items.len);
    try std.testing.expectEqual(@as(usize, 1), lines[1].items.len);
    try std.testing.expectEqual(@as(usize, 0), lines[2].items.len);
    for (lines[0..2]) |line| {
        const guide = line.items[0];
        try std.testing.expectEqual(@as(isize, 1), guide.visibleColumn);
        try std.testing.expectEqual(@as(isize, -1), guide.column);
        try std.testing.expectEqualStrings("bracket-indent-guide lvl-0", guide.className);
        try std.testing.expect(guide.horizontalLine == null);
    }
    try std.testing.expectEqual(@as(isize, 11), lines[0].items[0].forWrappedLinesAfterColumn);
    try std.testing.expectEqual(@as(isize, -1), lines[1].items[0].forWrappedLinesAfterColumn);
}

test "bracket pairs: text before the closing bracket keeps the closing guide line" {
    const allocator = std.testing.allocator;
    const GuidesTextModelPart = @import("../../../../common/model/guidesTextModelPart.zig").GuidesTextModelPart;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "fn main() {\n    x\n    y }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    var pairs = try fixture.ctx.model.getBracketPairsInRangeWithMinIndentation(fixture.ctx.model.getFullModelRange());
    defer pairs.deinit();
    try std.testing.expectEqual(@as(i64, 4), pairs.items[0].minVisibleColumnIndentation);

    var guides = GuidesTextModelPart.init(fixture.ctx.model, fixture.ctx.languageService);
    defer guides.dispose();
    const lines = try guides.getLinesBracketGuides(
        allocator,
        1,
        3,
        null,
        .{ .includeInactive = true, .horizontalGuides = .Disabled, .highlightActive = false },
    );
    defer {
        for (lines) |*line| line.deinit();
        allocator.free(lines);
    }
    // Text before the closing bracket makes upstream render the horizontal
    // end line at the bottom, so the vertical guide also covers line 3.
    try std.testing.expectEqual(@as(usize, 1), lines[2].items.len);
    const closing_guide = lines[2].items[0];
    try std.testing.expectEqual(@as(isize, 5), closing_guide.visibleColumn);
    try std.testing.expectEqual(@as(isize, 7), closing_guide.forWrappedLinesBeforeOrAtColumn);
}

test "bracket pairs: guide view merges indentation and bracket guides" {
    const allocator = std.testing.allocator;
    const indent_guides = @import("../../../../browser/viewParts/indentGuides/indentGuides.zig");
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "root\n    if (x) {\n        y\n    }", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    var guides_part = @import("../../../../common/model/guidesTextModelPart.zig").GuidesTextModelPart.init(
        fixture.ctx.model,
        fixture.ctx.languageService,
    );
    defer guides_part.dispose();

    const lines = try indent_guides.getGuidesByLine(
        allocator,
        fixture.ctx.model,
        &guides_part,
        1,
        fixture.ctx.model.getLineCount(),
        Position.init(2, 1),
        .{
            .include_inactive_bracket_pairs = true,
            .horizontal_guides = .Disabled,
            .highlight_active_bracket_pair = true,
            .highlight_active_indentation = .enabled,
        },
    );
    defer {
        for (lines) |*line| line.deinit();
        allocator.free(lines);
    }

    // Line 2 has a level-1 indent guide and the bracket guide for `{ }`.
    try std.testing.expectEqual(@as(usize, 2), lines[1].items.len);
    try std.testing.expectEqualStrings("core-guide-indent lvl-0", lines[1].items[0].className);
    try std.testing.expectEqual(@as(isize, 5), lines[1].items[1].visibleColumn);
    try std.testing.expect(std.mem.startsWith(u8, lines[1].items[1].className, "bracket-indent-guide"));
    // Bracket guides on the line disable the default active indent highlight.
    try std.testing.expect(std.mem.indexOf(u8, lines[1].items[0].className, "indent-active") == null);
}

test "bracket pairs: stable ids keep pairings after an incremental edit" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{ .{ "(", ")" }, .{ "[", "]" } };
    var fixture = try Fixture.init(allocator, "[a)", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    try fixture.ctx.applyEdit(Range.init(1, 1, 1, 1), "(");
    fixture.ctx.model.forceTokenization(fixture.ctx.model.getLineCount());
    try fixture.ctx.model.bracketPairs().updateNow();

    var pairs = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer pairs.deinit();

    var found_parentheses = false;
    for (pairs.items) |pair| {
        if (std.mem.eql(u8, pair.openingBracket, "(") and pair.closingBracket != null and std.mem.eql(u8, pair.closingBracket.?, ")")) {
            found_parentheses = true;
        }
    }
    try std.testing.expect(found_parentheses);
}

test "bracket pairs: a configuration change invalidates the tree" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "{}", null);
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);
    try fixture.ctx.model.bracketPairs().updateNow();

    var before = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 0), before.items.len);

    var brackets = [_]CharacterPair{.{ "{", "}" }};
    try fixture.ctx.languageService.registerLanguageConfiguration(languageId, makeConfig(&brackets, &brackets));

    var after = try fixture.ctx.model.getBracketPairsInRange(fixture.ctx.model.getFullModelRange());
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.items.len);
}

test "bracket pairs: matching uses the AST when colorization is disabled" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "{", "}" }};
    var fixture = try Fixture.init(allocator, "{}", makeConfig(&brackets, &brackets));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);

    fixture.ctx.model.updateOptions(.{
        .tabSize = null,
        .indentSize = null,
        .insertSpaces = null,
        .trimAutoWhitespace = null,
        .bracketColorizationOptions = .{ .enabled = false, .independentColorPoolPerBracketType = false },
    });

    try std.testing.expect(!fixture.ctx.model.bracketPairs().useFallbackMatcher());
}

test "bracket pairs: colorized levels use colorizedBracketPairs relations" {
    const allocator = std.testing.allocator;
    var brackets = [_]CharacterPair{.{ "<", ">" }};
    var colorized = [_]CharacterPair{ .{ "{", "}" }, .{ "[", "]" }, .{ "(", ")" } };
    var fixture = try Fixture.init(allocator, " {} [<()>] <{>} ", makeConfig(&brackets, &colorized));
    defer fixture.deinit();
    fixture.ctx.model.forceTokenization(1);
    try fixture.ctx.model.bracketPairs().updateNow();
    const full = fixture.ctx.model.getFullModelRange();

    var only_colorized = try fixture.ctx.model.getBracketsInRange(full, true);
    defer only_colorized.deinit();
    const expected_colorized = [_]struct { start: usize, end: usize, level: isize }{
        .{ .start = 2, .end = 3, .level = 0 },
        .{ .start = 3, .end = 4, .level = 0 },
        .{ .start = 5, .end = 6, .level = 0 },
        .{ .start = 7, .end = 8, .level = 1 },
        .{ .start = 8, .end = 9, .level = 1 },
        .{ .start = 10, .end = 11, .level = 0 },
        .{ .start = 13, .end = 14, .level = 0 },
        .{ .start = 15, .end = 16, .level = -1 },
    };
    try std.testing.expectEqual(expected_colorized.len, only_colorized.items.len);
    for (expected_colorized, only_colorized.items) |expected, actual| {
        try std.testing.expectEqual(expected.start, actual.range.startColumn);
        try std.testing.expectEqual(expected.end, actual.range.endColumn);
        try std.testing.expectEqual(expected.level, actual.nestingLevel);
    }

    var all = try fixture.ctx.model.getBracketsInRange(full, false);
    defer all.deinit();
    const expected_all = [_]struct { start: usize, end: usize, level: isize }{
        .{ .start = 2, .end = 3, .level = 0 },
        .{ .start = 3, .end = 4, .level = 0 },
        .{ .start = 5, .end = 6, .level = 0 },
        .{ .start = 6, .end = 7, .level = 1 },
        .{ .start = 7, .end = 8, .level = 2 },
        .{ .start = 8, .end = 9, .level = 2 },
        .{ .start = 9, .end = 10, .level = 1 },
        .{ .start = 10, .end = 11, .level = 0 },
        .{ .start = 12, .end = 13, .level = 0 },
        .{ .start = 13, .end = 14, .level = 1 },
        .{ .start = 14, .end = 15, .level = 0 },
        .{ .start = 15, .end = 16, .level = -1 },
    };
    try std.testing.expectEqual(expected_all.len, all.items.len);
    for (expected_all, all.items) |expected, actual| {
        try std.testing.expectEqual(expected.start, actual.range.startColumn);
        try std.testing.expectEqual(expected.end, actual.range.endColumn);
        try std.testing.expectEqual(expected.level, actual.nestingLevel);
    }
}

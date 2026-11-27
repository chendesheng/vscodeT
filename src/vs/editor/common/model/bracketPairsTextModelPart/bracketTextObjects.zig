// Deliberate Zig addition, not a VS Code upstream port.
//
// Shared bracket text-object lookup for the native Vim and Helix engines. All
// matching comes from the ported `BracketPairsTextModelPart` (the same
// token-aware AST used by VS Code bracket matching, colorization and guides):
// this module only walks outward from the innermost pair to the requested
// bracket type and converts the bracket ranges into inside/around ranges. It
// never scans document text for brackets.
const std = @import("std");
const TextModel = @import("../textModel.zig").TextModel;
const Position = @import("../../core/position.zig").Position;
const Range = @import("../../core/range.zig").Range;

/// The opening and closing bracket ranges of one pair.
pub const Pair = struct {
    open: Range,
    close: Range,

    /// Text between the brackets, excluding both bracket tokens.
    pub fn inside(self: Pair) Range {
        return Range.init(self.open.endLineNumber, self.open.endColumn, self.close.startLineNumber, self.close.startColumn);
    }

    /// Both brackets and the text between them.
    pub fn around(self: Pair) Range {
        return Range.init(self.open.startLineNumber, self.open.startColumn, self.close.endLineNumber, self.close.endColumn);
    }
};

/// The innermost bracket pair at `position`: the pair whose bracket token
/// contains the position, or else the innermost pair that encloses it.
pub fn closest(model: *TextModel, position: Position) ?Pair {
    const brackets = model.bracketPairs();
    const found = brackets.matchBracket(position, null) orelse
        brackets.findEnclosingBrackets(position, null) orelse return null;
    return .{ .open = found[0], .close = found[1] };
}

/// The innermost pair of the requested type that contains `position`.
///
/// `matchBracket`/`findEnclosingBrackets` return the innermost pair of any
/// type. When that pair has a different bracket text, walk outward through the
/// enclosing pairs until the requested type is found. Requiring the next
/// opening start to be strictly earlier guarantees termination.
pub fn ofType(model: *TextModel, position: Position, open_text: []const u8, close_text: []const u8) !?Pair {
    const brackets = model.bracketPairs();
    var candidate = brackets.matchBracket(position, null) orelse brackets.findEnclosingBrackets(position, null);
    while (candidate) |range_pair| {
        if (try pairMatches(model, range_pair, open_text, close_text)) {
            return .{ .open = range_pair[0], .close = range_pair[1] };
        }
        const outside = range_pair[0].getStartPosition();
        const next = brackets.findEnclosingBrackets(outside, null) orelse return null;
        if (!next[0].getStartPosition().isBefore(outside)) return null;
        candidate = next;
    }
    return null;
}

fn pairMatches(model: *TextModel, pair: [2]Range, open_text: []const u8, close_text: []const u8) !bool {
    if (!try rangeEquals(model, pair[0], open_text)) return false;
    return rangeEquals(model, pair[1], close_text);
}

fn rangeEquals(model: *TextModel, range: Range, text: []const u8) !bool {
    var value = try model.getValueInRange(range, null);
    defer value.deinit();
    return std.mem.eql(u8, value.items, text);
}

const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
const language_configuration = @import("../../languages/languageConfiguration.zig");

const test_language_id = "bracketTextObjectsTestLanguage";
var default_brackets = [_]language_configuration.CharacterPair{
    .{ "(", ")" },
    .{ "[", "]" },
    .{ "{", "}" },
};
var angle_brackets = [_]language_configuration.CharacterPair{
    .{ "(", ")" },
    .{ "[", "]" },
    .{ "{", "}" },
    .{ "<", ">" },
};

fn testModel(allocator: std.mem.Allocator, text: []const u8, brackets: []language_configuration.CharacterPair) !TestModel {
    var ctx = try TestModel.init(allocator, text, test_language_id);
    errdefer ctx.deinit();
    var config = language_configuration.empty();
    config.brackets = brackets;
    try ctx.languageService.registerLanguageConfiguration(test_language_id, config);
    return ctx;
}

test "bracketTextObjects: closest pair and inside/around ranges" {
    const allocator = std.testing.allocator;
    const text = "f(a, (b), c)";
    var ctx = try testModel(allocator, text, &default_brackets);
    defer ctx.deinit();

    const inner = closest(ctx.model, Position.init(1, 7)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position.init(1, 6), inner.open.startPosition());
    try std.testing.expectEqual(Position.init(1, 8), inner.close.startPosition());
    try std.testing.expectEqual(Position.init(1, 7), inner.inside().startPosition());
    try std.testing.expectEqual(Position.init(1, 8), inner.inside().getEndPosition());
    try std.testing.expectEqual(Position.init(1, 6), inner.around().startPosition());
    try std.testing.expectEqual(Position.init(1, 9), inner.around().getEndPosition());

    const outer = closest(ctx.model, Position.init(1, 3)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position.init(1, 2), outer.open.startPosition());
    try std.testing.expectEqual(Position.init(1, 12), outer.close.startPosition());
    try std.testing.expectEqual(Position.init(1, 3), outer.inside().startPosition());
    try std.testing.expectEqual(Position.init(1, 12), outer.inside().getEndPosition());
}

test "bracketTextObjects: typed lookup walks outward through other bracket types" {
    const allocator = std.testing.allocator;
    var ctx = try testModel(allocator, "f([a])", &default_brackets);
    defer ctx.deinit();

    const parens = (try ofType(ctx.model, Position.init(1, 4), "(", ")")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position.init(1, 2), parens.open.startPosition());
    try std.testing.expectEqual(Position.init(1, 6), parens.close.startPosition());
    var parens_inside = try ctx.model.getValueInRange(parens.inside(), null);
    defer parens_inside.deinit();
    try std.testing.expectEqualStrings("[a]", parens_inside.items);

    const brackets = (try ofType(ctx.model, Position.init(1, 4), "[", "]")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position.init(1, 3), brackets.open.startPosition());
    try std.testing.expectEqual(Position.init(1, 5), brackets.close.startPosition());
    var brackets_inside = try ctx.model.getValueInRange(brackets.inside(), null);
    defer brackets_inside.deinit();
    try std.testing.expectEqualStrings("a", brackets_inside.items);

    try std.testing.expect(try ofType(ctx.model, Position.init(1, 4), "{", "}") == null);

    // Cursor on the inner opening bracket still finds the outer requested pair.
    const from_bracket = (try ofType(ctx.model, Position.init(1, 3), "(", ")")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position.init(1, 2), from_bracket.open.startPosition());
    try std.testing.expectEqual(Position.init(1, 6), from_bracket.close.startPosition());
}

test "bracketTextObjects: typed lookup follows the language bracket configuration" {
    const allocator = std.testing.allocator;
    var with_angle = try testModel(allocator, "f(<a>)", &angle_brackets);
    defer with_angle.deinit();
    const angle = (try ofType(with_angle.model, Position.init(1, 4), "<", ">")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position.init(1, 3), angle.open.startPosition());
    try std.testing.expectEqual(Position.init(1, 5), angle.close.startPosition());

    var without_angle = try testModel(allocator, "f(<a>)", &default_brackets);
    defer without_angle.deinit();
    try std.testing.expect(try ofType(without_angle.model, Position.init(1, 4), "<", ">") == null);
}

test "bracketTextObjects: multiline and empty pairs" {
    const allocator = std.testing.allocator;
    var multiline = try testModel(allocator, "f(\n  a\n)", &default_brackets);
    defer multiline.deinit();
    const pair = (try ofType(multiline.model, Position.init(2, 3), "(", ")")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position.init(1, 3), pair.inside().startPosition());
    try std.testing.expectEqual(Position.init(3, 1), pair.inside().getEndPosition());
    try std.testing.expectEqual(Position.init(1, 2), pair.around().startPosition());
    try std.testing.expectEqual(Position.init(3, 2), pair.around().getEndPosition());

    var empty = try testModel(allocator, "()", &default_brackets);
    defer empty.deinit();
    const empty_pair = closest(empty.model, Position.init(1, 2)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(empty_pair.inside().isEmpty());
    try std.testing.expectEqual(Position.init(1, 2), empty_pair.inside().startPosition());
    try std.testing.expectEqual(Position.init(1, 1), empty_pair.around().startPosition());
    try std.testing.expectEqual(Position.init(1, 3), empty_pair.around().getEndPosition());
}

test "bracketTextObjects: unclosed and unmatched brackets return null" {
    const allocator = std.testing.allocator;
    var unclosed = try testModel(allocator, "f(a", &default_brackets);
    defer unclosed.deinit();
    try std.testing.expect(try ofType(unclosed.model, Position.init(1, 3), "(", ")") == null);

    var unmatched = try testModel(allocator, "a) b", &default_brackets);
    defer unmatched.deinit();
    try std.testing.expect(try ofType(unmatched.model, Position.init(1, 3), "(", ")") == null);
}

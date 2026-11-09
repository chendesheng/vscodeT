const std = @import("std");
const ArrayList = std.array_list.Managed;

const Position = @import("../../../../common/core/position.zig").Position;
const Range = @import("../../../../common/core/range.zig").Range;
const Selection = @import("../../../../common/core/selection.zig").Selection;
const language_configuration = @import("../../../../common/languages/languageConfiguration.zig");
const TokenizationRegistry = @import("../../../../common/tokenizationRegistry.zig").TokenizationRegistry;
const languages = @import("../../../../common/languages.zig");
const TokenPacked = @import("../../../../common/tokens/lineTokens.zig").TokenPacked;
const TokenMetadata = @import("../../../../common/encodedTokenAttributes.zig").TokenMetadata;
const StandardTokenType = @import("../../../../common/encodedTokenAttributes.zig").StandardTokenType;
const NullState = @import("../../../../common/languages/nullTokenize.zig").NullState;

const bracketMatching = @import("../../../../contrib/bracketMatching/browser/bracketMatching.zig");
const BracketMatchingController = bracketMatching.BracketMatchingController;
const TestModel = @import("../../port/testSupport.zig").TestModel;

const language_id = "bracketMatchingTestLanguage";

var test_brackets = [_]language_configuration.CharacterPair{
    .{ "{", "}" },
    .{ "[", "]" },
    .{ "(", ")" },
};

const BracketSupport = struct {
    fn getInitialState(_: *anyopaque, _: std.mem.Allocator) anyerror!languages.IState {
        return NullState;
    }

    fn tokenizeEncoded(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        line: []const u8,
        hasEOL: bool,
        state: languages.IState,
    ) anyerror!languages.EncodedTokenizationResult {
        _ = hasEOL;
        if (line.len == 0) {
            return .{ .tokens = try allocator.alloc(TokenPacked, 0), .endState = state };
        }
        var tokens = try allocator.alloc(TokenPacked, 1);
        var metadata = TokenMetadata.default;
        metadata.tokenType = StandardTokenType.Other;
        metadata.balancedBrackets = true;
        tokens[0] = .{ .endOffset = @intCast(line.len), .metadata = metadata };
        return .{ .tokens = tokens, .endState = state };
    }

    fn interface(self: *BracketSupport) languages.ITokenizationSupport {
        return .{
            .context = self,
            .vtable = &.{
                .getInitialState = getInitialState,
                .tokenizeEncoded = tokenizeEncoded,
            },
        };
    }
};

const Fixture = struct {
    ctx: TestModel,
    controller: BracketMatchingController,
    support: *BracketSupport,

    fn init(allocator: std.mem.Allocator, text: []const u8) !Fixture {
        const support = try allocator.create(BracketSupport);
        support.* = .{};
        errdefer allocator.destroy(support);

        try TokenizationRegistry.instance.register(language_id, support.interface());
        errdefer TokenizationRegistry.instance.unregister(language_id);

        var ctx = try TestModel.init(allocator, text, language_id);
        errdefer ctx.deinit();

        var config = language_configuration.empty();
        config.brackets = &test_brackets;
        try ctx.languageService.registerLanguageConfiguration(language_id, config);

        return .{
            .ctx = ctx,
            .controller = BracketMatchingController.init(allocator, ctx.model),
            .support = support,
        };
    }

    fn deinit(self: *Fixture) void {
        self.controller.deinit();
        self.ctx.deinit();
        TokenizationRegistry.instance.unregister(language_id);
        self.ctx.allocator.destroy(self.support);
    }

    fn removeBracketsAt(self: *Fixture, position: Position) !void {
        const pair = self.controller.removeBracketsForSelection(Selection.init(position.lineNumber, position.column, position.lineNumber, position.column)) orelse return;
        try self.ctx.applyEdits(&[_]@import("../../port/testSupport.zig").Edit{
            .{ .range = pair[0], .text = "" },
            .{ .range = pair[1], .text = "" },
        });
    }
};

fn expectSelection(actual: ?Selection, expected: Selection) !void {
    if (actual == null) {
        std.debug.print("bracket selection: expected ({d},{d})->({d},{d}), got null\n", .{ expected.selectionStartLineNumber, expected.selectionStartColumn, expected.positionLineNumber, expected.positionColumn });
        return error.TestUnexpectedResult;
    }
    if (!expected.equalsSelection(&actual.?)) {
        std.debug.print("bracket selection: expected ({d},{d})->({d},{d}), actual ({d},{d})->({d},{d})\n", .{
            expected.selectionStartLineNumber, expected.selectionStartColumn, expected.positionLineNumber, expected.positionColumn,
            actual.?.selectionStartLineNumber, actual.?.selectionStartColumn, actual.?.positionLineNumber, actual.?.positionColumn,
        });
        return error.TestUnexpectedResult;
    }
}

test "bracket matching: jump to matching bracket position" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "var x = (3 + (5-7)) + ((5+3)+5);");
    defer fixture.deinit();

    var selection = Selection.init(1, 20, 1, 20);
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 9, 1, 9));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 19, 1, 19));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 9, 1, 9));

    selection = Selection.init(1, 23, 1, 23);
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 31, 1, 31));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 23, 1, 23));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 31, 1, 31));
}

test "bracket matching: jump to next bracket" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "var x = (3 + (5-7)); y();");
    defer fixture.deinit();

    var selection = Selection.init(1, 16, 1, 16);
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 18, 1, 18));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 14, 1, 14));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 18, 1, 18));

    selection = Selection.init(1, 21, 1, 21);
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 23, 1, 23));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 24, 1, 24));
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 23, 1, 23));

    selection = Selection.init(1, 26, 1, 26);
    selection = fixture.controller.jumpToBracket(selection).?;
    try expectSelection(selection, Selection.init(1, 26, 1, 26));
}

test "bracket matching: select to next bracket" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "var x = (3 + (5-7)); y();");
    defer fixture.deinit();

    try expectSelection(fixture.controller.selectToBracketForSelection(Selection.init(1, 9, 1, 9), true), Selection.init(1, 9, 1, 20));
    try expectSelection(fixture.controller.selectToBracketForSelection(Selection.init(1, 20, 1, 20), true), Selection.init(1, 20, 1, 9));
    try expectSelection(fixture.controller.selectToBracketForSelection(Selection.init(1, 16, 1, 16), true), Selection.init(1, 14, 1, 19));
    try expectSelection(fixture.controller.selectToBracketForSelection(Selection.init(1, 21, 1, 21), true), Selection.init(1, 23, 1, 25));
    try std.testing.expect(fixture.controller.selectToBracketForSelection(Selection.init(1, 26, 1, 26), true) == null);
}

test "bracket matching: jump to enclosing brackets" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(
        allocator,
        "const x = {\n    something: [0, 1, 2],\n    another: true,\n    somethingmore: [0, 2, 4]\n};",
    );
    defer fixture.deinit();

    const selection = fixture.controller.jumpToBracket(Selection.init(3, 5, 3, 5)).?;
    try std.testing.expect(selection.equalsSelection(&Selection.init(5, 1, 5, 1)));
}

test "bracket matching: select to bracket can exclude brackets" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(
        allocator,
        "const x = {\n    something: [0, 1, 2],\n    another: true,\n    somethingmore: [0, 2, 4]\n};",
    );
    defer fixture.deinit();

    const selection = fixture.controller.selectToBracketForSelection(Selection.init(3, 5, 3, 5), false).?;
    try std.testing.expect(selection.equalsSelection(&Selection.init(1, 12, 5, 1)));
}

test "bracket matching: select with multicursor" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "{  }   {   }   { }");
    defer fixture.deinit();

    const selections = [_]Selection{
        Selection.init(1, 3, 1, 3),
        Selection.init(1, 10, 1, 10),
        Selection.init(1, 17, 1, 17),
    };
    const selected = (try fixture.controller.selectToBracket(&selections, true)).?;
    defer allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 3), selected.len);
    try std.testing.expect(selected[0].equalsSelection(&Selection.init(1, 1, 1, 5)));
    try std.testing.expect(selected[1].equalsSelection(&Selection.init(1, 8, 1, 13)));
    try std.testing.expect(selected[2].equalsSelection(&Selection.init(1, 16, 1, 19)));
}

test "bracket matching: remove brackets" {
    const allocator = std.testing.allocator;

    {
        var fixture = try Fixture.init(allocator, "var x = (3 + (5-7)); y();");
        defer fixture.deinit();
        try fixture.removeBracketsAt(Position.init(1, 9));
        const value = try fixture.ctx.model.getValue(.TextDefined, false);
        defer value.deinit();
        try std.testing.expectEqualStrings("var x = 3 + (5-7); y();", value.items);
    }

    {
        var fixture = try Fixture.init(allocator, "var x = (3 + (5-7)); y();");
        defer fixture.deinit();
        try fixture.removeBracketsAt(Position.init(1, 16));
        const value = try fixture.ctx.model.getValue(.TextDefined, false);
        defer value.deinit();
        try std.testing.expectEqualStrings("var x = (3 + 5-7); y();", value.items);
        try fixture.removeBracketsAt(Position.init(1, 10));
        const value2 = try fixture.ctx.model.getValue(.TextDefined, false);
        defer value2.deinit();
        try std.testing.expectEqualStrings("var x = 3 + 5-7; y();", value2.items);
        try fixture.removeBracketsAt(Position.init(1, 9));
        const value3 = try fixture.ctx.model.getValue(.TextDefined, false);
        defer value3.deinit();
        try std.testing.expectEqualStrings("var x = 3 + 5-7; y();", value3.items);
    }
}

test "bracket matching: updateBrackets caches and only matches collapsed selections" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator, "(a)");
    defer fixture.deinit();

    const selections = [_]Selection{Selection.init(1, 2, 1, 2)};
    const data = try fixture.controller.updateBrackets(&selections);
    try std.testing.expectEqual(@as(usize, 1), data.len);
    try std.testing.expect(data[0].brackets != null);
    try std.testing.expectEqual(bracketMatching.DecorationKind.with_overview_ruler, data[0].options);

    const non_empty = [_]Selection{Selection.init(1, 1, 1, 2)};
    const data2 = try fixture.controller.updateBrackets(&non_empty);
    try std.testing.expectEqual(@as(usize, 0), data2.len);
}
